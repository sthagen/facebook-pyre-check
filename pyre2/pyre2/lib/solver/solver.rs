/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::collections::HashSet;
use std::fmt;
use std::fmt::Display;
use std::mem;

use ruff_python_ast::name::Name;
use ruff_text_size::TextRange;
use starlark_map::small_map::Entry;
use starlark_map::small_map::SmallMap;
use starlark_map::small_set::SmallSet;

use crate::alt::answers::LookupAnswer;
use crate::error::collector::ErrorCollector;
use crate::error::context::TypeCheckContext;
use crate::solver::type_order::TypeOrder;
use crate::types::callable::Callable;
use crate::types::callable::Function;
use crate::types::callable::Params;
use crate::types::module::Module;
use crate::types::quantified::QuantifiedKind;
use crate::types::simplify::simplify_tuples;
use crate::types::simplify::unions;
use crate::types::types::TParams;
use crate::types::types::Type;
use crate::types::types::Var;
use crate::util::lock::RwLock;
use crate::util::recurser::Recurser;
use crate::util::uniques::UniqueFactory;
use crate::util::visit::VisitMut;

/// Error message when a variable has leaked from one module to another.
///
/// We have a rule that `Var`'s should not leak from one module to another, but it has happened.
/// The easiest debugging technique is to look at the `Solutions` and see if there is a `Var(Unique`
/// in the output. The usual cause is that we failed to visit all the necessary `Type` fields.
const VAR_LEAK: &str = "Internal error: a variable has leaked from one module to another.";

#[derive(Debug, Clone, PartialEq, Eq)]
enum Variable {
    /// A variable in a container with an unspecified element type, e.g. `[]: list[V]`
    Contained,
    /// A variable due to generic instantitation, `def f[T](x: T): T` with `f(1)`
    /// The second value is the default value of the type parameter, if one exists
    Quantified(QuantifiedKind, Option<Type>),
    /// A variable caused by recursion, e.g. `x = f(); def f(): return x`
    Recursive,
    /// A variable that used to decompose a type, e.g. getting T from Awaitable[T]
    Unwrap,
    /// A variable we have solved
    Answer(Type),
}

impl Display for Variable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Variable::Contained => write!(f, "Contained"),
            Variable::Quantified(k, Some(t)) => write!(f, "Quantified({k}, default={t})"),
            Variable::Quantified(k, None) => write!(f, "Quantified({k})"),
            Variable::Recursive => write!(f, "Recursive"),
            Variable::Unwrap => write!(f, "Unwrap"),
            Variable::Answer(t) => write!(f, "{t}"),
        }
    }
}

impl Variable {
    /// For some types of variables we should promote literals, for others we should not.
    /// E.g. `x = 1; while True: x = x` should be `Literal[1]` while
    /// `[1]` should be `List[int]`.
    fn promote<Ans: LookupAnswer>(&self, ty: Type, type_order: TypeOrder<Ans>) -> Type {
        if matches!(self, Variable::Contained | Variable::Quantified(_, _)) {
            ty.promote_literals(type_order.stdlib())
        } else {
            ty
        }
    }
}

#[derive(Debug)]
pub struct Solver {
    variables: RwLock<SmallMap<Var, Variable>>,
}

impl Display for Solver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (x, y) in self.variables.read().iter() {
            writeln!(f, "{x} = {y}")?;
        }
        Ok(())
    }
}

/// A number chosen such that all practical types are less than this depth,
/// but we don't want to stack overflow.
const TYPE_LIMIT: usize = 20;

impl Solver {
    /// Create a new solver.
    pub fn new() -> Self {
        Self {
            variables: Default::default(),
        }
    }

    /// Expand a type. All variables that have been bound will be replaced with non-Var types,
    /// even if they are recursive (using `Any` for self-referential occurrences).
    /// Variables that have not yet been bound will remain as Var.
    ///
    /// In addition, if the type exceeds a large depth, it will be replaced with `Any`.
    pub fn expand(&self, mut t: Type) -> Type {
        self.expand_with_limit(&mut t, TYPE_LIMIT, &Recurser::new());
        t
    }

