/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Debug;
use std::fmt::Display;
use std::mem;
use std::sync::Arc;

use dupe::Dupe;
use itertools::Either;
use itertools::Itertools;
use ruff_python_ast::name::Name;
use ruff_python_ast::AnyParameterRef;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprAttribute;
use ruff_python_ast::ExprName;
use ruff_python_ast::ExprYield;
use ruff_python_ast::ExprYieldFrom;
use ruff_python_ast::Identifier;
use ruff_python_ast::Stmt;
use ruff_python_ast::StmtReturn;
use ruff_python_ast::TypeParam;
use ruff_python_ast::TypeParams;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use ruff_text_size::TextSize;
use starlark_map::small_map::SmallMap;
use starlark_map::small_set::SmallSet;
use vec1::Vec1;

use crate::binding::binding::Binding;
use crate::binding::binding::BindingAnnotation;
use crate::binding::binding::BindingLegacyTypeParam;
use crate::binding::binding::BindingYield;
use crate::binding::binding::BindingYieldFrom;
use crate::binding::binding::Key;
use crate::binding::binding::KeyAnnotation;
use crate::binding::binding::KeyExport;
use crate::binding::binding::KeyFunction;
use crate::binding::binding::KeyLegacyTypeParam;
use crate::binding::binding::KeyYield;
use crate::binding::binding::KeyYieldFrom;
use crate::binding::binding::Keyed;
use crate::binding::narrow::NarrowOps;
use crate::binding::scope::Flow;
use crate::binding::scope::FlowInfo;
use crate::binding::scope::FlowStyle;
use crate::binding::scope::InstanceAttribute;
use crate::binding::scope::Loop;
use crate::binding::scope::LoopExit;
use crate::binding::scope::ScopeKind;
use crate::binding::scope::ScopeTrace;
use crate::binding::scope::Scopes;
use crate::binding::table::TableKeyed;
use crate::error::collector::ErrorCollector;
use crate::error::kind::ErrorKind;
use crate::export::exports::Exports;
use crate::export::exports::LookupExport;
use crate::export::special::SpecialEntry;
use crate::export::special::SpecialEnv;
use crate::export::special::SpecialExport;
use crate::graph::index::Idx;
use crate::graph::index::Index;
use crate::graph::index_map::IndexMap;
use crate::metadata::RuntimeMetadata;
use crate::module::module_info::ModuleInfo;
use crate::module::module_name::ModuleName;
use crate::module::short_identifier::ShortIdentifier;
use crate::solver::solver::Solver;
use crate::table;
use crate::table_for_each;
use crate::table_try_for_each;
use crate::types::quantified::Quantified;
use crate::types::types::AnyStyle;
use crate::types::types::Var;
use crate::util::display::DisplayWith;
use crate::util::uniques::UniqueFactory;

#[derive(Clone, Dupe, Debug)]
pub struct Bindings(Arc<BindingsInner>);

pub type BindingEntry<K> = (Index<K>, IndexMap<K, <K as Keyed>::Value>);

table! {
    #[derive(Debug, Clone, Default)]
    pub struct BindingTable(pub BindingEntry)
}

#[derive(Clone, Debug)]
struct BindingsInner {
    module_info: ModuleInfo,
    table: BindingTable,
    scope_trace: Option<ScopeTrace>,
}

impl Display for Bindings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fn go<K: Keyed>(
            items: &BindingEntry<K>,
            me: &Bindings,
            f: &mut fmt::Formatter<'_>,
        ) -> fmt::Result {
            for (idx, k) in items.0.items() {
                writeln!(
                    f,
                    "{} = {}",
                    me.module_info().display(k),
                    items.1.get_exists(idx).display_with(me)
                )?;
            }
            Ok(())
        }
        table_try_for_each!(self.0.table, |items| go(items, self, f));
        Ok(())
    }
}

pub struct BindingsBuilder<'a> {
    pub module_info: ModuleInfo,
    pub lookup: &'a dyn LookupExport,
    pub config: &'a RuntimeMetadata,
    errors: &'a ErrorCollector,
    solver: &'a Solver,
    uniques: &'a UniqueFactory,
    pub scopes: Scopes,
    pub functions: Vec1<FuncInfo>,
    pub table: BindingTable,
}

