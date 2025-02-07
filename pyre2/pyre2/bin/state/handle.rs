/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use dupe::Dupe;

use crate::config::Config;
use crate::module::module_name::ModuleName;
use crate::state::loader::LoaderId;

#[derive(Debug, Clone, Dupe, PartialEq, Eq, Hash)]
pub struct Handle {
    module: ModuleName,
    config: Config,
    loader: LoaderId,
}

impl Handle {
    pub fn new(module: ModuleName, config: Config, loader: LoaderId) -> Self {
        Self {
            module,
            config,
            loader,
        }
    }

    pub fn module(&self) -> ModuleName {
        self.module
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn loader(&self) -> &LoaderId {
        &self.loader
    }
}
