/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// Clippy thinks ModuleData is mutable (it is), but the ArcId makes the Hash/Eq immutable
#![allow(clippy::mutable_key_type)]

use std::collections::HashMap;
use std::collections::HashSet;
use std::mem;
use std::path::PathBuf;
use std::sync::Arc;

use dupe::Dupe;
use enum_iterator::Sequence;
use ruff_python_ast::name::Name;
use ruff_text_size::TextRange;
use starlark_map::small_map::SmallMap;
use starlark_map::small_set::SmallSet;

use crate::alt::answers::AnswerEntry;
use crate::alt::answers::AnswerTable;
use crate::alt::answers::Answers;
use crate::alt::answers::AnswersSolver;
use crate::alt::answers::LookupAnswer;
use crate::alt::answers::Solutions;
use crate::alt::answers::SolutionsEntry;
use crate::alt::answers::SolutionsTable;
use crate::alt::traits::Solve;
use crate::binding::binding::KeyExport;
use crate::binding::binding::Keyed;
use crate::binding::bindings::BindingEntry;
use crate::binding::bindings::BindingTable;
use crate::binding::bindings::Bindings;
use crate::binding::table::TableKeyed;
use crate::error::collector::ErrorCollector;
use crate::error::error::Error;
use crate::error::expectation::Expectation;
use crate::error::kind::ErrorKind;
use crate::export::exports::Exports;
use crate::export::exports::LookupExport;
use crate::metadata::RuntimeMetadata;
use crate::module::module_info::ModuleInfo;
use crate::module::module_name::ModuleName;
use crate::module::module_path::ModulePath;
use crate::report::debug_info::DebugInfo;
use crate::state::dirty::Dirty;
use crate::state::epoch::Epoch;
use crate::state::epoch::Epochs;
use crate::state::handle::Handle;
use crate::state::loader::FindError;
use crate::state::loader::Loader;
use crate::state::loader::LoaderFindCache;
use crate::state::loader::LoaderId;
use crate::state::steps::Context;
use crate::state::steps::Load;
use crate::state::steps::Step;
use crate::state::steps::Steps;
use crate::state::subscriber::Subscriber;
use crate::types::class::Class;
use crate::types::stdlib::Stdlib;
use crate::types::types::Type;
use crate::util::arc_id::ArcId;
use crate::util::display::number_thousands;
use crate::util::enum_heap::EnumHeap;
use crate::util::lock::Mutex;
use crate::util::lock::RwLock;
use crate::util::locked_map::LockedMap;
use crate::util::no_hash::BuildNoHash;
use crate::util::prelude::SliceExt;
use crate::util::recurser::Recurser;
use crate::util::uniques::UniqueFactory;
use crate::util::upgrade_lock::UpgradeLock;
use crate::util::upgrade_lock::UpgradeLockExclusiveGuard;

pub struct State {
    uniques: UniqueFactory,
    stdlib: SmallMap<(RuntimeMetadata, LoaderId), Arc<Stdlib>>,
    modules: LockedMap<Handle, ArcId<ModuleData>>,
    loaders: SmallMap<LoaderId, Arc<LoaderFindCache<LoaderId>>>,
    /// Items we still need to process. Stored in a max heap, so that
    /// the highest step (the module that is closest to being finished)
    /// gets picked first, ensuring we release its memory quickly.
    todo: Mutex<EnumHeap<Step, ArcId<ModuleData>>>,
    /// Values whose solutions changed value since the last time we recomputed
    changed: Mutex<Vec<ArcId<ModuleData>>>,
    /// Handles which are dirty
    dirty: Mutex<SmallSet<ArcId<ModuleData>>>,
    /// The current epoch, gets incremented every time we recompute
    now: Epoch,
    /// Thing to tell about each action.
    subscriber: Option<Box<dyn Subscriber>>,

    // Set to true to keep data around forever.
    retain_memory: bool,
}

struct ModuleData {
    handle: Handle,
    state: UpgradeLock<Step, ModuleState>,
    deps: RwLock<HashMap<ModuleName, ArcId<ModuleData>, BuildNoHash>>,
    /// The reverse dependencies of this module. This is used to invalidate on change.
    /// Note that if we are only running once, e.g. on the command line, this isn't valuable.
    /// But we create it anyway for simplicity, since it doesn't seem to add much overhead.
    rdeps: Mutex<HashMap<Handle, ArcId<ModuleData>>>,
}