/// Things we collect from inside a function
#[derive(Default, Clone, Debug)]
pub struct FuncInfo {
    pub returns: Vec<StmtReturn>,
    pub yields: Vec<Either<ExprYield, ExprYieldFrom>>,
}

impl Bindings {
    #[expect(dead_code)] // Useful API
    fn len(&self) -> usize {
        let mut res = 0;
        table_for_each!(&self.0.table, |x: &BindingEntry<_>| res += x.1.len());
        res
    }

    pub fn display<K: Keyed>(&self, idx: Idx<K>) -> impl Display + '_
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.module_info().display(self.idx_to_key(idx))
    }

    pub fn module_info(&self) -> &ModuleInfo {
        &self.0.module_info
    }

    pub fn available_definitions(&self, position: TextSize) -> SmallSet<Idx<Key>> {
        if let Some(trace) = &self.0.scope_trace {
            trace.available_definitions(&self.0.table, position)
        } else {
            SmallSet::new()
        }
    }

    pub fn key_to_idx<K: Keyed>(&self, k: &K) -> Idx<K>
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().0.key_to_idx(k).unwrap_or_else(|| {
            panic!(
                "key_to_idx - key not found, module `{}`, path `{}`, key {k:?}",
                self.0.module_info.name(),
                self.0.module_info.path(),
            )
        })
    }

    pub fn get<K: Keyed>(&self, idx: Idx<K>) -> &K::Value
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().1.get(idx).unwrap_or_else(|| {
            let key = self.idx_to_key(idx);
            panic!(
                "Internal error: key lacking binding, module={}, path={}, key={}, key-debug={key:?}",
                self.module_info().name(),
                self.module_info().path(),
                self.module_info().display(key),
            )
        })
    }

    pub fn idx_to_key<K: Keyed>(&self, idx: Idx<K>) -> &K
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().0.idx_to_key(idx)
    }

    pub fn keys<K: Keyed>(&self) -> impl ExactSizeIterator<Item = Idx<K>> + '_
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().0.items().map(|(k, _)| k)
    }

    pub fn get_lambda_param(&self, name: &Identifier) -> Var {
        let b = self.get(self.key_to_idx(&Key::Definition(ShortIdentifier::new(name))));
        if let Binding::LambdaParameter(var) = b {
            *var
        } else {
            panic!(
                "Internal error: unexpected binding for lambda parameter `{}` @  {:?}: {}, module={}, path={}",
                &name.id,
                name.range,
                b.display_with(self),
                self.module_info().name(),
                self.module_info().path(),
            )
        }
    }

    pub fn get_function_param(&self, name: &Identifier) -> Either<Idx<KeyAnnotation>, Var> {
        let b = self.get(self.key_to_idx(&Key::Definition(ShortIdentifier::new(name))));
        if let Binding::FunctionParameter(p) = b {
            match p {
                Either::Left(idx) => Either::Left(*idx),
                Either::Right((var, _)) => Either::Right(*var),
            }
        } else {
            panic!(
                "Internal error: unexpected binding for parameter `{}` @  {:?}: {}, module={}, path={}",
                &name.id,
                name.range,
                b.display_with(self),
                self.module_info().name(),
                self.module_info().path(),
            )
        }
    }

    pub fn new(
        module_scope_range: TextRange,
        x: Vec<Stmt>,
        module_info: ModuleInfo,
        exports: Exports,
        solver: &Solver,
        lookup: &dyn LookupExport,
        config: &RuntimeMetadata,
        errors: &ErrorCollector,
        uniques: &UniqueFactory,
        enable_trace: bool,
    ) -> Self {
        let mut builder = BindingsBuilder {
            module_info: module_info.dupe(),
            lookup,
            config,
            errors,
            solver,
            uniques,
            scopes: Scopes::module(module_scope_range, enable_trace),
            functions: Vec1::new(FuncInfo::default()),
            table: Default::default(),
        };
        builder.init_static_scope(&x, true);
        if module_info.name() != ModuleName::builtins() {
            builder.inject_builtins();
        }
        builder.stmts(x);
        // Create dummy bindings for any invalid yield/yield from expressions.
        let (func_info, _) = builder.functions.split_off_first();
        for x in func_info.yields {
            match x {
                Either::Left(x) => {
                    builder
                        .table
                        .insert(KeyYield(x.range), BindingYield::Invalid(x));
                }
                Either::Right(x) => {
                    builder
                        .table
                        .insert(KeyYieldFrom(x.range), BindingYieldFrom::Invalid(x));
                }
            }
        }
        for x in func_info.returns {
            if let Some(x) = x.value {
                builder
                    .table
                    .insert(Key::Anon(x.range()), Binding::Expr(None, *x));
            }
            errors.add(
                x.range,
                "Invalid `return` outside of a function".to_owned(),
                ErrorKind::Unknown,
            );
        }
        let scope_trace = builder.scopes.finish();
        let last_scope = scope_trace.toplevel_scope();
        for (k, static_info) in &last_scope.stat.0 {
            let info = last_scope.flow.info.get(k);
            let val = match info {
                Some(FlowInfo { key, .. }) => {
                    if let Some(ann) = static_info.annot {
                        Binding::AnnotatedType(ann, Box::new(Binding::Forward(*key)))
                    } else {
                        Binding::Forward(*key)
                    }
                }
                None => {
                    // We think we have a binding for this, but we didn't encounter a flow element, so have no idea of what.
                    // This might be because we haven't fully implemented all bindings, or because the two disagree. Just guess.
                    errors.add(
                        static_info.loc,
                        format!("Could not find flow binding for `{k}`"),
                        ErrorKind::Unknown,
                    );
                    Binding::AnyType(AnyStyle::Error)
                }
            };
            if exports.contains(k, lookup) {
                builder.table.insert(KeyExport(k.clone()), val);
            }
        }
        Self(Arc::new(BindingsInner {
            module_info,
            table: builder.table,
            scope_trace: if enable_trace {
                Some(scope_trace)
            } else {
                None
            },
        }))
    }
}

