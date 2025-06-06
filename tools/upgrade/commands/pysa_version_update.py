# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

"""
TODO(T132414938) Add a module-level docstring
"""

import argparse
import json
import logging

from pyre_extensions import override

from ..configuration import Configuration
from ..repository import Repository
from .command import Command

LOG: logging.Logger = logging.getLogger(__name__)


class PysaVersionUpdate(Command):
    def __init__(
        self,
        *,
        repository: Repository,
        hash: str,
        no_commit: bool,
    ) -> None:
        super().__init__(repository)
        self._hash: str = hash
        self._no_commit: bool = no_commit

    @staticmethod
    def from_arguments(
        arguments: argparse.Namespace, repository: Repository
    ) -> "PysaVersionUpdate":
        return PysaVersionUpdate(
            repository=repository,
            hash=arguments.hash,
            no_commit=arguments.no_commit,
        )

    @classmethod
    def add_arguments(cls, parser: argparse.ArgumentParser) -> None:
        super(PysaVersionUpdate, PysaVersionUpdate).add_arguments(parser)
        parser.set_defaults(command=cls.from_arguments)
        parser.add_argument("hash", help="Hash of new Pysa version")
        parser.add_argument(
            "--no-commit", action="store_true", help="Keep changes in working state."
        )

    @override
    def run(self) -> None:
        global_configuration = Configuration.find_project_configuration()

        # Update to new pysa version in `.pyre_configuration`
        configuration = Configuration(global_configuration)
        old_version = configuration.pysa_version
        if not old_version:
            LOG.error(
                "Global configuration at %s has no pysa_version field.",
                global_configuration,
            )
            return
        configuration.set_pysa_version(self._hash)
        configuration.write()

        # Update to new pysa version in `.pysa_configuration`
        path = Configuration.find_parent_file(".pysa_configuration")
        if path:
            # TODO(T224086333): move `.pysa_configuration`'s `pysa_version` to less nested `version` field
            contents = json.loads(path.read_text(encoding="utf-8"))
            contents["pyre_configuration"]["pysa_version"] = self._hash
            path.write_text(json.dumps(contents, indent=2), encoding="utf-8")
