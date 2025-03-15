/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use ruff_python_ast::visitor::source_order::walk_stmt;
use ruff_python_ast::visitor::source_order::SourceOrderVisitor;
use ruff_python_ast::ExceptHandler;
use ruff_python_ast::Expr;
use ruff_python_ast::ExprFString;
use ruff_python_ast::FStringElement;
use ruff_python_ast::FStringPart;
use ruff_python_ast::ModModule;
use ruff_python_ast::Pattern;
use ruff_python_ast::Stmt;

use crate::util::visit::Visit;
use crate::util::visit::VisitMut;

impl Visit<Expr> for ModModule {
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a Expr)) {
        Visitors::visit_mod_expr(self, f);
    }
}

impl VisitMut for Expr {
    fn visit_mut<'a>(&'a mut self, f: &mut dyn FnMut(&'a mut Self)) {
        Visitors::visit_expr_mut(self, f);
    }
}

impl Visit for Stmt {
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a Self)) {
        Visitors::visit_stmt(self, f);
    }
}

impl Visit<Expr> for ExprFString {
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a Expr)) {
        Visitors::visit_fstring_expr(self, f);
    }
}

impl Visit for Expr {
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a Self)) {
        Visitors::visit_expr(self, f);
    }
}

impl Visit for Pattern {
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a Self)) {
        Visitors::visit_pattern(self, f);
    }
}

/// Just used for convenient namespacing - not a real type
///
/// Functions based on <https://ndmitchell.com/#uniplate_30_sep_2007>.
struct Visitors;

impl Visitors {
    fn visit_mod_expr<'a>(x: &'a ModModule, mut f: impl FnMut(&'a Expr)) {
        x.body
            .iter()
            .for_each(|x| Visitors::visit_stmt_expr(x, &mut f));
    }

