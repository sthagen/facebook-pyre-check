use std::fmt;
use std::fmt::Debug;
use std::fmt::Display;
use std::mem;
use std::ops::Deref;
use std::sync::Arc;

use dupe::Dupe;
use itertools::Either;
use itertools::Itertools;
use parse_display::Display;
use ruff_python_ast::name::Name;
use ruff_python_ast::Comprehension;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprAttribute;
use ruff_python_ast::ExprName;
use ruff_python_ast::ExprNoneLiteral;
use ruff_python_ast::ExprSubscript;
use ruff_python_ast::Identifier;
use ruff_python_ast::Parameters;
use ruff_python_ast::Stmt;
use ruff_python_ast::StmtClassDef;
use ruff_python_ast::StmtFunctionDef;
use ruff_python_ast::StmtReturn;
use ruff_python_ast::StringFlags;
use ruff_python_ast::TypeParam;
use ruff_python_ast::TypeParams;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use starlark_map::small_map::Entry;
use starlark_map::small_map::SmallMap;
use starlark_map::small_set::SmallSet;
use vec1::Vec1;

use crate::alt::binding::Binding;
use crate::alt::binding::BindingAnnotation;
use crate::alt::binding::BindingBaseClass;
use crate::alt::binding::BindingLegacyTypeParam;
use crate::alt::binding::BindingMro;
use crate::alt::binding::BindingTypeParams;
use crate::alt::binding::ContextManagerKind;
use crate::alt::binding::FunctionKind;
use crate::alt::binding::Key;
use crate::alt::binding::KeyAnnotation;
use crate::alt::binding::KeyBaseClass;
use crate::alt::binding::KeyLegacyTypeParam;
use crate::alt::binding::KeyMro;
use crate::alt::binding::KeyTypeParams;
use crate::alt::binding::RaisedException;
use crate::alt::binding::SizeExpectation;
use crate::alt::binding::UnpackedPosition;
use crate::alt::definitions::Definitions;
use crate::alt::exports::Exports;
use crate::alt::table::Keyed;
use crate::alt::table::TableKeyed;
use crate::alt::util::is_ellipse;
use crate::alt::util::is_never;
use crate::ast::Ast;
use crate::config::Config;
use crate::error::collector::ErrorCollector;
use crate::graph::index::Idx;
use crate::graph::index::Index;
use crate::graph::index_map::IndexMap;
use crate::module::module_info::ModuleInfo;
use crate::module::module_name::ModuleName;
use crate::table;
use crate::table_for_each;
use crate::table_try_for_each;
use crate::types::special_form::SpecialForm;
use crate::types::types::AnyStyle;
use crate::types::types::Quantified;
use crate::types::types::Type;
use crate::uniques::UniqueFactory;
use crate::util::display::DisplayWith;
use crate::visitors::Visitors;

#[derive(Clone, Dupe, Debug)]
pub struct Bindings(Arc<BindingsInner>);

pub type BindingEntry<K> = (Index<K>, IndexMap<K, <K as Keyed>::Value>);

table! {
    #[derive(Debug, Clone, Default)]
    pub struct BindingTable(BindingEntry)
}

#[derive(Clone, Debug)]
struct BindingsInner {
    module_info: ModuleInfo,
    table: BindingTable,
}

impl Display for Bindings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fn go<K: Keyed>(
            items: &BindingEntry<K>,
            me: &Bindings,
            f: &mut fmt::Formatter<'_>,
        ) -> fmt::Result {
            for (idx, k) in items.0.items() {
                writeln!(f, "{} = {}", k, items.1.get_exists(idx).display_with(me))?;
            }
            Ok(())
        }
        table_try_for_each!(self.0.table, |items| go(items, self, f));
        Ok(())
    }
}

struct BindingsBuilder<'a> {
    module_info: ModuleInfo,
    modules: &'a SmallMap<ModuleName, Exports>,
    config: &'a Config,
    errors: &'a ErrorCollector,
    uniques: &'a UniqueFactory,
    scopes: Vec1<Scope>,
    /// Accumulate all the return statements
    returns: Vec<StmtReturn>,
    table: BindingTable,
}

/// Many names may map to the same TextRange (e.g. from foo import *).
/// But no other static will point at the same TextRange.
#[derive(Default, Clone, Debug)]
struct Static(SmallMap<Name, TextRange>);

impl Static {
    fn add(&mut self, name: Name, range: TextRange) {
        // Use whichever one we see first
        self.0.entry(name).or_insert(range);
    }

    fn stmts(
        &mut self,
        x: &[Stmt],
        module_info: &ModuleInfo,
        top_level: bool,
        modules: &SmallMap<ModuleName, Exports>,
        config: &Config,
    ) {
        let mut d = Definitions::new(x, module_info.name(), module_info.is_init(), config);
        if top_level && module_info.name() != ModuleName::builtins() {
            d.inject_implicit();
        }
        for (name, (range, _)) in d.definitions {
            self.add(name, range)
        }
        for (m, range) in d.import_all {
            let extra = modules.get(&m).unwrap().wildcard(modules);
            for name in extra.iter() {
                self.add(name.clone(), range)
            }
        }
    }

    fn expr_lvalue(&mut self, x: &Expr) {
        let mut add = |name: &ExprName| self.add(name.id.clone(), name.range);
        Ast::expr_lvalue(x, &mut add);
    }
}

/// The current value of the name, plus optionally the current value of the annotation.
#[derive(Default, Clone, Debug)]
struct Flow {
    info: SmallMap<Name, FlowInfo>,
    // Should this flow be merged into the next? Flow merging occurs after constructs like branches and loops.
    no_next: bool,
}

#[derive(Debug, Clone)]
struct FlowInfo {
    key: Key,
    /// The annotation associated with this key, if any.
    /// If there is one, all subsequent bindings must obey this annotation.
    ann: Option<Idx<KeyAnnotation>>,
    /// Am I the result of an import (which needs merging)
    is_import: bool,
}

impl FlowInfo {
    fn new(key: Key, ann: Option<Idx<KeyAnnotation>>) -> Self {
        Self {
            key,
            ann,
            is_import: false,
        }
    }
}

#[derive(Clone, Debug)]
struct ClassBodyInner {
    name: Identifier,
    instance_attributes_by_method: SmallMap<Name, SmallMap<Name, Binding>>,
}

impl ClassBodyInner {
    fn as_self_type_key(&self) -> Key {
        Key::SelfType(self.name.clone())
    }
}

#[derive(Clone, Debug)]
struct MethodInner {
    name: Identifier,
    self_name: Option<Identifier>,
    instance_attributes: SmallMap<Name, Binding>,
}

