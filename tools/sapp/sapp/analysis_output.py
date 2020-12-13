# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

import json
import os
from glob import glob
from pathlib import Path
from typing import IO, Any, Dict, Iterable, List, NamedTuple, Optional

from .sharded_files import ShardedFile


METADATA_GLOB = "*metadata.json"


# pyre-fixme[2]: Parameter annotation cannot contain `Any`.
class Metadata(NamedTuple):
    analysis_root: str
    repo_root: Optional[str] = None
    repository_name: Optional[str] = None
    tool: Optional[str] = None
    analysis_tool_version: Optional[str] = None
    commit_hash: Optional[str] = None
    job_instance: Optional[int] = None
    project: Optional[str] = None
    # Mapping from code to rule metadata.
    # pyre-ignore: we don't have a shape for rules yet.
    rules: Dict[int, Any] = {}

    @property
    def root(self) -> str:
        return self.repo_root or self.analysis_root


class AnalysisOutputError(Exception):
    pass


class AnalysisOutput(object):
    """Represents one of various ways the analysis output can be specified.

    Use "filename_specs" to represent a list of any:
      A file name, a file handle, or a sharded file pattern

    Use "filename_glob" to specify a set of filename patterns instead. This
    assumes the output lives in the given directory. Avoid patterns like '*'
    which will include the metadata.json file in the directory.

    Note that "filename_specs" has precedence over "filename_glob".

    Access to the output is provided via generators that provide file handles
    to the diagnostics json (issues), or the summary json (pre and post).
    """

    def __init__(
        self,
        *,
        directory: Optional[str] = None,
        filename_specs: Optional[List[str]] = None,
        filename_glob: Optional[str] = None,
        file_handle: Optional[IO[str]] = None,
        metadata: Optional[Metadata] = None,
        tool: Optional[str] = None,
    ) -> None:
        self.directory = directory
        self.filename_specs: List[str] = filename_specs or []
        self.filename_glob = filename_glob
        self.file_handle = file_handle
        self.metadata = metadata
        self.tool = tool

        if filename_specs is [] and file_handle and hasattr(file_handle, "name"):
            self.filename_specs = [file_handle.name]

    def __str__(self) -> str:
        if self.directory:
            return f"AnalysisOutput({repr(self.directory)})"

        return f"AnalysisOutput({repr(self.filename_specs)})"

    @classmethod
    def from_str(cls, identifier: str) -> "AnalysisOutput":
        if os.path.isdir(identifier):
            return cls.from_directory(identifier)
        elif os.path.isfile(identifier):
            return cls.from_file(identifier)
        elif os.path.isdir(os.path.dirname(identifier)) and "@" in os.path.basename(
            identifier
        ):
            return cls.from_file(identifier)
        else:
            raise AnalysisOutputError(f"Unrecognized identifier `{identifier}`")

    @classmethod
    def from_directory(cls, directory: str) -> "AnalysisOutput":
        metadata = {}
        for file in glob(os.path.join(directory, METADATA_GLOB)):
            with open(file) as f:
                metadata.update(json.load(f))

        # Note: filename_specs takes precedence over filename_glob.
        filename_specs = []
        filename_glob = None
        if "filename_specs" in metadata:
            filename_specs = [
                os.path.join(directory, os.path.basename(spec))
                for spec in metadata["filename_specs"]
            ]
        elif "filename_spec" in metadata:
            filename_specs = [
                os.path.join(directory, os.path.basename(metadata["filename_spec"]))
            ]
        elif "filename_glob" in metadata:
            filename_glob = metadata["filename_glob"]
            if not filename_glob:
                raise AnalysisOutputError(
                    f"Empty 'filename_glob' not allowed. In {METADATA_GLOB}, "
                    "Use either 'filename_spec' or specify something in "
                    "'filename_glob'."
                )
        else:
            # Legacy
            filename_specs = [
                os.path.join(directory, os.path.basename(metadata["filenames"][0]))
            ]

        repo_root = metadata.get("repo_root")
        analysis_root = metadata["root"]

        rules = {rule["code"]: rule for rule in metadata.get("rules", [])}

        return cls(
            directory=directory,
            filename_specs=filename_specs,
            filename_glob=filename_glob,
            metadata=Metadata(
                analysis_tool_version=metadata["version"],
                commit_hash=metadata.get("commit"),
                analysis_root=analysis_root,
                repo_root=repo_root,
                job_instance=metadata.get("job_instance"),
                tool=metadata.get("tool"),
                repository_name=metadata.get("repository_name"),
                project=metadata.get("project"),
                rules=rules,
            ),
        )

    @classmethod
    def from_file(cls, file_name: str) -> "AnalysisOutput":
        # """Pass in either a single file name or a sharded file pattern.
        # Performs early validation by 1) opening the file if it is a single file,
        # or 2) computing and checking the file shards.
        # """
        return cls(filename_specs=[file_name])

    @classmethod
    def from_handle(cls, file_handle: IO[str]) -> "AnalysisOutput":
        return cls(file_handle=file_handle)

    def file_handles(self) -> Iterable[IO[str]]:
        """Generates all file handles represented by the analysis.
        Callee owns file handle and closes it when the next is yielded or the
        generator ends.
        """
        if self.file_handle:
            # pyre-fixme[7]: Expected `Iterable[IO[str]]` but got
            #  `Generator[Optional[IO[str]], None, None]`.
            yield self.file_handle
            # pyre-fixme[16]: `Optional` has no attribute `close`.
            self.file_handle.close()
            self.file_handle = None
        else:
            for name in self.file_names():
                with open(name, "r") as f:
                    yield f

    def file_names(self) -> Iterable[str]:
        """Generates all file names that are used to generate file_handles."""
        filename_specs = self.filename_specs
        filename_glob = self.filename_glob
        for spec in filename_specs:
            if self._is_sharded(spec):
                yield from ShardedFile(spec).get_filenames()
            else:
                yield spec

        if filename_glob is not None:
            directory = self.directory
            assert directory is not None
            # str() cast to convert the returned Path to string for a
            # consistent return type.
            for path in Path(directory).glob(filename_glob):
                yield str(path)

    @classmethod
    def _is_sharded(cls, spec: str) -> bool:
        return "@" in spec

    def has_sharded(self) -> bool:
        return any(self._is_sharded(spec) for spec in self.filename_specs)
