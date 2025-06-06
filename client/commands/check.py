# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

"""
This module provides the logic for the `pyre check` command, which runs a
single-shot type check (as opposed to `pyre incremental`, which starts a
server to enable quick incremental updates.)
"""

import contextlib
import dataclasses
import json
import logging
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Iterator, List, Sequence

from .. import (
    backend_arguments,
    command_arguments,
    configuration as configuration_module,
    error,
    frontend_configuration,
)
from . import commands, incremental, start

LOG: logging.Logger = logging.getLogger(__name__)


@dataclasses.dataclass(frozen=True)
class CheckResult:
    """
    Data structure for storing the result of the check command. We have this so we can call
    check from other scripts and retrieve the raw error objects, rather than having to dump them
    to stdout only to read them back in.
    """

    exit_code: commands.ExitCode
    errors: List[error.Error]


@dataclasses.dataclass(frozen=True)
class Arguments:
    """
    Data structure for configuration options the backend check command can recognize.
    Need to keep in sync with `source/command/checkCommand.ml`
    """

    base_arguments: backend_arguments.BaseArguments

    additional_logging_sections: Sequence[str] = dataclasses.field(default_factory=list)
    show_error_traces: bool = False
    strict: bool = False

    def serialize(self) -> Dict[str, Any]:
        return {
            **self.base_arguments.serialize(),
            "additional_logging_sections": self.additional_logging_sections,
            "show_error_traces": self.show_error_traces,
            "strict": self.strict,
        }


def create_check_arguments(
    configuration: frontend_configuration.Base,
    check_arguments: command_arguments.CheckArguments,
) -> Arguments:
    """
    Translate client configurations to backend check configurations.

    This API is not pure since it needs to access filesystem to filter out
    nonexistent directories. It is idempotent though, since it does not alter
    any filesystem state.
    """
    source_paths = backend_arguments.get_source_path_for_check(
        configuration,
        kill_buck_after_build=False,
        number_of_buck_threads=None,
    )

    logging_sections = check_arguments.logging_sections
    additional_logging_sections = (
        [] if logging_sections is None else logging_sections.split(",")
    )
    if check_arguments.noninteractive:
        additional_logging_sections.append("-progress")

    log_directory = configuration.get_log_directory()
    profiling_output = (
        backend_arguments.get_profiling_log_path(log_directory)
        if check_arguments.enable_profiling
        else None
    )
    memory_profiling_output = (
        backend_arguments.get_profiling_log_path(log_directory)
        if check_arguments.enable_memory_profiling
        else None
    )

    logger = configuration.get_remote_logger()
    remote_logging = (
        backend_arguments.RemoteLogging(
            logger=logger, identifier=check_arguments.log_identifier or ""
        )
        if logger is not None
        else None
    )

    return Arguments(
        base_arguments=backend_arguments.BaseArguments(
            log_path=str(log_directory),
            global_root=str(configuration.get_global_root()),
            checked_directory_allowlist=backend_arguments.get_checked_directory_allowlist(
                configuration, source_paths
            ),
            checked_directory_blocklist=(configuration.get_ignore_all_errors()),
            debug=check_arguments.debug,
            enable_readonly_analysis=configuration.get_enable_readonly_analysis(),
            enable_strict_override_check=configuration.get_enable_strict_override_check(),
            enable_strict_any_check=configuration.get_enable_strict_any_check(),
            enable_unawaited_awaitable_analysis=(
                configuration.get_enable_unawaited_awaitable_analysis()
            ),
            excludes=configuration.get_excludes(),
            extensions=configuration.get_valid_extension_suffixes(),
            include_suppressed_errors=configuration.get_include_suppressed_errors(),
            relative_local_root=configuration.get_relative_local_root(),
            memory_profiling_output=memory_profiling_output,
            number_of_workers=configuration.get_number_of_workers(),
            parallel=not check_arguments.sequential,
            profiling_output=profiling_output,
            python_version=configuration.get_python_version(),
            system_platform=configuration.get_system_platform(),
            shared_memory=configuration.get_shared_memory(),
            remote_logging=remote_logging,
            search_paths=configuration.get_existent_search_paths(),
            source_paths=source_paths,
        ),
        additional_logging_sections=additional_logging_sections,
        show_error_traces=check_arguments.show_error_traces,
        strict=configuration.is_strict(),
    )