struct ModuleState {
    epochs: Epochs,
    dirty: Dirty,
    steps: Steps,
}

impl ModuleData {
    fn new(handle: Handle, now: Epoch) -> Self {
        Self {
            handle,
            state: UpgradeLock::new(ModuleState {
                epochs: Epochs::new(now),
                dirty: Dirty::default(),
                steps: Steps::default(),
            }),
            deps: Default::default(),
            rdeps: Default::default(),
        }
    }
}

impl State {
    pub fn new() -> Self {
        Self {
            uniques: UniqueFactory::new(),
            now: Epoch::zero(),
            stdlib: Default::default(),
            modules: Default::default(),
            loaders: Default::default(),
            todo: Default::default(),
            changed: Default::default(),
            dirty: Default::default(),
            subscriber: None,
            retain_memory: true, // Will always be overwritten by entry points
        }
    }

    pub fn import_handle(&self, handle: &Handle, module: ModuleName) -> Result<Handle, FindError> {
        Ok(Handle::new(
            module,
            self.get_cached_find(handle.loader(), module)?,
            handle.config().dupe(),
            handle.loader().dupe(),
        ))
    }

    fn clean(
        &self,
        module_data: &ArcId<ModuleData>,
        exclusive: UpgradeLockExclusiveGuard<Step, ModuleState>,
    ) {
        // We need to clean up the state.
        // If things have changed, we need to update the last_step.
        // We clear memory as an optimisation only.

        // Mark ourselves as having completed everything.
        let finish = |w: &mut ModuleState| {
            w.epochs.checked = self.now;
            w.dirty.clean();
        };
        // Rebuild stuff. Pass clear_ast to indicate we need to rebuild the AST, otherwise can reuse it (if present).
        let rebuild = |w: &mut ModuleState, clear_ast: bool| {
            w.steps.last_step = if clear_ast || w.steps.ast.is_none() {
                Some(Step::Load)
            } else {
                Some(Step::Ast)
            };
            if clear_ast {
                w.steps.ast = None;
            }
            w.steps.exports = None;
            w.steps.answers = None;
            // Do not clear solutions, since we can use that for equality
            w.epochs.computed = self.now;
            if let Some(subscriber) = &self.subscriber {
                subscriber.start_work(module_data.handle.dupe());
            }
            let deps = mem::take(&mut *module_data.deps.write());
            for d in deps.values() {
                let removed = d.rdeps.lock().remove(&module_data.handle);
                assert!(removed.is_some());
            }
            finish(w);
        };

        // Validate the load flag.
        if exclusive.dirty.load
            && let Some(old_load) = exclusive.steps.load.dupe()
        {
            let (code, self_error) =
                Load::load_from_path(module_data.handle.path(), module_data.handle.loader());
            if self_error.is_some() || &code != old_load.module_info.contents() {
                let mut write = exclusive.write();
                write.steps.load = Some(Arc::new(Load::load_from_data(
                    module_data.handle.module(),
                    module_data.handle.path().dupe(),
                    old_load.errors.style(),
                    code,
                    self_error,
                )));
                rebuild(&mut write, true);
                return;
            }
            // The contents are the same, so we can just reuse the old load
        }

        if exclusive.dirty.deps {
            let mut write = exclusive.write();
            rebuild(&mut write, false);
            return;
        }

        // Validate the find flag.
        if exclusive.dirty.find {
            let loader = self.get_cached_loader(module_data.handle.loader());
            let mut is_dirty = false;
            for x in module_data.deps.read().values() {
                match loader.find(x.handle.module()) {
                    Ok((path, _)) if &path == x.handle.path() => {}
                    _ => {
                        is_dirty = true;
                        break;
                    }
                }
            }
            if is_dirty {
                let mut write = exclusive.write();
                rebuild(&mut write, false);
                return;
            }
        }

        // The module was not dirty. Make sure our dependencies aren't dirty either.
        let mut write = exclusive.write();
        finish(&mut write);
    }

