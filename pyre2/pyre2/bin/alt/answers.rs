/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Debug;
use std::ops::Deref;
use std::sync::Arc;

use dupe::Dupe;
use ruff_python_ast::name::Name;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprNoneLiteral;
use ruff_python_ast::TypeParam;
use ruff_python_ast::TypeParams;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use starlark_map::ordered_set::OrderedSet;
use starlark_map::small_map::Entry;
use starlark_map::small_map::SmallMap;

use crate::alt::callable::CallArg;
use crate::alt::classes::ClassField;
use crate::ast::Ast;
use crate::binding::binding::Binding;
use crate::binding::binding::BindingAnnotation;
use crate::binding::binding::BindingClassField;
use crate::binding::binding::BindingClassMetadata;
use crate::binding::binding::BindingExpect;
use crate::binding::binding::BindingLegacyTypeParam;
use crate::binding::binding::ContextManagerKind;
use crate::binding::binding::EmptyAnswer;
use crate::binding::binding::FunctionBinding;
use crate::binding::binding::FunctionKind;
use crate::binding::binding::Key;
use crate::binding::binding::KeyAnnotation;
use crate::binding::binding::KeyClassField;
use crate::binding::binding::KeyClassMetadata;
use crate::binding::binding::KeyExpect;
use crate::binding::binding::KeyExport;
use crate::binding::binding::KeyLegacyTypeParam;
use crate::binding::binding::Keyed;
use crate::binding::binding::RaisedException;
use crate::binding::binding::SizeExpectation;
use crate::binding::binding::UnpackedPosition;
use crate::binding::bindings::BindingEntry;
use crate::binding::bindings::BindingTable;
use crate::binding::bindings::Bindings;
use crate::binding::table::TableKeyed;
use crate::dunder;
use crate::dunder::inplace_dunder;
use crate::error::collector::ErrorCollector;
use crate::export::exports::LookupExport;
use crate::graph::calculation::Calculation;
use crate::graph::index::Idx;
use crate::graph::index_map::IndexMap;
use crate::module::module_info::ModuleInfo;
use crate::module::module_name::ModuleName;
use crate::module::short_identifier::ShortIdentifier;
use crate::solver::Solver;
use crate::table;
use crate::table_for_each;
use crate::table_mut_for_each;
use crate::table_try_for_each;
use crate::type_order::TypeOrder;
use crate::types::annotation::Annotation;
use crate::types::annotation::Qualifier;
use crate::types::callable::Callable;
use crate::types::callable::CallableKind;
use crate::types::callable::Param;
use crate::types::callable::ParamList;
use crate::types::callable::Required;
use crate::types::class::Class;
use crate::types::class_metadata::ClassMetadata;
use crate::types::literal::Lit;
use crate::types::module::Module;
use crate::types::stdlib::Stdlib;
use crate::types::tuple::Tuple;
use crate::types::type_var::Restriction;
use crate::types::type_var::TypeVar;
use crate::types::type_var::Variance;
use crate::types::types::AnyStyle;
use crate::types::types::LegacyTypeParameterLookup;
use crate::types::types::Quantified;
use crate::types::types::TParamInfo;
use crate::types::types::TParams;
use crate::types::types::Type;
use crate::types::types::TypeAlias;
use crate::types::types::TypeAliasStyle;
use crate::types::types::Var;
use crate::util::display::DisplayWith;
use crate::util::prelude::SliceExt;
use crate::util::recurser::Recurser;
use crate::util::uniques::UniqueFactory;

pub const UNKNOWN: Name = Name::new_static("~unknown");

/// Invariants:
///
/// * Every module name referenced anywhere MUST be present
///   in the `exports` and `bindings` map.
/// * Every key referenced in `bindings`/`answers` MUST be present.
///
/// We never issue contains queries on these maps.
#[derive(Debug)]
pub struct Answers {
    solver: Solver,
    table: AnswerTable,
}

pub type AnswerEntry<K> =
    IndexMap<K, Calculation<Arc<<K as Keyed>::Answer>, <K as SolveRecursive>::Recursive>>;

table!(
    #[derive(Debug, Default)]
    pub struct AnswerTable(AnswerEntry)
);

impl DisplayWith<Bindings> for Answers {
    fn fmt(&self, f: &mut fmt::Formatter<'_>, bindings: &Bindings) -> fmt::Result {
        fn go<K: SolveRecursive>(
            bindings: &Bindings,
            entry: &AnswerEntry<K>,
            f: &mut fmt::Formatter<'_>,
        ) -> fmt::Result
        where
            BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        {
            for (idx, answer) in entry.iter() {
                let key = bindings.idx_to_key(idx);
                let value = bindings.get(idx);
                writeln!(
                    f,
                    "{} = {} = {}",
                    bindings.module_info().display(key),
                    value.display_with(bindings),
                    match answer.get() {
                        Some(v) => v.to_string(),
                        None => "(unsolved)".to_owned(),
                    },
                )?;
            }
            Ok(())
        }

        table_try_for_each!(self.table, |x| go(bindings, x, f));
        Ok(())
    }
}

pub type SolutionsEntry<K> = SmallMap<K, <K as Keyed>::Answer>;

table!(
    #[derive(Default, Debug, Clone)]
    pub struct Solutions(pub SolutionsEntry)
);

impl DisplayWith<ModuleInfo> for Solutions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>, ctx: &ModuleInfo) -> fmt::Result {
        fn go<K: Keyed>(
            entry: &SolutionsEntry<K>,
            f: &mut fmt::Formatter<'_>,
            ctx: &ModuleInfo,
        ) -> fmt::Result
        where
            BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        {
            for (key, answer) in entry.iter() {
                writeln!(f, "{} = {}", ctx.display(key), answer)?;
            }
            Ok(())
        }

        table_try_for_each!(self, |x| go(x, f, ctx));
        Ok(())
    }
}

#[derive(Clone)]
pub struct AnswersSolver<'a, Ans: LookupAnswer> {
    exports: &'a dyn LookupExport,
    answers: &'a Ans,
    current: &'a Answers,
    errors: &'a ErrorCollector,
    bindings: &'a Bindings,
    pub uniques: &'a UniqueFactory,
    pub recurser: &'a Recurser<Var>,
    pub stdlib: &'a Stdlib,
}

pub trait LookupAnswer: Sized {
    fn get<K: Solve<Self> + Keyed<EXPORTED = true>>(
        &self,
        name: ModuleName,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        Solutions: TableKeyed<K, Value = SolutionsEntry<K>>;
}

pub trait SolveRecursive: Keyed {
    type Recursive: Dupe = ();

    fn promote_recursive(x: Self::Recursive) -> Self::Answer;