    /// Expand, but if the resulting type will be greater than limit levels deep, return an `Any`.
    /// Avoids producing things that stack overflow later in the process.
    fn expand_with_limit(&self, t: &mut Type, limit: usize, recurser: &Recurser<Var>) {
        if limit == 0 {
            // TODO: Should probably add an error here, and use any_error,
            // but don't have any good location information to hand.
            *t = Type::any_implicit();
        } else if let Type::Var(x) = t {
            if let Some(_guard) = recurser.recurse(*x) {
                if let Some(Variable::Answer(w)) = {
                    // Important we bind this lock in an inner scope, so it is dropped before
                    // we call expand_with_limit again.
                    let lock = self.variables.read();
                    lock.get(x).cloned()
                } {
                    *t = w;
                    self.expand_with_limit(t, limit - 1, recurser);
                }
            } else {
                *t = Type::any_implicit();
            }
        } else {
            t.recurse_mut(&mut |t| self.expand_with_limit(t, limit - 1, recurser));
        }
    }

    /// Given a `Var`, ensures that the solver has an answer for it (or inserts Any if not already),
    /// and returns that answer. Note that if the `Var` is already bound to something that contains a
    /// `Var` (including itself), then we will return the answer.
    pub fn force_var(&self, v: Var) -> Type {
        let mut lock = self.variables.write();
        let e = lock.get_mut(&v).expect(VAR_LEAK);
        match e {
            Variable::Answer(t) => t.clone(),
            _ => {
                let mut default = None;
                let quantified_kind = if let Variable::Quantified(q, default_value) = e {
                    default = default_value.clone();
                    *q
                } else {
                    QuantifiedKind::TypeVar
                };
                let res = default.unwrap_or_else(|| quantified_kind.empty_value());
                *e = Variable::Answer(res.clone());
                res
            }
        }
    }

    fn deep_force_mut_with_limit(&self, t: &mut Type, limit: usize, recurser: &Recurser<Var>) {
        if limit == 0 {
            // TODO: Should probably add an error here, and use any_error,
            // but don't have any good location information to hand.
            *t = Type::any_implicit();
        } else if let Type::Var(v) = t {
            if let Some(_guard) = recurser.recurse(*v) {
                *t = self.force_var(*v);
                self.deep_force_mut_with_limit(t, limit - 1, recurser);
            } else {
                *t = Type::any_implicit();
            }
        } else {
            t.recurse_mut(&mut |t| self.deep_force_mut_with_limit(t, limit - 1, recurser));
        }
    }

    /// A version of `deep_force` that works in-place on a `Type`.
    pub fn deep_force_mut(&self, t: &mut Type) {
        self.deep_force_mut_with_limit(t, TYPE_LIMIT, &Recurser::new());
        // After forcing, we might be able to simplify some unions
        self.simplify_mut(t);
    }

    /// Simplify a type as much as we can.
    fn simplify_mut(&self, t: &mut Type) {
        t.transform_mut(&mut |x| {
            if let Type::Union(xs) = x {
                *x = unions(mem::take(xs));
            }
            if let Type::Tuple(tuple) = x {
                *x = simplify_tuples(mem::take(tuple));
            }
            // When a param spec is resolved, collapse any Concatenate and Callable types that use it
            if let Type::Concatenate(box ts, box Type::ParamSpecValue(paramlist)) = x {
                let params = mem::take(paramlist).prepend_types(ts).into_owned();
                *x = Type::ParamSpecValue(params);
            }
            if let Type::Concatenate(box ts, box Type::Concatenate(ts2, pspec)) = x {
                *x = Type::Concatenate(
                    ts.iter().chain(ts2.iter()).cloned().collect(),
                    pspec.clone(),
                );
            }
            let (callable, kind) = match x {
                Type::Callable(box c) => (Some(c), None),
                Type::Function(box Function {
                    signature: c,
                    metadata: k,
                }) => (Some(c), Some(k)),
                _ => (None, None),
            };
            if let Some(Callable {
                params: Params::ParamSpec(box ts, pspec),
                ret,
            }) = callable
            {
                let new_callable = |c| {
                    if let Some(k) = kind {
                        Type::Function(Box::new(Function {
                            signature: c,
                            metadata: k.clone(),
                        }))
                    } else {
                        Type::Callable(Box::new(c))
                    }
                };
                match pspec {
                    Type::ParamSpecValue(paramlist) => {
                        let params = mem::take(paramlist).prepend_types(ts).into_owned();
                        let new_callable = new_callable(Callable::list(params, ret.clone()));
                        *x = new_callable;
                    }
                    Type::Ellipsis if ts.is_empty() => {
                        *x = new_callable(Callable::ellipsis(ret.clone()));
                    }
                    Type::Concatenate(box ts2, box pspec) => {
                        *x = new_callable(Callable::concatenate(
                            ts.iter().chain(ts2.iter()).cloned().collect(),
                            pspec.clone(),
                            ret.clone(),
                        ));
                    }
                    _ => {}
                }
            }
        });
    }