#[derive(Clone, Debug)]
enum ScopeKind {
    Annotation,
    ClassBody(ClassBodyInner),
    Comprehension,
    Function,
    Method(MethodInner),
    Module,
}

#[derive(Clone, Debug, Display)]
enum LoopExit {
    NeverRan,
    #[display("break")]
    Break,
    #[display("continue")]
    Continue,
}

/// Flow snapshots for all possible exitpoints from a loop.
#[derive(Clone, Debug)]
struct Loop(Vec<(LoopExit, Flow)>);

#[derive(Clone, Debug)]
struct Scope {
    stat: Static,
    flow: Flow,
    /// Are Flow types above this unreachable.
    /// Set when we enter something like a function, and can't guarantee what flow values are in scope.
    barrier: bool,
    kind: ScopeKind,
    /// Stack of for/while loops we're in. Does not include comprehensions.
    loops: Vec<Loop>,
}

impl Scope {
    fn new(barrier: bool, kind: ScopeKind) -> Self {
        Self {
            stat: Default::default(),
            flow: Default::default(),
            barrier,
            kind,
            loops: Default::default(),
        }
    }

    fn annotation() -> Self {
        Self::new(false, ScopeKind::Annotation)
    }

    fn class_body(name: Identifier) -> Self {
        Self::new(
            false,
            ScopeKind::ClassBody(ClassBodyInner {
                name,
                instance_attributes_by_method: SmallMap::new(),
            }),
        )
    }

    fn comprehension() -> Self {
        Self::new(false, ScopeKind::Comprehension)
    }

    fn function() -> Self {
        Self::new(true, ScopeKind::Function)
    }

    fn method(name: Identifier) -> Self {
        Self::new(
            true,
            ScopeKind::Method(MethodInner {
                name,
                self_name: None,
                instance_attributes: SmallMap::new(),
            }),
        )
    }

    fn module() -> Self {
        Self::new(false, ScopeKind::Module)
    }
}

impl Bindings {
    pub fn len(&self) -> usize {
        let mut res = 0;
        table_for_each!(&self.0.table, |x: &BindingEntry<_>| res += x.1.len());
        res
    }

    pub fn display<K: Keyed>(&self, idx: Idx<K>) -> impl Display + '_
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.idx_to_key(idx)
    }

    pub fn module_info(&self) -> &ModuleInfo {
        &self.0.module_info
    }

    pub fn contains_key<K: Keyed>(&self, k: &K) -> bool
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().0.contains(k)
    }

    pub fn key_to_idx<K: Keyed>(&self, k: &K) -> Idx<K>
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().0.key_to_idx(k)
    }

    pub fn get<K: Keyed>(&self, idx: Idx<K>) -> &K::Value
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        self.0.table.get::<K>().1.get_exists(idx)
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

    pub fn new(
        x: Vec<Stmt>,
        module_info: ModuleInfo,
        modules: &SmallMap<ModuleName, Exports>,
        config: &Config,
        errors: &ErrorCollector,
        uniques: &UniqueFactory,
    ) -> Self {
        let mut builder = BindingsBuilder {
            module_info: module_info.dupe(),
            modules,
            config,
            errors,
            uniques,
            scopes: Vec1::new(Scope::module()),
            returns: Vec::new(),
            table: Default::default(),
        };
        builder
            .scopes
            .last_mut()
            .stat
            .stmts(&x, &module_info, true, modules, config);
        if module_info.name() != ModuleName::builtins() {
            builder.inject_implicit();
        }
        builder.stmts(x);
        for (k, range) in builder.scopes.last().stat.0.iter() {
            let info = builder.scopes.last().flow.info.get(k);
            let val = match info {
                Some(FlowInfo {
                    key,
                    ann: Some(ann),
                    ..
                }) => Binding::AnnotatedType(*ann, Box::new(Binding::Forward(key.clone()))),
                Some(FlowInfo { key, ann: None, .. }) => Binding::Forward(key.clone()),
                None => {
                    // We think we have a binding for this, but we didn't encounter a flow element, so have no idea of what.
                    // This might be because we haven't fully implemented all bindings, or because the two disagree. Just guess.
                    errors.add(
                        &module_info,
                        *range,
                        format!("Could not find flow binding for `{k}`"),
                    );
                    Binding::AnyType(AnyStyle::Error)
                }
            };
            builder.table.insert(Key::Export(k.clone()), val);
        }
        Self(Arc::new(BindingsInner {
            module_info,
            table: builder.table,
        }))
    }
}

impl BindingTable {
    fn insert<K: Keyed>(&mut self, key: K, value: K::Value) -> Idx<K>
    where
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
    {
        let entry = self.get_mut::<K>();
        let idx = entry.0.insert(key);
        entry.1.insert_once(idx, value);
        idx
    }

    fn insert_anywhere(&mut self, name: Name, range: TextRange) -> &mut SmallSet<Key> {
        let idx = self.types.0.insert_if_missing(Key::Anywhere(name, range));
        match self
            .types
            .1
            .insert_if_missing(idx, || Binding::Phi(SmallSet::new()))
        {
            Binding::Phi(phi) => phi,
            _ => unreachable!(),
        }
    }
}

impl<'a> BindingsBuilder<'a> {
    fn stmts(&mut self, x: Vec<Stmt>) {
        for x in x {
            self.stmt(x);
        }
    }

    fn inject_implicit(&mut self) {
        let builtins_module = ModuleName::builtins();
        let builtins_export = self.modules.get(&builtins_module).unwrap();
        for name in builtins_export.wildcard(self.modules).iter() {
            let key = Key::Import(name.clone(), TextRange::default());
            self.table
                .insert(key.clone(), Binding::Import(builtins_module, name.clone()));
            self.bind_key(name, key, None, false);
        }
    }

    fn todo(&mut self, msg: &str, x: impl Ranged + Debug) {
        self.errors.todo(&self.module_info, msg, x);
    }

    fn lookup_name(&mut self, name: &Identifier) -> Option<Key> {
        let mut barrier = false;
        for scope in self.scopes.iter().rev() {
            if !barrier && let Some(flow) = scope.flow.info.get(&name.id) {
                return Some(flow.key.clone());
            } else if !matches!(scope.kind, ScopeKind::ClassBody(_))
                && let Some(name_id) = scope.stat.0.get(&name.id)
            {
                self.table.insert_anywhere(name.id.clone(), *name_id);
                return Some(Key::Anywhere(name.id.clone(), *name_id));
            }
            barrier = barrier || scope.barrier;
        }
        None
    }