    fn visit_type_mut(v: &mut Self::Answer, f: &mut dyn FnMut(&mut Type));
}

impl SolveRecursive for Key {
    type Recursive = Var;
    fn promote_recursive(x: Self::Recursive) -> Self::Answer {
        Type::Var(x)
    }
    fn visit_type_mut(v: &mut Type, f: &mut dyn FnMut(&mut Type)) {
        f(v);
    }
}
impl SolveRecursive for KeyExpect {
    type Recursive = ();
    fn promote_recursive(_: Self::Recursive) -> Self::Answer {
        EmptyAnswer
    }
    fn visit_type_mut(_: &mut Self::Answer, _: &mut dyn FnMut(&mut Type)) {}
}
impl SolveRecursive for KeyExport {
    type Recursive = Var;
    fn promote_recursive(x: Self::Recursive) -> Self::Answer {
        Type::Var(x)
    }
    fn visit_type_mut(v: &mut Type, f: &mut dyn FnMut(&mut Type)) {
        f(v);
    }
}
impl SolveRecursive for KeyClassField {
    type Recursive = ();
    fn promote_recursive(_: Self::Recursive) -> Self::Answer {
        // TODO(stroxler) Revisit the recursive handling, which needs changes in the plumbing
        // to work correctly; what we have here is a fallback to permissive gradual typing.
        ClassField::recursive()
    }
    fn visit_type_mut(v: &mut ClassField, f: &mut dyn FnMut(&mut Type)) {
        v.visit_type_mut(f);
    }
}
impl SolveRecursive for KeyAnnotation {
    fn promote_recursive(_: Self::Recursive) -> Self::Answer {
        Annotation::default()
    }
    fn visit_type_mut(v: &mut Annotation, f: &mut dyn FnMut(&mut Type)) {
        v.ty.iter_mut().for_each(f);
    }
}
impl SolveRecursive for KeyClassMetadata {
    fn promote_recursive(_: Self::Recursive) -> Self::Answer {
        ClassMetadata::recursive()
    }
    fn visit_type_mut(v: &mut ClassMetadata, f: &mut dyn FnMut(&mut Type)) {
        v.visit_mut(f);
    }
}
impl SolveRecursive for KeyLegacyTypeParam {
    fn promote_recursive(_: Self::Recursive) -> Self::Answer {
        LegacyTypeParameterLookup::NotParameter(Type::any_implicit())
    }
    fn visit_type_mut(v: &mut LegacyTypeParameterLookup, f: &mut dyn FnMut(&mut Type)) {
        v.not_parameter_mut().into_iter().for_each(f);
    }
}

pub trait Solve<Ans: LookupAnswer>: SolveRecursive {
    fn solve(answers: &AnswersSolver<Ans>, binding: &Self::Value) -> Arc<Self::Answer>;

    fn recursive(answers: &AnswersSolver<Ans>) -> Self::Recursive;

    fn record_recursive(
        _answers: &AnswersSolver<Ans>,
        _key: &Self,
        _answer: Arc<Self::Answer>,
        _recursive: Self::Recursive,
    ) {
    }
}

impl<Ans: LookupAnswer> Solve<Ans> for Key {
    fn solve(answers: &AnswersSolver<Ans>, binding: &Binding) -> Arc<Type> {
        answers.solve_binding(binding)
    }

    fn recursive(answers: &AnswersSolver<Ans>) -> Self::Recursive {
        answers.solver().fresh_recursive(answers.uniques)
    }