    fn demand(&self, module_data: &ArcId<ModuleData>, step: Step) {
        let mut computed = false;
        loop {
            let reader = module_data.state.read();
            if reader.epochs.checked != self.now {
                if let Some(ex) = reader.exclusive(Step::first()) {
                    self.clean(module_data, ex);
                    // We might have done some cleaning
                    computed = true;
                }
                continue;
            }

            let todo = match reader.steps.next_step() {
                Some(todo) if todo <= step => todo,
                _ => break,
            };
            let mut exclusive = match reader.exclusive(todo) {
                Some(exclusive) => exclusive,
                None => {
                    // The world changed, we should check again
                    continue;
                }
            };
            let todo = match exclusive.steps.next_step() {
                Some(todo) if todo <= step => todo,
                _ => break,
            };

            computed = true;
            let compute = todo.compute().0(&exclusive.steps);
            if todo == Step::Answers && !self.retain_memory {
                // We have captured the Ast, and must have already built Exports (we do it serially),
                // so won't need the Ast again.
                let to_drop;
                let mut writer = exclusive.write();
                to_drop = writer.steps.ast.take();
                exclusive = writer.exclusive();
                drop(to_drop);
            }

            let stdlib = self.get_stdlib(&module_data.handle);
            let loader = self.get_cached_loader(module_data.handle.loader());
            let set = compute(&Context {
                retain_memory: self.retain_memory,
                module: module_data.handle.module(),
                path: module_data.handle.path(),
                config: module_data.handle.config(),
                loader: &*loader,
                uniques: &self.uniques,
                stdlib: &stdlib,
                lookup: &self.lookup(module_data.dupe()),
            });
            {
                let mut changed = false;
                let mut to_drop = None;
                let mut writer = exclusive.write();
                let mut load_result = None;
                let old_solutions = if todo == Step::Solutions {
                    writer.steps.solutions.take()
                } else {
                    None
                };
                set(&mut writer.steps);
                if todo == Step::Solutions {
                    if old_solutions.as_ref().map(|x| &x.1)
                        != writer.steps.solutions.as_ref().map(|x| &x.1)
                    {
                        if old_solutions.is_some() {
                            changed = true;
                        }
                        writer.epochs.changed = self.now;
                    }
                    if !self.retain_memory {
                        // From now on we can use the answers directly, so evict the bindings/answers.
                        to_drop = writer.steps.answers.take();
                    }
                    load_result = writer.steps.load.dupe();
                }
                drop(writer);
                // Release the lock before dropping
                drop(to_drop);
                if changed {
                    self.changed.lock().push(module_data.dupe());
                    let mut dirtied = Vec::new();
                    for x in module_data.rdeps.lock().values() {
                        loop {
                            let reader = x.state.read();
                            if reader.epochs.computed == self.now || reader.dirty.deps {
                                // Either doesn't need setting, or already set
                                break;
                            }
                            if let Some(exclusive) = reader.exclusive(Step::first()) {
                                if exclusive.epochs.computed == self.now || exclusive.dirty.deps {
                                    break;
                                }
                                dirtied.push(x.dupe());
                                let mut writer = exclusive.write();
                                writer.dirty.deps = true;
                                break;
                            }
                            // continue around the loop - failed to get the lock, but we really want it
                        }
                    }
                    self.dirty.lock().extend(dirtied);
                }
                if let Some(load) = load_result
                    && let Some(subscriber) = &self.subscriber
                {
                    subscriber.finish_work(module_data.handle.dupe(), load);
                }
            }
            if todo == step {
                break; // Fast path - avoid asking again since we just did it.
            }
        }
        if computed && let Some(next) = step.next() {
            // For a large benchmark, LIFO is 10Gb retained, FIFO is 13Gb.
            // Perhaps we are getting to the heart of the graph with LIFO?
            self.todo.lock().push_lifo(next, module_data.dupe());
        }
    }

    fn get_module(&self, handle: &Handle) -> ArcId<ModuleData> {
        self.get_module_ex(handle).0
    }

    /// Return the module, plus true if the module was newly created.
    fn get_module_ex(&self, handle: &Handle) -> (ArcId<ModuleData>, bool) {
        let mut created = None;
        let res = self
            .modules
            .ensure(handle, || {
                let res = ArcId::new(ModuleData::new(handle.dupe(), self.now));
                created = Some(res.dupe());
                res
            })
            .dupe();
        // Due to race conditions, we might create two ModuleData, but only the first is returned.
        // Figure out if we won the race, and thus are the person who actually did the creation.
        let created = Some(&res) == created.as_ref();
        if created && let Some(subscriber) = &self.subscriber {
            subscriber.start_work(handle.dupe());
        }
        (res, created)
    }

