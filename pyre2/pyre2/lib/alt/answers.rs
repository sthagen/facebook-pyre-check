/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Debug;
use std::fmt::Display;
use std::path::PathBuf;
use std::sync::Arc;

use dupe::Dupe;
use dupe::OptionDupedExt;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use starlark_map::small_map::SmallMap;

use crate::alt::traits::Solve;
use crate::alt::traits::SolveRecursive;
use crate::binding::binding::Keyed;
use crate::binding::bindings::BindingEntry;
use crate::binding::bindings::BindingTable;
use crate::binding::bindings::Bindings;
use crate::binding::table::TableKeyed;
use crate::error::collector::ErrorCollector;
use crate::error::context::ErrorContext;
use crate::error::context::TypeCheckContext;
use crate::error::kind::ErrorKind;
use crate::error::style::ErrorStyle;
use crate::export::exports::LookupExport;
use crate::graph::calculation::Calculation;
use crate::graph::index::Idx;
use crate::graph::index_map::IndexMap;
use crate::module::module_info::ModuleInfo;
use crate::module::module_name::ModuleName;
use crate::module::module_path::ModulePath;
use crate::solver::solver::Solver;
use crate::solver::type_order::TypeOrder;
use crate::table;
use crate::table_for_each;
use crate::table_mut_for_each;
use crate::table_try_for_each;
use crate::types::class::Class;
use crate::types::equality::TypeEq;
use crate::types::equality::TypeEqCtx;
use crate::types::stdlib::Stdlib;
use crate::types::types::AnyStyle;
use crate::types::types::Type;
use crate::types::types::Var;
use crate::util::display::DisplayWith;
use crate::util::display::DisplayWithCtx;
use crate::util::lock::Mutex;
use crate::util::prelude::SliceExt;
use crate::util::recurser::Recurser;
use crate::util::uniques::UniqueFactory;
use crate::util::visit::VisitMut;

#[derive(Debug, Default)]
pub struct Traces {
    types: SmallMap<TextRange, Arc<Type>>,
}

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
    trace: Option<Mutex<Traces>>,
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

pub type SolutionsEntry<K> = SmallMap<K, Arc<<K as Keyed>::Answer>>;

table!(
    // Only the exported keys are stored in the solutions table.
    #[derive(Default, Debug, Clone, PartialEq, Eq)]
    pub struct SolutionsTable(pub SolutionsEntry)
);

#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct Solutions(SolutionsTable);

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

        table_try_for_each!(&self.0, |x| go(x, f, ctx));
        Ok(())
    }
}

pub struct SolutionsDifference<'a> {
    key: (&'a dyn DisplayWith<ModuleInfo>, &'a dyn Debug),
    lhs: Option<(&'a dyn Display, &'a dyn Debug)>,
    rhs: Option<(&'a dyn Display, &'a dyn Debug)>,
}

impl Debug for SolutionsDifference<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SolutionsDifference")
            .field("key", self.key.1)
            .field("lhs", &self.lhs.map(|x| x.1))
            .field("rhs", &self.rhs.map(|x| x.1))
            .finish()
    }
}

impl Display for SolutionsDifference<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let missing = |f: &mut fmt::Formatter, x: Option<(&dyn Display, &dyn Debug)>| match x {
            None => write!(f, "missing"),
            Some(x) => write!(f, "`{}`", x.0),
        };

        // The key has type DisplayWith<ModuleInfo>.
        // We don't know if the key originates on the LHS or RHS, so we don't know which is the appropriate ModuleInfo.
        // However, we do know it is exported, and exported things can't rely on locations, so regardless
        // of the ModuleInfo, it should display the same. Therefore, we fake one up.
        let fake_module_info = ModuleInfo::new(
            ModuleName::builtins(),
            ModulePath::memory(PathBuf::new()),
            Default::default(),
        );

        write!(f, "`")?;
        self.key.0.fmt(f, &fake_module_info)?;
        write!(f, "` was ")?;
        missing(f, self.lhs)?;
        write!(f, " now ")?;
        missing(f, self.rhs)?;
        Ok(())
    }
}

impl Solutions {
    pub fn table(&self) -> &SolutionsTable {
        &self.0
    }

