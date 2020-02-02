#!/usr/bin/env python3

import glob
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from abc import ABC
from contextlib import contextmanager
from logging import Logger
from pathlib import Path
from typing import Any, Dict, Generator, List, NamedTuple, Optional, Pattern

from pyre_paths import pyre_client


LOG: Logger = logging.getLogger(__name__)
CONFIGURATION = ".pyre_configuration"
LOCAL_CONFIGURATION = ".pyre_configuration.local"

BINARY_OVERRIDE = "PYRE_BINARY"
BINARY_VERSION_PATTERN: Pattern[str] = re.compile(r"Binary version: (\w*).*")


class FilesystemError(IOError):
    pass


class CommandData(NamedTuple):
    working_directory: str
    command: List[str]


class PyreResult(NamedTuple):
    command: str
    output: Optional[str]
    error_output: Optional[str]
    return_code: int


@contextmanager
def _watch_directory(source_directory: str) -> Generator[None, None, None]:
    subprocess.check_call(
        ["watchman", "watch", source_directory],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    yield
    subprocess.check_call(
        ["watchman", "watch-del", source_directory],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class TestCommand(unittest.TestCase, ABC):
    directory: Path
    typeshed: Path
    command_history: List[CommandData]

    def __init__(self, methodName: str) -> None:
        super(TestCommand, self).__init__(methodName)
        # workaround for initialization type errors
        self.directory = Path(".")
        self.typeshed = Path(".")
        self.command_history = []
        if not os.environ.get("PYRE_CLIENT"):
            os.environ["PYRE_CLIENT"] = pyre_client

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.typeshed = Path(self.directory, "fake_typeshed")
        self.buck_config = Path(self.directory, ".buckconfig").touch()
        Path(self.typeshed, "stdlib").mkdir(parents=True)
        self.initial_filesystem()

    def tearDown(self) -> None:
        self.cleanup()
        self.command_history = []
        shutil.rmtree(self.directory)

    def initial_filesystem(self) -> None:
        pass

    def cleanup(self) -> None:
        pass

    def create_project_configuration(
        self, root: Optional[str] = None, contents: Optional[Dict[str, Any]] = None
    ) -> None:
        root: Path = Path(root) if root else self.directory
        configuration_path = root / CONFIGURATION
        if not contents:
            # Use binary override if it is built.
            binary_override = os.environ.get(BINARY_OVERRIDE)
            # TODO(T57341910): Set binary override in buck test.
            if binary_override:
                contents = {"version": "$BINARY_OVERRIDE"}
            else:
                # Default to published binary version.
                output = subprocess.run(
                    ["pyre", "--version"], capture_output=True
                ).stdout.decode()
                output_match = re.match(BINARY_VERSION_PATTERN, output)
                version = output_match.group(1) if output_match else None
                if version and version != "No":
                    contents = {"version": version, "use_buck_builder": True}
                else:
                    binary_location = shutil.which("pyre.bin")
                    if binary_location is None:
                        LOG.error(
                            "No project configuration content provided and "
                            "could not find a binary to run."
                        )
                        raise FilesystemError
                    contents = {"binary": binary_location}
        with configuration_path.open("w+") as configuration_file:
            json.dump(contents, configuration_file)

    def create_local_configuration(self, root: str, contents: Dict[str, Any]) -> None:
        root: Path = self.directory / root
        root.mkdir(exist_ok=True)
        with (root / LOCAL_CONFIGURATION).open("w+") as configuration_file:
            json.dump(contents, configuration_file)

    def create_directory(self, relative_path: str) -> None:
        Path(self.directory, relative_path).mkdir(parents=True)

    def create_file(self, relative_path: str, contents: str = "") -> None:
        file_path = self.directory / relative_path
        file_path.parent.mkdir(exist_ok=True, parents=True)
        file_path.write_text(textwrap.dedent(contents))

    def create_file_with_error(self, relative_path: str) -> None:
        contents = """
            def foo(x: int) -> str:
                return x
            """
        self.create_file(relative_path, contents)

    def delete_file(self, relative_path: str) -> None:
        try:
            (self.directory / relative_path).unlink()
        except FileNotFoundError:
            LOG.debug(
                "Deletion of {} skipped; file does not exist.".format(relative_path)
            )

    def run_pyre(
        self,
        command: str,
        *arguments: str,
        working_directory: Optional[str] = None,
        timeout: int = 30,
        prompts: Optional[List[str]] = None
    ) -> PyreResult:
        working_directory: Path = (
            self.directory / working_directory if working_directory else self.directory
        )
        prompt_inputs = "\n".join(prompts).encode() if prompts else None
        command: List[str] = [
            "pyre",
            "--noninteractive",
            "--output=json",
            "--typeshed",
            str(self.typeshed),
            command,
            *arguments,
        ]
        try:
            self.command_history.append(CommandData(str(working_directory), command))
            process = subprocess.run(
                command,
                cwd=working_directory,
                input=prompt_inputs,
                timeout=timeout,
                capture_output=True,
            )
            return PyreResult(
                " ".join(command),
                process.stdout.decode(),
                process.stderr.decode(),
                process.returncode,
            )
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout
            stderr = error.stderr
            result = PyreResult(
                " ".join(command),
                stdout.decode() if stdout else "",
                stderr.decode() if stderr else "",
                -1,
            )
            LOG.error(self.get_context(result))
            raise error

    def get_servers(self) -> List[Dict[str, Any]]:
        result = self.run_pyre("--output=json", "servers")
        try:
            running_servers = json.loads(result.output or "")
        except json.JSONDecodeError as json_error:
            LOG.error(self.get_context(result))
            raise json_error
        return running_servers

    def get_context(self, result: Optional[PyreResult] = None) -> str:
        # TODO(T60769864): Avoid printing context twice in buck runs.
        # TODO(T57341910): Log pyre rage / debug when appropriate.
        context = ""

        def format_section(title: str, *contents: str) -> str:
            divider = "=" * 15
            # pyre-ignore[9]: Unable to unpack `str`, expected a tuple.
            contents = "\n\n".join([content.strip() for content in contents])
            section = "\n\n{} {} {}\n\n{}\n".format(divider, title, divider, contents)
            return section

        # Pyre Output
        if result:
            if result.output or result.error_output:
                context += format_section(
                    "Pyre Output",
                    "Command: `" + result.command + "`",
                    result.output or "",
                    result.error_output or "",
                )

        # Filesystem Structure
        filesystem_structure = subprocess.run(
            ["tree", self.directory, "-a", "-I", "typeshed"], capture_output=True
        ).stdout.decode()
        context += format_section("Filesystem Structure", filesystem_structure)

        # Version Information
        version_output = subprocess.run(
            ["pyre", "--version"], cwd=self.directory, capture_output=True
        ).stdout.decode()
        configurations = glob.glob(
            str(self.directory / "**/.pyre_configuration*"), recursive=True
        )
        configuration_contents = ""
        for configuration in configurations:
            configuration_contents += configuration + "\n  "
            configuration_contents += Path(configuration).read_text() + "\n\n"
        context += format_section("Versioning", version_output, configuration_contents)

        # Repro Instructions
        instructions = ""
        if self.command_history:
            instructions += "- Create directory structure above and run:\n\t"
            instructions += "\n\t".join(
                [
                    "["
                    + str(command.working_directory).replace(
                        str(self.directory), "$project_root"
                    )
                    + "] "
                    + " ".join(command.command)
                    for command in self.command_history
                ]
            )
        test_id = self.id()
        instructions += "\n\n- Re-run only this failing test:\n\t"
        instructions += "[tools/pyre] python3 {} {}".format(
            "scripts/run_client_integration_test.py", test_id
        )
        instructions += "\n\n- Flaky? Stress test this failing test:\n\t"
        test_target = "//tools/pyre/scripts:pyre_client_integration_test_runner"
        buck_arguments = "--jobs 18 --stress-runs 20 --record-results"
        test_name = test_id.split(".")[-1]
        test_qualifier = r"\.".join(test_id.split(".")[:-1])
        instructions += r"[tools/pyre] buck test {} -- '{} \({}\)' {}".format(
            test_target, test_name, test_qualifier, buck_arguments
        )
        context += format_section("Repro Instructions", instructions)
        return context

    def assert_succeeded(self, result: PyreResult) -> None:
        self.assertEqual(result.return_code, 0)

    def assert_failed(self, result: PyreResult) -> None:
        self.assertEqual(result.return_code, 2)

    def assert_has_errors(self, result: PyreResult) -> None:
        self.assertEqual(result.return_code, 1, self.get_context(result))

    def assert_no_errors(self, result: PyreResult) -> None:
        self.assertEqual(result.return_code, 0, self.get_context(result))

    def assert_file_exists(
        self, relative_path: str, json_contents: Optional[Dict[str, Any]] = None
    ) -> None:
        file_path = self.directory / relative_path
        self.assertTrue(file_path.exists(), self.get_context())
        if json_contents:
            file_contents = file_path.read_text()
            self.assertEqual(
                json.loads(file_contents), json_contents, self.get_context()
            )

    def assert_server_exists(
        self, server_name: str, result: Optional[PyreResult] = None
    ) -> None:
        running_servers = self.get_servers()
        server_exists = any(server["name"] == server_name for server in running_servers)
        self.assertTrue(server_exists, self.get_context(result))

    def assert_no_servers_exist(self, result: Optional[PyreResult] = None) -> None:
        self.assertEqual(self.get_servers(), [], self.get_context(result))


class BaseCommandTest(TestCommand):
    # TODO(T57341910): Test command-agnostic behavior like `pyre --version`
    pass


class AnalyzeTest(TestCommand):
    # TODO(T57341910): Fill in test cases
    # Currently fails with invalid model error.
    pass


class CheckTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_file_with_error("local_project/has_type_error.py")

    def test_command_line_source_directory_check(self) -> None:
        result = self.run_pyre("--source-directory", "local_project", "check")
        self.assert_has_errors(result)

        result = self.run_pyre("-l", "local_project", "check")
        self.assert_failed(result)

    def test_command_line_targets_check(self) -> None:
        pass

    def test_local_configuration_check(self) -> None:
        self.create_local_configuration("local_project", {"source_directories": ["."]})
        result = self.run_pyre("-l", "local_project", "check")
        self.assert_has_errors(result)


class ColorTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    # pyre -l project path current fails with server connection failure.
    pass


class DeobfuscateTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    # Currently fails with error parsing command line, no help.
    pass


class IncrementalTest(TestCommand):
    def cleanup(self) -> None:
        self.run_pyre("kill")

    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_directory("local_project")
        self.create_local_configuration("local_project", {"source_directories": ["."]})
        self.create_file_with_error("local_project/has_type_error.py")
        self.create_file(".watchmanconfig", "{}")

    def test_no_existing_server(self) -> None:
        result = self.run_pyre(
            "-l", "local_project", "incremental", "--incremental-style=fine_grained"
        )
        self.assert_has_errors(result)


class InferTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_local_configuration("local_project", {"source_directories": ["."]})
        contents = """
            def foo():
                return 1
        """
        self.create_file("local_project/missing_annotation.py", contents)

    def test_infer_stubs(self) -> None:
        self.run_pyre("-l", "local_project", "infer")
        self.assert_file_exists(
            ".pyre/local_project/types/local_project/missing_annotation.pyi"
        )

    def test_infer_in_place(self) -> None:
        pass

    def test_infer_from_existing_stubs(self) -> None:
        pass

    def test_infer_from_json(self) -> None:
        pass

    def test_infer_options(self) -> None:
        # print-only, full-only, recursive
        pass


class InitializeTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_file("fake_pyre.bin")

    def test_initialize_project_configuration(self) -> None:
        with _watch_directory(self.directory):
            self.run_pyre(
                "init",
                prompts=["y", "fake_pyre.bin", "fake_typeshed", "//example:target"],
            )
            expected_contents = {
                "binary": str(self.directory / "fake_pyre.bin"),
                "source_directories": ["//example:target"],
                "typeshed": str(self.directory / "fake_typeshed"),
            }
            self.assert_file_exists(
                ".pyre_configuration", json_contents=expected_contents
            )

    def test_initialize_local_configuration(self) -> None:
        self.create_directory("local_project")
        with _watch_directory(self.directory):
            self.run_pyre(
                "init",
                "--local",
                working_directory="local_project",
                prompts=["Y", "//example:target", "Y", "Y", "Y"],
            )
            expected_contents = {
                "differential": True,
                "push_blocking": True,
                "targets": ["//example:target"],
            }
            self.assert_file_exists(
                "local_project/.pyre_configuration.local",
                json_contents=expected_contents,
            )


class KillTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_local_configuration("local_one", {"source_directories": ["."]})
        self.create_file_with_error("local_one/has_type_error.py")
        self.create_local_configuration("local_two", {"source_directories": ["."]})
        self.create_file_with_error("local_two/has_type_error.py")

    def test_kill_without_server(self) -> None:
        result = self.run_pyre("kill")
        self.assert_succeeded(result)
        self.assert_no_servers_exist()

    def test_kill(self) -> None:
        self.run_pyre("-l", "local_one", "start")
        self.assert_server_exists("local_one")
        self.run_pyre("kill")
        self.assert_no_servers_exist()

        self.run_pyre("-l", "local_one", "restart")
        self.assert_server_exists("local_one")
        self.run_pyre("kill")
        self.assert_no_servers_exist()

        self.run_pyre("-l", "local_one")
        self.run_pyre("-l", "local_two")
        self.assert_server_exists("local_one")
        self.assert_server_exists("local_two")
        self.run_pyre("kill")
        self.assert_no_servers_exist()


class PersistentTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    pass


class ProfileTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    pass


class QueryTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    # TODO(T57341910): Test pyre query help.
    pass


class RageTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    pass


class ReportingTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    pass


class RestartTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_local_configuration("local_one", {"source_directories": ["."]})
        self.create_file_with_error("local_one/has_type_error.py")
        self.create_local_configuration("local_two", {"source_directories": ["."]})
        self.create_file_with_error("local_two/has_type_error.py")

    def test_restart(self) -> None:
        # TODO(T57341910): Test blank restart
        self.assert_no_servers_exist()

        result = self.run_pyre("-l", "local_one", "restart")
        self.assert_has_errors(result)
        self.assert_server_exists("local_one")

        result = self.run_pyre("-l", "local_one", "restart")
        self.assert_has_errors(result)
        self.assert_server_exists("local_one")


class ServersTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_local_configuration("local_one", {"source_directories": ["."]})
        self.create_file_with_error("local_one/has_type_error.py")
        self.create_local_configuration("local_two", {"source_directories": ["."]})
        self.create_file_with_error("local_two/has_type_error.py")

    def test_list_servers(self) -> None:
        self.run_pyre("servers", "list")
        self.run_pyre("-l", "local_one")
        self.run_pyre("servers", "list")
        self.run_pyre("-l", "local_two")
        self.run_pyre("servers", "list")


class StartTest(TestCommand):
    def cleanup(self) -> None:
        self.run_pyre("kill")

    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_directory("local_project")
        self.create_local_configuration("local_project", {"source_directories": ["."]})
        self.create_file_with_error("local_project/test.py")

    def test_server_start(self) -> None:
        with _watch_directory(self.directory):
            result = self.run_pyre("-l", "local_project", "start")
            self.assert_no_errors(result)

        # TODO(T57341910): Test concurrent pyre server processes.


class StatisticsTest(TestCommand):
    # TODO(T57341910): Fill in test cases.
    pass


class StopTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_local_configuration("local_one", {"source_directories": ["."]})
        self.create_file_with_error("local_one/has_type_error.py")
        self.create_local_configuration("local_two", {"source_directories": ["."]})
        self.create_file_with_error("local_two/has_type_error.py")

    def test_stop_without_server(self) -> None:
        self.run_pyre("stop")
        self.run_pyre("-l", "local_one", "stop")

    def test_stop(self) -> None:
        self.run_pyre("-l", "local_one", "start")
        self.run_pyre("-l", "local_two", "stop")
        self.run_pyre("-l", "local_one", "stop")

        self.run_pyre("-l", "local_one", "restart")
        self.run_pyre("-l", "local_one", "stop")

        self.run_pyre("-l", "local_one", "start")
        self.run_pyre("-l", "local_two", "start")
        self.run_pyre("-l", "local_one", "stop")


if __name__ == "__main__":
    unittest.main()