impl BindingTable {
    pub fn insert<K: Keyed>(&mut self, key: K, value: K::Value) -> Idx<K>
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        let entry = self.get_mut::<K>();
        let idx = entry.0.insert(key);
        self.insert_idx(idx, value)
    }

    pub fn insert_idx<K: Keyed>(&mut self, idx: Idx<K>, value: K::Value) -> Idx<K>
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        let entry = self.get_mut::<K>();
        let existing = entry.1.insert(idx, value);
        if let Some(existing) = existing {
            panic!(
                "Key {:?} already exists with value {:?}, cannot insert new value {:?}",
                entry.0.idx_to_key(idx),
                existing,
                entry.1.get_exists(idx)
            );
        }
        idx
    }

    fn insert_anywhere(
        &mut self,
        name: Name,
        range: TextRange,
    ) -> (Idx<Key>, &mut SmallSet<Idx<Key>>) {
        let idx = self.types.0.insert(Key::Anywhere(name, range));
        match self
            .types
            .1
            .insert_if_missing(idx, || Binding::Phi(SmallSet::new()))
        {
            Binding::Phi(phi) => (idx, phi),
            _ => unreachable!(),
        }
    }
}

impl<'a> BindingsBuilder<'a> {
    pub fn init_static_scope(&mut self, x: &[Stmt], top_level: bool) {
        self.scopes.current_mut().stat.stmts(
            x,
            &self.module_info,
            top_level,
            self.lookup,
            self.config,
            |x| {
                self.table
                    .annotations
                    .0
                    .insert(KeyAnnotation::Annotation(x))
            },
        );
    }

    pub fn stmts(&mut self, xs: Vec<Stmt>) {
        for x in xs {
            self.stmt(x);
        }
    }

    fn inject_builtins(&mut self) {
        let builtins_module = ModuleName::builtins();
        match self.lookup.get(builtins_module) {
            Ok(builtins_export) => {
                for name in builtins_export.wildcard(self.lookup).iter() {
                    let key = Key::Import(name.clone(), TextRange::default());
                    let idx = self
                        .table
                        .insert(key, Binding::Import(builtins_module, name.clone()));
                    self.bind_key(
                        name,
                        idx,
                        Some(FlowStyle::Import(builtins_module, name.clone())),
                    );
                }
            }
            Err(err) => {
                self.error(TextRange::default(), err.display(builtins_module));
            }
        }
    }

