/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::ffi::OsStr;
use std::ffi::OsString;
use std::path;
use std::path::Component;
use std::path::Path;
use std::path::PathBuf;

use anyhow::Context;
use serde::Deserialize;
use starlark_map::small_set::SmallSet;

use crate::util::fs_anyhow;
use crate::util::listing::FileList;
use crate::util::prelude::SliceExt;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
pub struct Globs(Vec<String>);

impl Globs {
    pub fn new(patterns: Vec<String>) -> Self {
        //! Create a new `Globs` from the given patterns. If you want them to be relative
        //! to a root, please use `Globs::new_with_root()` instead.
        Self(patterns)
    }

    pub fn new_with_root(root: &Path, patterns: Vec<String>) -> Self {
        //! Create a new `Globs`, rewriting all patterns to be relative to `root`.
        if root == Path::new("") || root == Path::new(".") {
            return Self(patterns);
        }
        Self(
            patterns
                .into_iter()
                .map(|pattern| Self::pattern_relative_to_root(root, pattern))
                .collect(),
        )
    }

    fn pattern_relative_to_root(root: &Path, pattern: String) -> String {
        let pattern_root = Self::get_root_for_pattern(&pattern);
        if pattern_root.is_absolute() {
            return pattern;
        }

        let mut root_str = root.display().to_string();
        if !root_str.ends_with(path::MAIN_SEPARATOR_STR) {
            root_str += path::MAIN_SEPARATOR_STR;
        }
        format!("{root_str}{pattern}")
    }

    fn contains_asterisk(part: &OsStr) -> bool {
        let asterisk = OsString::from("*");
        let asterisk = asterisk.as_encoded_bytes();
        let bytes = part.as_encoded_bytes();

        if bytes == asterisk {
            return true;
        } else if asterisk.len() > bytes.len() {
            return false;
        }

        for i in 0..=bytes.len() - asterisk.len() {
            if *asterisk == bytes[i..i + asterisk.len()] {
                return true;
            }
        }
        false
    }

    fn get_root_for_pattern(pattern: &str) -> PathBuf {
        let mut path = PathBuf::new();

        // we need to add any path prefix and root items (there should be at most one of each,
        // and prefix only exists on windows) to the root we're building
        let parsed_path = PathBuf::from(pattern);
        parsed_path
            .components()
            .take_while(|comp| {
                match comp {
                    // this should be alright to do, since a prefix will always come before a root,
                    // which will always come before the rest of the path
                    Component::Prefix(_)
                    | Component::RootDir
                    | Component::CurDir
                    | Component::ParentDir => true,
                    Component::Normal(part) => !Self::contains_asterisk(part),
                }
            })
            .for_each(|comp| path.push(comp));
        if path.extension().is_some() {
            path.pop();
        }
        path
    }

    fn is_python_extension(ext: Option<&OsStr>) -> bool {
        ext.is_some_and(|e| e == "py" || e == "pyi")
    }

    fn resolve_dir(path: &Path, results: &mut Vec<PathBuf>) -> anyhow::Result<()> {
        for entry in fs_anyhow::read_dir(path)? {
            let entry = entry
                .with_context(|| format!("When iterating over directory `{}`", path.display()))?;
            let path = entry.path();
            if path.is_dir() {
                Self::resolve_dir(&path, results)?;
            } else if Self::is_python_extension(path.extension()) {
                results.push(path);
            }
        }
        Ok(())
    }

    fn resolve_pattern(pattern: &str) -> anyhow::Result<Vec<PathBuf>> {
        let mut result = Vec::new();
        let paths = glob::glob(pattern)?;
        for path in paths {
            let path = path?;
            if path.is_dir() {
                Self::resolve_dir(&path, &mut result)?;
            } else if Self::is_python_extension(path.extension()) {
                result.push(path);
            }
        }
        Ok(result)
    }
}

impl FileList for Globs {
    /// Given a glob pattern, return the directories that can contain files that match the pattern.
    fn roots(&self) -> Vec<PathBuf> {
        self.0.map(|s| Self::get_root_for_pattern(s))
    }

