/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::cmp::Ordering;

use dupe::Dupe;
use ruff_python_ast::name::Name;
use starlark_map::small_map::SmallMap;

use crate::types::callable::Callable;
use crate::types::callable::Param;
use crate::types::callable::ParamList;
use crate::types::callable::Params;
use crate::types::callable::Required;
use crate::types::class::Class;
use crate::types::class::TArgs;
use crate::types::qname::QName;
use crate::types::types::Type;
use crate::util::arc_id::ArcId;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TypedDictField {
    pub ty: Type,
    pub required: bool,
    pub read_only: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct TypedDictInner(Class, TArgs, SmallMap<Name, TypedDictField>);

impl PartialOrd for TypedDictInner {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TypedDictInner {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.cmp(&other.0)
    }
}

#[derive(Debug, Clone, Dupe, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct TypedDict(ArcId<TypedDictInner>);

impl TypedDict {
    pub fn new(cls: Class, targs: TArgs, fields: SmallMap<Name, TypedDictField>) -> Self {
        Self(ArcId::new(TypedDictInner(cls, targs, fields)))
    }

    pub fn qname(&self) -> &QName {
        self.0.0.qname()
    }

    pub fn name(&self) -> &Name {
        &self.0.0.name().id
    }

    pub fn fields(&self) -> &SmallMap<Name, TypedDictField> {
        &self.0.2
    }

    pub fn class_object(&self) -> &Class {
        &self.0.0
    }

    pub fn targs(&self) -> &TArgs {
        &self.0.1
    }

    pub fn as_callable(&self) -> Callable {
        let params = self
            .fields()
            .iter()
            .map(|(name, field)| {
                Param::KwOnly(
                    name.clone(),
                    field.ty.clone(),
                    if field.required {
                        Required::Required
                    } else {
                        Required::Optional
                    },
                )
            })
            .collect();
        Callable {
            params: Params::List(ParamList::new(params)),
            ret: Type::TypedDict(self.clone()),
        }
    }
}
