# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

import ast
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import IO, Any
from unittest.mock import MagicMock, mock_open, patch

from .. import module_loader
from ..model_generator import Configuration


class ModuleLoaderTest(unittest.TestCase):
    @patch("builtins.open")
    def test_load_module(self, open: MagicMock) -> None:
        valid_path = "/valid"
        invalid_syntax_path = "/syntax"
        invalid_path = "/invalid"

        valid_syntax = textwrap.dedent(
            """
            def my_function():
                pass
        """
        )

        invalid_syntax = textwrap.dedent(
            """
            def: () my_function:
                pass
        """
        )

        # pyre-ignore[3]: Return type must be specified as type that does not
        # contain Any.
        # pyre-fixme[53]: Captured variable `invalid_syntax` is not annotated.
        def _open_implementation(path: str, mode: str) -> IO[Any]:
            if path == valid_path:
                return mock_open(read_data=valid_syntax).return_value
            elif path == invalid_syntax_path:
                return mock_open(read_data=invalid_syntax).return_value
            else:
                raise FileNotFoundError(path)

        open.side_effect = _open_implementation

        module = module_loader.load_module(valid_path)
        self.assertIsInstance(module, ast.Module)
        # pyre-ignore[16]: Optional type has no attribute body.
        self.assertEqual(module.body[0].name, "my_function")

        module = module_loader.load_module(invalid_syntax_path)
        self.assertIsNone(module)

        module = module_loader.load_module(invalid_path)
        self.assertIsNone(module)

    def test_find_all_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            Configuration.root = directory_name

            directory = Path(directory_name)
            nested_directories = directory / "dir/dir/dir/dir/"
            stub_directory = directory / "stubs"
            nested_directories.mkdir(parents=True)
            stub_directory.mkdir()

            garbage_file = directory / "garbage.yp"
            no_nest = directory / "file.py"
            one_nest = directory / "dir/file.py"
            many_nest = directory / "dir/dir/dir/dir/file.py"
            py_file = directory / "stubs/file.py"
            pyi_file = directory / "stubs/file.pyi"

            garbage_file.touch()
            no_nest.touch()
            one_nest.touch()
            many_nest.touch()
            py_file.touch()
            pyi_file.touch()

            self.assertListEqual(
                sorted([str(no_nest), str(one_nest), str(many_nest), str(pyi_file)]),
                sorted(module_loader.find_all_paths()),
            )