    pub fn todo(&mut self, msg: &str, x: impl Ranged + Debug) {
        self.errors.todo(msg, x);
    }

    pub fn as_special_export(&self, e: &Expr) -> Option<SpecialExport> {
        SpecialExport::as_special_export(self, e)
    }

    pub fn error(&self, range: TextRange, msg: String) {
        self.errors.add(range, msg, ErrorKind::Unknown);
    }

    fn lookup_name(&mut self, name: &Name) -> Option<Idx<Key>> {
        let mut barrier = false;
        for scope in self.scopes.iter_rev() {
            if !barrier && let Some(flow) = scope.flow.info.get(name) {
                return Some(flow.key);
            } else if !matches!(scope.kind, ScopeKind::ClassBody(_))
                && let Some(info) = scope.stat.0.get(name)
            {
                let key = info.as_key(name);
                return Some(self.table.types.0.insert(key));
            }
            barrier = barrier || scope.barrier;
        }
        None
    }

    pub fn forward_lookup(&mut self, name: &Identifier) -> Option<Binding> {
        self.lookup_name(&name.id).map(Binding::Forward)
    }

    pub fn lookup_legacy_tparam(
        &mut self,
        name: &Identifier,
    ) -> Either<Idx<KeyLegacyTypeParam>, Option<Idx<Key>>> {
        let found = self.lookup_name(&name.id);
        if let Some(mut idx) = found {
            loop {
                if let Some(b) = self.table.types.1.get(idx) {
                    match b {
                        Binding::Forward(fwd_idx) => {
                            idx = *fwd_idx;
                            continue;
                        }
                        Binding::TypeVar(..)
                        | Binding::ParamSpec(..)
                        | Binding::TypeVarTuple(..) => {
                            return Either::Left(self.table.insert(
                                KeyLegacyTypeParam(ShortIdentifier::new(name)),
                                BindingLegacyTypeParam(idx),
                            ));
                        }
                        Binding::Import(..) => {
                            // TODO: We need to recursively look through imports to determine
                            // whether it is a legacy type parameter. We can't simply walk through
                            // bindings, because we could recursively reach ourselves, resulting in
                            // a deadlock.
                            return Either::Left(self.table.insert(
                                KeyLegacyTypeParam(ShortIdentifier::new(name)),
                                BindingLegacyTypeParam(idx),
                            ));
                        }
                        _ => {}
                    }
                }
                break;
            }
        }
        Either::Right(found)
    }

    pub fn bind_definition(
        &mut self,
        name: &Identifier,
        binding: Binding,
        style: Option<FlowStyle>,
    ) -> Option<Idx<KeyAnnotation>> {
        let idx = self
            .table
            .insert(Key::Definition(ShortIdentifier::new(name)), binding);
        self.bind_key(&name.id, idx, style)
    }

    pub fn bind_assign(
        &mut self,
        name: &ExprName,
        binding: impl FnOnce(Option<Idx<KeyAnnotation>>) -> Binding,
    ) {
        let key = Key::Definition(ShortIdentifier::expr_name(name));
        let idx = self.table.types.0.insert(key);
        let ann = self.bind_key(&name.id, idx, None);
        self.table.types.1.insert(idx, binding(ann));
    }

    /// In methods, we track assignments to `self` attribute targets so that we can
    /// be aware of class fields defined in methods.
    ///
    /// We currently apply this logic in all methods, although downstream code only uses
    /// attributes defined in constructors; this may change in the future.
    ///
    /// Returns `true` if the attribute was a self attribute.
    pub fn bind_attr_if_self(
        &mut self,
        x: &ExprAttribute,
        binding: Binding,
        annotation: Option<Idx<KeyAnnotation>>,
    ) -> bool {
        for scope in self.scopes.iter_rev_mut() {
            if let ScopeKind::Method(method) = &mut scope.kind
                && let Some(self_name) = &method.self_name
                && matches!(&*x.value, Expr::Name(name) if name.id == self_name.id)
            {
                if !method.instance_attributes.contains_key(&x.attr.id) {
                    method.instance_attributes.insert(
                        x.attr.id.clone(),
                        InstanceAttribute(binding, annotation, x.attr.range()),
                    );
                }
                return true;
            }
        }
        false
    }