    pub fn get<K: Keyed<EXPORTED = true>>(&self, key: &K) -> Option<&Arc<<K as Keyed>::Answer>>
    where
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        self.0.get().get(key)
    }

    /// Find the first key that differs between two solutions, with the two values.
    ///
    /// Don't love that we always allocate String's for the result, but it's rare that
    /// there is a difference, and if there is, we'll do quite a lot of computation anyway.
    pub fn first_difference<'a>(&'a self, other: &'a Self) -> Option<SolutionsDifference<'a>> {
        fn f<'a, K: Keyed>(
            x: &'a SolutionsEntry<K>,
            y: &'a Solutions,
            ctx: &mut TypeEqCtx,
        ) -> Option<SolutionsDifference<'a>>
        where
            SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
        {
            let y = y.0.get::<K>();
            if y.len() > x.len() {
                for (k, v) in y.iter() {
                    if !x.contains_key(k) {
                        return Some(SolutionsDifference {
                            key: (k, k),
                            lhs: None,
                            rhs: Some((v, v)),
                        });
                    }
                }
                unreachable!();
            }
            for (k, v) in x.iter() {
                match y.get(k) {
                    Some(v2) if !v.type_eq(v2, ctx) => {
                        return Some(SolutionsDifference {
                            key: (k, k),
                            lhs: Some((v, v)),
                            rhs: Some((v2, v2)),
                        });
                    }
                    None => {
                        return Some(SolutionsDifference {
                            key: (k, k),
                            lhs: Some((v, v)),
                            rhs: None,
                        });
                    }
                    _ => {}
                }
            }
            None
        }

        let mut difference = None;
        // Important we have a single TypeEqCtx, so that we don't have
        // types used in different ways.
        let mut ctx = TypeEqCtx::default();
        table_for_each!(self.0, |x| {
            if difference.is_none() {
                difference = f(x, other, &mut ctx);
            }
        });
        difference
    }
}

#[derive(Clone)]
pub struct AnswersSolver<'a, Ans: LookupAnswer> {
    answers: &'a Ans,
    current: &'a Answers,
    // The base solver is only used to reset the error collector at binding
    // boundaries. Answers code should generally use the error collector passed
    // along the call stack instead.
    base_errors: &'a ErrorCollector,
    bindings: &'a Bindings,
    pub exports: &'a dyn LookupExport,
    pub uniques: &'a UniqueFactory,
    pub recurser: &'a Recurser<Var>,
    pub stdlib: &'a Stdlib,
}

pub trait LookupAnswer: Sized {
    fn get<K: Solve<Self> + Keyed<EXPORTED = true>>(
        &self,
        module: ModuleName,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>;
}

impl Answers {
    pub fn new(bindings: &Bindings, solver: Solver, enable_trace: bool) -> Self {
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
        let trace = if enable_trace {
            Some(Mutex::new(Traces::default()))
        } else {
            None
        };

        Self {
            solver,
            table,
            trace,
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
        compute_everything: bool,
    ) -> Solutions {
        let mut res = SolutionsTable::default();

        fn pre_solve<Ans: LookupAnswer, K: Solve<Ans>>(
            items: &mut SolutionsEntry<K>,
            answers: &AnswersSolver<Ans>,
            compute_everything: bool,
        ) where
            AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
            BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        {
            if K::EXPORTED {
                items.reserve(answers.bindings.keys::<K>().len());
            }
            if !K::EXPORTED
                && !compute_everything
                && answers.base_errors.style() == ErrorStyle::Never
            {
                // No point doing anything here.
                return;
            }
            for idx in answers.bindings.keys::<K>() {
                let v = answers.get_idx(idx);
                if K::EXPORTED {
                    let k = answers.bindings.idx_to_key(idx);
                    items.insert(k.clone(), v.dupe());
                }
            }
        }
        let answers_solver = AnswersSolver {
            stdlib,
            answers,
            bindings,
            base_errors: errors,
            exports,
            uniques,
            recurser: &Recurser::new(),
            current: self,
        };
        table_mut_for_each!(&mut res, |items| pre_solve(
            items,
            &answers_solver,
            compute_everything
        ));

        // Now force all types to be fully resolved.
        fn post_solve<K: Keyed>(items: &mut SolutionsEntry<K>, solver: &Solver) {
            for v in items.values_mut() {
                let mut vv = (**v).clone();
                vv.visit_mut(&mut |x| solver.deep_force_mut(x));
                *v = Arc::new(vv);
            }
        }
        table_mut_for_each!(&mut res, |items| post_solve(items, &self.solver));
        Solutions(res)
    }

    pub fn solve_exported_key<Ans: LookupAnswer, K: Solve<Ans> + Keyed<EXPORTED = true>>(
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
            base_errors: errors,
            exports,
            recurser: &Recurser::new(),
            current: self,
        };
        let v = solver.get(key);
        let mut vv = (*v).clone();
        vv.visit_mut(&mut |x| self.solver.deep_force_mut(x));
        Arc::new(vv)
    }