    /// Like [`expand`], but also forces variables that haven't yet been bound
    /// to become `Any`, both in the result and in the `Solver` going forward.
    /// Guarantees there will be no `Var` in the result.
    ///
    /// In addition, if the type exceeds a large depth, it will be replaced with `Any`.
    pub fn deep_force(&self, mut t: Type) -> Type {
        self.deep_force_mut(&mut t);
        t
    }

    /// Generate a fresh variable based on code that is unspecified inside a container,
    /// e.g. `[]` with an unknown type of element.
    pub fn fresh_contained(&self, uniques: &UniqueFactory) -> Var {
        let v = Var::new(uniques);
        self.variables.write().insert(v, Variable::Contained);
        v
    }

    // Generate a fresh variable used to decompose a type, e.g. getting T from Awaitable[T]
    pub fn fresh_unwrap(&self, uniques: &UniqueFactory) -> Var {
        let v = Var::new(uniques);
        self.variables.write().insert(v, Variable::Unwrap);
        v
    }

    /// Generate fresh variables and substitute them in replacing a `Forall`.
    pub fn fresh_quantified(
        &self,
        params: &TParams,
        t: Type,
        uniques: &UniqueFactory,
    ) -> (Vec<Var>, Type) {
        let vs: Vec<Var> = params.iter().map(|_| Var::new(uniques)).collect();
        let t = t.subst(
            &params
                .iter()
                .map(|p| p.quantified)
                .zip(vs.iter().map(|x| x.to_type()))
                .collect(),
        );
        let mut lock = self.variables.write();
        for (v, param) in vs.iter().zip(params.iter()) {
            lock.insert(
                *v,
                Variable::Quantified(param.quantified.kind(), param.default.clone()),
            );
        }
        (vs, t)
    }

    /// Called after a quantified function has been called. Given `def f[T](x: int): list[T]`,
    /// after the generic has completed, the variable `T` now behaves more like an empty container
    /// than a generic. If it hasn't been solved, make that switch.
    pub fn finish_quantified(&self, vs: &[Var]) {
        let mut lock = self.variables.write();
        for v in vs {
            let e = lock.get_mut(v).expect(VAR_LEAK);
            if matches!(*e, Variable::Quantified(_, _)) {
                *e = Variable::Contained;
            }
        }
    }

    /// Generate a fresh variable used to tie recursive bindings.
    pub fn fresh_recursive(&self, uniques: &UniqueFactory) -> Var {
        let v = Var::new(uniques);
        self.variables.write().insert(v, Variable::Recursive);
        v
    }

    pub fn for_display(&self, t: Type) -> Type {
        let mut t = self.expand(t);
        self.simplify_mut(&mut t);
        t.deterministic_printing()
    }

    /// Generate an error message that `got <: want` failed.
    pub fn error(
        &self,
        want: &Type,
        got: &Type,
        errors: &ErrorCollector,
        loc: TextRange,
        tcc: &dyn Fn() -> TypeCheckContext,
    ) {
        let tcc = tcc();
        let msg = tcc.kind.format_error(
            &self.for_display(got.clone()),
            &self.for_display(want.clone()),
            errors.module_info().name(),
        );
        let kind = tcc.kind.as_error_kind();
        match tcc.context {
            Some(ctx) => {
                errors.add(loc, msg, kind, Some(&|| ctx.clone()));
            }
            None => {
                errors.add(loc, msg, kind, None);
            }
        }
    }