    fn add_error(
        &self,
        module_data: &ArcId<ModuleData>,
        range: TextRange,
        msg: String,
        kind: ErrorKind,
    ) {
        let load = module_data.state.read().steps.load.dupe().unwrap();
        load.errors.add(range, msg, kind, None);
    }

    fn lookup<'a>(&'a self, module_data: ArcId<ModuleData>) -> StateHandle<'a> {
        StateHandle {
            state: self,
            module_data,
        }
    }

    fn lookup_stdlib(&self, handle: &Handle, name: &Name) -> Option<Class> {
        let module_data = self.get_module(handle);
        if !self
            .lookup_export(&module_data)
            .contains(name, &self.lookup(module_data.dupe()))
        {
            self.add_error(
                &module_data,
                TextRange::default(),
                format!(
                    "Stdlib import failure, was expecting `{}` to contain `{name}`",
                    module_data.handle.module()
                ),
                ErrorKind::MissingModuleAttribute,
            );
            return None;
        }

        let t = self.lookup_answer(module_data.dupe(), &KeyExport(name.clone()));
        match t.arc_clone() {
            Type::ClassDef(cls) => Some(cls),
            ty => {
                self.add_error(
                    &module_data,
                    TextRange::default(),
                    format!(
                        "Did not expect non-class type `{ty}` for stdlib import `{}.{name}`",
                        module_data.handle.module()
                    ),
                    ErrorKind::MissingModuleAttribute,
                );
                None
            }
        }
    }

    fn lookup_export(&self, module_data: &ArcId<ModuleData>) -> Exports {
        self.demand(module_data, Step::Exports);
        let lock = module_data.state.read();
        lock.steps.exports.dupe().unwrap()
    }

    fn lookup_answer<'b, K: Solve<StateHandle<'b>> + Keyed<EXPORTED = true>>(
        &'b self,
        module_data: ArcId<ModuleData>,
        key: &K,
    ) -> Arc<<K as Keyed>::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        {
            // if we happen to have solutions available, use them instead
            if let Some(solutions) = &module_data.state.read().steps.solutions {
                return solutions.1.get(key).unwrap().dupe();
            }
        }

        self.demand(&module_data, Step::Answers);
        let (load, answers) = {
            let steps = module_data.state.read();
            if let Some(solutions) = &steps.steps.solutions {
                return solutions.1.get(key).unwrap().dupe();
            }
            (
                steps.steps.load.dupe().unwrap(),
                steps.steps.answers.dupe().unwrap(),
            )
        };
        let stdlib = self.get_stdlib(&module_data.handle);
        let lookup = self.lookup(module_data);
        answers.1.solve_key(
            &lookup,
            &lookup,
            &answers.0,
            &load.errors,
            &stdlib,
            &self.uniques,
            key,
        )
    }

    pub fn collect_errors(&self) -> Vec<Error> {
        let mut errors = Vec::new();
        for module in self.modules.values() {
            let steps = module.state.read();
            if let Some(load) = &steps.steps.load {
                errors.extend(load.errors.collect());
            }
        }
        errors
    }

    pub fn module_count(&self) -> usize {
        self.modules.len()
    }

    pub fn count_errors(&self) -> usize {
        self.modules
            .values()
            .map(|x| {
                x.state
                    .read()
                    .steps
                    .load
                    .as_ref()
                    .map_or(0, |x| x.errors.len())
            })
            .sum()
    }

    pub fn print_errors(&self) {
        for module in self.modules.values() {
            let steps = module.state.read();
            if let Some(load) = &steps.steps.load {
                load.errors.print();
            }
        }
    }

    pub fn print_error_summary(&self, limit: usize) {
        let loads = self
            .modules
            .values()
            .filter_map(|x| x.state.read().steps.load.dupe())
            .collect::<Vec<_>>();
        let mut items = ErrorCollector::summarise(loads.iter().map(|x| &x.errors));
        items.reverse();
        items.truncate(limit);
        for (error, count) in items.iter().rev() {
            eprintln!("{} instances of {error}", number_thousands(*count));
        }
    }

    fn get_cached_find(
        &self,
        loader: &LoaderId,
        module: ModuleName,
    ) -> Result<ModulePath, FindError> {
        self.get_cached_loader(loader).find(module).map(|x| x.0)
    }

    fn get_cached_loader(&self, loader: &LoaderId) -> Arc<LoaderFindCache<LoaderId>> {
        if self.loaders.len() == 1 {
            // Since we know our one must exist, we can shortcut
            return self.loaders.first().unwrap().1.dupe();
        }

        // Safe because we always fill these in before starting
        self.loaders.get(loader).unwrap().dupe()
    }

    fn get_stdlib(&self, handle: &Handle) -> Arc<Stdlib> {
        if self.stdlib.len() == 1 {
            // Since we know our one must exist, we can shortcut
            return self.stdlib.first().unwrap().1.dupe();
        }

        // Safe because we always run compute_stdlib first
        self.stdlib
            .get(&(handle.config().dupe(), handle.loader().dupe()))
            .unwrap()
            .dupe()
    }

    fn compute_stdlib(&mut self, configs: SmallSet<(RuntimeMetadata, LoaderId)>) {
        self.stdlib = configs
            .iter()
            .map(|k| (k.dupe(), Arc::new(Stdlib::for_bootstrapping())))
            .collect();
        let stdlibs = configs
            .iter()
            .map(|(c, l)| {
                (
                    (c.dupe(), l.dupe()),
                    Arc::new(Stdlib::new(|module, name| {
                        let path = self.get_cached_find(l, module).ok()?;
                        self.lookup_stdlib(&Handle::new(module, path, c.dupe(), l.dupe()), name)
                    })),
                )
            })
            .collect();
        self.stdlib = stdlibs;
    }

    fn work(&self) {
        // ensure we have answers for everything, keep going until we don't discover any new modules
        loop {
            let mut lock = self.todo.lock();
            let x = match lock.pop() {
                Some(x) => x.1,
                None => break,
            };
            drop(lock);
            self.demand(&x, Step::last());
        }
    }

    fn run_step(&mut self, handles: &[Handle]) {
        self.now.next();
        let configs = handles
            .iter()
            .map(|x| (x.config().dupe(), x.loader().dupe()))
            .collect::<SmallSet<_>>();
        self.compute_stdlib(configs);

        {
            let dirty = mem::take(&mut *self.dirty.lock());
            let mut lock = self.todo.lock();
            for x in dirty {
                lock.push_fifo(Step::first(), x);
            }
            for h in handles {
                if let (m, true) = self.get_module_ex(h) {
                    lock.push_fifo(Step::first(), m);
                }
            }
        }

        rayon::scope(|s| {
            for _ in 0..rayon::current_num_threads() {
                // Only run work on Rayon threads, as we increased their stack limit
                s.spawn(|_| self.work());
            }
        });
    }

    fn ensure_loaders(&mut self, handles: &[Handle]) {
        for h in handles {
            self.loaders
                .entry(h.loader().dupe())
                .or_insert_with(|| Arc::new(LoaderFindCache::new(h.loader().dupe())));
        }
    }

    fn invalidate_rdeps(&mut self, changed: &[ArcId<ModuleData>]) {
        // We need to invalidate all modules that depend on anything in changed, including transitively.
        fn f(
            dirty_handles: &mut SmallMap<ArcId<ModuleData>, bool>,
            stack: &mut HashSet<ArcId<ModuleData>>,
            x: &ArcId<ModuleData>,
        ) -> bool {
            if let Some(res) = dirty_handles.get(x) {
                *res
            } else if stack.contains(x) {
                // Recursive hypothesis - do not write to dirty
                false
            } else {
                stack.insert(x.dupe());
                let reader = x.deps.read();
                let res = reader.values().any(|y| f(dirty_handles, stack, y));
                stack.remove(x);
                dirty_handles.insert(x.dupe(), res);
                res
            }
        }

        let mut dirty_handles = changed
            .iter()
            .map(|x| (x.dupe(), true))
            .collect::<SmallMap<_, _>>();
        let mut stack = HashSet::new();
        for x in self.modules.values() {
            f(&mut dirty_handles, &mut stack, x);
        }

        let mut dirty_set = self.dirty.lock();
        for (x, dirty) in dirty_handles {
            if dirty {
                x.state.write(Step::Load).unwrap().dirty.deps = true;
                dirty_set.insert(x);
            }
        }
    }

    fn run_internal(&mut self, handles: &[Handle]) {
        // We first compute all the modules that are either new or have changed.
        // Then we repeatedly compute all the modules who depend on modules that changed.
        // To ensure we guarantee termination, and don't endure more than a linear overhead,
        // if we end up spotting the same module changing twice, we just invalidate
        // everything in the cycle and force it to compute.
        let mut changed_twice = SmallSet::new();
        self.ensure_loaders(handles);
        loop {
            self.run_step(handles);
            let changed = mem::take(&mut *self.changed.lock());
            if changed.is_empty() {
                return;
            }
            for c in &changed {
                if !changed_twice.insert(c.dupe()) {
                    // We are in a cycle of mutual dependencies, so give up.
                    // Just invalidate everything in the cycle and recompute it all.
                    self.invalidate_rdeps(&changed);
                    self.run_step(handles);
                    return;
                }
            }
        }
    }

    /// Run, collecting all errors and destroying the state.
    /// The state afterwards will be useful for timing queries.
    /// Note we grab the `mut` only to stop other people accessing us simultaneously,
    /// we don't actually need it.
    pub fn run_one_shot(&mut self, handles: &[Handle], subscriber: Option<Box<dyn Subscriber>>) {
        self.retain_memory = false;
        self.subscriber = subscriber;
        self.run_internal(handles);
        self.subscriber = None;
    }

    pub fn run(&mut self, handles: &[Handle], subscriber: Option<Box<dyn Subscriber>>) {
        self.retain_memory = true;
        self.subscriber = subscriber;
        self.run_internal(handles);
        self.subscriber = None;
    }

    pub fn handles(&self) -> Vec<Handle> {
        self.modules.keys().cloned().collect()
    }

    pub fn get_bindings(&self, handle: &Handle) -> Option<Bindings> {
        self.modules
            .get(handle)?
            .state
            .read()
            .steps
            .answers
            .as_ref()
            .map(|x| x.0.dupe())
    }

    pub fn get_answers(&self, handle: &Handle) -> Option<Arc<Answers>> {
        self.modules
            .get(handle)?
            .state
            .read()
            .steps
            .answers
            .as_ref()
            .map(|x| x.1.dupe())
    }

    pub fn get_module_info(&self, handle: &Handle) -> Option<ModuleInfo> {
        self.modules
            .get(handle)?
            .state
            .read()
            .steps
            .load
            .as_ref()
            .map(|x| x.module_info.dupe())
    }

    pub fn get_ast(&self, handle: &Handle) -> Option<Arc<ruff_python_ast::ModModule>> {
        self.modules.get(handle)?.state.read().steps.ast.dupe()
    }

    #[allow(dead_code)]
    pub fn get_solutions(&self, handle: &Handle) -> Option<Arc<Solutions>> {
        let reader = self.modules.get(handle)?.state.read();
        Some(reader.steps.solutions.as_ref()?.1.dupe())
    }

    pub fn ad_hoc_solve<R: Sized, F: FnOnce(AnswersSolver<StateHandle>) -> R>(
        &self,
        handle: &Handle,
        solve: F,
    ) -> Option<R> {
        let module_data = self.modules.get(handle)?;
        let lookup = self.lookup(module_data.dupe());
        let steps = &module_data.state.read().steps;
        let errors = &steps.load.as_ref()?.errors;
        let (bindings, answers) = steps.answers.as_deref().as_ref()?;
        let stdlib = self.get_stdlib(handle);
        let recurser = Recurser::new();
        let solver = AnswersSolver::new(
            &lookup,
            answers,
            errors,
            bindings,
            &lookup,
            &self.uniques,
            &recurser,
            &stdlib,
        );
        let result = solve(solver);
        Some(result)
    }

    pub fn debug_info(&self, handles: &[Handle]) -> DebugInfo {
        let owned = handles.map(|x| {
            let module = self.get_module(x);
            let steps = module.state.read();
            (
                steps.steps.load.dupe().unwrap(),
                steps.steps.answers.dupe().unwrap(),
                steps.steps.solutions.dupe().unwrap(),
            )
        });
        DebugInfo::new(&owned.map(|x| (&x.0.module_info, &x.0.errors, &x.1.0, &*x.2.1)))
    }

    pub fn check_against_expectations(&self) -> anyhow::Result<()> {
        for module in self.modules.values() {
            let steps = module.state.read();
            let load = steps.steps.load.as_ref().unwrap();
            Expectation::parse(load.module_info.dupe(), load.module_info.contents())
                .check(&load.errors.collect())?;
        }
        Ok(())
    }

    /// Called if the `find` portion of loading might have changed.
    /// E.g. you have include paths, and a new file appeared earlier on the path.
    #[expect(dead_code)]
    pub fn invalidate_find(&mut self, loader: &LoaderId) {
        if let Some(cache) = self.loaders.get_mut(loader) {
            *cache = Arc::new(LoaderFindCache::new(loader.dupe()));
        }
        let mut dirty_set = self.dirty.lock();
        for (handle, module_data) in self.modules.iter_unordered() {
            if handle.loader() == loader {
                module_data.state.write(Step::Load).unwrap().dirty.find = true;
                dirty_set.insert(module_data.dupe());
            }
        }
    }

    /// Called if the `load_from_memory` portion of loading might have changed.
    /// Specify which in-memory files might have changed.
    pub fn invalidate_memory(&mut self, loader: LoaderId, files: &[PathBuf]) {
        let files = files
            .iter()
            .map(|x| ModulePath::memory(x.clone()))
            .collect::<SmallSet<_>>();
        let mut dirty_set = self.dirty.lock();
        for (handle, module_data) in self.modules.iter_unordered() {
            if handle.loader() == &loader && files.contains(handle.path()) {
                module_data.state.write(Step::Load).unwrap().dirty.load = true;
                dirty_set.insert(module_data.dupe());
            }
        }
    }

    /// Called if the files read from the disk might have changed.
    /// Specify which files might have changed.
    /// You must use the same absolute/relative paths as were given by `find`.
    #[expect(dead_code)]
    pub fn invalidate_disk(&mut self, files: &[PathBuf]) {
        // We create the set out of ModulePath as it allows us to reuse the fact `ModulePath` has cheap hash
        // when checking the modules.
        let files = files
            .iter()
            .map(|x| ModulePath::filesystem(x.clone()))
            .collect::<SmallSet<_>>();
        let mut dirty_set = self.dirty.lock();
        for (handle, module_data) in self.modules.iter_unordered() {
            if files.contains(handle.path()) {
                module_data.state.write(Step::Load).unwrap().dirty.load = true;
                dirty_set.insert(module_data.dupe());
            }
        }
    }

    /* Notes on how to move to incremental

    /// Run, collecting all errors and leaving enough around for further queries and incremental updates.
    pub fn run_incremental(&mut self) -> Vec<Error> {
        // FIXME: Should be incremental and not retain all state.
        unimplemented!()
    }

    /// Note that a particular path has changed, and the results are potentially invalid.
    pub fn update(&mut self, path: &Path) {
        let _ = path;
        // FIXME: For now, just invalidate everything.
        self.clear();
    }
    */
}