    pub fn get_idx<K: SolveRecursive>(&self, k: Idx<K>) -> Option<Arc<K::Answer>>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
    {
        self.table.get::<K>().get(k)?.get()
    }

    pub fn for_display(&self, t: Type) -> Type {
        self.solver.for_display(t)
    }

    pub fn get_type_trace(&self, range: TextRange) -> Option<Arc<Type>> {
        let lock = self.trace.as_ref()?.lock();
        lock.types.get(&range).duped()
    }
}

impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    pub fn new(
        answers: &'a Ans,
        current: &'a Answers,
        base_errors: &'a ErrorCollector,
        bindings: &'a Bindings,
        exports: &'a dyn LookupExport,
        uniques: &'a UniqueFactory,
        recurser: &'a Recurser<Var>,
        stdlib: &'a Stdlib,
    ) -> AnswersSolver<'a, Ans> {
        AnswersSolver {
            stdlib,
            uniques,
            answers,
            bindings,
            base_errors,
            exports,
            recurser,
            current,
        }
    }

    pub fn bindings(&self) -> &Bindings {
        self.bindings
    }

    pub fn module_info(&self) -> &ModuleInfo {
        self.bindings.module_info()
    }

    pub fn solver(&self) -> &Solver {
        &self.current.solver
    }

    pub fn for_display(&self, t: Type) -> Type {
        self.solver().for_display(t)
    }

    pub fn get_from_module<K: Solve<Ans> + Keyed<EXPORTED = true>>(
        &self,
        module: ModuleName,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        if module == self.module_info().name() {
            self.get(k)
        } else {
            self.answers.get(module, k)
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
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        self.get_from_module(cls.module_name(), k)
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
                K::solve(self, binding, self.base_errors)
            },
            || K::recursive(self),
        );
        if let Ok((v, Some(r))) = &result {
            let k = self.bindings().idx_to_key(idx);
            K::record_recursive(self, k, v.dupe(), r.clone(), self.base_errors);
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

    pub fn record_recursive(
        &self,
        loc: TextRange,
        answer: Arc<Type>,
        recursive: Var,
        errors: &ErrorCollector,
    ) {
        self.solver().record_recursive(
            recursive,
            answer.arc_clone(),
            self.type_order(),
            errors,
            loc,
        );
    }

    pub fn record_type_trace(&self, loc: TextRange, ty: &Type) {
        if let Some(trace) = &self.current.trace {
            trace.lock().types.insert(loc, Arc::new(ty.clone()));
        }
    }

    pub fn check_type(
        &self,
        want: &Type,
        got: &Type,
        loc: TextRange,
        errors: &ErrorCollector,
        tcc: &dyn Fn() -> TypeCheckContext,
    ) -> Type {
        if matches!(got, Type::Any(AnyStyle::Error)) {
            // Don't propagate errors
            got.clone()
        } else if self.solver().is_subset_eq(got, want, self.type_order()) {
            got.clone()
        } else {
            self.solver()
                .error(want, got, errors, ErrorKind::TypeMismatch, loc, tcc);
            want.clone()
        }
    }

    pub fn distribute_over_union(&self, ty: &Type, mut f: impl FnMut(&Type) -> Type) -> Type {
        match ty {
            Type::Union(tys) => self.unions(tys.map(f)),
            Type::Type(box Type::Union(tys)) => {
                self.unions(tys.map(|ty| f(&Type::type_form(ty.clone()))))
            }
            _ => f(ty),
        }
    }

    pub fn unions(&self, xs: Vec<Type>) -> Type {
        self.solver().unions(xs, self.type_order())
    }

    pub fn union(&self, x: Type, y: Type) -> Type {
        self.unions(vec![x, y])
    }

    pub fn todo(&self, errors: &ErrorCollector, msg: &str, x: impl Ranged + Debug) -> Type {
        errors.todo(msg, x);
        Type::any_error()
    }

    pub fn error(
        &self,
        errors: &ErrorCollector,
        range: TextRange,
        kind: ErrorKind,
        context: Option<&dyn Fn() -> ErrorContext>,
        msg: String,
    ) -> Type {
        errors.add(range, msg, kind, context);
        Type::any_error()
    }
}
