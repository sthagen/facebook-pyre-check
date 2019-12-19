# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import json
import logging
import multiprocessing
import os
import platform
import subprocess
import sys
import time
import traceback
from argparse import Namespace
from pathlib import Path
from typing import Any, Dict, Optional, Set, TextIO

from . import buck
from .exceptions import EnvironmentException
from .filesystem import find_root, translate_paths  # noqa


CONFIGURATION_FILE: str = ".pyre_configuration"
BINARY_NAME: str = "pyre.bin"
CLIENT_NAME: str = "pyre-client"
LOG_DIRECTORY: str = ".pyre"


LOG = logging.getLogger(__name__)  # type: logging.Logger


def assert_readable_directory(directory: str) -> None:
    if not os.path.isdir(directory):
        raise EnvironmentException("{} is not a valid directory.".format(directory))
    if not os.access(directory, os.R_OK):
        raise EnvironmentException("{} is not a readable directory.".format(directory))


def assert_writable_directory(directory: str) -> None:
    if not os.path.isdir(directory):
        raise EnvironmentException("{} is not a valid directory.".format(directory))
    if not os.access(directory, os.W_OK):
        raise EnvironmentException("{} is not a writable directory.".format(directory))


def readable_directory(directory: str) -> str:
    assert_readable_directory(directory)
    return directory


def is_capable_terminal(file: TextIO = sys.stderr) -> bool:
    """
    Determine whether we are connected to a capable terminal.
    """
    if not os.isatty(file.fileno()):
        return False
    terminal = os.getenv("TERM", "dumb")
    # Hardcoded list of non-capable terminals.
    return terminal not in ["dumb", "emacs"]


def get_binary_version(configuration) -> str:
    override = os.getenv("PYRE_BINARY")
    if override:
        return "override: {}".format(override)

    configured = configuration.version_hash
    if configured:
        return configured

    return "No version set"


def get_binary_version_from_file(local_path: Optional[str]) -> str:
    override = os.getenv("PYRE_BINARY")
    if override:
        return "override: {}".format(override)

    def read_version(configuration_path: str) -> Optional[str]:
        with open(configuration_path) as file:
            configuration_contents = file.read()
            return json.loads(configuration_contents).pop("version", None)

    version = None  # type: Optional[str]
    try:
        # Get local configuration version
        if local_path:
            local_configuration = os.path.join(
                local_path, CONFIGURATION_FILE + ".local"
            )
            version = read_version(local_configuration)

        # Get configuration version
        if not version:
            version = read_version(CONFIGURATION_FILE)
    except Exception:
        pass
    # pyre-fixme[7]: Expected `str` but got `Optional[str]`.
    return "No version set" if not version else version


def find_project_root(original_directory: str) -> str:
    """Pyre always runs from the directory containing the nearest .pyre_configuration,
    if one exists."""
    global_root = find_root(original_directory, CONFIGURATION_FILE)
    return global_root or original_directory


def find_local_root(original_directory: str) -> Optional[str]:
    global_root = find_root(original_directory, CONFIGURATION_FILE)
    local_root = find_root(original_directory, CONFIGURATION_FILE + ".local")
    # Check for illegal nested local configuration.
    if local_root:
        parent_local_root = find_root(
            os.path.dirname(local_root), CONFIGURATION_FILE + ".local"
        )
        if parent_local_root:
            raise EnvironmentException(
                "Local configuration is nested under another local configuration at "
                "`{}`. Please combine the sources into a single configuration or split "
                "the parent configuration to avoid inconsistent errors.".format(
                    parent_local_root
                )
            )

    # If the global configuration root is deeper than local configuration, ignore local.
    if global_root and local_root and global_root.startswith(local_root):
        local_root = None
    if local_root:
        return local_root


