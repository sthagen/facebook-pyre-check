/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Display;
use std::sync::Arc;

use dupe::Dupe;
use ruff_python_ast::name::Name;
use ruff_python_ast::Arguments;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprCall;
use ruff_python_ast::Identifier;
use ruff_python_ast::StmtClassDef;
use ruff_text_size::TextRange;
use starlark_map::small_map::SmallMap;
use starlark_map::small_set::SmallSet;

use crate::alt::answers::AnswersSolver;
use crate::alt::answers::LookupAnswer;
use crate::alt::attr::Attribute;
use crate::alt::attr::NoAccessReason;
use crate::alt::types::class_metadata::ClassMetadata;
use crate::alt::types::class_metadata::EnumMetadata;
use crate::binding::binding::ClassFieldInitialValue;
use crate::binding::binding::KeyClassField;
use crate::binding::binding::KeyClassMetadata;
use crate::binding::binding::KeyClassSynthesizedFields;
use crate::binding::binding::KeyLegacyTypeParam;
use crate::dunder;
use crate::error::collector::ErrorCollector;
use crate::error::style::ErrorStyle;
use crate::graph::index::Idx;
use crate::types::annotation::Annotation;
use crate::types::callable::BoolKeywords;
use crate::types::callable::CallableKind;
use crate::types::callable::DataclassKeywords;
use crate::types::callable::Param;
use crate::types::callable::Required;
use crate::types::class::Class;
use crate::types::class::ClassFieldProperties;
use crate::types::class::ClassType;
use crate::types::class::TArgs;
use crate::types::literal::Lit;
use crate::types::tuple::Tuple;
use crate::types::typed_dict::TypedDict;
use crate::types::types::BoundMethod;
use crate::types::types::CalleeKind;
use crate::types::types::Decoration;
use crate::types::types::TParams;
use crate::types::types::Type;
use crate::util::display::count;
use crate::util::prelude::SliceExt;

/// Correctly analyzing which attributes are visible on class objects, as well
/// as handling method binding correctly, requires distinguishing which fields
/// are assigned values in the class body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClassFieldInitialization {
    /// If this is a dataclass field, BoolKeywords stores the field's dataclass properties.
    Class(Option<BoolKeywords>),
    Instance,
}

impl Display for ClassFieldInitialization {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Class(_) => write!(f, "initialized in body"),
            Self::Instance => write!(f, "not initialized in body"),
        }
    }
}

impl ClassFieldInitialization {
    pub fn recursive() -> Self {
        ClassFieldInitialization::Class(None)
    }
}

/// Raw information about an attribute declared somewhere in a class. We need to
/// know whether it is initialized in the class body in order to determine
/// both visibility rules and whether method binding should be performed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassField(pub ClassFieldInner);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassFieldInner {
    Simple {
        ty: Type,
        annotation: Option<Annotation>,
        initialization: ClassFieldInitialization,
        readonly: bool,
    },
}

impl ClassField {
    fn new(
        ty: Type,
        annotation: Option<Annotation>,
        initialization: ClassFieldInitialization,
        readonly: bool,
    ) -> Self {
        Self(ClassFieldInner::Simple {
            ty,
            annotation,
            initialization,
            readonly,
        })
    }

    pub fn recursive() -> Self {
        Self(ClassFieldInner::Simple {
            ty: Type::any_implicit(),
            annotation: None,
            initialization: ClassFieldInitialization::recursive(),
            readonly: false,
        })
    }

    pub fn visit_type_mut(&mut self, mut f: &mut dyn FnMut(&mut Type)) {
        match &mut self.0 {
            ClassFieldInner::Simple { ty, annotation, .. } => {
                f(ty);
                for a in annotation.iter_mut() {
                    a.visit_type_mut(&mut f);
                }
            }
        }
    }

    fn initialization(&self) -> ClassFieldInitialization {
        match &self.0 {
            ClassFieldInner::Simple { initialization, .. } => initialization.clone(),
        }
    }

    fn instantiate_for(&self, cls: &ClassType) -> Self {
        match &self.0 {
            ClassFieldInner::Simple {
                ty,
                annotation,
                initialization,
                readonly,
            } => Self(ClassFieldInner::Simple {
                ty: cls.instantiate_member(ty.clone()),
                annotation: annotation.clone(),
                initialization: initialization.clone(),
                readonly: *readonly,
            }),
        }
    }

