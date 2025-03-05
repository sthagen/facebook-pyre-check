/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt;
use std::fmt::Display;
use std::hash::Hasher;

use dupe::Dupe;
use ruff_python_ast::Identifier;

use crate::module::module_info::ModuleInfo;
use crate::types::qname::QName;
use crate::types::types::Type;
use crate::util::arc_id::ArcId;

/// Used to represent ParamSpec calls. Each ParamSpec is unique, so use the ArcId to separate them.
#[derive(Clone, Dupe, Debug, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub struct ParamSpec(ArcId<ParamSpecInner>);

impl Display for ParamSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.qname.id())
    }
}

#[derive(Debug, PartialEq, Eq, Ord, PartialOrd)]
struct ParamSpecInner {
    qname: QName,
}

impl ParamSpec {
    pub fn new_identity(name: Identifier, module: ModuleInfo) -> Self {
        Self(ArcId::new(ParamSpecInner {
            qname: QName::new(name, module),
        }))
    }

    pub fn qname(&self) -> &QName {
        &self.0.qname
    }

    pub fn to_type(&self) -> Type {
        Type::ParamSpec(self.dupe())
    }

    pub fn immutable_eq(&self, other: &ParamSpec) -> bool {
        self.0.qname.immutable_eq(&other.0.qname)
    }

    pub fn immutable_hash<H: Hasher>(&self, state: &mut H) {
        self.0.qname.immutable_hash(state);
    }

    pub fn mutate(&self, x: &ParamSpec) {
        self.0.qname.mutate(&x.0.qname);
    }
}