    /// Return the annotation that should be used at the moment, if one was provided.
    pub fn bind_key(
        &mut self,
        name: &Name,
        key: Idx<Key>,
        style: Option<FlowStyle>,
    ) -> Option<Idx<KeyAnnotation>> {
        self.scopes.update_flow_info(name, key, style);
        let info = self.scopes.current().stat.0.get(name).unwrap_or_else(|| {
            let module = self.module_info.name();
            panic!("Name `{name}` not found in static scope of module `{module}`")
        });
        if info.count > 1 {
            self.table
                .insert_anywhere(name.clone(), info.loc)
                .1
                .insert(key);
        }
        info.annot
    }

    pub fn type_params(&mut self, x: &mut TypeParams) -> Vec<Quantified> {
        let mut qs = Vec::new();
        for x in x.type_params.iter_mut() {
            let q = match x {
                TypeParam::TypeVar(x) => {
                    if let Some(bound) = &mut x.bound {
                        self.ensure_type(bound, &mut None);
                    }
                    if let Some(default) = &mut x.default {
                        self.ensure_type(default, &mut None);
                    }
                    Quantified::type_var(self.uniques)
                }
                TypeParam::ParamSpec(_) => Quantified::param_spec(self.uniques),
                TypeParam::TypeVarTuple(_) => Quantified::type_var_tuple(self.uniques),
            };
            qs.push(q);
            let name = x.name();
            self.scopes
                .current_mut()
                .stat
                .add(name.id.clone(), name.range, None);
            self.bind_definition(name, Binding::TypeParameter(q), None);
        }
        qs
    }

    pub fn add_loop_exitpoint(&mut self, exit: LoopExit, range: TextRange) {
        let scope = self.scopes.current_mut();
        let flow = scope.flow.clone();
        if let Some(innermost) = scope.loops.last_mut() {
            innermost.0.push((exit, flow));
            scope.flow.no_next = true;
        } else {
            self.error(range, format!("Cannot `{exit}` outside loop"));
        }
    }

    pub fn bind_narrow_ops(&mut self, narrow_ops: &NarrowOps, use_range: TextRange) {
        for (name, (op, op_range)) in narrow_ops.0.iter() {
            if let Some(name_key) = self.lookup_name(name) {
                let binding_key = self.table.insert(
                    Key::Narrow(name.clone(), *op_range, use_range),
                    Binding::Narrow(name_key, op.clone()),
                );
                self.scopes.update_flow_info(name, binding_key, None);
            }
        }
    }

    pub fn bind_lambda_param(&mut self, name: &Identifier) {
        let var = self.solver.fresh_contained(self.uniques);
        let bind_key = self.table.insert(
            Key::Definition(ShortIdentifier::new(name)),
            Binding::LambdaParameter(var),
        );
        self.scopes
            .current_mut()
            .stat
            .add(name.id.clone(), name.range, None);
        self.bind_key(&name.id, bind_key, None);
    }

    pub fn bind_function_param(
        &mut self,
        x: AnyParameterRef,
        function_idx: Idx<KeyFunction>,
        self_type: Option<Idx<Key>>,
    ) {
        let name = x.name();
        let annot = x.annotation().map(|x| {
            self.table.insert(
                KeyAnnotation::Annotation(ShortIdentifier::new(name)),
                BindingAnnotation::AnnotateExpr(x.clone(), self_type),
            )
        });
        let (annot, def) = match annot {
            Some(annot) => (annot, Either::Left(annot)),
            None => {
                let var = self.solver.fresh_contained(self.uniques);
                let annot = self.table.insert(
                    KeyAnnotation::Annotation(ShortIdentifier::new(name)),
                    BindingAnnotation::Type(var.to_type()),
                );
                (annot, Either::Right((var, function_idx)))
            }
        };
        let key = self.table.insert(
            Key::Definition(ShortIdentifier::new(name)),
            Binding::FunctionParameter(def),
        );
        self.scopes
            .current_mut()
            .stat
            .add(name.id.clone(), name.range, Some(annot));
        self.bind_key(
            &name.id,
            key,
            Some(FlowStyle::Annotated {
                is_initialized: x.default().is_some(),
            }),
        );
    }