    fn forward_lookup(&mut self, name: &Identifier) -> Option<Binding> {
        self.lookup_name(name).map(Binding::Forward)
    }

    // Given a name appearing in an expression, create a `Usage` key for that
    // name at the current location. The binding will indicate how to compute
    // the type if we found that name in scope; if we do not find the name we
    // record an error and fall back to `Any`.
    //
    // This function is the the core scope lookup logic for binding creation.
    fn ensure_name(&mut self, name: &Identifier, value: Option<Binding>) {
        let key = Key::Usage(name.clone());
        match value {
            Some(value) => {
                self.table.insert(key, value);
            }
            None if name.as_str() == "__file__" || name.as_str() == "__name__" => {
                self.table.insert(key, Binding::StrType);
            }
            None => {
                // Name wasn't found. Record a type error and fall back to `Any`.
                self.errors.add(
                    &self.module_info,
                    name.range,
                    format!("Could not find name `{name}`"),
                );
                self.table.insert(key, Binding::AnyType(AnyStyle::Error));
            }
        }
    }

    /// Execute through the expr, ensuring every name has a binding.
    fn ensure_expr(&mut self, x: &Expr) {
        let mut new_scope = false;
        let mut bind_comprehensions = |comps: &Vec<Comprehension>| {
            new_scope = true;
            self.scopes.push(Scope::comprehension());
            for comp in comps.iter() {
                self.scopes.last_mut().stat.expr_lvalue(&comp.target);
                let make_binding = |k| Binding::IterableValue(k, comp.iter.clone());
                self.bind_target(&comp.target, &make_binding);
            }
        };
        match x {
            Expr::Name(x) => {
                let name = Ast::expr_name_identifier(x.clone());
                let binding = self.forward_lookup(&name);
                self.ensure_name(&name, binding);
            }
            Expr::ListComp(x) => {
                bind_comprehensions(&x.generators);
            }
            Expr::SetComp(x) => {
                bind_comprehensions(&x.generators);
            }
            Expr::DictComp(x) => {
                bind_comprehensions(&x.generators);
            }
            Expr::Generator(x) => {
                bind_comprehensions(&x.generators);
            }
            _ => {}
        }
        Visitors::visit_expr(x, |x| self.ensure_expr(x));
        if new_scope {
            self.scopes.pop().unwrap();
        }
    }

    /// Execute through the expr, ensuring every name has a binding.
    fn ensure_expr_opt(&mut self, x: Option<&Expr>) {
        if let Some(x) = x {
            self.ensure_expr(x);
        }
    }

    /// Execute through the expr, ensuring every name has a binding.
    fn ensure_type(
        &mut self,
        x: &mut Expr,
        forward_lookup: &mut impl FnMut(&mut Self, &Identifier) -> Option<Binding>,
    ) {
        match x {
            Expr::Name(x) => {
                let name = Ast::expr_name_identifier(x.clone());
                let binding = forward_lookup(self, &name);
                self.ensure_name(&name, binding);
            }
            Expr::Subscript(ExprSubscript {
                value: box Expr::Name(name),
                ..
            }) if name.id == "Literal" => {
                // Don't go inside a literal, since you might find strings which are really strings, not string-types
                self.ensure_expr(x);
            }
            Expr::Subscript(ExprSubscript {
                value: box Expr::Name(name),
                slice: box Expr::Tuple(tup),
                ..
            }) if name.id == "Annotated" && !tup.is_empty() => {
                // Only go inside the first argument to Annotated, the rest are non-type metadata.
                self.ensure_type(&mut Expr::Name(name.clone()), forward_lookup);
                self.ensure_type(&mut tup.elts[0], forward_lookup);
                for e in tup.elts[1..].iter_mut() {
                    self.ensure_expr(e);
                }
            }
            Expr::StringLiteral(literal) => {
                let mut s = literal.value.to_str().to_owned();
                if literal.value.iter().any(|x| x.flags.is_triple_quoted()) {
                    // Implicitly bracketed, so add them explicitly
                    s = format!("({s})");
                }
                // We use position information to uniquely key names, so make sure we find fresh positions.
                // Because of string escapes and splits, these might not be perfect, but they are definitely fresh
                // as they point inside the string we got rid of.
                match Ast::parse_expr(&s, literal.range.start()) {
                    Ok(expr) => {
                        *x = expr;
                        // You are not allowed to nest type strings in type strings,
                        self.ensure_expr(x);
                    }
                    Err(e) => {
                        self.errors.add(
                            &self.module_info,
                            literal.range,
                            format!("Could not parse type string: {s}, got {e}"),
                        );
                    }
                }
            }
            _ => Visitors::visit_expr_mut(x, |x| self.ensure_type(x, forward_lookup)),
        }
    }

    /// Execute through the expr, ensuring every name has a binding.
    fn ensure_type_opt(
        &mut self,
        x: Option<&mut Expr>,
        forward_lookup: &mut impl FnMut(&mut Self, &Identifier) -> Option<Binding>,
    ) {
        if let Some(x) = x {
            self.ensure_type(x, forward_lookup);
        }
    }

    fn bind_definition(
        &mut self,
        name: &Identifier,
        binding: Binding,
        annotation: Option<Idx<KeyAnnotation>>,
    ) -> Option<Idx<KeyAnnotation>> {
        let key = Key::Definition(name.clone());
        let ann = self.bind_key(&name.id, key.clone(), annotation, false);
        self.table.insert(key, binding);
        ann
    }

    fn bind_unpacking(
        &mut self,
        elts: &[Expr],
        make_binding: &dyn Fn(Option<Idx<KeyAnnotation>>) -> Binding,
        range: TextRange,
    ) {
        // An unpacking has zero or one splats (starred expressions).
        let mut splat = false;
        for (i, e) in elts.iter().enumerate() {
            match e {
                Expr::Starred(e) => {
                    splat = true;
                    // Counts how many elements are after the splat.
                    let j = elts.len() - i - 1;
                    let make_nested_binding = |ann: Option<Idx<KeyAnnotation>>| {
                        Binding::UnpackedValue(
                            Box::new(make_binding(ann)),
                            range,
                            UnpackedPosition::Slice(i, j),
                        )
                    };
                    self.bind_target(&e.value, &make_nested_binding);
                }
                _ => {
                    let idx = if splat {
                        // If we've encountered a splat, we no longer know how many values have been consumed
                        // from the front, but we know how many are left at the back.
                        UnpackedPosition::ReverseIndex(elts.len() - i)
                    } else {
                        UnpackedPosition::Index(i)
                    };
                    let make_nested_binding = |ann: Option<Idx<KeyAnnotation>>| {
                        Binding::UnpackedValue(Box::new(make_binding(ann)), range, idx.clone())
                    };
                    self.bind_target(e, &make_nested_binding);
                }
            }
        }
        let expect = if splat {
            SizeExpectation::Ge(elts.len() - 1)
        } else {
            SizeExpectation::Eq(elts.len())
        };
        self.table.insert(
            Key::Anon(range),
            Binding::UnpackedLength(Box::new(make_binding(None)), range, expect),
        );
    }

