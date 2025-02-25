/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::sync::Arc;

use dupe::Dupe;
use ruff_python_ast::name::Name;
use ruff_python_ast::Expr;
use ruff_python_ast::Identifier;
use ruff_python_ast::StmtClassDef;
use ruff_text_size::TextRange;
use starlark_map::small_map::SmallMap;

use crate::alt::answers::AnswersSolver;
use crate::alt::answers::LookupAnswer;
use crate::alt::attr::Attribute;
use crate::alt::class::class_field::ClassField;
use crate::alt::class::class_field::WithDefiningClass;
use crate::alt::types::class_metadata::ClassMetadata;
use crate::alt::types::class_metadata::EnumMetadata;
use crate::binding::binding::KeyClassMetadata;
use crate::binding::binding::KeyLegacyTypeParam;
use crate::dunder;
use crate::error::collector::ErrorCollector;
use crate::graph::index::Idx;
use crate::types::class::Class;
use crate::types::class::ClassFieldProperties;
use crate::types::class::ClassType;
use crate::types::class::TArgs;
use crate::types::tuple::Tuple;
use crate::types::typed_dict::TypedDict;
use crate::types::types::TParams;
use crate::types::types::Type;
use crate::util::display::count;
use crate::util::prelude::SliceExt;

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
                            let arg = if arg.is_kind_type_var_tuple() {
                                self.error(
                                    errors,
                                    range,
                                    "TypeVarTuple must be unpacked".to_owned(),
                                )
                            } else {
                                arg.clone()
                            };
                            if middle.is_empty() {
                                prefix.push(arg);
                            } else {
                                suffix.push(arg);
                            }
                        }
                        _ => {}
                    }
                    targ_idx += 1;
                }
                let tuple_type = match middle.as_slice() {
                    [] => Type::tuple(prefix),
                    [middle] => Type::Tuple(Tuple::unpacked(prefix, middle.clone(), suffix)),
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
                        Type::Tuple(Tuple::unpacked(
                            prefix,
                            Type::Tuple(Tuple::Unbounded(Box::new(self.unions(middle_types)))),
                            suffix,
                        ))
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
                        let arg = if arg.is_kind_type_var_tuple() {
                            self.error(errors, range, "TypeVarTuple must be unpacked".to_owned())
                        } else {
                            arg.clone()
                        };
                        checked_targs.push(arg);
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
        range: Option<TextRange>,
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
            TArgs::new(
                tparams
                    .iter()
                    .map(|x| {
                        if let Some(default) = &x.default {
                            default.clone()
                        } else if range.is_some() {
                            Type::any_error()
                        } else {
                            Type::any_implicit()
                        }
                    })
                    .collect(),
            )
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

    /// Version of `promote` that does not potentially raise errors.
    /// Should only be used for unusual scenarios.
    pub fn promote_silently(&self, cls: &Class) -> Type {
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

    pub(in crate::alt::class) fn get_class_member(
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