    fn files(&self) -> anyhow::Result<Vec<PathBuf>> {
        let mut result = SmallSet::new();
        for pattern in &self.0 {
            let res = Self::resolve_pattern(pattern)
                .with_context(|| format!("When resolving pattern `{pattern}`"))?;
            if res.is_empty() {
                return Err(anyhow::anyhow!("No files matched pattern `{}`", pattern));
            }
            result.extend(res);
        }
        Ok(result.into_iter().collect())
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn test_roots() {
        fn f(pattern: &str, root: &str) {
            let globs = Globs::new(vec![pattern.to_owned()]);
            assert_eq!(
                globs.roots(),
                vec![PathBuf::from(root)],
                "Glob parsing failed for pattern {}",
                pattern
            );
        }

        f("project/**/files", "project");
        f("**/files", "");
        f("pattern", "pattern");
        f("pattern.txt", "");
        f("a/b", "a/b");
        f("a/b/c.txt", "a/b");
        f("a/b*/c", "a");
        f("a/b/*.txt", "a/b");
        f("/**", "/");
        f("/absolute/path/**/files", "/absolute/path");

        if cfg!(windows) {
            // These all use the \ separator, which only works on Windows.
            f(r"C:\\windows\project\**\files", r"C:\\windows\project");
            f(
                r"c:\windows\project\**\files",
                r"c:\windows\project\**files",
            );
            f(r"\windows\project\**\files", r"\windows\project");
            f(r"c:project\**\files", "c:project");
            f(r"project\**\files", "project");
            f(r"**\files", "");
            f("pattern", "pattern");
            f("pattern.txt", "");
            f(r"a\b", r"a\b");
            f(r"a\b\c.txt", r"a\b");
            f(r"a\b*\c", "a");
            f(r"a\b\*.txt", r"a\b");
        }
    }

    #[test]
    fn test_contains_asterisk() {
        assert!(!Globs::contains_asterisk(&OsString::from("")));
        assert!(Globs::contains_asterisk(&OsString::from("*")));
        assert!(Globs::contains_asterisk(&OsString::from("*a")));
        assert!(Globs::contains_asterisk(&OsString::from("a*")));
        assert!(!Globs::contains_asterisk(&OsString::from("abcd")));
        assert!(Globs::contains_asterisk(&OsString::from("**")));
        assert!(Globs::contains_asterisk(&OsString::from("asdf*fdsa")));
    }

    #[test]
    fn test_globs_relative_to_root() {
        let inputs: Vec<String> = [
            "project/**/files",
            "**/files",
            "pattern",
            "pattern.txt",
            "a/b",
            "a/b/c.txt",
            "a/b*/c",
            "a/b/*.txt",
            "/**",
            "/absolute/path/**/files",
        ]
        .into_iter()
        .map(String::from)
        .collect();

        let f = |root: PathBuf, expected: [&str; 10]| {
            let expected: Vec<String> = expected.into_iter().map(String::from).collect();
            let globs = Globs::new_with_root(root.as_path(), inputs.clone());
            assert_eq!(globs.0, expected);
        };

        f(
            PathBuf::from(""),
            [
                "project/**/files",
                "**/files",
                "pattern",
                "pattern.txt",
                "a/b",
                "a/b/c.txt",
                "a/b*/c",
                "a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
        f(
            PathBuf::from("."),
            [
                "project/**/files",
                "**/files",
                "pattern",
                "pattern.txt",
                "a/b",
                "a/b/c.txt",
                "a/b*/c",
                "a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
        f(
            PathBuf::from(".."),
            [
                "../project/**/files",
                "../**/files",
                "../pattern",
                "../pattern.txt",
                "../a/b",
                "../a/b/c.txt",
                "../a/b*/c",
                "../a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
        f(
            PathBuf::from("no/trailing/slash"),
            [
                "no/trailing/slash/project/**/files",
                "no/trailing/slash/**/files",
                "no/trailing/slash/pattern",
                "no/trailing/slash/pattern.txt",
                "no/trailing/slash/a/b",
                "no/trailing/slash/a/b/c.txt",
                "no/trailing/slash/a/b*/c",
                "no/trailing/slash/a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
        f(
            PathBuf::from("relative/path/to/"),
            [
                "relative/path/to/project/**/files",
                "relative/path/to/**/files",
                "relative/path/to/pattern",
                "relative/path/to/pattern.txt",
                "relative/path/to/a/b",
                "relative/path/to/a/b/c.txt",
                "relative/path/to/a/b*/c",
                "relative/path/to/a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
        f(
            PathBuf::from("/absolute/path/to"),
            [
                "/absolute/path/to/project/**/files",
                "/absolute/path/to/**/files",
                "/absolute/path/to/pattern",
                "/absolute/path/to/pattern.txt",
                "/absolute/path/to/a/b",
                "/absolute/path/to/a/b/c.txt",
                "/absolute/path/to/a/b*/c",
                "/absolute/path/to/a/b/*.txt",
                "/**",
                "/absolute/path/**/files",
            ],
        );
    }

    #[test]
    fn test_is_python_extension() {
        assert!(!Globs::is_python_extension(None));
        assert!(!Globs::is_python_extension(Some(OsStr::new(
            "hello world!"
        ))));
        assert!(Globs::is_python_extension(Some(OsStr::new("py"))));
        assert!(Globs::is_python_extension(Some(OsStr::new("pyi"))));
    }
}