    /// In methods, we track assignments to `self` attribute targets so that we can
    /// be aware of class fields defined in methods. This is particularly important in
    /// constructors, we currently are applying this logic for all methods.
    ///
    /// TODO(stroxler): This logic is consistent with Pyright but unsound, we'll need
    /// to decide how to handle attributes defined outside of constructors.
    fn bind_attr_if_self(&mut self, x: &ExprAttribute, binding: Binding) {
        for scope in self.scopes.iter_mut().rev() {
            if let ScopeKind::Method(method) = &mut scope.kind
                && let Some(self_name) = &method.self_name
                && matches!(&*x.value, Expr::Name(name) if name.id == self_name.id)
            {
                if !method.instance_attributes.contains_key(&x.attr.id) {
                    method
                        .instance_attributes
                        .insert(x.attr.id.clone(), binding);
                }
                break;
            }
        }
    }

    fn bind_target(
        &mut self,
        target: &Expr,
        make_binding: &dyn Fn(Option<Idx<KeyAnnotation>>) -> Binding,
    ) {
        match target {
            Expr::Name(name) => {
                let id = Ast::expr_name_identifier(name.clone());
                let key = Key::Definition(id.clone());
                let ann = self.bind_key(&id.id, key.clone(), None, false);
                self.table.insert(key, make_binding(ann));
            }
            Expr::Attribute(x) => {
                self.ensure_expr(&x.value);
                let ann = self.table.insert(
                    KeyAnnotation::AttrAnnotation(x.range),
                    BindingAnnotation::AttrType(x.clone()),
                );
                let binding = make_binding(Some(ann));
                self.bind_attr_if_self(x, binding.clone());
                self.table.insert(Key::Anon(x.range), binding);
            }
            Expr::Subscript(x) => {
                self.ensure_expr(&x.value);
                self.ensure_expr(&x.slice);
                let binding = make_binding(None);
                self.table.insert(
                    Key::Anon(x.range),
                    Binding::SubscriptValue(Box::new(binding), x.clone()),
                );
            }
            Expr::Tuple(tup) => {
                self.bind_unpacking(&tup.elts, make_binding, tup.range);
            }
            Expr::List(lst) => {
                self.bind_unpacking(&lst.elts, make_binding, lst.range);
            }
            _ => self.todo("unrecognized assignment target", target),
        }
    }

    /// Return the annotation that should be used at the moment, if one was provided.
    fn bind_key(
        &mut self,
        name: &Name,
        key: Key,
        annotation: Option<Idx<KeyAnnotation>>,
        is_import: bool,
    ) -> Option<Idx<KeyAnnotation>> {
        let annotation = match self.scopes.last_mut().flow.info.entry(name.clone()) {
            Entry::Occupied(mut e) => {
                // if there was a previous annotation, reuse that
                let annotation = annotation.or_else(|| e.get().ann);
                *e.get_mut() = FlowInfo {
                    key: key.clone(),
                    ann: annotation,
                    is_import,
                };
                annotation
            }
            Entry::Vacant(e) => {
                e.insert(FlowInfo {
                    key: key.clone(),
                    ann: annotation,
                    is_import,
                });
                annotation
            }
        };
        let defn_range = self.scopes.last().stat.0.get(name).unwrap_or_else(|| {
            let module = self.module_info.name();
            panic!("Name `{name}` not found in static scope of module `{module}`")
        });
        self.table
            .insert_anywhere(name.clone(), *defn_range)
            .insert(key);
        annotation
    }

    fn type_params(&mut self, x: &TypeParams) -> Vec<Quantified> {
        let mut qs = Vec::new();
        for x in x.iter() {
            let (q, name) = match x {
                TypeParam::TypeVar(x) => {
                    let q = Quantified::type_var(self.uniques, format!("generic {}", x.name));
                    (q, &x.name)
                }
                TypeParam::ParamSpec(x) => {
                    let q = Quantified::param_spec(self.uniques, format!("param spec {}", x.name));
                    (q, &x.name)
                }
                TypeParam::TypeVarTuple(x) => {
                    let q = Quantified::type_var_tuple(
                        self.uniques,
                        format!("type var tuple {}", x.name),
                    );
                    (q, &x.name)
                }
            };
            qs.push(q);
            self.scopes.last_mut().stat.add(name.id.clone(), name.range);
            self.bind_definition(name, Binding::TypeParameter(q), None);
        }
        qs
    }

    fn parameters(&mut self, x: &mut Parameters, self_type: &Option<Key>) {
        let mut self_name = None;
        for x in x.iter() {
            let name = x.name();
            if self_type.is_some() && self_name.is_none() {
                self_name = Some(name.clone());
            }
            let ann_val = match x.annotation() {
                Some(a) => BindingAnnotation::AnnotateExpr(a.clone(), self_type.clone()),
                None => {
                    if let Some(self_name) = &self_name
                        && name.id == *self_name.id
                    {
                        BindingAnnotation::Forward(self_type.clone().unwrap())
                    } else {
                        BindingAnnotation::Type(Type::any_implicit())
                    }
                }
            };
            let ann_key = self
                .table
                .insert(KeyAnnotation::Annotation(name.clone()), ann_val);
            let bind_key = Key::Definition(name.clone());
            self.table.insert(
                bind_key.clone(),
                Binding::AnnotatedType(ann_key, Box::new(Binding::AnyType(AnyStyle::Implicit))),
            );

            self.scopes.last_mut().stat.add(name.id.clone(), name.range);
            self.bind_key(&name.id, bind_key, Some(ann_key), false);
        }
        if let Scope {
            kind: ScopeKind::Method(method),
            ..
        } = self.scopes.last_mut()
        {
            method.self_name = self_name;
        }
    }

