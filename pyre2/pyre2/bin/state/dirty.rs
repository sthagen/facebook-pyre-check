/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#[derive(Debug, Default, Clone)]
pub struct Dirty {
    dirty_load: bool,
    dirty_find: bool,
}

impl Dirty {
    pub fn set_dirty_load(&mut self) {
        self.dirty_load = true;
    }

    pub fn set_dirty_find(&mut self) {
        self.dirty_find = true;
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty_load || self.dirty_find
    }
}