    pub fn as_param(self, name: &Name, default: bool, kw_only: bool) -> Param {
        let ClassField(ClassFieldInner::Simple { ty, .. }) = self;
        let required = match default {
            true => Required::Optional,
            false => Required::Required,
        };
        if kw_only {
            Param::KwOnly(name.clone(), ty, required)
        } else {
            Param::Pos(name.clone(), ty, required)
        }
    }

    fn depends_on_class_type_parameter(&self, cls: &Class) -> bool {
        let tparams = cls.tparams();
        let mut qs = SmallSet::new();
        match &self.0 {
            ClassFieldInner::Simple { ty, .. } => ty.collect_quantifieds(&mut qs),
        };
        tparams.quantified().any(|q| qs.contains(&q))
    }

    fn as_raw_special_method_type(self, cls: &ClassType) -> Option<Type> {
        match self.instantiate_for(cls).0 {
            ClassFieldInner::Simple { ty, .. } => match self.initialization() {
                ClassFieldInitialization::Class(_) => Some(ty),
                ClassFieldInitialization::Instance => None,
            },
        }
    }

    fn as_special_method_type(self, cls: &ClassType) -> Option<Type> {
        self.as_raw_special_method_type(cls).and_then(|ty| {
            if is_unbound_function(&ty) {
                Some(make_bound_method(cls.self_type(), ty))
            } else {
                None
            }
        })
    }

    fn as_instance_attribute(self, cls: &ClassType) -> Attribute {
        match self.instantiate_for(cls).0 {
            ClassFieldInner::Simple { ty, readonly, .. } => match self.initialization() {
                ClassFieldInitialization::Class(_) => bind_instance_attribute(cls, ty),
                ClassFieldInitialization::Instance if readonly => Attribute::read_only(ty),
                ClassFieldInitialization::Instance => Attribute::read_write(ty),
            },
        }
    }

    fn as_class_attribute(self, cls: &Class) -> Attribute {
        match &self.0 {
            ClassFieldInner::Simple {
                initialization: ClassFieldInitialization::Instance,
                ..
            } => Attribute::no_access(NoAccessReason::ClassUseOfInstanceAttribute(cls.clone())),
            ClassFieldInner::Simple {
                initialization: ClassFieldInitialization::Class(_),
                ty,
                ..
            } => {
                if self.depends_on_class_type_parameter(cls) {
                    Attribute::no_access(NoAccessReason::ClassAttributeIsGeneric(cls.clone()))
                } else {
                    bind_class_attribute(cls, ty.clone())
                }
            }
        }
    }
}

fn is_unbound_function(ty: &Type) -> bool {
    match ty {
        Type::Forall(_, t) => is_unbound_function(t),
        Type::Callable(_, _) => true,
        Type::Overload(_) => true,
        _ => false,
    }
}

fn bind_class_attribute(cls: &Class, attr: Type) -> Attribute {
    match attr {
        Type::Decoration(Decoration::StaticMethod(box attr)) => Attribute::read_write(attr),
        Type::Decoration(Decoration::ClassMethod(box attr)) => {
            Attribute::read_write(make_bound_method(Type::ClassDef(cls.dupe()), attr))
        }
        // Accessing a property descriptor on the class gives the property itself,
        // with no magic access rules at runtime.
        p @ Type::Decoration(Decoration::Property(_)) => Attribute::read_write(p),
        attr => Attribute::read_write(attr),
    }
}

fn bind_instance_attribute(cls: &ClassType, attr: Type) -> Attribute {
    match attr {
        Type::Decoration(Decoration::StaticMethod(box attr)) => Attribute::read_write(attr),
        Type::Decoration(Decoration::ClassMethod(box attr)) => Attribute::read_write(
            make_bound_method(Type::ClassDef(cls.class_object().dupe()), attr),
        ),
        Type::Decoration(Decoration::Property(box (getter, setter))) => Attribute::property(
            make_bound_method(Type::ClassType(cls.clone()), getter),
            setter.map(|setter| make_bound_method(Type::ClassType(cls.clone()), setter)),
            cls.class_object().dupe(),
        ),
        attr => Attribute::read_write(if is_unbound_function(&attr) {
            make_bound_method(cls.self_type(), attr)
        } else {
            attr
        }),
    }
}