    fn function_def(&mut self, mut x: StmtFunctionDef) {
        let body = mem::take(&mut x.body);
        let kind = if is_ellipse(&body) {
            FunctionKind::Stub
        } else {
            FunctionKind::Impl
        };
        let mut return_annotation = mem::take(&mut x.returns);
        let return_count = self.returns.len();
        let never = is_never(&body, self.config);
        if never != Some(Vec::new()) && kind == FunctionKind::Impl {
            // If we can reach the end, and the code is real (not just ellipse),
            // check None is an OK return type.
            // Note that we special case ellipse even in non-interface, as that is what Pyright does.
            self.returns.push(StmtReturn {
                range: match never.as_deref() {
                    Some([x]) => x.range(), // Try and narrow the range
                    _ => x.range,
                },
                value: None,
            });
        }
        let func_name = x.name.clone();
        let self_type = match &self.scopes.last().kind {
            ScopeKind::ClassBody(body) => Some(body.as_self_type_key()),
            _ => None,
        };

        self.scopes.push(Scope::annotation());

        let tparams = x
            .type_params
            .as_ref()
            .map(|tparams| self.type_params(tparams));

        let mut legacy_tparam_builder = LegacyTParamBuilder::new(tparams.is_some());

        // We need to bind all the parameters expressions _after_ the type params, but before the parameter names,
        // which might shadow some types.
        for (param, default) in Ast::parameters_iter_mut(&mut x.parameters) {
            self.ensure_type_opt(param.annotation.as_deref_mut(), &mut |lookup_name, name| {
                legacy_tparam_builder.forward_lookup(lookup_name, name)
            });
            if let Some(default) = default {
                self.ensure_expr_opt(default.as_deref());
            }
        }
        self.ensure_type_opt(
            return_annotation.as_deref_mut(),
            &mut |lookup_name, name| legacy_tparam_builder.forward_lookup(lookup_name, name),
        );

        legacy_tparam_builder.add_name_definitions(self);

        if self_type.is_none() {
            self.scopes.push(Scope::function());
        } else {
            self.scopes.push(Scope::method(func_name.clone()));
        }

        self.table.insert(
            KeyTypeParams(func_name.clone()),
            BindingTypeParams::Function(
                tparams.unwrap_or_default(),
                legacy_tparam_builder.lookup_keys(),
            ),
        );

        self.parameters(&mut x.parameters, &self_type);

        self.scopes.last_mut().stat.stmts(
            &body,
            &self.module_info,
            false,
            self.modules,
            self.config,
        );
        self.stmts(body);
        let func_scope = self.scopes.pop().unwrap();
        self.scopes.pop().unwrap();

        if let ScopeKind::Method(method) = &func_scope.kind
            && let ScopeKind::ClassBody(body) = &mut self.scopes.last_mut().kind
        {
            body.instance_attributes_by_method
                .insert(method.name.id.clone(), method.instance_attributes.clone());
        }

        self.bind_definition(&x.name.clone(), Binding::Function(x, kind), None);

        let mut return_exprs = Vec::new();
        while self.returns.len() > return_count {
            return_exprs.push(self.returns.pop().unwrap());
        }
        let return_ann = return_annotation.map(|x| {
            let key = KeyAnnotation::ReturnAnnotation(func_name.clone());
            self.table
                .insert(key.clone(), BindingAnnotation::AnnotateExpr(*x, self_type))
        });
        let mut return_expr_keys = SmallSet::with_capacity(return_exprs.len());
        for x in return_exprs {
            let key = Key::ReturnExpression(func_name.clone(), x.range);
            self.table
                .insert(key.clone(), Binding::Expr(return_ann, return_expr(x)));
            return_expr_keys.insert(key);
        }
        let mut return_type = Binding::phi(return_expr_keys);
        if let Some(ann) = return_ann {
            return_type = Binding::AnnotatedType(ann, Box::new(return_type));
        }
        self.table.insert(Key::ReturnType(func_name), return_type);
    }

    fn class_def(&mut self, mut x: StmtClassDef) {
        let body = mem::take(&mut x.body);
        let self_type_key = Key::SelfType(x.name.clone());

        self.scopes.push(Scope::class_body(x.name.clone()));
        self.table.insert(
            self_type_key.clone(),
            Binding::SelfType(Key::Definition(x.name.clone())),
        );
        x.type_params.iter().for_each(|x| {
            self.type_params(x);
        });

        let n_bases = x.bases().len();

        let mut legacy_tparam_builder = LegacyTParamBuilder::new(x.type_params.is_some());

        x.bases().iter().enumerate().for_each(|(i, base)| {
            let mut base = base.clone();
            // Forward refs are fine *inside* of a base expression in the type arguments,
            // but outermost class cannot be a forward ref.
            match &base {
                Expr::StringLiteral(v) => {
                    self.errors.add(
                        &self.module_info,
                        base.range(),
                        format!(
                            "Cannot use string annotation `{}` as a base class",
                            v.value.to_str()
                        ),
                    );
                }
                _ => {}
            }
            self.ensure_type(&mut base, &mut |lookup_name, name| {
                legacy_tparam_builder.forward_lookup(lookup_name, name)
            });
            self.table.insert(
                KeyBaseClass::BaseClass(x.name.clone(), i),
                BindingBaseClass::BaseClassExpr(base.clone(), self_type_key.clone()),
            );
        });
        self.table
            .insert(KeyMro::Mro(x.name.clone()), BindingMro::Mro(self_type_key));

        let definition_key = Key::Definition(x.name.clone());
        self.table.insert(
            KeyTypeParams(x.name.clone()),
            BindingTypeParams::Class(definition_key, legacy_tparam_builder.lookup_keys()),
        );

        legacy_tparam_builder.add_name_definitions(self);

        self.scopes.last_mut().stat.stmts(
            &body,
            &self.module_info,
            false,
            self.modules,
            self.config,
        );
        self.stmts(body);

        let last_scope = self.scopes.pop().unwrap();
        let mut fields = SmallSet::new();
        for (name, info) in last_scope.flow.info.iter() {
            let mut val = Binding::Forward(Key::Anywhere(
                name.clone(),
                *last_scope.stat.0.get(name).unwrap(),
            ));
            if let Some(ann) = &info.ann {
                val = Binding::AnnotatedType(*ann, Box::new(val));
            }
            fields.insert(name.clone());
            self.table
                .insert(Key::ClassField(x.name.clone(), name.clone()), val);
        }
        if let ScopeKind::ClassBody(body) = &last_scope.kind {
            for (method_name, instance_attributes) in body.instance_attributes_by_method.iter() {
                if method_name == "__init__" {
                    for (name, binding) in instance_attributes.iter() {
                        if !fields.contains(name) {
                            fields.insert(name.clone());
                            self.table.insert(
                                Key::ClassField(x.name.clone(), name.clone()),
                                binding.clone(),
                            );
                        }
                    }
                }
            }
        } else {
            unreachable!("Expected class body scope, got {:?}", last_scope.kind);
        }

        self.bind_definition(&x.name.clone(), Binding::Class(x, fields, n_bases), None);
    }