    /// Union a list of types together. In the process may cause some variables to be forced.
    pub fn unions<Ans: LookupAnswer>(
        &self,
        branches: Vec<Type>,
        type_order: TypeOrder<Ans>,
    ) -> Type {
        if branches.is_empty() {
            return Type::never();
        }
        for b in &branches[1..] {
            // Do the is_subset_eq only to force free variables
            Subset {
                solver: self,
                type_order,
                union: true,
                gas: 25,
                recursive_assumptions: SmallSet::new(),
            }
            .is_subset_eq(&branches[0], b);
        }

        // We want to union modules differently, by merging their module sets
        let mut modules: SmallMap<Vec<Name>, Module> = SmallMap::new();
        let mut branches = branches
            .into_iter()
            .flat_map(|x| match x {
                // Maybe we should force x before looking at it, but that causes issues with
                // recursive variables that we can't examine.
                // In practice unlikely anyone has a recursive variable which evaluates to a module.
                Type::Module(m) => {
                    match modules.entry(m.path().to_owned()) {
                        Entry::Occupied(mut e) => {
                            e.get_mut().merge(&m);
                        }
                        Entry::Vacant(e) => {
                            e.insert(m);
                        }
                    }
                    None
                }
                t => Some(t),
            })
            .collect::<Vec<_>>();
        branches.extend(modules.into_values().map(Type::Module));

        unions(branches)
    }

    /// Record a variable that is used recursively.
    pub fn record_recursive<Ans: LookupAnswer>(
        &self,
        v: Var,
        t: Type,
        type_order: TypeOrder<Ans>,
        errors: &ErrorCollector,
        loc: TextRange,
    ) {
        fn expand(
            t: Type,
            variables: &SmallMap<Var, Variable>,
            seen: &mut HashSet<Var>,
            res: &mut Vec<Type>,
        ) {
            match t {
                Type::Var(v) if seen.insert(v) => {
                    match variables.get(&v) {
                        Some(Variable::Answer(t)) => {
                            expand(t.clone(), variables, seen, res);
                        }
                        _ => res.push(v.to_type()),
                    }
                    seen.remove(&v);
                }
                Type::Union(ts) => {
                    for t in ts {
                        expand(t, variables, seen, res);
                    }
                }
                _ => res.push(t),
            }
        }

        let mut lock = self.variables.write();
        match lock.get(&v) {
            Some(Variable::Answer(got)) => {
                let got = got.clone();
                drop(lock);
                // We got forced into choosing a type to satisfy a subset constraint, so check we are OK with that.
                if !self.is_subset_eq(&got, &t, type_order) {
                    self.error(&t, &got, errors, loc, &|| TypeCheckContext::unknown());
                }
            }
            _ => {
                // If you are recording `@1 = @1 | something` then the `@1` can't contribute any
                // possibilities, so just ignore it.
                let mut res = Vec::new();
                // First expand all union/var into a list of the possible unions
                expand(t, &lock, &mut HashSet::new(), &mut res);
                // Then remove any reference to self, before unioning it back together
                res.retain(|x| x != &Type::Var(v));
                lock.insert(v, Variable::Answer(unions(res)));
            }
        }
    }

    /// Is `got <: want`? If you aren't sure, return `false`.
    /// May cause contained variables to be resolved to an answer.
    pub fn is_subset_eq<Ans: LookupAnswer>(
        &self,
        got: &Type,
        want: &Type,
        type_order: TypeOrder<Ans>,
    ) -> bool {
        Subset {
            solver: self,
            type_order,
            union: false,
            gas: 25,
            recursive_assumptions: SmallSet::new(),
        }
        .is_subset_eq(got, want)
    }
}

