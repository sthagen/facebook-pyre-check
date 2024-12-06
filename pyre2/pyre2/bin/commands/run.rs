/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use clap::Parser;

use crate::util::trace::init_tracing;

/// Set this to true to run profiling of fast jobs.
/// Will run this repeatedly.
const PROFILING: bool = false;

#[derive(Debug, Parser)]
struct Standard<T: clap::Args> {
    /// Enable verbose logging.
    #[clap(long = "verbose", short = 'v')]
    verbose: bool,

    #[clap(flatten)]
    args: T,
}

impl<T: clap::Args> Standard<T> {
    fn init_tracing(&self) {
        if !PROFILING {
            init_tracing(self.verbose, false);
        }
    }
}

#[derive(Debug, Parser)]
#[command(name = "pyre2")]
#[command(about = "Next generation of Pyre type checker", long_about = None)]
enum Args {
    /// Test typing result a single file
    #[clap(name = "check", alias = "expect-test")]
    ExpectTest(Standard<crate::commands::check::Args>),

    /// Entry point for Buck integration
    BuckCheck(Standard<crate::commands::buck_check::Args>),

    /// Start an LSP server
    Lsp(Standard<crate::commands::lsp::Args>),
}

/// Run based on the command line arguments.
pub fn run() -> anyhow::Result<()> {
    if PROFILING {
        loop {
            let _ = run_once(false);
        }
    }
    run_once(true)
}

fn run_once(allow_forget: bool) -> anyhow::Result<()> {
    let args = Args::parse();
    match args {
        Args::ExpectTest(args) => {
            args.init_tracing();
            args.args.run(allow_forget)
        }
        Args::BuckCheck(args) => {
            args.init_tracing();
            args.args.run()
        }
        Args::Lsp(args) => {
            args.init_tracing();
            args.args.run()
        }
    }
}