    fn add_loop_exitpoint(&mut self, exit: LoopExit, range: TextRange) {
        let scope = self.scopes.last_mut();
        let flow = scope.flow.clone();
        if let Some(innermost) = scope.loops.last_mut() {
            innermost.0.push((exit, flow));
            scope.flow.no_next = true;
        } else {
            self.errors.add(
                &self.module_info,
                range,
                format!("Cannot `{exit}` outside loop"),
            );
        }
    }

    /// Evaluate the statements and update the bindings.
    /// Every statement should end up in the bindings, perhaps with a location that is never used.
    fn stmt(&mut self, x: Stmt) {
        match x {
            Stmt::FunctionDef(x) => self.function_def(x),
            Stmt::ClassDef(x) => self.class_def(x),
            Stmt::Return(x) => {
                self.ensure_expr_opt(x.value.as_deref());
                self.returns.push(x);
                self.scopes.last_mut().flow.no_next = true;
            }
            Stmt::Delete(x) => self.todo("Bindings::stmt", &x),
            Stmt::Assign(x) => {
                let name = if x.targets.len() == 1
                    && let Expr::Name(name) = &x.targets[0]
                {
                    Some(name.id.clone())
                } else {
                    None
                };
                self.ensure_expr(&x.value);
                for target in x.targets.iter() {
                    let make_binding = |k: Option<Idx<KeyAnnotation>>| {
                        let b = Binding::Expr(k, *x.value.clone());
                        if let Some(name) = &name {
                            Binding::NameAssign(name.clone(), k, Box::new(b), x.value.range())
                        } else {
                            b
                        }
                    };
                    self.bind_target(target, &make_binding)
                }
            }
            Stmt::AugAssign(x) => {
                if matches!(&*x.target, Expr::Name(y) if y.id == "__all__") {
                    // For now, don't raise a todo, since we use it everywhere.
                    // Fix it later.
                } else {
                    self.todo("Bindings::stmt", &x)
                }
            }
            Stmt::AnnAssign(mut x) => match *x.target {
                Expr::Name(name) => {
                    let name = Ast::expr_name_identifier(name);
                    let ann_key = KeyAnnotation::Annotation(name.clone());
                    self.ensure_type(&mut x.annotation, &mut BindingsBuilder::forward_lookup);
                    let ann_val = if let Some(special) = SpecialForm::new(&name.id, &x.annotation) {
                        BindingAnnotation::Type(special.to_type())
                    } else {
                        BindingAnnotation::AnnotateExpr(*x.annotation, None)
                    };
                    let ann_key = self.table.insert(ann_key, ann_val);

                    if let Some(value) = x.value
                        && (!self.module_info.is_interface()
                            || !matches!(&*value, Expr::EllipsisLiteral(_)))
                    {
                        self.ensure_expr(&value);
                        let range = value.range();
                        self.bind_definition(
                            &name.clone(),
                            Binding::NameAssign(
                                name.id,
                                Some(ann_key),
                                Box::new(Binding::Expr(Some(ann_key), *value)),
                                range,
                            ),
                            Some(ann_key),
                        );
                    } else {
                        self.bind_definition(
                            &name,
                            Binding::AnnotatedType(
                                ann_key,
                                Box::new(Binding::AnyType(AnyStyle::Implicit)),
                            ),
                            Some(ann_key),
                        );
                    }
                }
                Expr::Attribute(attr) => {
                    self.ensure_expr(&attr.value);
                    self.ensure_type(&mut x.annotation, &mut BindingsBuilder::forward_lookup);
                    // This is the type of the attribute.
                    let attr_key = self.table.insert(
                        KeyAnnotation::AttrAnnotation(attr.range),
                        BindingAnnotation::AttrType(attr.clone()),
                    );
                    // This is the type annotation on the assignment.
                    let ann_key = self.table.insert(
                        KeyAnnotation::AttrAnnotation(x.annotation.range()),
                        BindingAnnotation::AnnotateExpr(*x.annotation, None),
                    );
                    let value_type = match &x.value {
                        Some(v) => Binding::Expr(None, *v.clone()),
                        None => Binding::AnyType(AnyStyle::Implicit),
                    };
                    self.bind_attr_if_self(
                        &attr,
                        Binding::AnnotatedType(ann_key, Box::new(value_type)),
                    );
                    self.table.insert(
                        Key::Anon(attr.range),
                        Binding::Eq(ann_key, attr_key, attr.attr.id),
                    );
                    if let Some(v) = &x.value {
                        self.ensure_expr(v);
                        self.table.insert(
                            Key::Anon(v.range()),
                            Binding::Expr(Some(ann_key), *v.clone()),
                        );
                    }
                }
                _ => self.todo("Bindings::stmt AnnAssign", &x),
            },
            Stmt::TypeAlias(x) => {
                if let Expr::Name(name) = *x.name {
                    let qs = if let Some(params) = x.type_params {
                        self.type_params(&params)
                    } else {
                        Vec::new()
                    };
                    self.ensure_expr(&x.value);
                    let expr_binding = Binding::Expr(None, *x.value);
                    let binding =
                        Binding::ScopedTypeAlias(name.id.clone(), qs, Box::new(expr_binding));
                    self.bind_definition(&Ast::expr_name_identifier(name), binding, None);
                } else {
                    self.todo("Bindings::stmt TypeAlias", &x);
                }
            }
            Stmt::For(x) => {
                let range = TextRange::new(x.range.start(), x.body.last().unwrap().range().end());
                self.setup_loop(range);
                self.ensure_expr(&x.iter);
                let make_binding = |k| Binding::IterableValue(k, *x.iter.clone());
                self.bind_target(&x.target, &make_binding);
                self.stmts(x.body.clone());
                self.teardown_loop(range, x.orelse);
            }
            Stmt::While(x) => {
                let range = TextRange::new(x.range.start(), x.body.last().unwrap().range().end());
                self.setup_loop(range);
                self.ensure_expr(&x.test);
                self.stmts(x.body.clone());
                self.teardown_loop(range, x.orelse);
            }
            Stmt::If(x) => {
                // Need to deal with type guards in future.
                let range = x.range;
                let mut exhaustive = false;
                let mut branches = Vec::new();
                for (test, body) in Ast::if_branches_owned(x) {
                    let b = self.config.evaluate_bool_opt(test.as_ref());
                    if b == Some(false) {
                        continue; // We won't pick this branch
                    }
                    let mut base = self.scopes.last().flow.clone();
                    self.ensure_expr_opt(test.as_ref());
                    self.stmts(body);
                    mem::swap(&mut self.scopes.last_mut().flow, &mut base);
                    branches.push(base);
                    if b == Some(true) {
                        exhaustive = true;
                        break; // We picked this branch, none others stand a chance
                    }
                }
                if !exhaustive {
                    branches.push(self.scopes.last().flow.clone());
                }
                self.scopes.last_mut().flow = self.merge_flow(branches, range, false);
            }
            Stmt::With(x) => {
                let kind = if x.is_async {
                    ContextManagerKind::Async
                } else {
                    ContextManagerKind::Sync
                };
                for item in x.items.iter() {
                    self.ensure_expr(&item.context_expr);
                    if let Some(opts) = &item.optional_vars {
                        let make_binding = |k: Option<Idx<KeyAnnotation>>| {
                            Binding::ContextValue(k, item.context_expr.clone(), kind)
                        };
                        self.bind_target(opts, &make_binding);
                    } else {
                        self.table.insert(
                            Key::Anon(item.range()),
                            Binding::ContextValue(None, item.context_expr.clone(), kind),
                        );
                    }
                }
                self.stmts(x.body.clone());
            }
            Stmt::Match(x) => self.todo("Bindings::stmt", &x),
            Stmt::Raise(x) => {
                if let Some(exc) = x.exc {
                    self.ensure_expr(&exc);
                    let raised = if let Some(cause) = x.cause {
                        self.ensure_expr(&cause);
                        RaisedException::WithCause(*exc, *cause)
                    } else {
                        RaisedException::WithoutCause(*exc)
                    };
                    self.table
                        .insert(Key::Anon(x.range), Binding::CheckRaisedException(raised));
                } else {
                    // If there's no exception raised, don't bother checking the cause.
                }
                self.scopes.last_mut().flow.no_next = true;
            }
            Stmt::Try(x) => self.todo("Bindings::stmt", &x),
            Stmt::Assert(x) => {
                self.ensure_expr(&x.test);
                self.table
                    .insert(Key::Anon(x.test.range()), Binding::Expr(None, *x.test));
                if let Some(msg_expr) = x.msg {
                    self.ensure_expr(&msg_expr);
                    self.table
                        .insert(Key::Anon(msg_expr.range()), Binding::Expr(None, *msg_expr));
                };
            }
            Stmt::Import(x) => {
                for x in x.names {
                    let m = ModuleName::from_name(&x.name.id);
                    match x.asname {
                        Some(asname) => {
                            self.bind_definition(
                                &asname,
                                Binding::Module(m, m.components(), None),
                                None,
                            );
                        }
                        None => {
                            let first = m.first_component();
                            let flow_info = self.scopes.last().flow.info.get(&first);
                            let module_key = match flow_info {
                                Some(flow_info) if flow_info.is_import => {
                                    Some(flow_info.key.clone())
                                }
                                _ => None,
                            };
                            let key = Key::Import(first.clone(), x.name.range);
                            self.table.insert(
                                key.clone(),
                                Binding::Module(m, vec![first.clone()], module_key),
                            );
                            self.bind_key(&first, key, None, true);
                        }
                    }
                }
            }
            Stmt::ImportFrom(x) => {
                if let Some(m) = self.module_info.name().new_maybe_relative(
                    self.module_info.is_init(),
                    x.level,
                    x.module.as_ref().map(|x| &x.id),
                ) {
                    for x in x.names {
                        if &x.name == "*" {
                            let module = self.modules.get(&m).unwrap();
                            for name in module.wildcard(self.modules).iter() {
                                let key = Key::Import(name.clone(), x.range);
                                let val = if module.contains(name, self.modules) {
                                    Binding::Import(m, name.clone())
                                } else {
                                    self.errors.add(
                                        &self.module_info,
                                        x.range,
                                        format!("Could not import `{name}` from `{m}`"),
                                    );
                                    Binding::AnyType(AnyStyle::Error)
                                };
                                self.table.insert(key.clone(), val);
                                self.bind_key(name, key, None, false);
                            }
                        } else {
                            let asname = x.asname.unwrap_or_else(|| x.name.clone());
                            let val = if self
                                .modules
                                .get(&m)
                                .unwrap()
                                .contains(&x.name.id, self.modules)
                            {
                                Binding::Import(m, x.name.id)
                            } else {
                                self.errors.add(
                                    &self.module_info,
                                    x.range,
                                    format!("Could not import `{}` from `{m}`", x.name.id),
                                );
                                Binding::AnyType(AnyStyle::Error)
                            };
                            self.bind_definition(&asname, val, None);
                        }
                    }
                } else {
                    self.errors.add(
                        &self.module_info,
                        x.range,
                        format!(
                            "Could not resolve relative import `{}`",
                            ".".repeat(x.level as usize)
                        ),
                    );
                    for x in x.names {
                        let asname = x.asname.unwrap_or_else(|| x.name.clone());
                        self.bind_definition(&asname, Binding::AnyType(AnyStyle::Error), None);
                    }
                }
            }
            Stmt::Global(x) => self.todo("Bindings::stmt", &x),
            Stmt::Nonlocal(x) => self.todo("Bindings::stmt", &x),
            Stmt::Expr(x) => {
                self.ensure_expr(&x.value);
                self.table
                    .insert(Key::Anon(x.range), Binding::Expr(None, *x.value));
            }
            Stmt::Pass(_) => { /* no-op */ }
            Stmt::Break(x) => {
                self.add_loop_exitpoint(LoopExit::Break, x.range);
            }
            Stmt::Continue(x) => {
                self.add_loop_exitpoint(LoopExit::Continue, x.range);
            }
            Stmt::IpyEscapeCommand(x) => self.todo("Bindings::stmt", &x),
        }
    }

