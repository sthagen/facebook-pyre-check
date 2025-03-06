/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::mem;

use ruff_python_ast::name::Name;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprCall;
use ruff_python_ast::ExprName;
use ruff_python_ast::Identifier;
use ruff_python_ast::Keyword;
use ruff_python_ast::Stmt;
use ruff_python_ast::StmtImportFrom;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;

use crate::ast::Ast;
use crate::binding::binding::AnnotationStyle;
use crate::binding::binding::AnnotationTarget;
use crate::binding::binding::Binding;
use crate::binding::binding::BindingAnnotation;
use crate::binding::binding::BindingExpect;
use crate::binding::binding::ContextManagerKind;
use crate::binding::binding::Key;
use crate::binding::binding::KeyAnnotation;
use crate::binding::binding::KeyExpect;
use crate::binding::binding::RaisedException;
use crate::binding::bindings::BindingsBuilder;
use crate::binding::narrow::NarrowOps;
use crate::binding::scope::FlowStyle;
use crate::binding::scope::LoopExit;
use crate::binding::scope::ScopeKind;
use crate::error::kind::ErrorKind;
use crate::export::special::SpecialExport;
use crate::graph::index::Idx;
use crate::module::module_name::ModuleName;
use crate::module::short_identifier::ShortIdentifier;
use crate::types::special_form::SpecialForm;
use crate::types::types::AnyStyle;
use crate::util::display::DisplayWith;

impl<'a> BindingsBuilder<'a> {
    fn bind_unimportable_names(&mut self, x: &StmtImportFrom) {
        for x in &x.names {
            if &x.name != "*" {
                let asname = x.asname.as_ref().unwrap_or(&x.name);
                // We pass None as imported_from, since we are really faking up a local error definition
                self.bind_definition(asname, Binding::AnyType(AnyStyle::Error), None);
            }
        }
    }

    // Check that the variable name in a functional definition matches the first argument string
    fn check_functional_definition_name(&mut self, name: &Name, arg: &Expr) {
        if let Expr::StringLiteral(x) = arg {
            if x.value.to_str() != name.as_str() {
                self.error(
                    arg.range(),
                    format!("Expected string literal \"{}\"", name),
                    ErrorKind::InvalidArgument,
                );
            }
        } else {
            self.error(
                arg.range(),
                format!("Expected string literal \"{}\"", name),
                ErrorKind::InvalidArgument,
            );
        }
    }

    fn assign_type_var(&mut self, name: &ExprName, call: &mut ExprCall) {
        self.ensure_expr(&mut call.func);
        let mut iargs = call.arguments.args.iter_mut();
        if let Some(expr) = iargs.next() {
            self.ensure_expr(expr);
        }
        // The constraints (i.e., any positional arguments after the first)
        // and some keyword arguments are types.
        for arg in iargs {
            self.ensure_type(arg, &mut None);
        }
        for kw in call.arguments.keywords.iter_mut() {
            if let Some(id) = &kw.arg
                && (id.id == "bound" || id.id == "default")
            {
                self.ensure_type(&mut kw.value, &mut None);
            } else {
                self.ensure_expr(&mut kw.value);
            }
        }
        self.bind_assign(name, |ann| {
            Binding::TypeVar(
                ann,
                Identifier::new(name.id.clone(), name.range()),
                Box::new(call.clone()),
            )
        })
    }

    fn assign_param_spec(&mut self, name: &ExprName, call: &mut ExprCall) {
        self.ensure_expr(&mut call.func);
        self.bind_assign(name, |ann| {
            Binding::ParamSpec(
                ann,
                Identifier::new(name.id.clone(), name.range()),
                Box::new(call.clone()),
            )
        })
    }

    fn assign_type_var_tuple(&mut self, name: &ExprName, call: &mut ExprCall) {
        self.ensure_expr(&mut call.func);
        self.bind_assign(name, |ann| {
            Binding::TypeVarTuple(
                ann,
                Identifier::new(name.id.clone(), name.range()),
                Box::new(call.clone()),
            )
        })
    }