def find_log_directory(
    log_directory: Optional[str],
    current_directory: str,
    local_configuration: Optional[str],
) -> str:
    """Pyre outputs all logs to a .pyre directory that lives in the project root."""
    if not log_directory:
        log_directory = os.path.join(current_directory, LOG_DIRECTORY)
        if local_configuration:
            # `log_directory` will never escape `.pyre/` because in `switch_root` we have
            # guaranteed that configurations are never deeper than local configurations
            relative = os.path.relpath(local_configuration, current_directory)
            log_directory = os.path.join(log_directory, relative)
    Path(log_directory).mkdir(parents=True, exist_ok=True)
    return log_directory


def _resolve_filter_paths(
    arguments: Namespace, configuration, original_directory: str
) -> Set[str]:
    filter_paths = []
    if arguments.source_directories or arguments.targets:
        if arguments.source_directories:
            filter_paths += arguments.source_directories
        if arguments.targets:
            filter_paths += [
                buck.presumed_target_root(target) for target in arguments.targets
            ]
    else:
        local_configuration_root = configuration.local_configuration_root
        if local_configuration_root:
            filter_paths = [local_configuration_root]
    return translate_paths(filter_paths, original_directory)


def number_of_workers() -> int:
    try:
        return max(multiprocessing.cpu_count() - 4, 1)
    except NotImplementedError:
        return 4


def log_statistics(
    category: str,
    arguments: Optional[Namespace] = None,
    # this is typed as a Any because configuration imports __init__
    configuration: Optional[Any] = None,
    integers: Optional[Dict[str, int]] = None,
    normals: Optional[Dict[str, str]] = None,
    logger: Optional[str] = None,
) -> None:
    integers = integers or {}
    if "time" not in integers:
        integers["time"] = int(time.time())
    normals = normals or {}
    if configuration:
        normals = {
            **normals,
            "version": configuration.version_hash,
        }  # type: Dict[str, str]
        if not logger:
            logger = configuration.logger
    if not logger:
        raise ValueError("Logger must either be given or in configuration")
    if arguments:
        normals = {**normals, "arguments": str(arguments)}
    try:
        statistics = {
            "int": integers,
            "normal": {
                **normals,
                "command_line": " ".join(sys.argv),
                "host": platform.node() or "",
                "platform": platform.system() or "",
                "user": os.getenv("USER", ""),
            },
        }
        statistics = json.dumps(statistics).encode("ascii", "strict")
        subprocess.run([logger, category], input=statistics)
    except Exception:
        LOG.warning("Unable to log using `%s`", logger)
        LOG.info(traceback.format_exc())


def _find_directory_upwards(base: str, target: str) -> Optional[str]:
    """
    Walk directories upwards from base, until the root directory is
    reached. At each step, check if the target directory exist, and return
    it if found. Return None if the search is unsuccessful.
    """
    while True:
        step = os.path.join(base, target)
        LOG.debug("Trying with: `%s`", step)
        if os.path.isdir(step):
            return step
        parent_directory = os.path.dirname(base)
        if parent_directory == base:
            # We have reached the root.
            break
        base = parent_directory
    return None


def find_typeshed() -> Optional[str]:
    override = os.getenv("PYRE_TYPESHED")
    if override:
        return override

    current_directory = os.path.dirname(os.path.realpath(__file__))

    # Prefer the typeshed we bundled ourselves (if any) to the one
    # from the environment.
    bundled_typeshed = _find_directory_upwards(
        current_directory, "pyre_check/typeshed/"
    )
    if bundled_typeshed:
        return bundled_typeshed

    try:
        import typeshed  # pyre-fixme: Can't find module import typeshed

        return typeshed.typeshed
    except ImportError:
        LOG.debug("`import typeshed` failed, attempting a manual lookup")

    # This is a terrible, terrible hack.
    return _find_directory_upwards(current_directory, "typeshed/")


def find_taint_models_directory() -> Optional[str]:
    return _find_directory_upwards(
        os.path.dirname(os.path.realpath(__file__)), "pyre_check/taint/"
    )