    /// Helper for loops, inserts a phi key for every name in the given flow.
    fn insert_phi_keys(&mut self, x: Flow, range: TextRange) -> Flow {
        let items = x
            .info
            .iter_hashed()
            .map(|x| (x.0.cloned(), x.1.ann))
            .collect::<SmallSet<_>>();
        let mut res = SmallMap::with_capacity(items.len());
        for (name, ann) in items.into_iter() {
            let key = Key::Phi(name.key().clone(), range);
            res.insert_hashed(name, FlowInfo::new(key.clone(), ann));
        }
        Flow {
            info: res,
            no_next: false,
        }
    }

    fn setup_loop(&mut self, range: TextRange) {
        let base = self.scopes.last().flow.clone();
        // To account for possible assignments to existing names in a loop, we
        // speculatively insert phi keys upfront.
        self.scopes.last_mut().flow = self.insert_phi_keys(base.clone(), range);
        self.scopes
            .last_mut()
            .loops
            .push(Loop(vec![(LoopExit::NeverRan, base)]));
    }

    fn teardown_loop(&mut self, range: TextRange, orelse: Vec<Stmt>) {
        let done = self.scopes.last_mut().loops.pop().unwrap();
        let (mut breaks, mut other_exits): (Vec<Flow>, Vec<Flow>) =
            done.0.into_iter().partition_map(|(exit, flow)| match exit {
                LoopExit::Break => Either::Left(flow),
                LoopExit::NeverRan | LoopExit::Continue => Either::Right(flow),
            });
        if breaks.is_empty() || orelse.is_empty() {
            // At least one of `breaks` and `orelse` is empty. If `breaks` is empty, then `orelse`
            // always runs. If `orelse` is empty, then running it is a no-op.
            other_exits.append(&mut breaks);
            self.merge_loop_into_current(other_exits, range);
            self.stmts(orelse);
        } else {
            // When there are both `break`s and an `else`, the `else` runs only when we don't `break`.
            let other_range =
                TextRange::new(range.start(), orelse.first().unwrap().range().start());
            self.merge_loop_into_current(other_exits, other_range);
            self.stmts(orelse);
            self.merge_loop_into_current(breaks, range);
        }
    }