    /// Helper for loops, inserts a phi key for every name in the given flow.
    fn insert_phi_keys(&mut self, x: Flow, range: TextRange) -> Flow {
        let items = x
            .info
            .iter_hashed()
            .map(|x| x.0.cloned())
            .collect::<SmallSet<_>>();
        let mut res = SmallMap::with_capacity(items.len());
        for name in items.into_iter() {
            let key = self
                .table
                .types
                .0
                .insert(Key::Phi(name.key().clone(), range));
            let style = x
                .info
                .get_hashed(name.as_ref())
                .and_then(|old_info| old_info.style.clone());
            res.insert_hashed(name, FlowInfo { key, style });
        }
        Flow {
            info: res,
            no_next: false,
        }
    }

    pub fn setup_loop(&mut self, range: TextRange, narrow_ops: &NarrowOps) {
        let base = mem::take(&mut self.scopes.current_mut().flow);
        // To account for possible assignments to existing names in a loop, we
        // speculatively insert phi keys upfront.
        self.scopes.current_mut().flow = self.insert_phi_keys(base.clone(), range);
        self.bind_narrow_ops(narrow_ops, range);
        self.scopes
            .current_mut()
            .loops
            .push(Loop(vec![(LoopExit::NeverRan, base)]));
    }

    pub fn teardown_loop(&mut self, range: TextRange, narrow_ops: &NarrowOps, orelse: Vec<Stmt>) {
        let done = self.scopes.current_mut().loops.pop().unwrap();
        let (breaks, other_exits): (Vec<Flow>, Vec<Flow>) =
            done.0.into_iter().partition_map(|(exit, flow)| match exit {
                LoopExit::Break => Either::Left(flow),
                LoopExit::NeverRan | LoopExit::Continue => Either::Right(flow),
            });
        // We associate a range to the non-`break` exits from the loop; it doesn't matter much what
        // it is as long as it's different from the loop's range.
        let other_range = TextRange::new(range.start(), range.start());
        if breaks.is_empty() {
            // When there are no `break`s, the loop condition is always false once the body has exited,
            // and any `orelse` always runs.
            self.merge_loop_into_current(other_exits, range);
            self.bind_narrow_ops(&narrow_ops.negate(), other_range);
            self.stmts(orelse);
        } else {
            // Otherwise, we negate the loop condition and run the `orelse` only when we don't `break`.
            self.merge_loop_into_current(other_exits, other_range);
            self.bind_narrow_ops(&narrow_ops.negate(), other_range);
            self.stmts(orelse);
            self.merge_loop_into_current(breaks, range);
        }
    }

    fn merge_flow_style(&mut self, styles: Vec<Option<&FlowStyle>>) -> Option<FlowStyle> {
        // If these are all identical, return the identical ones.
        // Otherwise give up and return None, since not clear how to merge otherwise.
        let mut it = styles.into_iter();
        let first = it.next()??;
        for x in it {
            if x? != first {
                // TODO: Merging of flow style is hacky. What properties should be merged?
                return None;
            }
        }
        Some(first.clone())
    }

    pub fn merge_flow(&mut self, mut xs: Vec<Flow>, range: TextRange) -> Flow {
        if xs.len() == 1 && xs[0].no_next {
            return xs.pop().unwrap();
        }
        let (hidden_branches, mut visible_branches): (Vec<_>, Vec<_>) =
            xs.into_iter().partition(|x| x.no_next);

        // We normally go through the visible branches, but if nothing is visible no one is going to
        // fill in the Phi keys we promised. So just given up and use the hidden branches instead.
        if visible_branches.is_empty() {
            visible_branches = hidden_branches;
        }

        let names = visible_branches
            .iter()
            .flat_map(|x| x.info.iter_hashed().map(|x| x.0.cloned()))
            .collect::<SmallSet<_>>();
        let mut res = SmallMap::with_capacity(names.len());
        for name in names.into_iter() {
            let (values, styles): (SmallSet<Idx<Key>>, Vec<Option<&FlowStyle>>) = visible_branches
                .iter()
                .flat_map(|x| x.info.get(name.key()).map(|x| (x.key, x.style.as_ref())))
                .unzip();
            let style = self.merge_flow_style(styles);
            let key = self
                .table
                .insert(Key::Phi(name.key().clone(), range), Binding::phi(values));
            res.insert_hashed(name, FlowInfo { key, style });
        }
        Flow {
            info: res,
            no_next: false,
        }
    }

