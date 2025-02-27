/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::path::Path;
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::Context as _;
use clap::Parser;
use dupe::Dupe;
use serde::Deserialize;
use tracing::info;

use crate::clap_env;
use crate::commands::common::CommonArgs;
use crate::error::error::Error;
use crate::error::legacy::LegacyErrors;
use crate::metadata::PythonVersion;
use crate::metadata::RuntimeMetadata;
use crate::module::module_path::ModulePath;
use crate::module::source_db::BuckSourceDatabase;
use crate::run::CommandExitStatus;
use crate::state::handle::Handle;
use crate::state::loader::LoaderId;
use crate::state::state::State;
use crate::util::fs_anyhow;
use crate::util::prelude::VecExt;

#[derive(Debug, Clone, Parser)]
pub struct Args {
    /// Path to input JSON file
    input_path: PathBuf,

    /// Path to output JSON file
    #[arg(long = "output", short = 'o', env = clap_env("OUTPUT_PATH"))]
    output_path: Option<PathBuf>,

    #[clap(flatten)]
    common: CommonArgs,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
struct InputFile {
    dependencies: Vec<PathBuf>,
    py_version: String,
    sources: Vec<PathBuf>,
    typeshed: Option<PathBuf>,
}

fn read_input_file(path: &Path) -> anyhow::Result<InputFile> {
    let data = fs_anyhow::read(path)?;
    let input_file: InputFile = serde_json::from_slice(&data)
        .with_context(|| format!("failed to parse input JSON `{}`", path.display()))?;
    Ok(input_file)
}

fn compute_errors(
    config: RuntimeMetadata,
    sourcedb: BuckSourceDatabase,
    common: &CommonArgs,
) -> Vec<Error> {
    let modules = sourcedb.modules_to_check();
    let loader = LoaderId::new(sourcedb);
    let modules_to_check = modules.into_map(|(name, path)| {
        Handle::new(
            name,
            ModulePath::filesystem(path),
            config.dupe(),
            loader.dupe(),
        )
    });
    let mut state = State::new(common.parallel());
    state.run_one_shot(&modules_to_check, None);
    state.collect_errors()
}

fn write_output_to_file(path: &Path, legacy_errors: &LegacyErrors) -> anyhow::Result<()> {
    let output_bytes = serde_json::to_vec(legacy_errors)
        .with_context(|| "failed to serialize JSON value to bytes")?;
    fs_anyhow::write(path, &output_bytes)
}

fn write_output_to_stdout(legacy_errors: &LegacyErrors) -> anyhow::Result<()> {
    let content = serde_json::to_string_pretty(legacy_errors)?;
    println!("{}", content);
    Ok(())
}

fn write_output(errors: &[Error], path: Option<&Path>) -> anyhow::Result<()> {
    let legacy_errors = LegacyErrors::from_errors(errors);
    if let Some(path) = path {
        write_output_to_file(path, &legacy_errors)
    } else {
        write_output_to_stdout(&legacy_errors)
    }
}

impl Args {
    pub fn run(self) -> anyhow::Result<CommandExitStatus> {
        let input_file = read_input_file(self.input_path.as_path())?;
        let python_version = PythonVersion::from_str(&input_file.py_version)?;
        let config = RuntimeMetadata::new(python_version, "linux".to_owned());
        let sourcedb = BuckSourceDatabase::from_manifest_files(
            input_file.sources.as_slice(),
            input_file.dependencies.as_slice(),
            input_file.typeshed.as_slice(),
        )?;
        let type_errors = compute_errors(config, sourcedb, &self.common);
        info!("Found {} type errors", type_errors.len());
        write_output(&type_errors, self.output_path.as_deref())?;
        Ok(CommandExitStatus::Success)
    }
}