/// A helper to implement subset erogonomically.
/// Should only be used within `crate::subset`, which implements part of it.
pub struct Subset<'a, Ans: LookupAnswer> {
    solver: &'a Solver,
    pub type_order: TypeOrder<'a, Ans>,
    // True if we are doing a union, false if we are actually checking for subset.
    union: bool,
    gas: usize,
    /// Recursive assumptions of pairs of types that is_subset_eq returns true for.
    /// Used for structural typechecking of protocols.
    pub recursive_assumptions: SmallSet<(Type, Type)>,
}

impl<'a, Ans: LookupAnswer> Subset<'a, Ans> {
    pub fn force_var(&self, v: Var) -> Type {
        self.solver.force_var(v)
    }

    pub fn is_equal(&mut self, got: &Type, want: &Type) -> bool {
        self.is_subset_eq(got, want) && self.is_subset_eq(want, got)
    }

    pub fn is_subset_eq(&mut self, got: &Type, want: &Type) -> bool {
        if self.gas == 0 {
            // We really have no idea. Just give up for now.
            return false;
        }
        self.gas -= 1;
        let res = self.is_subset_eq_var(got, want);
        self.gas += 1;
        res
    }

    /// Implementation of Var subset cases, calling onward to solve non-Var cases.
    fn is_subset_eq_var(&mut self, got: &Type, want: &Type) -> bool {
        // This function does two things: it checks that got <: want, and it solves free variables assuming that
        // got <: want. Most callers want both behaviors. The exception is that in a union, we call is_subset_eq
        // for the sole purpose of solving contained variables, throwing away the check result.
        let should_force = |v: &Variable| !self.union || matches!(v, Variable::Contained);
        match (got, want) {
            _ if got == want => true,
            (Type::Var(v1), Type::Var(v2)) => {
                let mut variables = self.solver.variables.write();
                match (
                    variables.get(v1).expect(VAR_LEAK).clone(),
                    variables.get(v2).expect(VAR_LEAK).clone(),
                ) {
                    (Variable::Answer(t1), Variable::Answer(t2)) => {
                        drop(variables);
                        self.is_subset_eq(&t1, &t2)
                    }
                    (var_type, Variable::Answer(t2)) if should_force(&var_type) => {
                        if *got != t2 {
                            variables.insert(*v1, Variable::Answer(t2.clone()));
                        }
                        true
                    }
                    (Variable::Answer(t1), var_type) if should_force(&var_type) => {
                        if t1 != *want {
                            // Note that we promote the type when the var is on the RHS, but not when it's on the
                            // LHS, so that we infer more general types but leave user-specified types alone.
                            variables.insert(
                                *v2,
                                Variable::Answer(var_type.promote(t1, self.type_order)),
                            );
                        }
                        true
                    }
                    (var_type1, var_type2)
                        if should_force(&var_type1) && should_force(&var_type2) =>
                    {
                        // Tie the variables together. Doesn't matter which way round we do it.
                        variables.insert(*v1, Variable::Answer(Type::Var(*v2)));
                        true
                    }
                    (_, _) => false,
                }
            }
            (Type::Var(v1), t2) => {
                let mut variables = self.solver.variables.write();
                match variables.get(v1).expect(VAR_LEAK).clone() {
                    Variable::Answer(t1) => {
                        drop(variables);
                        self.is_subset_eq(&t1, t2)
                    }
                    var_type if should_force(&var_type) => {
                        variables.insert(*v1, Variable::Answer(t2.clone()));
                        true
                    }
                    _ => false,
                }
            }
            (t1, Type::Var(v2)) => {
                let mut variables = self.solver.variables.write();
                match variables.get(v2).expect(VAR_LEAK).clone() {
                    Variable::Answer(t2) => {
                        drop(variables);
                        self.is_subset_eq(t1, &t2)
                    }
                    var_type if should_force(&var_type) => {
                        // Note that we promote the type when the var is on the RHS, but not when it's on the
                        // LHS, so that we infer more general types but leave user-specified types alone.
                        variables.insert(
                            *v2,
                            Variable::Answer(var_type.promote(t1.clone(), self.type_order)),
                        );
                        true
                    }
                    _ => false,
                }
            }
            _ => self.is_subset_eq_impl(got, want),
        }
    }
}
