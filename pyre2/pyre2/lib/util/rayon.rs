/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

//! Utilities for creating the initial thread pool.

use std::sync::LazyLock;

use rayon::ThreadPool;
use tracing::debug;

use crate::util::lock::Mutex;

static THREADS: LazyLock<Mutex<Option<usize>>> = LazyLock::new(|| Mutex::new(None));

/// Set up the global thread pool.
pub fn init_rayon(threads: Option<usize>) {
    *THREADS.lock() = threads;
}

pub fn thread_pool() -> ThreadPool {
    let mut builder = rayon::ThreadPoolBuilder::new().stack_size(4 * 1024 * 1024);
    if let Some(threads) = *THREADS.lock() {
        builder = builder.num_threads(threads);
    }
    let pool = builder.build().expect("To be able to build a thread pool");
    // Only print the message once
    debug!("Running with {} threads", pool.current_num_threads());
    pool
}