pub struct StateHandle<'a> {
    state: &'a State,
    module_data: ArcId<ModuleData>,
}

impl<'a> StateHandle<'a> {
    fn get_module(&self, module: ModuleName) -> Result<ArcId<ModuleData>, FindError> {
        if let Some(res) = self.module_data.deps.read().get(&module) {
            return Ok(res.dupe());
        }

        let handle = self.state.import_handle(&self.module_data.handle, module)?;
        let res = self.state.get_module(&handle);
        if self
            .module_data
            .deps
            .write()
            .insert(module, res.dupe())
            .is_none()
        {
            res.rdeps
                .lock()
                .insert(self.module_data.handle.dupe(), self.module_data.dupe());
        }
        Ok(res)
    }
}

impl<'a> LookupExport for StateHandle<'a> {
    fn get(&self, module: ModuleName) -> Result<Exports, FindError> {
        Ok(self.state.lookup_export(&self.get_module(module)?))
    }
}

impl<'a> LookupAnswer for StateHandle<'a> {
    fn get<K: Solve<Self> + Keyed<EXPORTED = true>>(
        &self,
        module: ModuleName,
        k: &K,
    ) -> Arc<K::Answer>
    where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
        SolutionsTable: TableKeyed<K, Value = SolutionsEntry<K>>,
    {
        // The unwrap is safe because we must have said there were no exports,
        // so no one can be trying to get at them
        let module_data = self.get_module(module).unwrap();
        self.state.lookup_answer(module_data, k)
    }
}