    fn record_recursive(
        answers: &AnswersSolver<Ans>,
        key: &Key,
        answer: Arc<Type>,
        recursive: Var,
    ) {
        answers.record_recursive(key.range(), answer, recursive);
    }
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyExpect {
    fn solve(answers: &AnswersSolver<Ans>, binding: &BindingExpect) -> Arc<EmptyAnswer> {
        answers.solve_expectation(binding)
    }

    fn recursive(_: &AnswersSolver<Ans>) -> Self::Recursive {}
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyExport {
    fn solve(answers: &AnswersSolver<Ans>, binding: &Binding) -> Arc<Type> {
        answers.solve_binding(binding)
    }

    fn recursive(answers: &AnswersSolver<Ans>) -> Self::Recursive {
        answers.solver().fresh_recursive(answers.uniques)
    }

    fn record_recursive(
        answers: &AnswersSolver<Ans>,
        key: &KeyExport,
        answer: Arc<Type>,
        recursive: Var,
    ) {
        answers.record_recursive(key.range(), answer, recursive);
    }
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyClassField {
    fn solve(answers: &AnswersSolver<Ans>, binding: &BindingClassField) -> Arc<ClassField> {
        answers.solve_class_field(binding)
    }

    fn recursive(_: &AnswersSolver<Ans>) -> Self::Recursive {}
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyAnnotation {
    fn solve(answers: &AnswersSolver<Ans>, binding: &BindingAnnotation) -> Arc<Annotation> {
        answers.solve_annotation(binding)
    }

    fn recursive(_answers: &AnswersSolver<Ans>) -> Self::Recursive {}
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyClassMetadata {
    fn solve(answers: &AnswersSolver<Ans>, binding: &BindingClassMetadata) -> Arc<ClassMetadata> {
        answers.solve_mro(binding)
    }

    fn recursive(_answers: &AnswersSolver<Ans>) -> Self::Recursive {}
}

impl<Ans: LookupAnswer> Solve<Ans> for KeyLegacyTypeParam {
    fn solve(
        answers: &AnswersSolver<Ans>,
        binding: &BindingLegacyTypeParam,
    ) -> Arc<LegacyTypeParameterLookup> {
        answers.solve_legacy_tparam(binding)
    }

    fn recursive(_answers: &AnswersSolver<Ans>) -> Self::Recursive {}
}

impl Answers {
    pub fn new(bindings: &Bindings) -> Self {
        fn presize<K: SolveRecursive>(items: &mut AnswerEntry<K>, bindings: &Bindings)
        where
            BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        {
            let ks = bindings.keys::<K>();
            items.reserve(ks.len());
            for k in ks {
                items.insert_once(k, Calculation::new());
            }
        }
        let mut table = AnswerTable::default();
        table_mut_for_each!(&mut table, |items| presize(items, bindings));

        Self {
            solver: Solver::new(),
            table,
        }
    }

    #[expect(dead_code)]
    fn len(&self) -> usize {
        let mut res = 0;
        table_for_each!(&self.table, |x: &AnswerEntry<_>| res += x.len());
        res
    }

    pub fn solve<Ans: LookupAnswer>(
        &self,
        exports: &dyn LookupExport,
        answers: &Ans,
        bindings: &Bindings,
        errors: &ErrorCollector,
        stdlib: &Stdlib,
        uniques: &UniqueFactory,
        exported_only: bool,
    ) -> Solutions {
        let mut res = Solutions::default();

        fn pre_solve<Ans: LookupAnswer, K: Solve<Ans>>(
            items: &mut SolutionsEntry<K>,
            answers: &AnswersSolver<Ans>,
            exported_only: bool,
        ) where
            AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
            BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        {
            let retain = K::EXPORTED || !exported_only;
            if retain {
                items.reserve(answers.bindings.keys::<K>().len());
            }
            for idx in answers.bindings.keys::<K>() {
                let k = answers.bindings.idx_to_key(idx);
                let v = answers.get(k);
                if retain {
                    items.insert(k.clone(), Arc::unwrap_or_clone(v));
                }
            }
        }
        let answers_solver = AnswersSolver {
            stdlib,
            answers,
            bindings,
            errors,
            exports,
            uniques,
            recurser: &Recurser::new(),
            current: self,
        };
        table_mut_for_each!(&mut res, |items| pre_solve(
            items,
            &answers_solver,
            exported_only
        ));

        // Now force all types to be fully resolved.
        fn post_solve<K: SolveRecursive>(items: &mut SolutionsEntry<K>, solver: &Solver) {
            for v in items.values_mut() {
                K::visit_type_mut(v, &mut |x| solver.deep_force_mut(x));
            }
        }
        table_mut_for_each!(&mut res, |items| post_solve(items, &self.solver));
        res
    }

    pub fn solve_key<Ans: LookupAnswer, K: Solve<Ans>>(
        &self,
        exports: &dyn LookupExport,
        answers: &Ans,
        bindings: &Bindings,
        errors: &ErrorCollector,
        stdlib: &Stdlib,
        uniques: &UniqueFactory,
        key: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        let solver = AnswersSolver {
            stdlib,
            uniques,
            answers,
            bindings,
            errors,
            exports,
            recurser: &Recurser::new(),
            current: self,
        };
        solver.get(key)
    }
}

pub enum Iterable {
    OfType(Type),
    FixedLen(Vec<Type>),
}

impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    pub fn bindings(&self) -> &Bindings {
        self.bindings
    }

    pub fn errors(&self) -> &ErrorCollector {
        self.errors
    }

    pub fn module_info(&self) -> &ModuleInfo {
        self.bindings.module_info()
    }

    pub fn solver(&self) -> &Solver {
        &self.current.solver
    }

    pub fn get_from_module<K: Solve<Ans> + Keyed<EXPORTED = true>>(
        &self,
        name: ModuleName,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        Solutions: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        if name == self.module_info().name() {
            self.get(k)
        } else {
            self.answers.get(name, k)
        }
    }

    pub fn get_from_class<K: Solve<Ans> + Keyed<EXPORTED = true>>(
        &self,
        cls: &Class,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        Solutions: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        self.get_from_module(cls.module_info().name(), k)
    }

    pub fn type_order(&self) -> TypeOrder<Ans> {
        TypeOrder::new(self)
    }

    pub fn get_idx<K: Solve<Ans>>(&self, idx: Idx<K>) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        let calculation = self.current.table.get::<K>().get(idx).unwrap_or_else(|| {
            // Do not fix a panic by removing this error.
            // We should always be sure before calling `get`.
            panic!(
                "Internal error: Answer not found: {}, {}",
                self.module_info().name(),
                self.module_info().display(self.bindings().idx_to_key(idx)),
            )
        });
        let result = calculation.calculate_with_recursive(
            || {
                let binding = self.bindings().get(idx);
                K::solve(self, binding)
            },
            || K::recursive(self),
        );
        if let Ok((v, Some(r))) = &result {
            let k = self.bindings().idx_to_key(idx);
            K::record_recursive(self, k, v.clone(), r.clone());
        }
        match result {
            Ok((v, _)) => v,
            Err(r) => Arc::new(K::promote_recursive(r)),
        }
    }

    pub fn get<K: Solve<Ans>>(&self, k: &K) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.get_idx(self.bindings().key_to_idx(k))
    }

    fn record_recursive(&self, loc: TextRange, answer: Arc<Type>, recursive: Var) {
        self.solver().record_recursive(
            recursive,
            answer.arc_clone(),
            self.type_order(),
            self.errors(),
            self.module_info(),
            loc,
        );
    }

    fn solve_legacy_tparam(
        &self,
        binding: &BindingLegacyTypeParam,
    ) -> Arc<LegacyTypeParameterLookup> {
        match &*self.get_idx(binding.0) {
            Type::Type(box Type::TypeVar(x)) => {
                let q = Quantified::type_var(self.uniques);
                Arc::new(LegacyTypeParameterLookup::Parameter(TParamInfo {
                    name: x.qname().id().clone(),
                    quantified: q,
                    restriction: x.restriction().clone(),
                    default: x.default().cloned(),
                    variance: x.variance(),
                }))
            }
            Type::Type(box Type::TypeVarTuple(x)) => {
                let q = Quantified::type_var_tuple(self.uniques);
                Arc::new(LegacyTypeParameterLookup::Parameter(TParamInfo {
                    name: x.qname().id().clone(),
                    quantified: q,
                    restriction: Restriction::Unrestricted,
                    default: None,
                    variance: Some(Variance::Invariant),
                }))
            }
            Type::Type(box Type::ParamSpec(x)) => {
                let q = Quantified::param_spec(self.uniques);
                Arc::new(LegacyTypeParameterLookup::Parameter(TParamInfo {
                    name: x.qname().id().clone(),
                    quantified: q,
                    restriction: Restriction::Unrestricted,
                    default: None,
                    variance: Some(Variance::Invariant),
                }))
            }
            ty => Arc::new(LegacyTypeParameterLookup::NotParameter(ty.clone())),
        }
    }

    fn solve_mro(&self, binding: &BindingClassMetadata) -> Arc<ClassMetadata> {
        match binding {
            BindingClassMetadata(k, bases, keywords) => {
                let self_ty = self.get_idx(*k);
                match &*self_ty {
                    Type::ClassDef(cls) => Arc::new(self.class_metadata_of(cls, bases, keywords)),
                    _ => {
                        unreachable!("The key inside an Mro binding must be a class type")
                    }
                }
            }
        }
    }

    fn solve_annotation(&self, binding: &BindingAnnotation) -> Arc<Annotation> {
        match binding {
            BindingAnnotation::AnnotateExpr(x, self_type) => {
                let mut ann = self.expr_annotation(x);
                if let Some(self_type) = self_type
                    && let Some(ty) = &mut ann.ty
                {
                    let self_type = &*self.get_idx(*self_type);
                    ty.subst_self_type_mut(self_type);
                }
                Arc::new(ann)
            }
            BindingAnnotation::Type(x) => Arc::new(Annotation::new_type(x.clone())),
            BindingAnnotation::Forward(k) => {
                Arc::new(Annotation::new_type(self.get_idx(*k).arc_clone()))
            }
        }
    }

    fn expr_qualifier(&self, x: &Expr) -> Option<Qualifier> {
        let ty = match x {
            Expr::Name(_) | Expr::Attribute(_) => Some(self.expr(x, None)),
            _ => None,
        };
        if let Some(Type::Type(box Type::SpecialForm(special))) = ty {
            special.to_qualifier()
        } else {
            None
        }
    }

    fn expr_annotation(&self, x: &Expr) -> Annotation {
        match x {
            _ if let Some(qualifier) = self.expr_qualifier(x) => Annotation {
                qualifiers: vec![qualifier],
                ty: None,
            },
            Expr::Subscript(x)
                if Ast::unpack_slice(&x.slice).len() == 1
                    && let Some(qualifier) = self.expr_qualifier(&x.value) =>
            {
                let mut ann = self.expr_annotation(&x.slice);
                ann.qualifiers.insert(0, qualifier);
                ann
            }
            _ => Annotation::new_type(self.expr_untype(x)),
        }
    }

    /// Given an `iterable` type, determine the iteration type; this is the type
    /// of `x` if we were to loop using `for x in iterable`.
    pub fn iterate(&self, iterable: &Type, range: TextRange) -> Vec<Iterable> {
        // Use the iterable protocol interfaces to determine the iterable type.
        // Special cases like Tuple should be intercepted first.
        let iterate_by_interface = || {
            let iteration_ty = if let Some(iterator_ty) =
                self.call_method(iterable, &dunder::ITER, range, &[], &[])
            {
                Some(self.call_method_or_error(&iterator_ty, &dunder::NEXT, range, &[], &[]))
            } else {
                let int_ty = self.stdlib.int().to_type();
                let arg = CallArg::Type(&int_ty, range);
                self.call_method(iterable, &dunder::GETITEM, range, &[arg], &[])
            };
            Iterable::OfType(iteration_ty.unwrap_or_else(|| {
                self.error(
                    range,
                    format!(
                        "Type `{}` is not iterable",
                        iterable.clone().deterministic_printing()
                    ),
                )
            }))
        };
        match iterable {
            Type::ClassType(_) | Type::Type(box Type::ClassType(_)) => {
                vec![iterate_by_interface()]
            }
            Type::ClassDef(cls) => {
                if self.get_metadata_for_class(cls).is_typed_dict() {
                    vec![Iterable::OfType(self.error(
                        range,
                        format!(
                            "Type `{}` (a `TypedDict` class object) is not iterable",
                            iterable.clone().deterministic_printing()
                        ),
                    ))]
                } else {
                    vec![iterate_by_interface()]
                }
            }
            Type::TypedDict(_) => self.iterate(
                &self
                    .stdlib
                    .mapping(
                        self.stdlib.str().to_type(),
                        self.stdlib.object_class_type().clone().to_type(),
                    )
                    .to_type(),
                range,
            ),
            Type::Tuple(Tuple::Concrete(elts)) => vec![Iterable::FixedLen(elts.clone())],
            Type::Tuple(Tuple::Unbounded(box elt)) => vec![Iterable::OfType(elt.clone())],
            Type::LiteralString => vec![Iterable::OfType(self.stdlib.str().to_type())],
            Type::Literal(lit) if lit.is_string() => {
                vec![Iterable::OfType(self.stdlib.str().to_type())]
            }
            Type::Any(_) => vec![Iterable::OfType(Type::any_implicit())],
            Type::Var(v) if let Some(_guard) = self.recurser.recurse(*v) => {
                self.iterate(&self.solver().force_var(*v), range)
            }
            Type::Union(ts) => ts.iter().flat_map(|t| self.iterate(t, range)).collect(),
            _ => vec![Iterable::OfType(self.error(
                range,
                format!(
                    "`{}` is not iterable",
                    iterable.clone().deterministic_printing()
                ),
            ))],
        }
    }

    fn check_is_exception(&self, x: &Expr, range: TextRange, allow_none: bool) {
        let actual_type = self.expr(x, None);
        if allow_none && actual_type.is_none() {
            return;
        }
        let expected_types = if let base_exception_type @ Type::ClassType(c) =
            &self.stdlib.base_exception().to_type()
        {
            let base_exception_class_type = Type::ClassDef(c.class_object().dupe());
            vec![base_exception_type.clone(), base_exception_class_type]
        } else {
            unreachable!("The stdlib base exception type should be a ClassInstance")
        };
        if !self.solver().is_subset_eq(
            &actual_type,
            &Type::Union(expected_types),
            self.type_order(),
        ) {
            self.error(
                 range,
                 format!(
                     "Expression `{}` has type `{actual_type}` which does not derive from BaseException",
                     self.module_info().display(x)
                 ),
             );
        }
    }

    fn tvars_to_tparams_for_type_alias(
        &self,
        ty: &mut Type,
        seen: &mut SmallMap<TypeVar, Quantified>,
        tparams: &mut Vec<TParamInfo>,
    ) {
        match ty {
            Type::Union(ts) => {
                for t in ts.iter_mut() {
                    self.tvars_to_tparams_for_type_alias(t, seen, tparams);
                }
            }
            Type::ClassType(cls) => {
                for t in cls.targs_mut().as_mut() {
                    self.tvars_to_tparams_for_type_alias(t, seen, tparams);
                }
            }
            Type::Callable(callable, _) => {
                let visit = |t: &mut Type| self.tvars_to_tparams_for_type_alias(t, seen, tparams);
                callable.visit_mut(visit);
            }
            Type::TypeVar(ty_var) => {
                let q = match seen.entry(ty_var.dupe()) {
                    Entry::Occupied(e) => *e.get(),
                    Entry::Vacant(e) => {
                        let q = Quantified::type_var(self.uniques);
                        e.insert(q);
                        tparams.push(TParamInfo {
                            name: ty_var.qname().id().clone(),
                            quantified: q,
                            restriction: Restriction::Unrestricted,
                            default: ty_var.default().cloned(),
                            variance: ty_var.variance(),
                        });
                        q
                    }
                };
                *ty = Type::Quantified(q);
            }
            _ => {}
        }
    }

    fn as_type_alias(
        &self,
        name: &Name,
        style: TypeAliasStyle,
        ty: Type,
        range: TextRange,
    ) -> Type {
        if matches!(
            style,
            TypeAliasStyle::Scoped | TypeAliasStyle::LegacyExplicit
        ) && self.untype_opt(ty.clone(), range).is_none()
        {
            self.error(
                range,
                format!("Expected `{name}` to be a type alias, got {ty}"),
            );
            return Type::any_error();
        }
        let mut ty = match &ty {
            Type::ClassDef(cls) => Type::type_form(self.promote(cls, range)),
            t => t.clone(),
        };
        let mut seen = SmallMap::new();
        let mut tparams = Vec::new();
        match ty {
            Type::Type(ref mut t) => {
                self.tvars_to_tparams_for_type_alias(t, &mut seen, &mut tparams)
            }
            _ => {}
        }
        let ta = Type::TypeAlias(TypeAlias::new(name.clone(), ty, style));
        ta.forall(self.type_params(range, tparams))
    }

    fn context_value_enter(
        &self,
        context_manager_type: &Type,
        kind: ContextManagerKind,
        range: TextRange,
    ) -> Type {
        match kind {
            ContextManagerKind::Sync => {
                self.call_method_or_error(context_manager_type, &dunder::ENTER, range, &[], &[])
            }
            ContextManagerKind::Async => match self.unwrap_awaitable(&self.call_method_or_error(
                context_manager_type,
                &dunder::AENTER,
                range,
                &[],
                &[],
            )) {
                Some(ty) => ty,
                None => self.error(range, format!("Expected `{}` to be async", dunder::AENTER)),
            },
        }
    }

    fn context_value_exit(
        &self,
        context_manager_type: &Type,
        kind: ContextManagerKind,
        range: TextRange,
    ) -> Type {
        let base_exception_class_type = Type::type_form(self.stdlib.base_exception().to_type());
        let arg1 = Type::Union(vec![base_exception_class_type, Type::None]);
        let arg2 = Type::Union(vec![self.stdlib.base_exception().to_type(), Type::None]);
        let arg3 = Type::Union(vec![self.stdlib.traceback_type().to_type(), Type::None]);
        let exit_arg_types = [
            CallArg::Type(&arg1, range),
            CallArg::Type(&arg2, range),
            CallArg::Type(&arg3, range),
        ];
        match kind {
            ContextManagerKind::Sync => self.call_method_or_error(
                context_manager_type,
                &dunder::EXIT,
                range,
                &exit_arg_types,
                &[],
            ),
            ContextManagerKind::Async => match self.unwrap_awaitable(&self.call_method_or_error(
                context_manager_type,
                &dunder::AEXIT,
                range,
                &exit_arg_types,
                &[],
            )) {
                Some(ty) => ty,
                None => self.error(range, format!("Expected `{}` to be async", dunder::AEXIT)),
            },
        }
    }

    fn context_value(
        &self,
        context_manager_type: Type,
        kind: ContextManagerKind,
        range: TextRange,
    ) -> Type {
        let enter_type = self.context_value_enter(&context_manager_type, kind, range);
        let exit_type = self.context_value_exit(&context_manager_type, kind, range);
        self.check_type(
            &Type::Union(vec![self.stdlib.bool().to_type(), Type::None]),
            &exit_type,
            range,
        );
        // TODO: `exit_type` may also affect exceptional control flow, which is yet to be supported:
        // https://typing.readthedocs.io/en/latest/spec/exceptions.html#context-managers
        enter_type
    }

    pub fn scoped_type_params(&self, x: Option<&TypeParams>) -> Vec<TParamInfo> {
        match x {
            Some(x) => {
                fn get_quantified(t: &Type) -> Quantified {
                    match t {
                        Type::Type(box Type::Quantified(q)) => *q,
                        _ => unreachable!(),
                    }
                }
                let mut params = Vec::new();
                for raw_param in x.type_params.iter() {
                    let name = raw_param.name();
                    let restriction = match raw_param {
                        TypeParam::TypeVar(tv) => match &tv.bound {
                            Some(box Expr::Tuple(tup)) => {
                                Restriction::Constraints(tup.elts.map(|e| self.expr_untype(e)))
                            }
                            Some(e) => Restriction::Bound(self.expr_untype(e)),
                            None => Restriction::Unrestricted,
                        },
                        _ => Restriction::Unrestricted,
                    };
                    let default = raw_param.default().map(|e| self.expr_untype(e));
                    params.push(TParamInfo {
                        name: name.id.clone(),
                        quantified: get_quantified(
                            &self.get(&Key::Definition(ShortIdentifier::new(name))),
                        ),
                        restriction,
                        default,
                        variance: None,
                    });
                }
                params
            }
            None => Vec::new(),
        }
    }

    pub fn type_params(&self, range: TextRange, info: Vec<TParamInfo>) -> TParams {
        match TParams::new(info) {
            Ok(validated_tparams) => validated_tparams,
            Err(fixed_tparams) => {
                self.error(
                    range,
                    "A type parameter without a default cannot follow one with a default"
                        .to_owned(),
                );
                fixed_tparams
            }
        }
    }

    fn solve_binding(&self, binding: &Binding) -> Arc<Type> {
        // Replace any solved recursive variables with their answers.
        // We call self.unions() to simplify cases like
        // v = @1 | int, @1 = int.
        Arc::new(
            match self.solver().expand(self.solve_binding_inner(binding)) {
                Type::Union(ts) => self.unions(&ts),
                t => t,
            },
        )
    }

    fn solve_expectation(&self, binding: &BindingExpect) -> Arc<EmptyAnswer> {
        match binding {
            BindingExpect::UnpackedLength(b, range, expect) => {
                let iterable_ty = self.solve_binding_inner(b);
                let iterables = self.iterate(&iterable_ty, *range);
                for iterable in iterables {
                    match iterable {
                        Iterable::OfType(_) => {}
                        Iterable::FixedLen(ts) => {
                            let error = match expect {
                                SizeExpectation::Eq(n) => {
                                    if ts.len() == *n {
                                        None
                                    } else {
                                        match n {
                                            1 => Some(format!("{n} value")),
                                            _ => Some(format!("{n} values")),
                                        }
                                    }
                                }
                                SizeExpectation::Ge(n) => {
                                    if ts.len() >= *n {
                                        None
                                    } else {
                                        Some(format!("{n}+ values"))
                                    }
                                }
                            };
                            match error {
                                Some(expectation) => {
                                    self.error(
                                        *range,
                                        format!(
                                            "Cannot unpack {} (of size {}) into {}",
                                            iterable_ty,
                                            ts.len(),
                                            expectation,
                                        ),
                                    );
                                }
                                None => {}
                            }
                        }
                    }
                }
            }
            BindingExpect::CheckRaisedException(RaisedException::WithoutCause(exc)) => {
                self.check_is_exception(exc, exc.range(), false);
            }
            BindingExpect::CheckRaisedException(RaisedException::WithCause(box (exc, cause))) => {
                self.check_is_exception(exc, exc.range(), false);
                self.check_is_exception(cause, cause.range(), true);
            }
            BindingExpect::Eq(k1, k2, name) => {
                let ann1 = self.get_idx(*k1);
                let ann2 = self.get_idx(*k2);
                if let Some(t1) = &ann1.ty
                    && let Some(t2) = &ann2.ty
                    && *t1 != *t2
                {
                    self.error(
                        self.bindings().idx_to_key(*k1).range(),
                        format!(
                            "Inconsistent type annotations for {}: {}, {}",
                            name,
                            t1.clone().deterministic_printing(),
                            t2.clone().deterministic_printing(),
                        ),
                    );
                }
            }
            BindingExpect::CheckAssignTypeToAttribute(box (attr, got)) => {
                let base = self.expr(&attr.value, None);
                let got = self.solve_binding(got);
                self.check_attr_set_with_type(
                    base,
                    &attr.attr.id,
                    &got,
                    attr.range,
                    "Answers::solve_binding_inner::CheckAssignTypeToAttribute",
                );
            }
            BindingExpect::CheckAssignExprToAttribute(box (attr, value)) => {
                let base = self.expr(&attr.value, None);
                self.check_attr_set_with_expr(
                    base,
                    &attr.attr.id,
                    value,
                    attr.range,
                    "Answers::solve_binding_inner::CheckAssignExprToAttribute",
                );
            }
        }
        Arc::new(EmptyAnswer)
    }

    fn solve_class_field(&self, field: &BindingClassField) -> Arc<ClassField> {
        let value_ty = self.solve_binding(&field.value);
        let annotation = field.annotation.map(|a| self.get_idx(a));
        Arc::new(self.calculate_class_field(
            &field.name,
            value_ty.as_ref(),
            annotation.as_deref(),
            field.initialization,
            field.class,
            field.range,
        ))
    }

    fn solve_binding_inner(&self, binding: &Binding) -> Type {
        match binding {
            Binding::Expr(ann, e) => {
                let ty = ann.map(|k| self.get_idx(k));
                self.expr(e, ty.as_ref().and_then(|x| x.ty.as_ref()))
            }
            Binding::Generator(yield_type, return_type) => {
                let yield_type = self.solve_binding_inner(yield_type);
                let return_type = self.solve_binding_inner(return_type);
                self.stdlib
                    .generator(yield_type, Type::any_implicit(), return_type)
                    .to_type()
            }
            Binding::AsyncGenerator(yield_type) => {
                let yield_type = self.solve_binding_inner(yield_type);
                self.stdlib
                    .async_generator(yield_type, Type::any_implicit())
                    .to_type()
            }
            Binding::SendTypeOfYieldAnnotation(ann, range) => {
                let gen_ann: Option<Arc<Annotation>> = ann.map(|k| self.get_idx(k));
                match gen_ann {
                    Some(gen_ann) => {
                        let gen_type = gen_ann.get_type();

                        if let Some((_, send_type, _)) = self.decompose_generator(gen_type) {
                            send_type
                        } else {
                            self.error(*range, format!("Yield expression found but the function has an incompatible annotation `{gen_type}`"))
                        }
                    }

                    None => Type::any_explicit(),
                }
            }
            Binding::YieldTypeOfYieldAnnotation(ann, range) => {
                let gen_ann: Option<Arc<Annotation>> = ann.map(|k| self.get_idx(k));
                match gen_ann {
                    Some(gen_ann) => {
                        let gen_type = gen_ann.get_type();

                        if let Some((yield_type, _, _)) = self.decompose_generator(gen_type) {
                            yield_type
                        } else {
                            self.error(*range, format!("Yield expression found but the function has an incompatible annotation `{gen_type}`"))
                        }
                    }

                    None => Type::any_explicit(),
                }
            }
            Binding::ReturnTypeOfYieldAnnotation(ann, range) => {
                let gen_ann: Option<Arc<Annotation>> = ann.map(|k| self.get_idx(k));
                match gen_ann {
                    Some(gen_ann) => {
                        let gen_type = gen_ann.get_type();

                        if let Some((_, _, return_type)) = self.decompose_generator(gen_type) {
                            return_type
                        } else {
                            self.error(*range, format!("YieldFrom expression found but the function has an incompatible annotation `{gen_type}`"))
                        }
                    }

                    None => Type::any_explicit(),
                }
            }
            Binding::YieldTypeOfYield(x) => match x {
                Expr::Yield(x) => match &x.value {
                    Some(x) => self.expr(x, None),
                    None => self.expr(&Expr::NoneLiteral(ExprNoneLiteral { range: x.range }), None),
                },
                Expr::YieldFrom(x) => {
                    let gen_type = self.expr(&x.value, None);
                    self.decompose_generator(&gen_type)
                        .map_or(Type::any_implicit(), |(y, _, _)| y)
                }
                _ => unreachable!("yield or yield from expression expected"),
            },

            Binding::ReturnExpr(ann, e, has_yields) => {
                let ann: Option<Arc<Annotation>> = ann.map(|k| self.get_idx(k));
                let hint = ann.as_ref().and_then(|x| x.ty.as_ref());

                if *has_yields {
                    let hint = match hint {
                        Some(t) => {
                            let decomposed = self.decompose_generator(t);
                            decomposed.map(|(_, _, r)| r)
                        }
                        None => None,
                    };
                    self.expr(e, hint.as_ref())
                } else if matches!(hint, Some(Type::TypeGuard(_))) {
                    self.expr(e, Some(&Type::ClassType(self.stdlib.bool())))
                } else {
                    self.expr(e, hint)
                }
            }
            Binding::ExceptionHandler(box ann, is_star) => {
                let base_exception_type = self.stdlib.base_exception().to_type();
                let base_exception_group_any_type = if *is_star {
                    // Only query for `BaseExceptionGroup` if we see an `except*` handler (which
                    // was introduced in Python3.11).
                    // We can't unconditionally query for `BaseExceptionGroup` until Python3.10
                    // is out of its EOL period.
                    Some(
                        self.stdlib
                            .base_exception_group(Type::Any(AnyStyle::Implicit))
                            .to_type(),
                    )
                } else {
                    None
                };
                let check_exception_type = |exception_type: Type, range| {
                    let exception = self.untype(exception_type, range);
                    self.check_type(&base_exception_type, &exception, range);
                    if let Some(base_exception_group_any_type) =
                        base_exception_group_any_type.as_ref()
                        && !exception.is_any()
                        && self.solver().is_subset_eq(
                            &exception,
                            base_exception_group_any_type,
                            self.type_order(),
                        )
                    {
                        self.error(range, "Exception handler annotation in `except*` clause may not extend `BaseExceptionGroup`".to_owned());
                    }
                    exception
                };
                let exceptions = match ann {
                    // if the exception classes are written as a tuple literal, use each annotation's position for error reporting
                    Expr::Tuple(tup) => tup
                        .elts
                        .iter()
                        .map(|e| check_exception_type(self.expr(e, None), e.range()))
                        .collect(),
                    _ => {
                        let exception_types = self.expr(ann, None);
                        match exception_types {
                            Type::Tuple(Tuple::Concrete(ts)) => ts
                                .into_iter()
                                .map(|t| check_exception_type(t, ann.range()))
                                .collect(),
                            Type::Tuple(Tuple::Unbounded(box t)) => {
                                vec![check_exception_type(t, ann.range())]
                            }
                            _ => vec![check_exception_type(exception_types, ann.range())],
                        }
                    }
                };
                if *is_star {
                    self.stdlib
                        .exception_group(self.unions(&exceptions))
                        .to_type()
                } else {
                    self.unions(&exceptions)
                }
            }
            Binding::AugAssign(x) => {
                let base = self.expr(&x.target, None);
                self.call_method_or_error(
                    &base,
                    &inplace_dunder(x.op),
                    x.range,
                    &[CallArg::Expr(&x.value)],
                    &[],
                )
            }
            Binding::IterableValue(ann, e) => {
                let ty = ann.map(|k| self.get_idx(k));
                let hint =
                    ty.and_then(|x| x.ty.clone().map(|ty| self.stdlib.iterable(ty).to_type()));
                let iterables = self.iterate(&self.expr(e, hint.as_ref()), e.range());
                let mut values = Vec::new();
                for iterable in iterables {
                    match iterable {
                        Iterable::OfType(ty) => values.push(ty),
                        Iterable::FixedLen(ts) => values.extend(ts),
                    }
                }
                self.unions(&values)
            }
            Binding::ContextValue(ann, e, kind) => {
                let context_manager = self.expr(e, None);
                let context_value = self.context_value(context_manager, *kind, e.range());
                let ty = ann.map(|k| self.get_idx(k));
                match ty.as_ref().and_then(|x| x.ty.as_ref()) {
                    Some(ty) => self.check_type(ty, &context_value, e.range()),
                    None => context_value,
                }
            }
            Binding::SubscriptValue(box b, x) => {
                let base = self.expr(&x.value, None);
                let slice_ty = self.expr(&x.slice, None);
                let value_ty = self.solve_binding_inner(b);
                match (&base, &slice_ty) {
                    (Type::TypedDict(typed_dict), Type::Literal(Lit::String(field_name))) => {
                        if let Some(field) = typed_dict.fields().get(&Name::new(field_name.clone()))
                        {
                            if field.read_only {
                                self.error(
                                    x.slice.range(),
                                    format!(
                                        "Key `{}` in TypedDict `{}` is read-only",
                                        field_name,
                                        typed_dict.name(),
                                    ),
                                )
                            } else if !self.solver().is_subset_eq(
                                &value_ty,
                                &field.ty,
                                self.type_order(),
                            ) {
                                self.error(
                                    x.range(),
                                    format!("Expected {}, got {}", field.ty, value_ty),
                                )
                            } else {
                                Type::ClassType(self.stdlib.none_type())
                            }
                        } else {
                            self.error(
                                x.slice.range(),
                                format!(
                                    "TypedDict `{}` does not have key `{}`",
                                    typed_dict.name(),
                                    field_name
                                ),
                            )
                        }
                    }
                    (_, _) => self.call_method_or_error(
                        &base,
                        &dunder::SETITEM,
                        x.range,
                        &[
                            CallArg::Type(&slice_ty, x.slice.range()),
                            // use the subscript's location
                            CallArg::Type(&value_ty, x.range),
                        ],
                        &[],
                    ),
                }
            }
            Binding::UnpackedValue(b, range, pos) => {
                let iterables = self.iterate(&self.solve_binding_inner(b), *range);
                let mut values = Vec::new();
                for iterable in iterables {
                    values.push(match iterable {
                        Iterable::OfType(ty) => match pos {
                            UnpackedPosition::Index(_) | UnpackedPosition::ReverseIndex(_) => ty,
                            UnpackedPosition::Slice(_, _) => self.stdlib.list(ty).to_type(),
                        },
                        Iterable::FixedLen(ts) => {
                            match pos {
                                UnpackedPosition::Index(i) | UnpackedPosition::ReverseIndex(i) => {
                                    let idx = if matches!(pos, UnpackedPosition::Index(_)) {
                                        *i
                                    } else {
                                        ts.len() - *i
                                    };
                                    if let Some(element) = ts.get(idx) {
                                        element.clone()
                                    } else {
                                        // We'll report this error when solving for Binding::UnpackedLength.
                                        Type::any_error()
                                    }
                                }
                                UnpackedPosition::Slice(i, j) => {
                                    let start = *i;
                                    let end = ts.len() - *j;
                                    if start <= ts.len() && end >= start {
                                        let elem_ty = self.unions(&ts[start..end]);
                                        self.stdlib.list(elem_ty).to_type()
                                    } else {
                                        // We'll report this error when solving for Binding::UnpackedLength.
                                        Type::any_error()
                                    }
                                }
                            }
                        }
                    })
                }
                self.unions(&values)
            }
            Binding::Function(x) => {
                // Check every define, but only return the type of the last one.
                // TODO: Combine the types of @overload-decorated defines.
                let mut ty = Type::any_error();
                for x in x {
                    ty = self.function_def(x);
                }
                ty
            }
            Binding::Import(m, name) => self
                .get_from_module(*m, &KeyExport(name.clone()))
                .arc_clone(),
            Binding::ClassDef(box (x, fields), bases, decorators, legacy_tparams) => {
                let mut ty =
                    Type::ClassDef(self.class_definition(x, fields.clone(), bases, legacy_tparams));
                for x in decorators.iter().rev() {
                    ty = self.apply_decorator(x, ty)
                }
                ty
            }
            Binding::FunctionalClassDef(x, fields) => {
                Type::ClassDef(self.functional_class_definition(x, fields))
            }
            Binding::SelfType(k) => match &*self.get_idx(*k) {
                Type::ClassDef(c) => c.self_type(),
                _ => unreachable!(),
            },
            Binding::Forward(k) => self.get_idx(*k).arc_clone(),
            Binding::Phi(ks) => {
                if ks.len() == 1 {
                    self.get_idx(*ks.first().unwrap()).arc_clone()
                } else {
                    self.unions(
                        &ks.iter()
                            .map(|k| self.get_idx(*k).arc_clone())
                            .collect::<Vec<_>>(),
                    )
                }
            }
            Binding::Narrow(k, op) => self.narrow(&self.get_idx(*k), op),
            Binding::AnnotatedType(ann, val) => match &self.get_idx(*ann).ty {
                Some(ty) => ty.clone(),
                None => self.solve_binding_inner(val),
            },
            Binding::AnyType(x) => Type::Any(*x),
            Binding::StrType => self.stdlib.str().to_type(),
            Binding::TypeParameter(q) => Type::type_form(q.to_type()),
            Binding::Module(m, path, prev) => {
                let prev = prev
                    .as_ref()
                    .and_then(|x| self.get_idx(*x).as_module().cloned());
                match prev {
                    Some(prev) if prev.path() == path => prev.add_module(*m).to_type(),
                    _ => {
                        if path.len() == 1 {
                            Type::Module(Module::new(
                                path[0].clone(),
                                OrderedSet::from_iter([(*m)]),
                            ))
                        } else {
                            assert_eq!(&m.components(), path);
                            Type::Module(Module::new_as(*m))
                        }
                    }
                }
            }
            Binding::CheckLegacyTypeParam(key, range_if_scoped_params_exist) => {
                match &*self.get_idx(*key) {
                    LegacyTypeParameterLookup::Parameter(p) => {
                        // This class or function has scoped (PEP 695) type parameters. Mixing legacy-style parameters is an error.
                        if let Some(r) = range_if_scoped_params_exist {
                            self.error(
                                *r,
                                format!(
                                    "Type parameter {} is not included in the type parameter list",
                                    self.module_info()
                                        .display(&self.bindings().idx_to_key(*key).0)
                                ),
                            );
                        }
                        Type::type_form(p.quantified.to_type())
                    }
                    LegacyTypeParameterLookup::NotParameter(ty) => ty.clone(),
                }
            }
            Binding::NameAssign(name, annot_key, expr) => {
                let annot = annot_key.map(|k| self.get_idx(k));
                let ty = self.expr(expr, annot.as_ref().and_then(|x| x.ty.as_ref()));
                let expr_range = expr.range();
                match (annot, &ty) {
                    (Some(annot), _) if annot.qualifiers.contains(&Qualifier::TypeAlias) => {
                        self.as_type_alias(name, TypeAliasStyle::LegacyExplicit, ty, expr_range)
                    }
                    (None, Type::Type(box t))
                        if matches!(&**expr, Expr::Call(_))
                            && let Some(tvar) = t.as_tvar_declaration() =>
                    {
                        let tvar_name = &tvar.name.id;
                        if *name != *tvar_name && *tvar_name != UNKNOWN {
                            self.error(
                                expr_range,
                                format!("TypeVar must be assigned to a variable named {tvar_name}"),
                            );
                        }
                        ty
                    }
                    // TODO(stroxler, rechen): Do we want to include Type::ClassDef(_)
                    // when there is no annotation, so that `mylist = list` is treated
                    // like a value assignment rather than a type alias?
                    (None, Type::Type(_)) => {
                        self.as_type_alias(name, TypeAliasStyle::LegacyImplicit, ty, expr_range)
                    }
                    _ => ty,
                }
            }
            Binding::ScopedTypeAlias(name, params, expr) => {
                let ty = self.expr(expr, None);
                let expr_range = expr.range();
                let ta = self.as_type_alias(name, TypeAliasStyle::Scoped, ty, expr_range);
                match ta {
                    Type::Forall(..) => self.error(
                        expr.range(),
                        format!("Type parameters used in `{name}` but not declared"),
                    ),
                    Type::TypeAlias(_) => {
                        let params_range = params.as_ref().map_or(expr_range, |x| x.range);
                        ta.forall(
                            self.type_params(
                                params_range,
                                self.scoped_type_params(params.as_ref()),
                            ),
                        )
                    }
                    _ => ta,
                }
            }
            Binding::PatternMatchMapping(mapping_key, binding_key) => {
                // TODO: check that value is a mapping
                // TODO: check against duplicate keys (optional)
                let key_ty = self.expr(mapping_key, None);
                let binding_ty = self.get_idx(*binding_key).arc_clone();
                let arg = CallArg::Type(&key_ty, mapping_key.range());
                self.call_method_or_error(
                    &binding_ty,
                    &dunder::GETITEM,
                    mapping_key.range(),
                    &[arg],
                    &[],
                )
            }
            Binding::PatternMatchClassPositional(_, idx, key, range) => {
                // TODO: check that value matches class
                // TODO: check against duplicate keys (optional)
                let binding_ty = self.get_idx(*key).arc_clone();
                let match_args = self.attr_infer(&binding_ty, &dunder::MATCH_ARGS, *range);
                match match_args {
                    Type::Tuple(Tuple::Concrete(ts)) => {
                        if *idx < ts.len() {
                            if let Some(Type::Literal(Lit::String(box attr_name))) = ts.get(*idx) {
                                self.attr_infer(&binding_ty, &Name::new(attr_name), *range)
                            } else {
                                self.error(
                                    *range,
                                    format!(
                                        "Expected literal string in `__match_args__`, got {}",
                                        ts[*idx]
                                    ),
                                )
                            }
                        } else {
                            self.error(
                                *range,
                                format!("Index {idx} out of range for `__match_args__`"),
                            )
                        }
                    }
                    Type::Any(AnyStyle::Error) => match_args,
                    _ => self.error(
                        *range,
                        format!(
                            "Expected concrete tuple for __match_args__, got {}",
                            match_args
                        ),
                    ),
                }
            }
            Binding::PatternMatchClassKeyword(_, attr, key) => {
                // TODO: check that value matches class
                // TODO: check against duplicate keys (optional)
                let binding_ty = self.get_idx(*key).arc_clone();
                self.attr_infer(&binding_ty, &attr.id, attr.range)
            }
        }
    }

    fn function_def(&self, x: &FunctionBinding) -> Type {
        let check_default = |default: &Option<Box<Expr>>, ty: &Type| {
            let mut required = Required::Required;
            if let Some(default) = default {
                required = Required::Optional;
                if x.kind != FunctionKind::Stub
                    || !matches!(default.as_ref(), Expr::EllipsisLiteral(_))
                {
                    self.expr(default, Some(ty));
                }
            }
            required
        };
        let mut params = Vec::with_capacity(x.def.parameters.len());
        params.extend(x.def.parameters.posonlyargs.iter().map(|x| {
            let annot = self.get(&KeyAnnotation::Annotation(ShortIdentifier::new(
                &x.parameter.name,
            )));
            let ty = annot.get_type();
            let required = check_default(&x.default, ty);
            Param::PosOnly(ty.clone(), required)
        }));
        params.extend(x.def.parameters.args.iter().map(|x| {
            let annot = self.get(&KeyAnnotation::Annotation(ShortIdentifier::new(
                &x.parameter.name,
            )));
            let ty = annot.get_type();
            let required = check_default(&x.default, ty);
            Param::Pos(x.parameter.name.id.clone(), ty.clone(), required)
        }));
        params.extend(x.def.parameters.vararg.iter().map(|x| {
            let annot = self.get(&KeyAnnotation::Annotation(ShortIdentifier::new(&x.name)));
            let ty = annot.get_type();
            Param::VarArg(ty.clone())
        }));
        params.extend(x.def.parameters.kwonlyargs.iter().map(|x| {
            let annot = self.get(&KeyAnnotation::Annotation(ShortIdentifier::new(
                &x.parameter.name,
            )));
            let ty = annot.get_type();
            let required = check_default(&x.default, ty);
            Param::KwOnly(x.parameter.name.id.clone(), ty.clone(), required)
        }));
        params.extend(x.def.parameters.kwarg.iter().map(|x| {
            let annot = self.get(&KeyAnnotation::Annotation(ShortIdentifier::new(&x.name)));
            let ty = annot.get_type();
            Param::Kwargs(ty.clone())
        }));
        let ret = self
            .get(&Key::ReturnType(ShortIdentifier::new(&x.def.name)))
            .arc_clone();

        let ret = if x.def.is_async {
            self.stdlib
                .coroutine(Type::any_implicit(), Type::any_implicit(), ret)
                .to_type()
        } else {
            ret
        };
        let mut tparams = self.scoped_type_params(x.def.type_params.as_deref());
        let legacy_tparams = x
            .legacy_tparams
            .iter()
            .filter_map(|key| self.get_idx(*key).deref().parameter().cloned());
        tparams.extend(legacy_tparams);
        let callable = Type::Callable(
            Box::new(Callable::list(ParamList::new(params), ret)),
            CallableKind::from_name(self.module_info().name(), &x.def.name.id),
        );
        let mut ty = callable.forall(self.type_params(x.def.range, tparams));
        for x in x.decorators.iter().rev() {
            ty = self.apply_decorator(x, ty)
        }
        ty
    }

    pub fn check_type(&self, want: &Type, got: &Type, loc: TextRange) -> Type {
        if matches!(got, Type::Any(AnyStyle::Error)) {
            // Don't propagate errors
            got.clone()
        } else if self.solver().is_subset_eq(got, want, self.type_order()) {
            got.clone()
        } else {
            self.solver()
                .error(want, got, self.errors(), self.module_info(), loc);
            want.clone()
        }
    }

    pub fn distribute_over_union(&self, ty: &Type, mut f: impl FnMut(&Type) -> Type) -> Type {
        match ty {
            Type::Union(tys) => self.unions(&tys.iter().map(f).collect::<Vec<_>>()),
            _ => f(ty),
        }
    }

    pub fn unions(&self, xs: &[Type]) -> Type {
        self.solver().unions(xs.to_owned(), self.type_order())
    }

    pub fn union(&self, x: &Type, y: &Type) -> Type {
        self.unions(&[x.clone(), y.clone()])
    }

    pub fn todo(&self, msg: &str, x: impl Ranged + Debug) -> Type {
        self.errors().todo(self.module_info(), msg, x);
        Type::any_error()
    }

    pub fn error(&self, range: TextRange, msg: String) -> Type {
        self.errors().add(self.module_info(), range, msg);
        Type::any_error()
    }

    /// Unwraps a type, originally evaluated as a value, so that it can be used as a type annotation.
    /// For example, in `def f(x: int): ...`, we evaluate `int` as a value, gettings its type as
    /// `type[int]`, then call `untype(type[int])` to get the `int` annotation.
    pub fn untype(&self, ty: Type, range: TextRange) -> Type {
        if let Some(t) = self.untype_opt(ty.clone(), range) {
            t
        } else {
            self.error(
                range,
                format!("untype, got {}", ty.deterministic_printing()),
            )
        }
    }

    pub fn untype_opt(&self, ty: Type, range: TextRange) -> Option<Type> {
        match self.canonicalize_all_class_types(ty, range) {
            Type::Union(xs) if !xs.is_empty() => {
                let mut ts = Vec::new();
                for x in xs.into_iter() {
                    let t = self.untype_opt(x, range)?;
                    ts.push(t);
                }
                Some(self.unions(&ts))
            }
            Type::Var(v) if let Some(_guard) = self.recurser.recurse(v) => {
                self.untype_opt(self.solver().force_var(v), range)
            }
            Type::Type(box t) => Some(t),
            Type::None => Some(Type::None), // Both a value and a type
            Type::Ellipsis => Some(Type::Ellipsis), // A bit weird because of tuples, so just promote it
            Type::Any(style) => Some(style.propagate()),
            Type::TypeAlias(ta) => self.untype_opt(ta.as_type(), range),
            _ => None,
        }
    }

    pub fn expr_untype(&self, x: &Expr) -> Type {
        self.untype(self.expr(x, None), x.range())
    }

    pub fn get_import(&self, name: &Name, from: ModuleName) -> Option<Type> {
        if let Ok(exports) = self.exports.get(from) {
            if exports.contains(name, self.exports) {
                Some(
                    self.get_from_module(from, &KeyExport(name.clone()))
                        .arc_clone(),
                )
            } else {
                None
            }
        } else {
            // We have already errored on `m` when loading the module. No need to emit error again.
            Some(Type::any_error())
        }
    }
}
