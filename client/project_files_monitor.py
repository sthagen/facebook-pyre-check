# Copyright (c) 2019-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import functools
import logging
import os
from typing import Any, BinaryIO, Dict, Iterable, List, Optional, Set  # noqa

from . import json_rpc
from .analysis_directory import AnalysisDirectory
from .configuration import Configuration
from .filesystem import find_root
from .socket_connection import SocketConnection
from .watchman_subscriber import Subscription, WatchmanSubscriber


LOG = logging.getLogger(__name__)  # type: logging.Logger


class MonitorException(Exception):
    pass


class ProjectFilesMonitor(WatchmanSubscriber):
    """
        Logs from this monitor are found in
        .pyre/<local root>/file_monitor/file_monitor.log
        One file monitor is spawned per pyre server. When a server is stopped,
        the process of pyre file monitor associated to it is killed.
    """

    NAME = "file_monitor"

    def __init__(
        self,
        configuration: Configuration,
        current_directory: str,
        analysis_directory: AnalysisDirectory,
    ) -> None:
        base_path = os.path.join(configuration.log_directory, self._name)
        super(ProjectFilesMonitor, self).__init__(base_path)
        self._configuration = configuration
        self._analysis_directory = analysis_directory

        self._extensions = set(
            ["py", "pyi"] + configuration.extensions
        )  # type: Set[str]

        self._watchman_path = self._find_watchman_path(current_directory)  # type: str

        self.socket_connection = SocketConnection(self._configuration.log_directory)
        self.socket_connection.connect()
        self.socket_connection.perform_handshake(self._configuration.version_hash)

    @property
    def _name(self) -> str:
        return self.NAME

    @property
    @functools.lru_cache(1)
    def _subscriptions(self) -> List[Subscription]:
        subscription = {
            "expression": [
                "allof",
                ["type", "f"],
                ["not", "empty"],
                ["anyof", *[["suffix", extension] for extension in self._extensions]],
            ],
            "fields": ["name"],
        }
        return [
            Subscription(
                self._watchman_path, "pyre_file_change_subscription", subscription
            )
        ]

    @staticmethod
    def pid_path(configuration: Configuration) -> str:
        return os.path.join(
            configuration.log_directory,
            ProjectFilesMonitor.NAME,
            "{}.pid".format(ProjectFilesMonitor.NAME),
        )

    @staticmethod
    def is_alive(configuration: Configuration) -> bool:
        pid_path = ProjectFilesMonitor.pid_path(configuration)
        try:
            with open(pid_path) as file:
                pid = int(file.read())
                os.kill(pid, 0)  # throws if process is not running
            return True
        except Exception:
            return False

    def _handle_response(self, response: Dict[str, Any]) -> None:
        try:
            absolute_paths = [
                os.path.join(response["root"], path) for path in response["files"]
            ]
            LOG.info("Received Watchman update for files %s.", absolute_paths)

            updated_paths = self._analysis_directory.process_updated_files(
                absolute_paths
            )

            if updated_paths.is_empty():
                LOG.info("Skipping update: Pyre doesn't track any of these files.")
                return

            LOG.info(
                "Notifying server of update to files %s and invalidation of %s.",
                updated_paths.updated_paths,
                updated_paths.deleted_paths,
            )
            message = json_rpc.Request(
                method="updateFiles",
                parameters={
                    "files": updated_paths.updated_paths,
                    "invalidated": updated_paths.deleted_paths,
                },
            )
            if not message.write(self.socket_connection.output):
                LOG.info("Failed to communicate with server. Shutting down.")
                self._alive = False  # terminate daemon
                self.socket_connection.close()

        except KeyError:
            pass

    @staticmethod
    def _find_watchman_path(directory: str) -> str:
        watchman_path = find_root(directory, ".watchmanconfig")
        if not watchman_path:
            raise MonitorException(
                "Could not find a watchman directory from "
                "the current directory `{}`".format(directory)
            )
        return watchman_path