    fn merge_loop_into_current(&mut self, mut branches: Vec<Flow>, range: TextRange) {
        branches.push(mem::take(&mut self.scopes.current_mut().flow));
        self.scopes.current_mut().flow = self.merge_flow(branches, range);
    }
}

impl SpecialEnv for BindingsBuilder<'_> {
    fn current_module(&self) -> ModuleName {
        self.module_info.name()
    }

    fn lookup_special(&self, name: &Name) -> Option<SpecialEntry> {
        self.scopes.get_special_entry(name)
    }
}

/// Handle intercepting names inside either function parameter/return
/// annotations or base class lists of classes, in order to check whether they
/// point at type variable declarations and need to be converted to type
/// parameters.
pub struct LegacyTParamBuilder {
    /// All of the names used. Each one may or may not point at a type variable
    /// and therefore bind a legacy type parameter.
    legacy_tparams: SmallMap<Name, Either<(Identifier, Idx<KeyLegacyTypeParam>), Option<Idx<Key>>>>,
    /// Are there scoped type parameters? Used to control downstream errors.
    has_scoped_tparams: bool,
}

impl LegacyTParamBuilder {
    pub fn new(has_scoped_tparams: bool) -> Self {
        Self {
            legacy_tparams: SmallMap::new(),
            has_scoped_tparams,
        }
    }

    /// Perform a forward lookup of a name used in either base classes of a class
    /// or parameter/return annotations of a function. We do this to create bindings
    /// that allow us to later determine whether this name points at a type variable
    /// declaration, in which case we intercept it to treat it as a type parameter in
    /// the current scope.
    pub fn forward_lookup(
        &mut self,
        builder: &mut BindingsBuilder,
        name: &Identifier,
    ) -> Option<Binding> {
        let result = self
            .legacy_tparams
            .entry(name.id.clone())
            .or_insert_with(|| {
                builder
                    .lookup_legacy_tparam(name)
                    .map_left(|idx| (name.clone(), idx))
            });
        match result {
            Either::Left((_, idx)) => {
                let range_if_scoped_params_exist = if self.has_scoped_tparams {
                    Some(name.range())
                } else {
                    None
                };
                Some(Binding::CheckLegacyTypeParam(
                    *idx,
                    range_if_scoped_params_exist,
                ))
            }
            Either::Right(idx) => idx.map(Binding::Forward),
        }
    }

    /// Add `Definition` bindings to a class or function body scope for all the names
    /// referenced in the function parameter/return annotations or the class bases.
    ///
    /// We do this so that AnswersSolver has the opportunity to determine whether any
    /// of those names point at legacy (pre-PEP-695) type variable declarations, in which
    /// case the name should be treated as a Quantified type parameter inside this scope.
    pub fn add_name_definitions(&self, builder: &mut BindingsBuilder) {
        for entry in self.legacy_tparams.values() {
            if let Either::Left((name, idx)) = entry {
                builder
                    .scopes
                    .current_mut()
                    .stat
                    .add(name.id.clone(), name.range, None);
                builder.bind_definition(
                    name,
                    // Note: we use None as the range here because the range is
                    // used to error if legacy tparams are mixed with scope
                    // tparams, and we only want to do that once (which we do in
                    // the binding created by `forward_lookup`).
                    Binding::CheckLegacyTypeParam(*idx, None),
                    None,
                );
            }
        }
    }

    /// Get the keys that correspond to the result of checking whether a name
    /// corresponds to a legacy type param. This is used when actually computing
    /// the final type parameters for classes and functions, which have to take
    /// all the names that *do* map to type variable declarations and combine
    /// them (potentially) with scoped type parameters.
    pub fn lookup_keys(&self) -> Vec<Idx<KeyLegacyTypeParam>> {
        self.legacy_tparams
            .values()
            .filter_map(|x| x.as_ref().left().as_ref().map(|(_, idx)| *idx))
            .collect()
    }
}
