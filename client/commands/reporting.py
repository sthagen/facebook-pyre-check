# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import argparse
import fnmatch
import json
import logging
import os
from typing import Any, Dict, List, Optional, Sequence, Set

from .. import log
from ..analysis_directory import AnalysisDirectory
from ..configuration import Configuration
from ..error import Error
from ..filesystem import translate_path
from .command import TEXT, ClientException, Command, Result


LOG: logging.Logger = logging.getLogger(__name__)


class Reporting(Command):
    NAME = "reporting"

    def __init__(
        self,
        arguments: argparse.Namespace,
        original_directory: str,
        configuration: Optional[Configuration] = None,
        analysis_directory: Optional[AnalysisDirectory] = None,
    ) -> None:
        super().__init__(
            arguments, original_directory, configuration, analysis_directory
        )

    def _print(self, errors: Sequence[Error]) -> None:
        if errors:
            length = len(errors)
            LOG.error("Found %d type error%s!", length, "s" if length > 1 else "")
        else:
            LOG.log(log.SUCCESS, "No type errors found")

        if self._output == TEXT:
            log.stdout.write("\n".join([repr(error) for error in errors]))
        else:
            log.stdout.write(json.dumps([error.__dict__ for error in errors]))

    def _get_directories_to_analyze(self) -> Set[str]:
        current_project_directories = self._analysis_directory.get_filter_root()
        # The server may not exist in the same directory, so use absolute paths.
        directories_to_analyze = {
            translate_path(os.getcwd(), filter_root)
            for filter_root in current_project_directories
        }
        return directories_to_analyze

    def _get_errors(
        self, result: Result, bypass_filtering: bool = False
    ) -> Sequence[Error]:
        result.check()

        errors: List[Error] = []
        results: List[Dict[str, Any]] = []
        try:
            results = json.loads(result.output)
            if "errors" in results:
                results = results["errors"]
        except (json.JSONDecodeError, ValueError):
            raise ClientException("Invalid output: `{}`.".format(result.output))

        for error in results:
            full_path = os.path.realpath(
                os.path.join(self._analysis_directory.get_root(), error["path"])
            )
            # Relativize path to user's cwd.
            relative_path = self._relative_path(full_path)
            error["path"] = relative_path
            ignore_error = False
            external_to_global_root = True
            if full_path.startswith(self._current_directory):
                external_to_global_root = False
            if not os.path.exists(full_path):
                # Nonexistent paths can be created when search path stubs are renamed.
                external_to_global_root = True
            for absolute_ignore_path in self._ignore_all_errors_paths:
                if fnmatch.fnmatch(full_path, (absolute_ignore_path + "*")):
                    ignore_error = True
                    break
            errors.append(Error(ignore_error, external_to_global_root, **error))

        if bypass_filtering:
            return errors
        else:
            filtered_errors = [
                error
                for error in errors
                if (
                    not error.is_ignored()
                    and (self._verbose or not (error.is_external_to_global_root()))
                )
            ]
            sorted_errors = sorted(
                filtered_errors,
                key=lambda error: (error.path, error.line, error.column),
            )

            return sorted_errors
