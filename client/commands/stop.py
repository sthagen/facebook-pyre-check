# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import argparse
import logging
import os
import time
from logging import Logger
from typing import List, Optional

from .. import json_rpc
from ..analysis_directory import AnalysisDirectory
from ..configuration import Configuration
from ..project_files_monitor import ProjectFilesMonitor
from .command import ClientException, Command, Result, State
from .kill import Kill


LOG: Logger = logging.getLogger(__name__)


class Stop(Command):
    NAME = "stop"

    def __init__(
        self,
        arguments,
        original_directory: str,
        configuration: Optional[Configuration] = None,
        analysis_directory: Optional[AnalysisDirectory] = None,
    ) -> None:
        super(Stop, self).__init__(
            arguments, original_directory, configuration, analysis_directory
        )

    @classmethod
    def add_subparser(cls, parser: argparse._SubParsersAction) -> None:
        stop = parser.add_parser(cls.NAME, epilog="Signals the Pyre server to stop.")
        stop.set_defaults(command=cls)

    def _flags(self) -> List[str]:
        log_directory = self._log_directory
        flags = []
        if log_directory:
            flags.extend(["-log-directory", log_directory])
        return flags

    def _run(self) -> None:
        def _kill():
            arguments = self._arguments
            arguments.with_fire = False
            Kill(
                arguments,
                self._original_directory,
                self._configuration,
                self._analysis_directory,
            ).run()

        if self._state() == State.DEAD:
            LOG.warning("No server running, cleaning up any left over Pyre processes.")
            _kill()
        else:
            try:
                with open(
                    os.path.join(self._log_directory, "server", "server.pid")
                ) as pid_file:
                    pid_to_poll = int(pid_file.read())
            except (OSError, ValueError):
                pid_to_poll = None
            try:
                stopped = False
                # If this call fails, check() will throw a ClientException.
                if self._configuration._use_json_sockets:
                    request = json_rpc.Request(method="stop", parameters={})
                    self._send_and_handle_socket_request(request, self._version_hash)
                else:
                    self._call_client(command=self.NAME).check()
                # Poll for a second to ensure that the server has a chance to exit.
                if pid_to_poll is not None:
                    stop_time = time.time() + 1.0
                    LOG.info("Polling for server's process to stop...")
                    while time.time() < stop_time:
                        # send a null signal to validate the process's existence. If the
                        # process has terminated, a ProcessLookupError will be thrown.
                        os.kill(pid_to_poll, 0)
                        time.sleep(0.1)
                stopped = True
            except ClientException:
                # An error was encountered when running `pyre stop`.
                stopped = False
            except ProcessLookupError:
                LOG.info("The server process has stopped.")
                stopped = True

            if not stopped:
                LOG.warning("Could not stop server, attempting to kill.")
                _kill()
            else:
                LOG.info("Stopped server at `%s`", self._analysis_directory.get_root())

        try:
            pid_path = ProjectFilesMonitor.pid_path(self._configuration)
            with open(pid_path) as file:
                pid = int(file.read())
                os.kill(pid, 2)  # sigint
        except (FileNotFoundError, OSError, ValueError):
            pass

    def _socket_result_handler(self, result: Result) -> None:
        pass
