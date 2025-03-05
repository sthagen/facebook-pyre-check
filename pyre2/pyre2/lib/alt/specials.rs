/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use ruff_python_ast::Expr;
use ruff_python_ast::ExprList;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;

use crate::alt::answers::AnswersSolver;
use crate::alt::answers::LookupAnswer;
use crate::binding::binding::Key;
use crate::error::collector::ErrorCollector;
use crate::error::kind::ErrorKind;
use crate::module::short_identifier::ShortIdentifier;
use crate::types::callable::Param;
use crate::types::callable::Required;
use crate::types::literal::Lit;
use crate::types::special_form::SpecialForm;
use crate::types::tuple::Tuple;
use crate::types::types::Type;
use crate::util::prelude::SliceExt;

impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    fn extra_unpack_error(&self, errors: &ErrorCollector, range: TextRange) -> Type {
        self.error(
            errors,
            range,
            ErrorKind::BadUnpacking,
            None,
            "Only one unbounded type is allowed to be unpacked".to_owned(),
        )
    }

    // Check if type args can be used to construct a valid tuple type
    // If successful, returns the constructed tuple along with whether any arguments were unpacked
    // Otherwise, records an error and return None
    fn check_args_and_construct_tuple(
        &self,
        arguments: &[Expr],
        errors: &ErrorCollector,
    ) -> Option<(Tuple, bool)> {
        let mut prefix: Vec<Type> = Vec::new();
        let mut suffix: Vec<Type> = Vec::new();
        let mut middle: Option<Type> = None;
        let mut has_unpack = false;
        for value in arguments.iter() {
            if matches!(value, Expr::EllipsisLiteral(_)) {
                if let [t] = prefix.as_slice()
                    && middle.is_none()
                    && arguments.len() == 2
                {
                    if has_unpack || t.is_unpack() {
                        self.error(
                            errors,
                            value.range(),
                            ErrorKind::InvalidArgument,
                            None,
                            "`...` cannot be used with an unpacked TypeVarTuple or tuple"
                                .to_owned(),
                        );
                        return None;
                    } else {
                        return Some((Tuple::unbounded(t.clone()), false));
                    }
                } else {
                    self.error(
                        errors,
                        value.range(),
                        ErrorKind::InvalidArgument,
                        None,
                        "Invalid position for `...`".to_owned(),
                    );
                    return None;
                }
            }
            let ty = self.expr_untype(value, errors);
            match ty {
                Type::Unpack(box Type::Tuple(Tuple::Concrete(elts))) => {
                    has_unpack = true;
                    if middle.is_none() {
                        prefix.extend(elts)
                    } else {
                        suffix.extend(elts)
                    }
                }
                Type::Unpack(box ty @ Type::Tuple(Tuple::Unbounded(_))) => {
                    has_unpack = true;
                    if middle.is_none() {
                        middle = Some(ty)
                    } else {
                        self.extra_unpack_error(errors, value.range());
                        return None;
                    }
                }
                Type::Unpack(box Type::Tuple(Tuple::Unpacked(box (pre, mid, suff)))) => {
                    has_unpack = true;
                    if middle.is_none() {
                        prefix.extend(pre);
                        middle = Some(mid);
                        suffix.extend(suff)
                    } else {
                        self.extra_unpack_error(errors, value.range());
                        return None;
                    }
                }
                Type::Unpack(box ty) if ty.is_kind_type_var_tuple() => {
                    has_unpack = true;
                    if middle.is_none() {
                        middle = Some(ty)
                    } else {
                        self.extra_unpack_error(errors, value.range());
                        return None;
                    }
                }
                Type::Unpack(box ty) => {
                    self.error(
                        errors,
                        value.range(),
                        ErrorKind::BadUnpacking,
                        None,
                        format!("Expected a tuple or TypeVarTuple, got `{}`", ty),
                    );
                    return None;
                }
                ty if ty.is_kind_type_var_tuple() => {
                    self.error(
                        errors,
                        value.range(),
                        ErrorKind::InvalidTypeVarTuple,
                        None,
                        "TypeVarTuple must be unpacked".to_owned(),
                    );
                    return None;
                }
                _ => {
                    if middle.is_none() {
                        prefix.push(ty)
                    } else {
                        suffix.push(ty)
                    }
                }
            }
        }
        if let Some(middle) = middle {
            Some((Tuple::unpacked(prefix, middle, suffix), has_unpack))
        } else {
            Some((Tuple::concrete(prefix), has_unpack))
        }
    }

    pub fn apply_special_form(
        &self,
        special_form: SpecialForm,
        arguments: &[Expr],
        range: TextRange,
        errors: &ErrorCollector,
    ) -> Type {
        match special_form {
            SpecialForm::Optional if arguments.len() == 1 => Type::type_form(Type::Union(vec![
                self.expr_untype(&arguments[0], errors),
                Type::None,
            ])),
            SpecialForm::Optional => self.error(
                errors,
                range,
                ErrorKind::BadSpecialization,
                None,
                format!(
                    "Optional requires exactly one argument but {} was found",
                    arguments.len()
                ),
            ),
            SpecialForm::Union => Type::type_form(Type::Union(
                arguments.map(|arg| self.expr_untype(arg, errors)),
            )),
            SpecialForm::Tuple => match self.check_args_and_construct_tuple(arguments, errors) {
                Some((tuple, _)) => Type::type_form(Type::Tuple(tuple)),
                None => Type::type_form(Type::Tuple(Tuple::unbounded(Type::any_error()))),
            },
            SpecialForm::Literal => {
                let mut literals = Vec::new();
                for x in arguments.iter() {
                    let lit = Lit::from_expr(
                        x,
                        &|enum_name, member_name| {
                            let ty = self.get(&Key::Usage(ShortIdentifier::new(&enum_name)));
                            let cls = match &*ty {
                                Type::ClassDef(c) => c,
                                _ => {
                                    return None;
                                }
                            };
                            self.get_enum_member(cls, member_name)
                        },
                        errors,
                    );
                    literals.push(lit);
                }
                Type::type_form(self.unions(literals))
            }
            SpecialForm::Concatenate => {
                if arguments.len() < 2 {
                    self.error(
                        errors,
                        range,
                        ErrorKind::BadSpecialization,
                        None,
                        format!(
                            "`Concatenate` must take at least two arguments, got {}",
                            arguments.len()
                        ),
                    )
                } else {
                    let args = arguments[0..arguments.len() - 1]
                        .iter()
                        .map(|x| self.expr_untype(x, errors))
                        .collect();
                    let pspec = self.expr_untype(arguments.last().unwrap(), errors);
                    Type::type_form(Type::Concatenate(args, Box::new(pspec)))
                }
            }
            SpecialForm::Callable if arguments.len() == 2 => {
                let ret = self.expr_untype(&arguments[1], errors);
                match &arguments[0] {
                    Expr::List(ExprList { elts, .. }) => {
                        match self.check_args_and_construct_tuple(elts, errors) {
                            Some((tuple, true)) => Type::type_form(Type::callable(
                                vec![Param::VarArg(Type::Unpack(Box::new(Type::Tuple(tuple))))],
                                ret,
                            )),
                            Some((Tuple::Concrete(elts), false)) => {
                                Type::type_form(Type::callable(
                                    elts.map(|t| Param::PosOnly(t.clone(), Required::Required)),
                                    ret,
                                ))
                            }
                            Some(_) => {
                                self.error(
                                    errors,
                                    range,
                                    ErrorKind::BadSpecialization,
                                    None,
                                    "Unrecognized callable type form".to_owned(),
                                );
                                Type::type_form(Type::callable_ellipsis(Type::any_error()))
                            }
                            None => Type::type_form(Type::callable_ellipsis(Type::any_error())),
                        }
                    }
                    Expr::EllipsisLiteral(_) => Type::type_form(Type::callable_ellipsis(ret)),
                    name @ Expr::Name(_) => {
                        let ty = self.expr_untype(name, errors);
                        Type::type_form(Type::callable_param_spec(ty, ret))
                    }
                    x @ Expr::Subscript(_) => {
                        let ty = self.expr_untype(x, errors);
                        match ty {
                            Type::Concatenate(args, pspec) => {
                                Type::type_form(Type::callable_concatenate(args, *pspec, ret))
                            }
                            _ => {
                                self.error(errors, x.range(),ErrorKind::BadSpecialization, None, format!("Callable types can only have `Concatenate` in this position, got `{}`", ty.deterministic_printing()),);
                                Type::type_form(Type::callable_ellipsis(Type::any_error()))
                            }
                        }
                    }
                    x => {
                        self.todo(errors, "expr_infer, Callable type", x);
                        Type::type_form(Type::callable_ellipsis(Type::any_error()))
                    }
                }
            }
            SpecialForm::Callable => {
                self.error(
                    errors,
                    range,
                    ErrorKind::BadSpecialization,
                    None,
                    format!(
                        "Callable requires exactly two arguments but {} was found",
                        arguments.len()
                    ),
                );
                Type::type_form(Type::callable_ellipsis(Type::any_error()))
            }
            SpecialForm::TypeGuard if arguments.len() == 1 => Type::type_form(Type::TypeGuard(
                Box::new(self.expr_untype(&arguments[0], errors)),
            )),
            SpecialForm::TypeGuard => self.error(
                errors,
                range,
                ErrorKind::BadSpecialization,
                None,
                format!(
                    "TypeGuard requires exactly one argument but got {}",
                    arguments.len()
                ),
            ),
            SpecialForm::TypeIs if arguments.len() == 1 => Type::type_form(Type::TypeIs(Box::new(
                self.expr_untype(&arguments[0], errors),
            ))),
            SpecialForm::TypeIs => self.error(
                errors,
                range,
                ErrorKind::BadSpecialization,
                None,
                format!(
                    "TypeIs requires exactly one argument but got {}",
                    arguments.len()
                ),
            ),
            SpecialForm::Unpack if arguments.len() == 1 => Type::type_form(Type::Unpack(Box::new(
                self.expr_untype(&arguments[0], errors),
            ))),
            SpecialForm::Unpack => self.error(
                errors,
                range,
                ErrorKind::BadSpecialization,
                None,
                format!(
                    "Unpack requires exactly one argument but got {}",
                    arguments.len()
                ),
            ),
            SpecialForm::Type if arguments.len() == 1 => {
                Type::type_form(Type::type_form(self.expr_untype(&arguments[0], errors)))
            }
            SpecialForm::Type => self.error(
                errors,
                range,
                ErrorKind::BadSpecialization,
                None,
                format!(
                    "Type requires exactly one argument but got {}",
                    arguments.len()
                ),
            ),
            SpecialForm::Annotated if arguments.len() > 1 => self.expr_infer(&arguments[0], errors),
            _ => self.todo(
                errors,
                &format!(
                    "Answers::apply_special_form cannot handle `{special_form}[{}]`",
                    arguments
                        .map(|x| self.module_info().display(x).to_string())
                        .join(", ")
                ),
                range,
            ),
        }
    }
}
