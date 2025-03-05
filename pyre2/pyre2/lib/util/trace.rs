/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

//! Utilities for working with the `tracing` crate.

use std::io::stderr;
use std::io::stdout;
use std::io::IsTerminal;
use std::sync::Once;

use tracing_subscriber::filter::EnvFilter;
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

/// If we create tracing twice, the library panics. Avoid that.
/// Mostly happens when we run tests.
static INIT_TRACING_ONCE: Once = Once::new();

/// Set up tracing so it prints to stderr, and can be used for output.
/// Most things should use `info` and `debug` level for showing messages.
pub fn init_tracing(verbose: bool, force_ansi: bool) {
    INIT_TRACING_ONCE.call_once(|| {
        let env = "PYRE_LOG";
        let mut env_filter = EnvFilter::from_env(env);
        if std::env::var_os(env).is_none() {
            // Enable info log by default
            env_filter = env_filter.add_directive(if verbose {
                LevelFilter::DEBUG.into()
            } else {
                LevelFilter::INFO.into()
            });
        }

        let layer = tracing_subscriber::fmt::layer()
            .with_line_number(false)
            .with_file(false)
            .without_time()
            .with_writer(stderr)
            .with_ansi(force_ansi || stdout().is_terminal())
            .with_target(false)
            .with_test_writer()
            .with_filter(env_filter);

        tracing_subscriber::registry().with(layer).init();
    })
}
