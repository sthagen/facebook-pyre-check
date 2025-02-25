/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Display;

use dupe::Dupe;
use ruff_python_ast::Identifier;

use crate::module::module_info::ModuleInfo;
use crate::types::qname::QName;
use crate::types::types::Type;
use crate::util::arc_id::ArcId;

/// Used to represent TypeVar calls. Each TypeVar is unique, so use the ArcId to separate them.
#[derive(Clone, Dupe, Debug, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub struct TypeVar(ArcId<TypeVarInner>);

impl Display for TypeVar {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.qname.id())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum Restriction {
    Constraints(Vec<Type>),
    Bound(Type),
    Unrestricted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum Variance {
    Covariant,
    Contravariant,
    Invariant,
}

#[derive(Debug, Clone, PartialEq, Eq, Ord, PartialOrd)]
struct TypeVarInner {
    qname: QName,
    restriction: Restriction,
    default: Option<Type>,
    /// The variance if known, or None for infer_variance=True
    variance: Option<Variance>,
}

impl TypeVar {
    pub fn new(
        name: Identifier,
        module: ModuleInfo,
        restriction: Restriction,
        default: Option<Type>,
        variance: Option<Variance>,
    ) -> Self {
        Self(ArcId::new(TypeVarInner {
            qname: QName::new(name, module),
            restriction,
            default,
            variance,
        }))
    }

    pub fn qname(&self) -> &QName {
        &self.0.qname
    }

    pub fn restriction(&self) -> &Restriction {
        &self.0.restriction
    }

    pub fn default(&self) -> Option<&Type> {
        self.0.default.as_ref()
    }

    pub fn variance(&self) -> Option<Variance> {
        self.0.variance
    }

    pub fn to_type(&self) -> Type {
        Type::TypeVar(self.dupe())
    }
}
