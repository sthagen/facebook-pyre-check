# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import argparse
from typing import Optional

from ..analysis_directory import AnalysisDirectory, resolve_analysis_directory
from ..configuration import Configuration
from .command import Command, IncrementalStyle
from .incremental import Incremental
from .start import Start
from .stop import Stop


class Restart(Command):
    NAME = "restart"

    def __init__(
        self,
        arguments,
        original_directory: str,
        configuration: Optional[Configuration] = None,
        analysis_directory: Optional[AnalysisDirectory] = None,
    ) -> None:
        super(Restart, self).__init__(
            arguments, original_directory, configuration, analysis_directory
        )
        self._terminal: bool = arguments.terminal
        self._store_type_check_resolution: bool = arguments.store_type_check_resolution
        self._use_watchman: bool = not arguments.no_watchman
        self._incremental_style: IncrementalStyle = arguments.incremental_style

    @classmethod
    def add_subparser(cls, parser: argparse._SubParsersAction) -> None:
        restart = parser.add_parser(
            cls.NAME,
            epilog="Restarts a server. Equivalent to `pyre stop && pyre start`.",
        )
        restart.set_defaults(command=cls)
        restart.add_argument(
            "--terminal", action="store_true", help="Run the server in the terminal."
        )
        restart.add_argument(
            "--store-type-check-resolution",
            action="store_true",
            help="Store extra information for `types` queries.",
        )
        restart.add_argument(
            "--no-watchman",
            action="store_true",
            help="Do not spawn a watchman client in the background.",
        )
        restart.add_argument(
            "--incremental-style",
            type=IncrementalStyle,
            choices=list(IncrementalStyle),
            default=None,
            help="How to approach doing incremental checks.",
        )

    def generate_analysis_directory(self) -> AnalysisDirectory:
        return resolve_analysis_directory(
            self._arguments,
            self._configuration,
            self._original_directory,
            self._current_directory,
            build=True,
        )

    def _run(self) -> None:
        Stop(
            self._arguments,
            self._original_directory,
            self._configuration,
            self._analysis_directory,
        ).run()
        # Force the incremental run to be blocking.
        # pyre-fixme[16]: `Namespace` has no attribute `nonblocking`.
        self._arguments.nonblocking = False
        # pyre-fixme[16]: `Namespace` has no attribute `no_start`.
        self._arguments.no_start = False
        Incremental(
            self._arguments,
            self._original_directory,
            self._configuration,
            self._analysis_directory,
        ).run()
