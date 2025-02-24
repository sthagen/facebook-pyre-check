/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::cmp::Ordering;

use dupe::Dupe;
use ruff_python_ast::name::Name;
use starlark_map::ordered_map::OrderedMap;

use crate::types::callable::Required;
use crate::types::class::Class;
use crate::types::class::ClassType;
use crate::types::class::Substitution;
use crate::types::class::TArgs;
use crate::types::qname::QName;
use crate::types::types::Type;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TypedDictField {
    pub ty: Type,
    pub required: bool,
    pub read_only: bool,
}

impl TypedDictField {
    pub fn substitute(self, substitution: &Substitution) -> Self {
        Self {
            ty: substitution.substitute(self.ty),
            required: self.required,
            read_only: self.read_only,
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct TypedDict(Class, TArgs, OrderedMap<Name, TypedDictField>);

impl PartialOrd for TypedDict {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TypedDict {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.cmp(&other.0)
    }
}

impl TypedDict {
    pub fn new(cls: Class, targs: TArgs, fields: OrderedMap<Name, TypedDictField>) -> Self {
        Self(cls, targs, fields)
    }

    pub fn qname(&self) -> &QName {
        self.0.qname()
    }

    pub fn name(&self) -> &Name {
        self.0.name()
    }

    pub fn fields(&self) -> &OrderedMap<Name, TypedDictField> {
        &self.2
    }

    pub fn class_object(&self) -> &Class {
        &self.0
    }

    pub fn targs(&self) -> &TArgs {
        &self.1
    }

    pub fn as_class_type(&self) -> ClassType {
        // TypedDict instances behave very differently from instances of other classes, so we don't
        // represent TypedDicts as ClassType in normal typechecking logic. However, the two do
        // share a bit of behavior, so we occasionally convert a TypedDict to a ClassType in order
        // to reuse code.
        ClassType::new(self.0.dupe(), self.1.clone())
    }

    pub fn visit<'a>(&'a self, mut f: impl FnMut(&'a Type)) {
        self.1.visit(&mut f);
        self.2.iter().for_each(|(_, x)| f(&x.ty));
    }

    pub fn visit_mut<'a>(&'a mut self, mut f: impl FnMut(&'a mut Type)) {
        self.1.visit_mut(&mut f);
        self.2.iter_mut().for_each(|(_, x)| f(&mut x.ty));
    }

    pub fn kw_param_info(&self) -> Vec<(Name, Type, Required)> {
        self.fields()
            .iter()
            .map(|(name, field)| {
                (
                    name.clone(),
                    field.ty.clone(),
                    if field.required {
                        Required::Required
                    } else {
                        Required::Optional
                    },
                )
            })
            .collect()
    }
}
