# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import argparse
import errno
import json
import logging
import os
from logging import Logger
from typing import List, Optional

from .. import configuration_monitor, filesystem, project_files_monitor
from ..analysis_directory import AnalysisDirectory
from ..configuration import Configuration
from .command import ExitCode, IncrementalStyle, typeshed_search_path
from .reporting import Reporting


LOG: Logger = logging.getLogger(__name__)


def _fine_grained_incremental_override(feature_string: str) -> bool:
    try:
        return json.loads(feature_string).get("enable_fine_grained_incremental", False)
    except Exception:
        return False


class Start(Reporting):
    NAME = "start"

    def __init__(
        self,
        arguments,
        original_directory: str,
        configuration: Optional[Configuration] = None,
        analysis_directory: Optional[AnalysisDirectory] = None,
    ) -> None:
        super(Start, self).__init__(
            arguments, original_directory, configuration, analysis_directory
        )
        self._terminal: bool = arguments.terminal
        self._store_type_check_resolution: bool = arguments.store_type_check_resolution
        self._use_watchman: bool = not arguments.no_watchman

        features = self._features
        fine_grained_override = (
            _fine_grained_incremental_override(features)
            if features is not None
            else False
        )
        default_incremental_style = (
            IncrementalStyle.FINE_GRAINED
            if fine_grained_override
            else IncrementalStyle.SHALLOW
        )
        self._incremental_style: IncrementalStyle = (
            arguments.incremental_style or default_incremental_style
        )

        if self._no_saved_state:
            self._save_initial_state_to: Optional[str] = None
            self._changed_files_path: Optional[str] = None
            self._load_initial_state_from: Optional[str] = None
            self._saved_state_project: Optional[str] = None

    @classmethod
    def add_subparser(cls, parser: argparse._SubParsersAction) -> None:
        start = parser.add_parser(cls.NAME, epilog="Starts a pyre server as a daemon.")
        start.set_defaults(command=cls)
        start.add_argument(
            "--terminal", action="store_true", help="Run the server in the terminal."
        )
        start.add_argument(
            "--store-type-check-resolution",
            action="store_true",
            help="Store extra information for `types` queries.",
        )
        start.add_argument(
            "--no-watchman",
            action="store_true",
            help="Do not spawn a watchman client in the background.",
        )
        start.add_argument(
            "--incremental-style",
            type=IncrementalStyle,
            choices=list(IncrementalStyle),
            default=None,
            help="How to approach doing incremental checks.",
        )

    def _run(self) -> None:
        blocking = False
        lock = os.path.join(self._log_directory, "client.lock")
        while True:
            # Be optimistic in grabbing the lock in order to provide users with
            # a message when the lock is being waited on.
            try:
                with filesystem.acquire_lock(lock, blocking):
                    configuration_monitor.ConfigurationMonitor(
                        self._arguments,
                        self._configuration,
                        self._analysis_directory,
                        self._current_directory,
                    ).daemonize()

                    # This unsafe call is OK due to the client lock always
                    # being acquired before starting a server - no server can
                    # spawn in the interim which would cause a race.
                    try:
                        with filesystem.acquire_lock(
                            os.path.join(self._log_directory, "server", "server.lock"),
                            blocking=False,
                        ):
                            pass
                    except OSError:
                        LOG.warning(
                            "Server at `%s` exists, skipping.",
                            self._analysis_directory.get_root(),
                        )
                        self._exit_code = ExitCode.FAILURE
                        return

                    self._analysis_directory.prepare()

                    self._call_client(command=self.NAME).check()

                    if self._use_watchman:
                        try:
                            file_monitor = project_files_monitor.ProjectFilesMonitor(  # noqa
                                self._configuration,
                                self._current_directory,
                                self._analysis_directory,
                            )
                            file_monitor.daemonize()
                            LOG.info("Initialized file monitor.")
                        except project_files_monitor.MonitorException as error:
                            LOG.warning("Failed to initialize file monitor: %s", error)

                    return
            except OSError as exception:
                if exception.errno == errno.EAGAIN:
                    blocking = True
                    LOG.info("Waiting on the pyre client lock.")
                else:
                    raise exception

    def _flags(self) -> List[str]:
        flags = super()._flags()
        if self._taint_models_path:
            for path in self._taint_models_path:
                flags.extend(["-taint-models", path])
        filter_directories = self._get_directories_to_analyze()
        if len(filter_directories):
            flags.extend(["-filter-directories", ";".join(sorted(filter_directories))])
        if len(self._configuration.ignore_all_errors):
            flags.extend(
                [
                    "-ignore-all-errors",
                    ";".join(sorted(self._configuration.ignore_all_errors)),
                ]
            )
        if self._terminal:
            flags.append("-terminal")
        if self._store_type_check_resolution:
            flags.append("-store-type-check-resolution")
        save_initial_state_to = self._save_initial_state_to
        if save_initial_state_to and os.path.isdir(
            os.path.dirname(save_initial_state_to)
        ):
            flags.extend(["-save-initial-state-to", save_initial_state_to])
        saved_state_project = self._saved_state_project
        if saved_state_project:
            flags.extend(["-saved-state-project", saved_state_project])
            local_configuration_root = self._configuration.local_configuration_root
            if local_configuration_root is not None:
                relative = os.path.relpath(local_configuration_root)
                flags.extend(["-saved-state-metadata", relative.replace("/", "$")])
        configuration_file_hash = self._configuration.file_hash
        if configuration_file_hash:
            flags.extend(["-configuration-file-hash", configuration_file_hash])
        load_initial_state_from = self._load_initial_state_from
        if load_initial_state_from is not None:
            flags.extend(["-load-state-from", load_initial_state_from])
            changed_files_path = self._changed_files_path
            if changed_files_path is not None:
                flags.extend(["-changed-files-path", changed_files_path])
        elif self._changed_files_path is not None:
            LOG.error(
                "--load-initial-state-from must be set if --changed-files-path is set."
            )
        flags.extend(
            [
                "-workers",
                str(self._number_of_workers),
                "-expected-binary-version",
                self._configuration.version_hash,
            ]
        )
        search_path = self._configuration.search_path + typeshed_search_path(
            self._configuration.typeshed
        )
        if search_path:
            flags.extend(["-search-path", ",".join(search_path)])

        excludes = self._configuration.excludes
        for exclude in excludes:
            flags.extend(["-exclude", exclude])

        extensions = self._configuration.extensions
        for extension in extensions:
            flags.extend(["-extension", extension])

        if self._incremental_style == IncrementalStyle.TRANSITIVE:
            flags.append("-transitive")
        elif self._incremental_style == IncrementalStyle.FINE_GRAINED:
            flags.append("-new-incremental-check")

        if self._configuration.autocomplete:
            flags.append("-autocomplete")
        flags.extend(self._feature_flags())

        return flags