fn make_bound_method(obj: Type, attr: Type) -> Type {
    // TODO(stroxler): Think about what happens if `attr` is not callable. This
    // can happen with the current logic if a decorator spits out a non-callable
    // type that gets wrapped in `@classmethod`.
    Type::BoundMethod(Box::new(BoundMethod { obj, func: attr }))
}

impl Display for ClassField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            ClassFieldInner::Simple {
                ty, initialization, ..
            } => write!(f, "@{ty} ({initialization})"),
        }
    }
}

/// Result of looking up a member of a class in the MRO, including a handle to the defining
/// class which may be some ancestor.
///
/// For example, given `class A: x: int; class B(A): pass`, the defining class
/// for attribute `x` is `A` even when `x` is looked up on `B`.
#[derive(Debug)]
pub struct WithDefiningClass<T> {
    pub value: T,
    defining_class: Class,
}

impl<T> WithDefiningClass<T> {
    fn defined_on(&self, cls: &Class) -> bool {
        self.defining_class == *cls
    }
}

impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    pub fn class_definition(
        &self,
        x: &StmtClassDef,
        fields: SmallMap<Name, ClassFieldProperties>,
        bases: &[Expr],
        legacy_tparams: &[Idx<KeyLegacyTypeParam>],
        errors: &ErrorCollector,
    ) -> Class {
        let scoped_tparams = self.scoped_type_params(x.type_params.as_deref(), errors);
        let bases = bases.map(|x| self.base_class_of(x, errors));
        let tparams = self.class_tparams(&x.name, scoped_tparams, bases, legacy_tparams, errors);
        Class::new(
            x.name.clone(),
            self.module_info().dupe(),
            tparams,
            fields.clone(),
        )
    }

    pub fn functional_class_definition(
        &self,
        name: &Identifier,
        fields: &SmallMap<Name, ClassFieldProperties>,
    ) -> Class {
        Class::new(
            name.clone(),
            self.module_info().dupe(),
            TParams::default(),
            fields.clone(),
        )
    }

    pub fn get_metadata_for_class(&self, cls: &Class) -> Arc<ClassMetadata> {
        self.get_from_class(cls, &KeyClassMetadata(cls.short_identifier()))
    }

    fn get_enum_from_class(&self, cls: &Class) -> Option<EnumMetadata> {
        self.get_metadata_for_class(cls).enum_metadata().cloned()
    }

    pub fn get_enum_from_class_type(&self, class_type: &ClassType) -> Option<EnumMetadata> {
        self.get_enum_from_class(class_type.class_object())
    }

    fn check_and_create_targs(
        &self,
        cls: &Class,
        targs: Vec<Type>,
        range: TextRange,
        errors: &ErrorCollector,
    ) -> TArgs {
        let tparams = cls.tparams();
        let nargs = targs.len();
        let mut checked_targs = Vec::new();
        let mut targ_idx = 0;
        for (param_idx, param) in tparams.iter().enumerate() {
            if param.quantified.is_type_var_tuple() && targs.get(targ_idx).is_some() {
                let n_remaining_params = tparams.len() - param_idx - 1;
                let n_remaining_args = nargs - targ_idx;
                let mut prefix = Vec::new();
                let mut middle = Vec::new();
                let mut suffix = Vec::new();
                let args_to_consume = n_remaining_args.saturating_sub(n_remaining_params);
                for _ in 0..args_to_consume {
                    match targs.get(targ_idx) {
                        Some(Type::Unpack(box Type::Tuple(Tuple::Concrete(elts)))) => {
                            if middle.is_empty() {
                                prefix.extend(elts.clone());
                            } else {
                                suffix.extend(elts.clone());
                            }
                        }
                        Some(Type::Unpack(box t)) => {
                            if !suffix.is_empty() {
                                middle.push(Type::Tuple(Tuple::Unbounded(Box::new(
                                    self.unions(suffix),
                                ))));
                                suffix = Vec::new();
                            } else {
                                middle.push(t.clone())
                            }
                        }
                        Some(arg) => {
                            if middle.is_empty() {
                                prefix.push(arg.clone());
                            } else {
                                suffix.push(arg.clone());
                            }
                        }
                        _ => {}
                    }
                    targ_idx += 1;
                }
                let tuple_type = match middle.as_slice() {
                    [] => Type::tuple(prefix),
                    [middle] => Tuple::unpacked(prefix, middle.clone(), suffix),
                    // We can't precisely model unpacking two unbounded iterables, so we'll keep any
                    // concrete prefix and suffix elements and merge everything in between into an unbounded tuple
                    _ => {
                        let middle_types: Vec<Type> = middle
                            .iter()
                            .map(|t| {
                                self.unwrap_iterable(t)
                                    .unwrap_or(self.stdlib.object_class_type().clone().to_type())
                            })
                            .collect();
                        Tuple::unpacked(
                            prefix,
                            Type::Tuple(Tuple::Unbounded(Box::new(self.unions(middle_types)))),
                            suffix,
                        )
                    }
                };
                checked_targs.push(tuple_type);
            } else if param.quantified.is_type_var_tuple() {
                checked_targs.push(Type::any_tuple())
            } else if let Some(arg) = targs.get(targ_idx) {
                match arg {
                    Type::Unpack(_) => {
                        checked_targs.push(self.error(
                            errors,
                            range,
                            format!(
                                "Unpacked argument cannot be used for type parameter {}.",
                                param.name
                            ),
                        ));
                    }
                    _ => {
                        checked_targs.push(arg.clone());
                    }
                }
                targ_idx += 1;
            } else if let Some(default) = &param.default {
                checked_targs.push(default.clone());
            } else {
                self.error(
                    errors,
                    range,
                    format!(
                        "Expected {} for class `{}`, got {}.",
                        count(tparams.len(), "type argument"),
                        cls.name(),
                        nargs
                    ),
                );
                checked_targs.extend(vec![Type::any_error(); tparams.len().saturating_sub(nargs)]);
                break;
            }
        }
        if targ_idx < nargs {
            self.error(
                errors,
                range,
                format!(
                    "Expected {} for class `{}`, got {}.",
                    count(tparams.len(), "type argument"),
                    cls.name(),
                    nargs
                ),
            );
        }
        TArgs::new(checked_targs)
    }

    pub fn create_default_targs(
        &self,
        cls: &Class,
        // Placeholder for strict mode: we want to force callers to pass a range so
        // that we don't refactor in a way where none is available, but this is unused
        // because we do not have a strict mode yet.
        _range: Option<TextRange>,
    ) -> TArgs {
        let tparams = cls.tparams();
        if tparams.is_empty() {
            TArgs::default()
        } else {
            // TODO(stroxler): We should error here, but the error needs to be
            // configurable in the long run, and also suppressed in dependencies
            // no matter what the configuration is.
            //
            // Our plumbing isn't ready for that yet, so for now we are silently
            // using gradual type arguments.
            TArgs::new(vec![Type::any_error(); tparams.len()])
        }
    }

    fn type_of_instance(&self, cls: &Class, targs: TArgs) -> Type {
        let metadata = self.get_metadata_for_class(cls);
        if metadata.is_typed_dict() {
            let fields = self.sub_typed_dict_fields(cls, &targs);
            Type::TypedDict(Box::new(TypedDict::new(cls.dupe(), targs, fields)))
        } else {
            Type::ClassType(ClassType::new(cls.dupe(), targs))
        }
    }

    /// Given a class or typed dictionary and some (explicit) type arguments, construct a `Type`
    /// that represents the type of an instance of the class or typed dictionary with those `targs`.
    pub fn specialize(
        &self,
        cls: &Class,
        targs: Vec<Type>,
        range: TextRange,
        errors: &ErrorCollector,
    ) -> Type {
        let targs = self.check_and_create_targs(cls, targs, range, errors);
        self.type_of_instance(cls, targs)
    }

    /// Given a class or typed dictionary, create a `Type` that represents to an instance annotated
    /// with the class or typed dictionary's bare name. This will either have empty type arguments if the
    /// class or typed dictionary is not generic, or type arguments populated with gradual types if
    /// it is (e.g. applying an annotation of `list` to a variable means
    /// `list[Any]`).
    ///
    /// We require a range because depending on the configuration we may raise
    /// a type error when a generic class or typed dictionary is promoted using gradual types.
    pub fn promote(&self, cls: &Class, range: TextRange) -> Type {
        let targs = self.create_default_targs(cls, Some(range));
        self.type_of_instance(cls, targs)
    }

    /// Private version of `promote` that does not potentially
    /// raise strict mode errors. Should only be used for unusual scenarios.
    fn promote_silently(&self, cls: &Class) -> Type {
        let targs = self.create_default_targs(cls, None);
        self.type_of_instance(cls, targs)
    }

    pub fn unwrap_class_object_silently(&self, ty: &Type) -> Option<Type> {
        match ty {
            Type::ClassDef(c) => Some(self.promote_silently(c)),
            Type::TypeAlias(ta) => self.unwrap_class_object_silently(&ta.as_value(self.stdlib)),
            _ => None,
        }
    }

    /// Creates a type from the class with fresh variables for its type parameters.
    pub fn instantiate_fresh(&self, cls: &Class) -> Type {
        let qs = cls.tparams().quantified().collect::<Vec<_>>();
        let targs = TArgs::new(qs.map(|q| Type::Quantified(*q)));
        let promoted_cls = Type::type_form(self.type_of_instance(cls, targs));
        self.solver()
            .fresh_quantified(qs.as_slice(), promoted_cls, self.uniques)
            .1
    }

    /// Get an ancestor `ClassType`, in terms of the type parameters of `class`.
    fn get_ancestor(&self, class: &Class, want: &Class) -> Option<ClassType> {
        self.get_metadata_for_class(class)
            .ancestors(self.stdlib)
            .find(|ancestor| ancestor.class_object() == want)
            .cloned()
    }

    /// Is `want` a superclass of `class` in the class hierarchy? Will return `false` if
    /// `want` is a protocol, unless it is explicitly marked as a base class in the MRO.
    pub fn has_superclass(&self, class: &Class, want: &Class) -> bool {
        class == want || self.get_ancestor(class, want).is_some()
    }

    /// Return the type representing `class` upcast to `want`, if `want` is a
    /// supertype of `class` in the class hierarchy. Will return `None` if
    /// `want` is not a superclass, including if `want` is a protocol (unless it
    /// explicitly appears in the MRO).
    pub fn as_superclass(&self, class: &ClassType, want: &Class) -> Option<ClassType> {
        if class.class_object() == want {
            Some(class.clone())
        } else {
            self.get_ancestor(class.class_object(), want)
                .map(|ancestor| ancestor.substitute(&class.substitution()))
        }
    }

    pub fn calculate_class_field(
        &self,
        name: &Name,
        value_ty: &Type,
        annotation: Option<&Annotation>,
        initial_value: &ClassFieldInitialValue,
        class: &Class,
        range: TextRange,
        errors: &ErrorCollector,
    ) -> ClassField {
        let value_ty = if annotation.is_none() && value_ty.is_literal() {
            &value_ty.clone().promote_literals(self.stdlib)
        } else {
            value_ty
        };

        let metadata = self.get_metadata_for_class(class);
        let initialization = self.get_class_field_initialization(&metadata, initial_value);

        let (is_override, value_ty) = match value_ty {
            Type::Decoration(Decoration::Override(ty)) => (true, ty.as_ref()),
            _ => (false, value_ty),
        };

        let value_ty = if let Some(enum_) = metadata.enum_metadata()
            && self.is_valid_enum_member(name, value_ty, &initialization)
        {
            if annotation.is_some() {
                self.error(errors,range, format!("Enum member `{}` may not be annotated directly. Instead, annotate the _value_ attribute.", name));
            }

            if let Some(enum_value_ty) = self.type_of_enum_value(enum_) {
                if !matches!(value_ty, Type::Tuple(_))
                    && !self
                        .solver()
                        .is_subset_eq(value_ty, &enum_value_ty, self.type_order())
                {
                    self.error(errors,range, format!("The value for enum member `{}` must match the annotation of the _value_ attribute.", name));
                }
            }

            &Type::Literal(Lit::Enum(Box::new((
                enum_.cls.clone(),
                name.clone(),
                value_ty.clone(),
            ))))
        } else {
            value_ty
        };
        if metadata.is_typed_dict() && matches!(initialization, ClassFieldInitialization::Class(_))
        {
            self.error(
                errors,
                range,
                format!("TypedDict item `{}` may not be initialized.", name),
            );
        }
        let (ty, ann) = if let Some(ann) = annotation {
            match &ann.ty {
                Some(ty) => (ty, Some(ann)),
                None => (value_ty, Some(ann)),
            }
        } else {
            (value_ty, None)
        };
        let readonly = metadata.dataclass_metadata().map_or(false, |dataclass| {
            dataclass.kws.is_set(&DataclassKeywords::FROZEN)
        });
        let class_field = ClassField::new(ty.clone(), ann.cloned(), initialization, readonly);

        // check if this attribute is compatible with the parent attribute
        let class_type = match class.self_type() {
            Type::ClassType(class_type) => Some(class_type),
            _ => None,
        };

        if let Some(class_type) = class_type {
            let got = class_field.clone().as_instance_attribute(&class_type);

            let metadata = self.get_metadata_for_class(class);
            let parents = metadata.bases_with_metadata();

            let mut parent_attr_found = false;

            for (parent, parent_metadata) in parents {
                // todo zeina: skip dataclasses. Look into them next.
                if metadata.dataclass_metadata().is_some()
                    || parent_metadata.dataclass_metadata().is_some()
                    || (name.starts_with('_') && name.ends_with('_'))
                {
                    continue;
                }

                if let Some(want) = self.type_order().try_lookup_attr(parent.self_type(), name) {
                    parent_attr_found = true;
                    let attr_check = self.is_attr_subset(&got, &want, &mut |got, want| {
                        self.solver().is_subset_eq(got, want, self.type_order())
                    });

                    if !attr_check {
                        self.error(
                            errors,
                            range,
                            format!(
                                "Class member `{}` overrides parent class `{}` in an inconsistent manner",
                                name,
                                parent.name()
                            ),
                        );
                    }
                }
            }
            if is_override && !parent_attr_found {
                self.error(
                    errors,
                    range,
                    format!(
                        "Class member `{}` is marked as an override, but no parent class has a matching attribute",
                        name,
                    ),
                );
            }
        };

        class_field
    }

    fn get_class_field_initialization(
        &self,
        metadata: &ClassMetadata,
        initial_value: &ClassFieldInitialValue,
    ) -> ClassFieldInitialization {
        match initial_value {
            ClassFieldInitialValue::Instance => ClassFieldInitialization::Instance,
            ClassFieldInitialValue::Class(None) => ClassFieldInitialization::Class(None),
            ClassFieldInitialValue::Class(Some(e)) => {
                // If this field was created via a call to a dataclass field specifier, extract field properties from the call.
                if metadata.dataclass_metadata().is_some()
                    && let Expr::Call(ExprCall {
                        range: _,
                        func,
                        arguments: Arguments { keywords, .. },
                    }) = e
                {
                    let mut props = BoolKeywords::new();
                    // We already type-checked this expression as part of computing the type for the ClassField,
                    // so we can ignore any errors encountered here.
                    let ignore_errors = ErrorCollector::new(ErrorStyle::Never);
                    let func_ty = self.expr_infer(func, &ignore_errors);
                    if matches!(
                        func_ty.callee_kind(),
                        Some(CalleeKind::Callable(CallableKind::DataclassField))
                    ) {
                        for kw in keywords {
                            if let Some(id) = &kw.arg
                                && (id.id == DataclassKeywords::DEFAULT.0
                                    || id.id == "default_factory")
                            {
                                props.set(DataclassKeywords::DEFAULT.0, true);
                            } else {
                                let val = self.expr_infer(&kw.value, &ignore_errors);
                                props.set_keyword(kw.arg.as_ref(), val);
                            }
                        }
                    }
                    ClassFieldInitialization::Class(Some(props))
                } else {
                    ClassFieldInitialization::Class(None)
                }
            }
        }
    }

    pub fn get_class_field_non_synthesized(
        &self,
        cls: &Class,
        name: &Name,
    ) -> Option<Arc<ClassField>> {
        if cls.contains(name) {
            let field =
                self.get_from_class(cls, &KeyClassField(cls.short_identifier(), name.clone()));
            Some(field)
        } else {
            None
        }
    }

    pub fn get_class_field(&self, cls: &Class, name: &Name) -> Option<Arc<ClassField>> {
        if let Some(field) = self.get_class_field_non_synthesized(cls, name) {
            Some(field)
        } else {
            let synthesized_fields =
                self.get_from_class(cls, &KeyClassSynthesizedFields(cls.short_identifier()));
            let synth = synthesized_fields.get(name);
            synth.map(|f| f.inner.dupe())
        }
    }

    pub fn get_class_member(
        &self,
        cls: &Class,
        name: &Name,
    ) -> Option<WithDefiningClass<Arc<ClassField>>> {
        if let Some(field) = self.get_class_field(cls, name) {
            Some(WithDefiningClass {
                value: field,
                defining_class: cls.dupe(),
            })
        } else {
            self.get_metadata_for_class(cls)
                .ancestors(self.stdlib)
                .filter_map(|ancestor| {
                    self.get_class_field(ancestor.class_object(), name)
                        .map(|field| WithDefiningClass {
                            value: Arc::new(field.instantiate_for(ancestor)),
                            defining_class: ancestor.class_object().dupe(),
                        })
                })
                .next()
        }
    }

    pub fn get_instance_attribute(&self, cls: &ClassType, name: &Name) -> Option<Attribute> {
        self.get_class_member(cls.class_object(), name)
            .map(|member| Arc::unwrap_or_clone(member.value).as_instance_attribute(cls))
    }

    /// Gets an attribute from a class definition.
    ///
    /// Returns `None` if there is no such attribute, otherwise an `Attribute` object
    /// that describes whether access is allowed and the type if so.
    ///
    /// Access is disallowed for instance-only attributes and for attributes whose
    /// type contains a class-scoped type parameter - e.g., `class A[T]: x: T`.
    pub fn get_class_attribute(&self, cls: &Class, name: &Name) -> Option<Attribute> {
        let member = self.get_class_member(cls, name)?.value;
        Some(Arc::unwrap_or_clone(member).as_class_attribute(cls))
    }

    /// Get the class's `__new__` method.
    ///
    /// This lookup skips normal method binding logic (it behaves like a cross
    /// between a classmethod and a constructor; downstream code handles this
    /// using the raw callable type).
    pub fn get_dunder_new(&self, cls: &ClassType) -> Option<Type> {
        let new_member = self.get_class_member(cls.class_object(), &dunder::NEW)?;
        if new_member.defined_on(self.stdlib.object_class_type().class_object()) {
            // The default behavior of `object.__new__` is already baked into our implementation of
            // class construction; we only care about `__new__` if it is overridden.
            None
        } else {
            Arc::unwrap_or_clone(new_member.value).as_raw_special_method_type(cls)
        }
    }

    /// Get the class's `__init__` method, if we should analyze it
    /// We skip analyzing the call to `__init__` if:
    /// (1) it isn't defined (possible if we've been passed a custom typeshed), or
    /// (2) the class overrides `object.__new__` but not `object.__init__`, in wich case the
    ///     `__init__` call always succeeds at runtime.
    pub fn get_dunder_init(&self, cls: &ClassType, overrides_new: bool) -> Option<Type> {
        let init_method = self.get_class_member(cls.class_object(), &dunder::INIT)?;
        if !(overrides_new
            && init_method.defined_on(self.stdlib.object_class_type().class_object()))
        {
            Arc::unwrap_or_clone(init_method.value).as_special_method_type(cls)
        } else {
            None
        }
    }

    /// Get the metaclass `__call__` method.
    pub fn get_metaclass_dunder_call(&self, cls: &ClassType) -> Option<Type> {
        let metadata = self.get_metadata_for_class(cls.class_object());
        let metaclass = metadata.metaclass()?;
        let attr = self.get_class_member(metaclass.class_object(), &dunder::CALL)?;
        if attr.defined_on(self.stdlib.builtins_type().class_object()) {
            // The behavior of `type.__call__` is already baked into our implementation of constructors,
            // so we can skip analyzing it at the type level.
            None
        } else {
            Arc::unwrap_or_clone(attr.value).as_special_method_type(metaclass)
        }
    }
}