    fn merge_flow(&mut self, mut xs: Vec<Flow>, range: TextRange, is_loop: bool) -> Flow {
        if xs.len() == 1 && xs[0].no_next {
            return xs.pop().unwrap();
        }
        let visible_branches = xs.into_iter().filter(|x| !x.no_next).collect::<Vec<_>>();

        let names = visible_branches
            .iter()
            .flat_map(|x| x.info.iter_hashed().map(|x| x.0.cloned()))
            .collect::<SmallSet<_>>();
        let mut res = SmallMap::with_capacity(names.len());
        for name in names.into_iter() {
            let (values, unordered_anns): (SmallSet<Key>, SmallSet<Option<Idx<KeyAnnotation>>>) =
                visible_branches
                    .iter()
                    .flat_map(|x| x.info.get(name.key()).cloned().map(|x| (x.key, x.ann)))
                    .unzip();
            let mut anns = unordered_anns
                .into_iter()
                .flatten()
                .map(|k| (k, self.table.annotations.0.idx_to_key(k).range()))
                .collect::<Vec<_>>();
            anns.sort_by_key(|(_, range)| (range.start(), range.end()));
            // If there are multiple annotations, this picks the first one.
            let mut ann = None;
            for other_ann in anns.into_iter() {
                match &ann {
                    None => {
                        ann = Some(other_ann);
                    }
                    Some(ann) => {
                        // A loop might capture the same annotation multiple times at many exit points.
                        // But we only want to consider it when we join up `if` statements.
                        if !is_loop {
                            self.table.insert(
                                Key::Anon(other_ann.1),
                                Binding::Eq(other_ann.0, ann.0, name.deref().clone()),
                            );
                        }
                    }
                }
            }
            let key = Key::Phi(name.key().clone(), range);
            res.insert_hashed(name, FlowInfo::new(key.clone(), ann.map(|x| x.0)));
            self.table.insert(key, Binding::phi(values));
        }
        Flow {
            info: res,
            no_next: false,
        }
    }

    fn merge_loop_into_current(&mut self, mut branches: Vec<Flow>, range: TextRange) {
        branches.push(self.scopes.last().flow.clone());
        self.scopes.last_mut().flow = self.merge_flow(branches, range, true);
    }
}

/// Handle intercepting names inside either function parameter/return
/// annotations or base class lists of classes, in order to check whether they
/// point at type variable declarations and need to be converted to type
/// parameters.
struct LegacyTParamBuilder {
    /// All of the names used. Each one may or may not point at a type variable
    /// and therefore bind a legacy type parameter.
    legacy_tparams: SmallMap<Name, Option<(Identifier, Key)>>,
    /// Are there scoped type parameters? Used to control downstream errors.
    has_scoped_tparams: bool,
}

impl LegacyTParamBuilder {
    fn new(has_scoped_tparams: bool) -> Self {
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
    fn forward_lookup(
        &mut self,
        builder: &mut BindingsBuilder,
        name: &Identifier,
    ) -> Option<Binding> {
        self.legacy_tparams
            .entry(name.id.clone())
            .or_insert_with(|| builder.lookup_name(name).map(|x| (name.clone(), x)))
            .as_ref()
            .map(|(id, _)| {
                let range_if_scoped_params_exist = if self.has_scoped_tparams {
                    Some(name.range())
                } else {
                    None
                };
                Binding::CheckLegacyTypeParam(
                    KeyLegacyTypeParam(id.clone()),
                    range_if_scoped_params_exist,
                )
            })
    }

    /// Add `Definition` bindings to a class or function body scope for all the names
    /// referenced in the function parameter/return annotations or the class bases.
    ///
    /// We do this so that AnswersSolver has the opportunity to determine whether any
    /// of those names point at legacy (pre-PEP-695) type variable declarations, in which
    /// case the name should be treated as a Quantified type parameter inside this scope.
    fn add_name_definitions(&self, builder: &mut BindingsBuilder) {
        for entry in self.legacy_tparams.values() {
            if let Some((identifier, key)) = entry {
                builder.table.insert(
                    KeyLegacyTypeParam(identifier.clone()),
                    BindingLegacyTypeParam(key.clone()),
                );
                builder
                    .scopes
                    .last_mut()
                    .stat
                    .add(identifier.id.clone(), identifier.range);
                builder.bind_definition(
                    identifier,
                    // Note: we use None as the range here because the range is
                    // used to error if legacy tparams are mixed with scope
                    // tparams, and we only want to do that once (which we do in
                    // the binding created by `forward_lookup`).
                    Binding::CheckLegacyTypeParam(KeyLegacyTypeParam(identifier.clone()), None),
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
    fn lookup_keys(&self) -> Vec<KeyLegacyTypeParam> {
        self.legacy_tparams
            .values()
            .flatten()
            .map(|(id, _)| KeyLegacyTypeParam(id.clone()))
            .collect()
    }
}

fn return_expr(x: StmtReturn) -> Expr {
    match x.value {
        Some(x) => *x,
        None => Expr::NoneLiteral(ExprNoneLiteral { range: x.range }),
    }
}