@contextlib.contextmanager
def create_check_arguments_and_cleanup(
    configuration: frontend_configuration.Base,
    check_arguments: command_arguments.CheckArguments,
) -> Iterator[Arguments]:
    arguments = create_check_arguments(configuration, check_arguments)
    try:
        yield arguments
    finally:
        # It is safe to clean up source paths after check command since
        # any created artifact directory won't be reused by other commands.
        arguments.base_arguments.source_paths.cleanup()


class InvalidCheckResponse(Exception):
    pass


def parse_type_error_response_json(response_json: object) -> List[error.Error]:
    try:
        # The response JSON is expected to have the following form:
        # `{"errors": [error_json0, error_json1, ...]}`
        if isinstance(response_json, dict):
            errors_json = response_json.get("errors", [])
            if isinstance(errors_json, list):
                return [error.Error.from_json(error_json) for error_json in errors_json]

        raise InvalidCheckResponse(
            f"Unexpected JSON response from check command: {response_json}"
        )
    except error.ErrorParsingFailure as parsing_error:
        message = f"Unexpected error JSON from check command: {parsing_error}"
        raise InvalidCheckResponse(message) from parsing_error


def parse_type_error_response(response: str) -> List[error.Error]:
    try:
        response_json = json.loads(response)
        return parse_type_error_response_json(response_json)
    except json.JSONDecodeError as decode_error:
        message = f"Cannot parse response as JSON: {decode_error}"
        raise InvalidCheckResponse(message) from decode_error


def _run_check_command(command: Sequence[str]) -> CheckResult:
    with backend_arguments.backend_log_file(prefix="pyre_check") as log_file:
        with start.background_logging(Path(log_file.name)):
            # lint-ignore: NoUnsafeExecRule
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=log_file.file,
                universal_newlines=True,
                errors="replace",
            )
            return_code = result.returncode

            # Interpretation of the return code needs to be kept in sync with
            # `source/command/checkCommand.ml`.
            if return_code == 0:
                type_errors = parse_type_error_response(result.stdout)

                exit_code = (
                    commands.ExitCode.SUCCESS
                    if len(type_errors) == 0
                    else commands.ExitCode.FOUND_ERRORS
                )
                return CheckResult(exit_code, type_errors)
            elif return_code == 2:
                LOG.error("Pyre encountered a failure within buck.")
                return CheckResult(commands.ExitCode.BUCK_INTERNAL_ERROR, [])
            elif return_code == 3:
                LOG.error("Pyre encountered an error when building the buck targets.")
                return CheckResult(commands.ExitCode.BUCK_USER_ERROR, [])

            else:
                LOG.error(
                    f"The backend check command exited with non-zero return code: {return_code}. "
                    f"This likely indicates a problem with the Pyre binary at `{command[0]}`."
                )
                # The binary had an unexpected error. Allow a short time for
                # logs to be forwarded by the background logging thread before
                # exiting, otherwise we may drop important error messages.
                time.sleep(0.5)
                return CheckResult(commands.ExitCode.FAILURE, [])


def run_check(
    configuration: frontend_configuration.Base,
    check_arguments: command_arguments.CheckArguments,
) -> CheckResult:
    start_command = configuration.get_server_start_command(download_if_needed=True)
    if start_command is None:
        raise configuration_module.InvalidConfiguration(
            "Cannot locate a Pyre binary to run."
        )
    LOG.info(f"Pyre binary is located at `{start_command.get_pyre_binary_location()}`")

    with create_check_arguments_and_cleanup(
        configuration, check_arguments
    ) as arguments:
        with backend_arguments.temporary_argument_file(arguments) as argument_file_path:
            check_command = [
                str(start_command.get_pyre_binary_location()),
                "check",
                str(argument_file_path),
            ]
            return _run_check_command(check_command)


def run(
    configuration: frontend_configuration.Base,
    check_arguments: command_arguments.CheckArguments,
) -> commands.ExitCode:
    check_result = run_check(configuration, check_arguments)
    if check_result.exit_code in (
        commands.ExitCode.SUCCESS,
        commands.ExitCode.FOUND_ERRORS,
    ):
        incremental.display_type_errors(
            check_result.errors, output=check_arguments.output
        )
    return check_result.exit_code
