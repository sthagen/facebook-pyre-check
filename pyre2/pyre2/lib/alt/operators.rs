/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use dupe::Dupe;
use ruff_python_ast::name::Name;
use ruff_python_ast::CmpOp;
use ruff_python_ast::ExprBinOp;
use ruff_python_ast::ExprCompare;
use ruff_python_ast::Operator;
use ruff_python_ast::StmtAugAssign;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;

use crate::alt::answers::AnswersSolver;
use crate::alt::answers::LookupAnswer;
use crate::alt::call::CallStyle;
use crate::alt::callable::CallArg;
use crate::binding::binding::KeyAnnotation;
use crate::dunder;
use crate::error::collector::ErrorCollector;
use crate::error::context::ErrorContext;
use crate::error::context::TypeCheckContext;
use crate::error::context::TypeCheckKind;
use crate::error::kind::ErrorKind;
use crate::error::style::ErrorStyle;
use crate::graph::index::Idx;
use crate::types::types::Type;

impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    fn callable_dunder_helper(
        &self,
        method_type: Type,
        range: TextRange,
        errors: &ErrorCollector,
        context: &dyn Fn() -> ErrorContext,
        op: Operator,
        call_arg_type: &Type,
    ) -> Type {
        let callable = self.as_call_target_or_error(
            method_type,
            CallStyle::BinaryOp(op),
            range,
            errors,
            Some(context),
        );
        self.call_infer(
            callable,
            &[CallArg::Type(call_arg_type, range)],
            &[],
            range,
            errors,
            Some(context),
        )
    }

    pub fn binop_infer(&self, x: &ExprBinOp, errors: &ErrorCollector) -> Type {
        let binop_call = |op: Operator, lhs: &Type, rhs: &Type, range: TextRange| -> Type {
            let context =
                || ErrorContext::BinaryOp(op.as_str().to_owned(), lhs.clone(), rhs.clone());

            let method_type_dunder = self.type_of_attr_get_if_found(
                lhs,
                &Name::new(op.dunder()),
                range,
                errors,
                Some(&context),
                "Expr::binop_infer",
            );

            let method_type_reflected = self.type_of_attr_get_if_found(
                rhs,
                &Name::new(op.reflected_dunder()),
                range,
                errors,
                Some(&context),
                "Expr::binop_infer",
            );

            // Reflected operator implementation: This deviates from the runtime semantics by calling the reflected dunder if the regular dunder call errors.
            // At runtime, the reflected dunder is called only if the regular dunder method doesn't exist or if it returns NotImplemented.
            // This deviation is necessary, given that the typeshed stubs don't record when NotImplemented is returned
            match (method_type_dunder, method_type_reflected) {
                (Some(method_type_dunder), Some(method_type_reflected)) => {
                    let bin_op_new_errors_dunder =
                        ErrorCollector::new(self.module_info().dupe(), ErrorStyle::Delayed);

                    let ret = self.callable_dunder_helper(
                        method_type_dunder,
                        range,
                        &bin_op_new_errors_dunder,
                        &context,
                        op,
                        rhs,
                    );
                    if bin_op_new_errors_dunder.is_empty() {
                        ret
                    } else {
                        self.callable_dunder_helper(
                            method_type_reflected,
                            range,
                            errors,
                            &context,
                            op,
                            lhs,
                        )
                    }
                }
                (Some(method_type_dunder), None) => self.callable_dunder_helper(
                    method_type_dunder,
                    range,
                    errors,
                    &context,
                    op,
                    rhs,
                ),
                (None, Some(method_type_reflected)) => self.callable_dunder_helper(
                    method_type_reflected,
                    range,
                    errors,
                    &context,
                    op,
                    lhs,
                ),
                (None, None) => self.error(
                    errors,
                    x.range(),
                    ErrorKind::MissingAttribute,
                    Some(&context),
                    format!(
                        "Missing attribute {} or {}",
                        op.dunder(),
                        op.reflected_dunder()
                    ),
                ),
            }
        };
        let lhs = self.expr_infer(&x.left, errors);
        let rhs = self.expr_infer(&x.right, errors);
        if let Type::Any(style) = &lhs {
            return style.propagate();
        } else if x.op == Operator::BitOr
            && let Some(l) = self.untype_opt(lhs.clone(), x.left.range())
            && let Some(r) = self.untype_opt(rhs.clone(), x.right.range())
        {
            return Type::type_form(self.union(l, r));
        } else if x.op == Operator::Add
            && ((lhs == Type::LiteralString && rhs.is_literal_string())
                || (rhs == Type::LiteralString && lhs.is_literal_string()))
        {
            return Type::LiteralString;
        }
        self.distribute_over_union(&lhs, |lhs| {
            self.distribute_over_union(&rhs, |rhs| binop_call(x.op, lhs, rhs, x.range))
        })
    }

    pub fn augassign_infer(
        &self,
        ann: Option<Idx<KeyAnnotation>>,
        x: &StmtAugAssign,
        errors: &ErrorCollector,
    ) -> Type {
        let binop_call = |op: Operator, lhs: &Type, rhs: &Type, range: TextRange| -> Type {
            let context =
                || ErrorContext::InplaceBinaryOp(op.as_str().to_owned(), lhs.clone(), rhs.clone());
            let inplace_dunder = self.type_of_attr_get_if_found(
                lhs,
                &Name::new(op.in_place_dunder()),
                range,
                errors,
                Some(&context),
                "Binding::AugAssign",
            );
            let regular_dunder = self.type_of_attr_get_if_found(
                lhs,
                &Name::new(op.dunder()),
                range,
                errors,
                Some(&context),
                "Binding::AugAssign",
            );
            let reflected_dunder = self.type_of_attr_get_if_found(
                rhs,
                &Name::new(op.reflected_dunder()),
                range,
                errors,
                Some(&context),
                "Binding::AugAssign",
            );
            // first, try the in-place method like `__iadd__`
            if let Some(inplace) = inplace_dunder {
                if regular_dunder.is_some() || reflected_dunder.is_some() {
                    let inplace_errors =
                        ErrorCollector::new(self.module_info().dupe(), ErrorStyle::Delayed);
                    let ret = self.callable_dunder_helper(
                        inplace,
                        range,
                        &inplace_errors,
                        &context,
                        op,
                        rhs,
                    );
                    if inplace_errors.is_empty() {
                        return ret;
                    }
                } else {
                    return self.callable_dunder_helper(inplace, range, errors, &context, op, rhs);
                }
            }
            // next, try the regular method like `__add__`
            if let Some(regular) = regular_dunder {
                if reflected_dunder.is_some() {
                    let regular_errors =
                        ErrorCollector::new(self.module_info().dupe(), ErrorStyle::Delayed);
                    let ret = self.callable_dunder_helper(
                        regular,
                        range,
                        &regular_errors,
                        &context,
                        op,
                        rhs,
                    );
                    if regular_errors.is_empty() {
                        return ret;
                    }
                } else {
                    return self.callable_dunder_helper(regular, range, errors, &context, op, rhs);
                }
            }
            // finally, try the reflected method on the rhs, like `__radd__`
            if let Some(reflected) = reflected_dunder {
                self.callable_dunder_helper(reflected, range, errors, &context, op, lhs)
            } else {
                self.error(
                    errors,
                    range,
                    ErrorKind::MissingAttribute,
                    Some(&context),
                    format!(
                        "Missing attribute {}, {}, or {}",
                        op.in_place_dunder(),
                        op.dunder(),
                        op.reflected_dunder()
                    ),
                )
            }
        };
        let base = self.expr_infer(&x.target, errors);
        let rhs = self.expr_infer(&x.value, errors);
        if let Type::Any(style) = &base {
            return style.propagate();
        } else if x.op == Operator::Add && base.is_literal_string() && rhs.is_literal_string() {
            return Type::LiteralString;
        }
        let tcc: &dyn Fn() -> TypeCheckContext =
            &|| TypeCheckContext::of_kind(TypeCheckKind::AugmentedAssignment);
        let result = self.distribute_over_union(&base, |lhs| {
            self.distribute_over_union(&rhs, |rhs| binop_call(x.op, lhs, rhs, x.range))
        });
        // If we're assigning to something with an annotation, make sure the produced value is assignable to it
        if let Some(ann) = ann.map(|k| self.get_idx(k)) {
            if ann.annotation.is_final() {
                self.error(
                    errors,
                    x.range(),
                    ErrorKind::BadAssignment,
                    None,
                    format!("Cannot assign to {} because it is marked final", ann.target),
                );
            }
            if let Some(ann_ty) = ann.ty() {
                return self.check_type(ann_ty, &result, x.range(), errors, tcc);
            }
        }
        result
    }

    pub fn compare_infer(&self, x: &ExprCompare, errors: &ErrorCollector) -> Type {
        let left = self.expr_infer(&x.left, errors);
        let comparisons = x.ops.iter().zip(x.comparators.iter());
        for (op, comparator) in comparisons {
            let right = self.expr_infer(comparator, errors);
            let right_range = comparator.range();
            // We ignore the type produced here and return `bool` from the comparison.
            self.distribute_over_union(&left, |left| {
                self.distribute_over_union(&right, |right| {
                    let context = || {
                        ErrorContext::BinaryOp(op.as_str().to_owned(), left.clone(), right.clone())
                    };
                    let compare_by_method = |ty, method, arg| {
                        self.call_method(ty, &method, x.range, &[arg], &[], errors, Some(&context))
                    };
                    let comparison_error = || {
                        self.error(
                            errors,
                            x.range,
                            ErrorKind::UnsupportedOperand,
                            None,
                            context().format(),
                        )
                    };
                    match op {
                        CmpOp::Eq | CmpOp::NotEq | CmpOp::Is | CmpOp::IsNot => {
                            // We assume these comparisons never error. Technically, `__eq__` and
                            // `__ne__` can be overridden, but we generally bake in the assumption
                            // that `==` and `!=` check equality as typically defined in Python.
                            Type::any_implicit()
                        }
                        CmpOp::In | CmpOp::NotIn => {
                            // `x in y` desugars to `y.__contains__(x)`
                            if compare_by_method(
                                right,
                                dunder::CONTAINS,
                                CallArg::Type(left, x.left.range()),
                            )
                            .is_some()
                            {
                                // Comparison method called. We ignore the return type.
                                Type::any_implicit()
                            } else {
                                comparison_error()
                            }
                        }
                        _ => {
                            if let Some(magic_method) = dunder::rich_comparison_dunder(*op)
                                && compare_by_method(
                                    left,
                                    magic_method,
                                    CallArg::Type(right, right_range),
                                )
                                .is_some()
                            {
                                // Comparison method called. We ignore the return type.
                                Type::any_implicit()
                            } else {
                                comparison_error()
                            }
                        }
                    }
                })
            });
        }
        self.stdlib.bool().to_type()
    }
}