    fn assign_enum(
        &mut self,
        name: &ExprName,
        func: &mut Expr,
        arg_name: &mut Expr,
        members: &mut [Expr],
    ) {
        self.ensure_expr(func);
        self.ensure_expr(arg_name);
        for arg in &mut *members {
            self.ensure_expr(arg);
        }
        self.check_functional_definition_name(&name.id, arg_name);
        self.synthesize_enum_def(
            Identifier::new(name.id.clone(), name.range()),
            func.clone(),
            members,
        );
    }

    fn assign_typed_dict(
        &mut self,
        name: &ExprName,
        func: &mut Expr,
        arg_name: &Expr,
        args: &mut [Expr],
        keywords: &mut [Keyword],
    ) {
        self.ensure_expr(func);
        self.check_functional_definition_name(&name.id, arg_name);
        self.synthesize_typed_dict_def(
            Identifier::new(name.id.clone(), name.range),
            func.clone(),
            args,
            keywords,
        );
    }

    fn assign_typing_named_tuple(
        &mut self,
        name: &ExprName,
        func: &mut Expr,
        arg_name: &Expr,
        members: &[Expr],
    ) {
        self.ensure_expr(func);
        self.check_functional_definition_name(&name.id, arg_name);
        self.synthesize_typing_named_tuple_def(
            Identifier::new(name.id.clone(), name.range()),
            func.clone(),
            members,
        );
    }

    fn assign_collections_named_tuple(
        &mut self,
        name: &ExprName,
        func: &mut Expr,
        arg_name: &Expr,
        members: &mut [Expr],
        keywords: &mut [Keyword],
    ) {
        self.ensure_expr(func);
        self.check_functional_definition_name(&name.id, arg_name);
        self.synthesize_collections_named_tuple_def(
            Identifier::new(name.id.clone(), name.range()),
            members,
            keywords,
        );
    }

    fn assign_new_type(&mut self, name: &ExprName, new_type_name: &mut Expr, base: &mut Expr) {
        self.ensure_expr(new_type_name);
        self.check_functional_definition_name(&name.id, new_type_name);
        self.ensure_type(base, &mut None);
        self.synthesize_typing_new_type(
            Identifier::new(name.id.clone(), name.range()),
            base.clone(),
        );
    }