    fn visit_stmt<'a>(x: &'a Stmt, mut f: impl FnMut(&'a Stmt)) {
        fn fs<'a>(mut f: impl FnMut(&'a Stmt), xs: &'a [Stmt]) {
            xs.iter().for_each(&mut f);
        }

        match x {
            Stmt::FunctionDef(x) => fs(&mut f, &x.body),
            Stmt::ClassDef(x) => fs(&mut f, &x.body),
            Stmt::For(x) => {
                fs(&mut f, &x.body);
                fs(&mut f, &x.orelse)
            }
            Stmt::While(x) => {
                fs(&mut f, &x.body);
                fs(&mut f, &x.orelse);
            }
            Stmt::If(x) => {
                fs(&mut f, &x.body);
                for x in x.elif_else_clauses.iter() {
                    fs(&mut f, &x.body);
                }
            }
            Stmt::With(x) => fs(&mut f, &x.body),
            Stmt::Match(x) => {
                for x in x.cases.iter() {
                    fs(&mut f, &x.body);
                }
            }
            Stmt::Try(x) => {
                fs(&mut f, &x.body);
                x.handlers.iter().for_each(|x| match x {
                    ExceptHandler::ExceptHandler(x) => fs(&mut f, &x.body),
                });
                fs(&mut f, &x.orelse);
                fs(&mut f, &x.finalbody);
            }
            _ => {}
        }
    }

    fn visit_fstring_expr<'a>(x: &'a ExprFString, mut f: impl FnMut(&'a Expr)) {
        x.value.iter().for_each(|x| match x {
            FStringPart::FString(x) => x.elements.iter().for_each(|x| match x {
                FStringElement::Literal(_) => {}
                FStringElement::Expression(x) => f(&x.expression),
            }),
            _ => {}
        });
    }

    fn visit_stmt_expr<'a>(x: &'a Stmt, f: impl FnMut(&'a Expr)) {
        struct X<T>(T);
        impl<'a, T: FnMut(&'a Expr)> SourceOrderVisitor<'a> for X<T> {
            fn visit_expr(&mut self, x: &'a Expr) {
                self.0(x);
            }
        }
        walk_stmt(&mut X(f), x);
    }

    fn visit_expr<'a>(x: &'a Expr, mut f: impl FnMut(&'a Expr)) {
        match x {
            Expr::BoolOp(x) => x.values.iter().for_each(f),
            Expr::Named(x) => {
                f(&x.target);
                f(&x.value);
            }
            Expr::BinOp(x) => {
                f(&x.left);
                f(&x.right);
            }
            Expr::UnaryOp(x) => f(&x.operand),
            Expr::Lambda(x) => f(&x.body),
            Expr::If(x) => {
                f(&x.test);
                f(&x.body);
                f(&x.orelse);
            }
            Expr::Dict(x) => {
                x.items.iter().for_each(|x| {
                    x.key.as_ref().map(&mut f);
                    f(&x.value);
                });
            }
            Expr::Set(x) => x.elts.iter().for_each(f),
            Expr::ListComp(x) => {
                f(&x.elt);
                for x in &x.generators {
                    f(&x.iter);
                    x.ifs.iter().for_each(&mut f);
                }
            }
            Expr::SetComp(x) => {
                f(&x.elt);
                for x in &x.generators {
                    f(&x.iter);
                    x.ifs.iter().for_each(&mut f);
                }
            }
            Expr::DictComp(x) => {
                f(&x.key);
                f(&x.value);
                for x in &x.generators {
                    f(&x.iter);
                    x.ifs.iter().for_each(&mut f);
                }
            }
            Expr::Generator(x) => {
                f(&x.elt);
                for x in &x.generators {
                    f(&x.iter);
                    x.ifs.iter().for_each(&mut f);
                }
            }
            Expr::Await(x) => f(&x.value),
            Expr::Yield(x) => {
                if let Some(value) = &x.value {
                    f(value)
                }
            }
            Expr::YieldFrom(x) => f(&x.value),
            Expr::Compare(x) => {
                f(&x.left);
                x.comparators.iter().for_each(f);
            }
            Expr::Call(x) => {
                f(&x.func);
                x.arguments.args.iter().for_each(&mut f);
                x.arguments.keywords.iter().for_each(|x| f(&x.value));
            }
            Expr::FString(x) => {
                Visitors::visit_fstring_expr(x, f);
            }
            Expr::StringLiteral(_)
            | Expr::BytesLiteral(_)
            | Expr::NumberLiteral(_)
            | Expr::BooleanLiteral(_)
            | Expr::NoneLiteral(_)
            | Expr::EllipsisLiteral(_) => {}
            Expr::Attribute(x) => f(&x.value),
            Expr::Subscript(x) => {
                f(&x.value);
                f(&x.slice);
            }
            Expr::Starred(x) => f(&x.value),
            Expr::Name(_) => {}
            Expr::List(x) => x.elts.iter().for_each(f),
            Expr::Tuple(x) => x.elts.iter().for_each(f),
            Expr::Slice(x) => {
                x.lower.as_deref().map(&mut f);
                x.upper.as_deref().map(&mut f);
                x.step.as_deref().map(&mut f);
            }
            Expr::IpyEscapeCommand(_) => {}
        }
    }

    fn visit_expr_mut<'a>(x: &'a mut Expr, mut f: impl FnMut(&'a mut Expr)) {
        match x {
            Expr::BoolOp(x) => x.values.iter_mut().for_each(f),
            Expr::Named(x) => {
                f(&mut x.target);
                f(&mut x.value);
            }
            Expr::BinOp(x) => {
                f(&mut x.left);
                f(&mut x.right);
            }
            Expr::UnaryOp(x) => f(&mut x.operand),
            Expr::Lambda(x) => f(&mut x.body),
            Expr::If(x) => {
                f(&mut x.test);
                f(&mut x.body);
                f(&mut x.orelse);
            }
            Expr::Dict(x) => {
                x.items.iter_mut().for_each(|x| {
                    x.key.as_mut().map(&mut f);
                    f(&mut x.value);
                });
            }
            Expr::Set(x) => x.elts.iter_mut().for_each(f),
            Expr::ListComp(x) => {
                f(&mut x.elt);
                for x in &mut x.generators {
                    f(&mut x.iter);
                    x.ifs.iter_mut().for_each(&mut f);
                }
            }
            Expr::SetComp(x) => {
                f(&mut x.elt);
                for x in &mut x.generators {
                    f(&mut x.iter);
                    x.ifs.iter_mut().for_each(&mut f);
                }
            }
            Expr::DictComp(x) => {
                f(&mut x.key);
                f(&mut x.value);
                for x in &mut x.generators {
                    f(&mut x.iter);
                    x.ifs.iter_mut().for_each(&mut f);
                }
            }
            Expr::Generator(x) => {
                f(&mut x.elt);
                for x in &mut x.generators {
                    f(&mut x.iter);
                    x.ifs.iter_mut().for_each(&mut f);
                }
            }
            Expr::Await(x) => f(&mut x.value),
            Expr::Yield(x) => {
                if let Some(value) = &mut x.value {
                    f(value)
                }
            }
            Expr::YieldFrom(x) => f(&mut x.value),
            Expr::Compare(x) => {
                f(&mut x.left);
                x.comparators.iter_mut().for_each(f);
            }
            Expr::Call(x) => {
                f(&mut x.func);
                x.arguments.args.iter_mut().for_each(&mut f);
                x.arguments
                    .keywords
                    .iter_mut()
                    .for_each(|x| f(&mut x.value));
            }
            Expr::FString(x) => {
                for x in x.value.iter_mut() {
                    match x {
                        FStringPart::Literal(_) => {}
                        FStringPart::FString(x) => {
                            for x in x.elements.iter_mut() {
                                match x {
                                    FStringElement::Literal(_) => {}
                                    FStringElement::Expression(x) => f(&mut x.expression),
                                }
                            }
                        }
                    }
                }
            }
            Expr::StringLiteral(_)
            | Expr::BytesLiteral(_)
            | Expr::NumberLiteral(_)
            | Expr::BooleanLiteral(_)
            | Expr::NoneLiteral(_)
            | Expr::EllipsisLiteral(_) => {}
            Expr::Attribute(x) => f(&mut x.value),
            Expr::Subscript(x) => {
                f(&mut x.value);
                f(&mut x.slice);
            }
            Expr::Starred(x) => f(&mut x.value),
            Expr::Name(_) => {}
            Expr::List(x) => x.elts.iter_mut().for_each(f),
            Expr::Tuple(x) => x.elts.iter_mut().for_each(f),
            Expr::Slice(x) => {
                x.lower.as_deref_mut().map(&mut f);
                x.upper.as_deref_mut().map(&mut f);
                x.step.as_deref_mut().map(&mut f);
            }
            Expr::IpyEscapeCommand(_) => {}
        }
    }

    fn visit_pattern<'a>(x: &'a Pattern, mut f: impl FnMut(&'a Pattern)) {
        match x {
            Pattern::MatchValue(_) => {}
            Pattern::MatchSingleton(_) => {}
            Pattern::MatchSequence(x) => x.patterns.iter().for_each(f),
            Pattern::MatchMapping(x) => x.patterns.iter().for_each(f),
            Pattern::MatchClass(x) => x
                .arguments
                .patterns
                .iter()
                .chain(x.arguments.keywords.iter().map(|x| &x.pattern))
                .for_each(f),
            Pattern::MatchStar(_) => {}
            Pattern::MatchAs(x) => {
                if let Some(x) = &x.pattern {
                    f(x);
                }
            }
            Pattern::MatchOr(x) => {
                x.patterns.iter().for_each(f);
            }
        }
    }
}
