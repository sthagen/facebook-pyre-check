#!/usr/bin/env python3

import json
import logging
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from abc import ABC
from contextlib import contextmanager
from logging import Logger
from pathlib import Path
from typing import Any, Dict, Generator, List, NamedTuple, Optional


LOG: Logger = logging.getLogger(__name__)
CONFIGURATION = ".pyre_configuration"
LOCAL_CONFIGURATION = ".pyre_configuration.local"


class FilesystemError(IOError):
    pass


class PyreResult(NamedTuple):
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


# TODO(T57341910): Add structure for verifying output/logs/results/timeouts/processes
# TODO(T57341910): Command to re-run only failing tests in debug, & for stress testing
# TODO(T57341910): Fill in test cases
class TestCommand(unittest.TestCase, ABC):
    directory: Path

    def __init__(self, methodName: str) -> None:
        super(TestCommand, self).__init__(methodName)
        self.directory = Path(".")  # workaround for initialization type errors

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.initial_filesystem()

    def tearDown(self) -> None:
        self.cleanup()
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
            # TODO(T57341910): grab version from pyre --version, hard code other fields
            contents = {
                "version": "135a0b724041385fe600e6c624e61a16691fcf90",
                "use_buck_builder": True,
            }
        with configuration_path.open("w") as configuration_file:
            json.dump(contents, configuration_file)

    def create_local_configuration(self, root: str, contents: Dict[str, Any]) -> None:
        with Path(self.directory, root, LOCAL_CONFIGURATION).open(
            "w"
        ) as configuration_file:
            json.dump(contents, configuration_file)

    def create_directory(self, relative_path: str) -> None:
        Path(self.directory, relative_path).mkdir()

    def create_file(self, relative_path: str, contents: str = "") -> None:
        file_path = self.directory / relative_path
        file_path.parent.mkdir(exist_ok=True)
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
        timeout: int = 60,
        prompts: Optional[List[str]] = None
    ) -> PyreResult:
        working_directory: Path = (
            self.directory / working_directory if working_directory else self.directory
        )
        prompt_inputs = "\n".join(prompts).encode() if prompts else None
        try:
            process = subprocess.run(
                ["pyre", "--noninteractive", "--output=json", command, *arguments],
                cwd=working_directory,
                input=prompt_inputs,
                timeout=timeout,
                capture_output=True,
            )
            return PyreResult(
                process.stdout.decode(), process.stderr.decode(), process.returncode
            )
        except subprocess.TimeoutExpired as error:
            LOG.error(error.stderr)
            LOG.error(error.stdout)
            raise error

    def get_context(self, result: PyreResult) -> str:
        # TODO(T57341910): Provide repro and full env info for failure cases
        return result.error_output or ""

    def assert_has_errors(self, result: PyreResult) -> None:
        self.assertTrue(result.return_code == 1, self.get_context(result))

    def assert_no_errors(self, result: PyreResult) -> None:
        self.assertTrue(result.return_code == 0, self.get_context(result))

    def assert_file_exists(
        self, relative_path: str, json_contents: Optional[Dict[str, Any]] = None
    ) -> None:
        file_path = self.directory / relative_path
        self.assertTrue(file_path.exists())
        if json_contents:
            file_contents = file_path.read_text()
            self.assertEqual(json_contents, json.loads(file_contents))


class AnalyzeTest(TestCommand):
    pass


class CheckTest(TestCommand):
    pass


class ColorTest(TestCommand):
    pass


class DeobfuscateTest(TestCommand):
    pass


class IncrementalTest(TestCommand):
    def cleanup(self) -> None:
        self.run_pyre("kill")

    def initial_filesystem(self) -> None:
        self.create_project_configuration()
        self.create_directory("local_project")
        self.create_local_configuration("local_project", {"source_directories": ["."]})
        self.create_file_with_error("local_project/test.py")
        self.create_file(".watchmanconfig", "{}")

    def test_no_existing_server(self) -> None:
        result = self.run_pyre(
            "-l", "local_project", "incremental", "--incremental-style=fine_grained"
        )
        self.assert_has_errors(result)


class InferTest(TestCommand):
    pass


class InitializeTest(TestCommand):
    def initial_filesystem(self) -> None:
        self.create_file("fake_pyre.bin")
        self.create_directory("fake_typeshed")

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
                prompts=["//example:target", "Y", "Y", "Y"],
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
    pass


class PersistentTest(TestCommand):
    pass


class ProfileTest(TestCommand):
    pass


class QueryTest(TestCommand):
    pass


class RageTest(TestCommand):
    pass


class ReportingTest(TestCommand):
    pass


class RestartTest(TestCommand):
    pass


class ServersTest(TestCommand):
    pass


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


class StatisticsTest(TestCommand):
    pass


class StopTest(TestCommand):
    pass


if __name__ == "__main__":
    unittest.main()