    /// Evaluate the statements and update the bindings.
    /// Every statement should end up in the bindings, perhaps with a location that is never used.
    pub fn stmt(&mut self, x: Stmt) {
        match x {
            Stmt::FunctionDef(x) => {
                self.function_def(x);
            }
            Stmt::ClassDef(x) => self.class_def(x),
            Stmt::Return(mut x) => {
                self.ensure_expr_opt(x.value.as_deref_mut());
                self.functions.last_mut().returns.push(x);
                self.scopes.current_mut().flow.no_next = true;
            }
            Stmt::Delete(x) => self.todo("Bindings::stmt", &x),
            Stmt::Assign(mut x) => {
                let name = if x.targets.len() == 1
                    && let Expr::Name(name) = &x.targets[0]
                {
                    Some(name)
                } else {
                    None
                };
                let mut value = *x.value;
                if let Some(name) = name
                    && let Expr::Call(call) = &mut value
                    && let Some(special) = self.as_special_export(&call.func)
                {
                    match special {
                        SpecialExport::TypeVar => {
                            self.assign_type_var(name, call);
                            return;
                        }
                        SpecialExport::ParamSpec => {
                            self.assign_param_spec(name, call);
                            return;
                        }
                        SpecialExport::TypeVarTuple => {
                            self.assign_type_var_tuple(name, call);
                            return;
                        }
                        SpecialExport::Enum | SpecialExport::IntEnum | SpecialExport::StrEnum => {
                            if let Some((arg_name, members)) = call.arguments.args.split_first_mut()
                            {
                                self.assign_enum(name, &mut call.func, arg_name, members);
                                return;
                            }
                        }
                        SpecialExport::TypedDict => {
                            if let Some((arg_name, members)) = call.arguments.args.split_first_mut()
                            {
                                self.assign_typed_dict(
                                    name,
                                    &mut call.func,
                                    arg_name,
                                    members,
                                    &mut call.arguments.keywords,
                                );
                                return;
                            }
                        }
                        SpecialExport::TypingNamedTuple => {
                            if let Some((arg_name, members)) = call.arguments.args.split_first_mut()
                            {
                                self.assign_typing_named_tuple(
                                    name,
                                    &mut call.func,
                                    arg_name,
                                    members,
                                );
                                return;
                            }
                        }
                        SpecialExport::CollectionsNamedTuple => {
                            if let Some((arg_name, members)) = call.arguments.args.split_first_mut()
                            {
                                self.assign_collections_named_tuple(
                                    name,
                                    &mut call.func,
                                    arg_name,
                                    members,
                                    &mut call.arguments.keywords,
                                );
                                return;
                            }
                        }
                        SpecialExport::NewType => {
                            if let [new_type_name, base] = &mut *call.arguments.args {
                                self.assign_new_type(name, new_type_name, base);
                                return;
                            }
                        }
                        _ => {}
                    }
                }
                self.ensure_expr(&mut value);
                let name = name.cloned();
                for target in &mut x.targets {
                    let make_binding = |k: Option<Idx<KeyAnnotation>>| {
                        if let Some(name) = &name {
                            Binding::NameAssign(
                                name.id.clone(),
                                k.map(|k| (AnnotationStyle::Forwarded, k)),
                                Box::new(value.clone()),
                            )
                        } else {
                            Binding::Expr(k, value.clone())
                        }
                    };
                    self.bind_target(target, &make_binding, Some(&value));
                    self.ensure_expr(target);
                }
            }
            Stmt::AugAssign(mut x) => {
                self.ensure_expr(&mut x.target);
                self.ensure_expr(&mut x.value);
                let make_binding = |_: Option<Idx<KeyAnnotation>>| Binding::AugAssign(x.clone());
                self.bind_target(&x.target, &make_binding, None);
            }
            Stmt::AnnAssign(mut x) => match *x.target {
                Expr::Name(name) => {
                    let name = Ast::expr_name_identifier(name);
                    let ann_key = KeyAnnotation::Annotation(ShortIdentifier::new(&name));
                    self.ensure_type(&mut x.annotation, &mut None);
                    let ann_val = if let Some(special) = SpecialForm::new(&name.id, &x.annotation) {
                        BindingAnnotation::Type(
                            AnnotationTarget::Assign(name.id.clone()),
                            special.to_type(),
                        )
                    } else {
                        BindingAnnotation::AnnotateExpr(
                            AnnotationTarget::Assign(name.id.clone()),
                            *x.annotation.clone(),
                            None,
                        )
                    };
                    let ann_key = self.table.insert(ann_key, ann_val);

                    let flow_style =
                        if matches!(self.scopes.current().kind, ScopeKind::ClassBody(_)) {
                            let initial_value = x.value.as_deref().cloned();
                            FlowStyle::AnnotatedClassField { initial_value }
                        } else {
                            FlowStyle::Annotated {
                                is_initialized: x.value.is_some(),
                            }
                        };
                    let binding_value = if let Some(value) = x.value {
                        // Treat a name as initialized, but skip actually checking the value, if we are assigning `...` in a stub.
                        if self.module_info.path().is_interface()
                            && matches!(&*value, Expr::EllipsisLiteral(_))
                        {
                            None
                        } else {
                            Some(value)
                        }
                    } else {
                        None
                    };

                    let binding = if let Some(mut value) = binding_value {
                        // Handle forward references in explicit type aliases.
                        if self.as_special_export(&x.annotation) == Some(SpecialExport::TypeAlias) {
                            self.ensure_type(&mut value, &mut None);
                        } else {
                            self.ensure_expr(&mut value);
                        }
                        Binding::NameAssign(
                            name.id.clone(),
                            Some((AnnotationStyle::Direct, ann_key)),
                            value,
                        )
                    } else {
                        Binding::AnnotatedType(
                            ann_key,
                            Box::new(Binding::AnyType(AnyStyle::Implicit)),
                        )
                    };
                    if let Some(ann) = self.bind_definition(&name, binding, Some(flow_style))
                        && ann != ann_key
                    {
                        self.table.insert(
                            KeyExpect(name.range),
                            BindingExpect::Eq(ann_key, ann, name.id.clone()),
                        );
                    }
                }
                Expr::Attribute(mut attr) => {
                    self.ensure_expr(&mut attr.value);
                    self.ensure_type(&mut x.annotation, &mut None);
                    let ann_key = self.table.insert(
                        KeyAnnotation::AttrAnnotation(x.annotation.range()),
                        BindingAnnotation::AnnotateExpr(
                            AnnotationTarget::Assign(attr.attr.id.clone()),
                            *x.annotation,
                            None,
                        ),
                    );
                    let value_binding = match &x.value {
                        Some(v) => Binding::Expr(None, *v.clone()),
                        None => Binding::AnyType(AnyStyle::Implicit),
                    };
                    if !self.bind_attr_if_self(&attr, value_binding, Some(ann_key)) {
                        self.error(
                             x.range,
                             format!(
                                 "Type cannot be declared in assignment to non-self attribute `{}.{}`",
                                 attr.value.display_with(&self.module_info),
                                 attr.attr.id,
                             ),
                             ErrorKind::BadAssignment,
                         );
                    }
                    if let Some(box mut v) = x.value {
                        self.ensure_expr(&mut v);
                        self.table.insert(
                            KeyExpect(v.range()),
                            BindingExpect::CheckAssignExprToAttribute(Box::new((attr, v))),
                        );
                    }
                }
                _ => self.todo("Bindings::stmt AnnAssign", &x),
            },
            Stmt::TypeAlias(mut x) => {
                if let Expr::Name(name) = *x.name {
                    if let Some(params) = &mut x.type_params {
                        self.type_params(params);
                    }
                    self.ensure_type(&mut x.value, &mut None);
                    let binding = Binding::ScopedTypeAlias(name.id.clone(), x.type_params, x.value);
                    self.bind_definition(&Ast::expr_name_identifier(name), binding, None);
                } else {
                    self.todo("Bindings::stmt TypeAlias", &x);
                }
            }
            Stmt::For(mut x) => {
                self.setup_loop(x.range, &NarrowOps::new());
                self.ensure_expr(&mut x.iter);
                let make_binding = |k| Binding::IterableValue(k, *x.iter.clone());
                self.bind_target(&x.target, &make_binding, None);
                self.ensure_expr(&mut x.target);
                self.stmts(x.body);
                self.teardown_loop(x.range, &NarrowOps::new(), x.orelse);
            }
            Stmt::While(mut x) => {
                let narrow_ops = NarrowOps::from_expr(Some(&x.test));
                self.setup_loop(x.range, &narrow_ops);
                self.ensure_expr(&mut x.test);
                self.table
                    .insert(Key::Anon(x.test.range()), Binding::Expr(None, *x.test));
                self.stmts(x.body);
                self.teardown_loop(x.range, &narrow_ops, x.orelse);
            }
            Stmt::If(x) => {
                let range = x.range;
                let mut exhaustive = false;
                let mut branches = Vec::new();
                // Type narrowing operations that are carried over from one branch to the next. For example, in:
                //   if x is None:
                //     pass
                //   else:
                //     pass
                // x is bound to Narrow(x, Is(None)) in the if branch, and the negation, Narrow(x, IsNot(None)),
                // is carried over to the else branch.
                let mut negated_prev_ops = NarrowOps::new();
                let mut implicit_else = true;
                for (range, test, body) in Ast::if_branches_owned(x) {
                    let b = self.config.evaluate_bool_opt(test.as_ref());
                    if b == Some(false) {
                        continue; // We won't pick this branch
                    }
                    self.bind_narrow_ops(&negated_prev_ops, range);
                    let mut base = self.scopes.current().flow.clone();
                    let new_narrow_ops = NarrowOps::from_expr(test.as_ref());
                    if let Some(mut e) = test {
                        self.ensure_expr(&mut e);
                        self.table
                            .insert(Key::Anon(e.range()), Binding::Expr(None, e));
                    } else {
                        implicit_else = false;
                    }
                    self.bind_narrow_ops(&new_narrow_ops, range);
                    negated_prev_ops.and_all(new_narrow_ops.negate());
                    self.stmts(body);
                    mem::swap(&mut self.scopes.current_mut().flow, &mut base);
                    branches.push(base);
                    if b == Some(true) {
                        exhaustive = true;
                        break; // We picked this branch, none others stand a chance
                    }
                }
                if implicit_else {
                    // If there is no explicit else branch, we still want to merge the negated ops
                    // from the previous branches into the flow env.
                    // Note, using a default use_range is OK. The range is only needed to make the
                    // key distinct from other keys.
                    self.bind_narrow_ops(&negated_prev_ops, TextRange::default());
                }
                if !exhaustive {
                    branches.push(mem::take(&mut self.scopes.current_mut().flow));
                }
                self.scopes.current_mut().flow = self.merge_flow(branches, range);
            }
            Stmt::With(x) => {
                let kind = if x.is_async {
                    ContextManagerKind::Async
                } else {
                    ContextManagerKind::Sync
                };
                for mut item in x.items {
                    self.ensure_expr(&mut item.context_expr);
                    if let Some(mut opts) = item.optional_vars {
                        let make_binding = |k: Option<Idx<KeyAnnotation>>| {
                            Binding::ContextValue(k, item.context_expr.clone(), kind)
                        };
                        self.bind_target(&opts, &make_binding, None);
                        self.ensure_expr(&mut opts);
                    } else {
                        self.table.insert(
                            Key::Anon(item.range()),
                            Binding::ContextValue(None, item.context_expr, kind),
                        );
                    }
                }
                self.stmts(x.body);
            }
            Stmt::Match(x) => {
                self.stmt_match(x);
            }
            Stmt::Raise(x) => {
                if let Some(mut exc) = x.exc {
                    self.ensure_expr(&mut exc);
                    let raised = if let Some(mut cause) = x.cause {
                        self.ensure_expr(&mut cause);
                        RaisedException::WithCause(Box::new((*exc, *cause)))
                    } else {
                        RaisedException::WithoutCause(*exc)
                    };
                    self.table.insert(
                        KeyExpect(x.range),
                        BindingExpect::CheckRaisedException(raised),
                    );
                } else {
                    // If there's no exception raised, don't bother checking the cause.
                }
                self.scopes.current_mut().flow.no_next = true;
            }
            Stmt::Try(x) => {
                let range = x.range;
                let mut branches = Vec::new();
                let mut base = self.scopes.current().flow.clone();

                // We branch before the body, conservatively assuming that any statement can fail
                // entry -> try -> else -> finally
                //   |                     ^
                //   ----> handler --------|

                self.stmts(x.body);
                self.stmts(x.orelse);
                mem::swap(&mut self.scopes.current_mut().flow, &mut base);
                branches.push(base);

                for h in x.handlers {
                    base = self.scopes.current().flow.clone();
                    let range = h.range();
                    let h = h.except_handler().unwrap(); // Only one variant for now
                    if let Some(name) = h.name
                        && let Some(mut type_) = h.type_
                    {
                        self.ensure_expr(&mut type_);
                        self.bind_definition(
                            &name,
                            Binding::ExceptionHandler(type_, x.is_star),
                            None,
                        );
                    } else if let Some(mut type_) = h.type_ {
                        self.ensure_expr(&mut type_);
                        self.table.insert(
                            Key::Anon(range),
                            Binding::ExceptionHandler(type_, x.is_star),
                        );
                    }
                    self.stmts(h.body);
                    mem::swap(&mut self.scopes.current_mut().flow, &mut base);
                    branches.push(base);
                }

                self.scopes.current_mut().flow = self.merge_flow(branches, range);
                self.stmts(x.finalbody);
            }
            Stmt::Assert(mut x) => {
                self.ensure_expr(&mut x.test);
                self.bind_narrow_ops(&NarrowOps::from_expr(Some(&x.test)), x.range);
                self.table
                    .insert(Key::Anon(x.test.range()), Binding::Expr(None, *x.test));
                if let Some(mut msg_expr) = x.msg {
                    self.ensure_expr(&mut msg_expr);
                    self.table
                        .insert(Key::Anon(msg_expr.range()), Binding::Expr(None, *msg_expr));
                };
            }
            Stmt::Import(x) => {
                for x in x.names {
                    let m = ModuleName::from_name(&x.name.id);
                    if let Err(err) = self.lookup.get(m) {
                        self.error(x.range, err.display(m), ErrorKind::MissingModuleAttribute);
                    }
                    match x.asname {
                        Some(asname) => {
                            self.bind_definition(
                                &asname,
                                Binding::Module(m, m.components(), None),
                                Some(FlowStyle::ImportAs(m)),
                            );
                        }
                        None => {
                            let first = m.first_component();
                            let flow_info = self.scopes.current().flow.info.get(&first);
                            let module_key = match flow_info {
                                Some(flow_info)
                                    if matches!(
                                        flow_info.style,
                                        Some(FlowStyle::MergeableImport(_))
                                    ) =>
                                {
                                    Some(flow_info.key)
                                }
                                _ => None,
                            };
                            let key = self.table.insert(
                                Key::Import(first.clone(), x.name.range),
                                Binding::Module(m, vec![first.clone()], module_key),
                            );
                            self.bind_key(&first, key, Some(FlowStyle::MergeableImport(m)));
                        }
                    }
                }
            }
            Stmt::ImportFrom(x) => {
                if let Some(m) = self.module_info.name().new_maybe_relative(
                    self.module_info.path().is_init(),
                    x.level,
                    x.module.as_ref().map(|x| &x.id),
                ) {
                    match self.lookup.get(m) {
                        Ok(module_exports) => {
                            for x in x.names {
                                if &x.name == "*" {
                                    for name in module_exports.wildcard(self.lookup).iter() {
                                        let key = Key::Import(name.clone(), x.range);
                                        let val = if module_exports.contains(name, self.lookup) {
                                            Binding::Import(m, name.clone())
                                        } else {
                                            self.error(
                                                x.range,
                                                format!("Could not import `{name}` from `{m}`"),
                                                ErrorKind::MissingModuleAttribute,
                                            );
                                            Binding::AnyType(AnyStyle::Error)
                                        };
                                        let key = self.table.insert(key, val);
                                        self.bind_key(
                                            name,
                                            key,
                                            Some(FlowStyle::Import(m, name.clone())),
                                        );
                                    }
                                } else {
                                    let asname = x.asname.unwrap_or_else(|| x.name.clone());
                                    let val = if module_exports.contains(&x.name.id, self.lookup) {
                                        Binding::Import(m, x.name.id.clone())
                                    } else {
                                        let x_as_module_name = m.append(&x.name.id);
                                        if self.lookup.get(x_as_module_name).is_ok() {
                                            Binding::Module(
                                                x_as_module_name,
                                                x_as_module_name.components(),
                                                None,
                                            )
                                        } else {
                                            self.error(
                                                x.range,
                                                format!(
                                                    "Could not import `{}` from `{m}`",
                                                    x.name.id
                                                ),
                                                ErrorKind::MissingModuleAttribute,
                                            );
                                            Binding::AnyType(AnyStyle::Error)
                                        }
                                    };
                                    self.bind_definition(
                                        &asname,
                                        val,
                                        Some(FlowStyle::Import(m, x.name.id)),
                                    );
                                }
                            }
                        }
                        Err(err) => {
                            self.error(x.range, err.display(m), ErrorKind::MissingModuleAttribute);
                            self.bind_unimportable_names(&x);
                        }
                    }
                } else {
                    self.error(
                        x.range,
                        format!(
                            "Could not resolve relative import `{}`",
                            ".".repeat(x.level as usize)
                        ),
                        ErrorKind::ImportError,
                    );
                    self.bind_unimportable_names(&x);
                }
            }
            Stmt::Global(x) => self.todo("Bindings::stmt", &x),
            Stmt::Nonlocal(x) => self.todo("Bindings::stmt", &x),
            Stmt::Expr(mut x) => {
                self.ensure_expr(&mut x.value);
                self.table.insert(
                    Key::StmtExpr(x.value.range()),
                    Binding::Expr(None, *x.value),
                );
            }
            Stmt::Pass(_) => { /* no-op */ }
            Stmt::Break(x) => {
                self.add_loop_exitpoint(LoopExit::Break, x.range);
            }
            Stmt::Continue(x) => {
                self.add_loop_exitpoint(LoopExit::Continue, x.range);
            }
            Stmt::IpyEscapeCommand(x) => self.error(
                x.range,
                "IPython escapes are not supported".to_owned(),
                ErrorKind::Unsupported,
            ),
        }
    }
}
