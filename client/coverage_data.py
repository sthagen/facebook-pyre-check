# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

"""
This module defines shared logic used by Pyre coverage tooling, including
- LibCST visitors to collect coverage information, and dataclasses
  representing the resulting data.
- Helpers for determining which files correspond to modules where Pyre
  should collect coverage information.
- Helpers for parsing code into LibCST modules with position metadata
"""

from __future__ import annotations

import dataclasses
import itertools
import logging
import re
from enum import Enum
from pathlib import Path
from re import compile
from typing import Dict, Iterable, List, Optional, Pattern, Sequence

import libcst
import libcst.matchers as matchers
from libcst.metadata import CodeRange, PositionProvider
from typing_extensions import TypeAlias

from . import dataclasses_json_extensions as json_mixins

LOG: logging.Logger = logging.getLogger(__name__)

ErrorCode: TypeAlias = int
LineNumber: TypeAlias = int


@dataclasses.dataclass(frozen=True)
class Location(json_mixins.SnakeCaseAndExcludeJsonMixin):
    start_line: int
    start_column: int
    end_line: int
    end_column: int

    @staticmethod
    def from_code_range(code_range: CodeRange) -> Location:
        return Location(
            start_line=code_range.start.line,
            start_column=code_range.start.column,
            end_line=code_range.end.line,
            end_column=code_range.end.column,
        )


@dataclasses.dataclass(frozen=True)
class AnnotationInfo:
    node: libcst.CSTNode
    is_annotated: bool
    location: Location
    contains_explicit_any: bool


@dataclasses.dataclass(frozen=True)
class FunctionIdentifier(json_mixins.SnakeCaseAndExcludeJsonMixin):
    parent: Optional[str]
    name: str


@dataclasses.dataclass(frozen=True)
class ParameterAnnotationInfo(json_mixins.SnakeCaseAndExcludeJsonMixin):
    name: str
    is_annotated: bool
    location: Location
    contains_explicit_any: bool


@dataclasses.dataclass(frozen=True)
class ReturnAnnotationInfo(json_mixins.SnakeCaseAndExcludeJsonMixin):
    is_annotated: bool
    location: Location
    contains_explicit_any: bool


class ModuleMode(str, Enum):
    UNSAFE = "UNSAFE"
    STRICT = "STRICT"
    IGNORE_ALL = "IGNORE_ALL"


@dataclasses.dataclass(frozen=True)
class ModuleModeInfo(json_mixins.SnakeCaseAndExcludeJsonMixin):
    mode: ModuleMode
    explicit_comment_line: Optional[LineNumber]
    is_generated: bool
    is_test: bool


class FunctionAnnotationStatus(str, Enum):
    NOT_ANNOTATED = "NOT_ANNOTATED"
    PARTIALLY_ANNOTATED = "PARTIALLY_ANNOTATED"
    FULLY_ANNOTATED = "FULLY_ANNOTATED"

    @staticmethod
    def from_function_data(
        is_non_static_method: bool,
        is_return_annotated: bool,
        parameters: Sequence[libcst.Param],
    ) -> "FunctionAnnotationStatus":
        if is_return_annotated:
            parameters_requiring_annotation = (
                parameters[1:] if is_non_static_method else parameters
            )
            all_parameters_annotated = all(
                parameter.annotation is not None
                for parameter in parameters_requiring_annotation
            )
            if all_parameters_annotated:
                return FunctionAnnotationStatus.FULLY_ANNOTATED
            else:
                return FunctionAnnotationStatus.PARTIALLY_ANNOTATED
        else:
            any_parameter_annotated = any(
                parameter.annotation is not None for parameter in parameters
            )
            if any_parameter_annotated:
                return FunctionAnnotationStatus.PARTIALLY_ANNOTATED
            else:
                return FunctionAnnotationStatus.NOT_ANNOTATED


@dataclasses.dataclass(frozen=True)
class FunctionAnnotationInfo(json_mixins.SnakeCaseAndExcludeJsonMixin):
    identifier: FunctionIdentifier
    location: Location
    annotation_status: FunctionAnnotationStatus
    returns: ReturnAnnotationInfo
    parameters: Sequence[ParameterAnnotationInfo]
    is_method_or_classmethod: bool

    def non_self_cls_parameters(self) -> Iterable[ParameterAnnotationInfo]:
        if self.is_method_or_classmethod:
            yield from self.parameters[1:]
        else:
            yield from self.parameters

    @property
    def is_annotated(self) -> bool:
        return self.annotation_status != FunctionAnnotationStatus.NOT_ANNOTATED

    @property
    def is_partially_annotated(self) -> bool:
        return self.annotation_status == FunctionAnnotationStatus.PARTIALLY_ANNOTATED

    @property
    def is_fully_annotated(self) -> bool:
        return self.annotation_status == FunctionAnnotationStatus.FULLY_ANNOTATED


class VisitorWithPositionData(libcst.CSTVisitor):
    """
    Mixin to use for libcst visitors that need position data.
    """

    METADATA_DEPENDENCIES = (PositionProvider,)

    def location(self, node: libcst.CSTNode) -> Location:
        return Location.from_code_range(self.get_metadata(PositionProvider, node))


class AnnotationContext:
    class_name_stack: List[str]
    define_depth: int
    static_define_depth: int

    def __init__(self) -> None:
        self.class_name_stack = []
        self.define_depth = 0
        self.static_define_depth = 0

    # Mutators to maintain context

    @staticmethod
    def _define_includes_staticmethod(define: libcst.FunctionDef) -> bool:
        for decorator in define.decorators:
            decorator_node = decorator.decorator
            if isinstance(decorator_node, libcst.Name):
                if decorator_node.value == "staticmethod":
                    return True
        return False

    def update_for_enter_define(self, define: libcst.FunctionDef) -> None:
        self.define_depth += 1
        if self._define_includes_staticmethod(define):
            self.static_define_depth += 1

    def update_for_exit_define(self, define: libcst.FunctionDef) -> None:
        self.define_depth -= 1
        if self._define_includes_staticmethod(define):
            self.static_define_depth -= 1

    def update_for_enter_class(self, classdef: libcst.ClassDef) -> None:
        self.class_name_stack.append(classdef.name.value)

    def update_for_exit_class(self) -> None:
        self.class_name_stack.pop()

    # Queries of the context

    def get_function_identifier(self, node: libcst.FunctionDef) -> FunctionIdentifier:
        return FunctionIdentifier(
            parent=(
                ".".join(self.class_name_stack)
                if len(self.class_name_stack) > 0
                else None
            ),
            name=node.name.value,
        )

    def assignments_are_function_local(self) -> bool:
        return self.define_depth > 0

    def assignments_are_class_level(self) -> bool:
        return len(self.class_name_stack) > 0

    def is_non_static_method(self) -> bool:
        """
        Is a parameter implicitly typed? This happens in non-static methods for
        the initial parameter (conventionally `self` or `cls`).
        """
        return len(self.class_name_stack) > 0 and not self.static_define_depth > 0


class ExplicitAnyChecker(libcst.CSTVisitor):
    """
    Checks for explicit Any usage in code.
    """

    def __init__(self) -> None:
        self.has_explicit_any: bool = False

    def visit_Name(self, node: libcst.Name) -> None:
        if node.value == "Any":
            self.has_explicit_any = True

    def contains_explicit_any(self) -> bool:
        return self.has_explicit_any


class AnnotationCollector(VisitorWithPositionData):
    path: str = ""

    def contains_explicit_any(self, node: Optional[libcst.CSTNode]) -> bool:
        visitor = ExplicitAnyChecker()
        if node is not None:
            node.visit(visitor)
        return visitor.contains_explicit_any()

    def __init__(self) -> None:
        self.context: AnnotationContext = AnnotationContext()
        self.globals: List[AnnotationInfo] = []
        self.attributes: List[AnnotationInfo] = []
        self.functions: List[FunctionAnnotationInfo] = []
        self.line_count = 0

    def returns(self) -> Iterable[ReturnAnnotationInfo]:
        for function in self.functions:
            yield function.returns

    def parameters(self) -> Iterable[ParameterAnnotationInfo]:
        for function in self.functions:
            yield from function.non_self_cls_parameters()

    def get_parameter_annotation_info(
        self,
        params: Sequence[libcst.Param],
    ) -> List[ParameterAnnotationInfo]:
        return [
            ParameterAnnotationInfo(
                name=node.name.value,
                is_annotated=node.annotation is not None,
                location=self.location(node),
                contains_explicit_any=self.contains_explicit_any(node),
            )
            for node in params
        ]

    def visit_ClassDef(self, node: libcst.ClassDef) -> None:
        self.context.update_for_enter_class(node)

    def leave_ClassDef(self, original_node: libcst.ClassDef) -> None:
        self.context.update_for_exit_class()

    def visit_FunctionDef(self, node: libcst.FunctionDef) -> None:
        identifier = self.context.get_function_identifier(node)
        self.context.update_for_enter_define(node)

        returns = ReturnAnnotationInfo(
            is_annotated=node.returns is not None,
            location=self.location(node.name),
            contains_explicit_any=self.contains_explicit_any(node.returns),
        )

        parameters = self.get_parameter_annotation_info(
            params=node.params.params,
        )

        annotation_status = FunctionAnnotationStatus.from_function_data(
            is_non_static_method=self.context.is_non_static_method(),
            is_return_annotated=returns.is_annotated,
            parameters=node.params.params,
        )
        self.functions.append(
            FunctionAnnotationInfo(
                identifier,
                self.location(node),
                annotation_status,
                returns,
                parameters,
                self.context.is_non_static_method(),
            )
        )

    def leave_FunctionDef(self, original_node: libcst.FunctionDef) -> None:
        self.context.update_for_exit_define(original_node)

    def visit_Assign(self, node: libcst.Assign) -> None:
        if self.context.assignments_are_function_local():
            return
        implicitly_annotated_literal = False
        if isinstance(node.value, libcst.BaseNumber) or isinstance(
            node.value, libcst.BaseString
        ):
            implicitly_annotated_literal = True
        implicitly_annotated_value = False
        if isinstance(node.value, libcst.Name) or isinstance(node.value, libcst.Call):
            # An over-approximation of global values that do not need an explicit
            # annotation. Erring on the side of reporting these as annotated to
            # avoid showing false positives to users.
            implicitly_annotated_value = True
        location = self.location(node)
        if self.context.assignments_are_class_level():
            is_annotated = implicitly_annotated_literal or implicitly_annotated_value
            self.attributes.append(
                AnnotationInfo(
                    node,
                    is_annotated,
                    location,
                    contains_explicit_any=self.contains_explicit_any(node),
                )
            )
        else:
            is_annotated = implicitly_annotated_literal or implicitly_annotated_value
            self.globals.append(
                AnnotationInfo(
                    node,
                    is_annotated,
                    location,
                    contains_explicit_any=self.contains_explicit_any(node),
                )
            )

    def visit_AnnAssign(self, node: libcst.AnnAssign) -> None:
        node.annotation
        if self.context.assignments_are_function_local():
            return
        location = self.location(node)
        if self.context.assignments_are_class_level():
            self.attributes.append(
                AnnotationInfo(
                    node,
                    True,
                    location,
                    contains_explicit_any=self.contains_explicit_any(node.annotation),
                )
            )
        else:
            self.globals.append(
                AnnotationInfo(
                    node,
                    True,
                    location,
                    contains_explicit_any=self.contains_explicit_any(node.annotation),
                )
            )

    def leave_Module(self, original_node: libcst.Module) -> None:
        file_range = self.get_metadata(PositionProvider, original_node)
        if original_node.has_trailing_newline:
            self.line_count = file_range.end.line
        else:
            # Seems to be a quirk in LibCST, the module CodeRange still goes 1 over
            # even when there is no trailing new line in the file.
            self.line_count = file_range.end.line - 1


class SuppressionKind(str, Enum):
    PYRE_FIXME = "PYRE_FIXME"
    PYRE_IGNORE = "PYRE_IGNORE"
    TYPE_IGNORE = "TYPE_IGNORE"


@dataclasses.dataclass(frozen=True)
class TypeErrorSuppression(json_mixins.SnakeCaseAndExcludeJsonMixin):
    kind: SuppressionKind
    location: Location
    error_codes: Optional[Sequence[ErrorCode]]


class SuppressionCollector(VisitorWithPositionData):
    suppression_regexes: Dict[SuppressionKind, str] = {
        SuppressionKind.PYRE_FIXME: r".*# *pyre-fixme(\[(\d* *,? *)*\])?",
        SuppressionKind.PYRE_IGNORE: r".*# *pyre-ignore(\[(\d* *,? *)*\])?",
        SuppressionKind.TYPE_IGNORE: r".*# *type: ignore",
    }

    def __init__(self) -> None:
        self.suppressions: List[TypeErrorSuppression] = []

    @staticmethod
    def _error_codes_from_re_group(
        match: re.Match[str],
        line: int,
    ) -> Optional[List[int]]:
        if len(match.groups()) < 1:
            code_group = None
        else:
            code_group = match.group(1)
        if code_group is None:
            return None
        code_strings = code_group.strip("[] ").split(",")
        try:
            codes = [int(code) for code in code_strings]
            return codes
        except ValueError:
            LOG.warning("Invalid error suppression code: %s", line)
            return []

    def suppression_from_comment(
        self,
        node: libcst.Comment,
    ) -> Iterable[TypeErrorSuppression]:
        location = self.location(node)
        for suppression_kind, regex in self.suppression_regexes.items():
            match = re.match(regex, node.value)
            if match is not None:
                yield TypeErrorSuppression(
                    kind=suppression_kind,
                    location=location,
                    error_codes=self._error_codes_from_re_group(
                        match=match,
                        line=location.start_line,
                    ),
                )

    def visit_Comment(self, node: libcst.Comment) -> None:
        for suppression in self.suppression_from_comment(node):
            self.suppressions.append(suppression)


class ModuleModeCollector(VisitorWithPositionData):
    unsafe_regex: Pattern[str] = compile(r" ?#+ *pyre-unsafe")
    strict_regex: Pattern[str] = compile(r" ?#+ *pyre-strict")
    ignore_all_regex: Pattern[str] = compile(r" ?#+ *pyre-ignore-all-errors")
    ignore_all_by_code_regex: Pattern[str] = compile(
        r" ?#+ *pyre-ignore-all-errors\[[0-9]+[0-9, ]*\]"
    )
    is_generated_regex: Pattern[str] = compile(r"@" + "generated")

    def __init__(self, strict_by_default: bool) -> None:
        self.strict_by_default: bool = strict_by_default
        # Note: the last comment will win here if there are multiple. This doesn't
        # matter for practical purposes because multiple modes produce a type error,
        # so it should be very rare to see them.
        self.mode: ModuleMode = (
            ModuleMode.STRICT if strict_by_default else ModuleMode.UNSAFE
        )
        self.explicit_comment_line: Optional[int] = None
        self.is_generated: bool = False

    def is_strict_module(self) -> bool:
        return self.mode == ModuleMode.STRICT

    def visit_Comment(self, node: libcst.Comment) -> None:
        if self.strict_regex.match(node.value):
            self.mode = ModuleMode.STRICT
            self.explicit_comment_line = self.location(node).start_line
        elif self.unsafe_regex.match(node.value):
            self.mode = ModuleMode.UNSAFE
            self.explicit_comment_line = self.location(node).start_line
        elif self.ignore_all_regex.match(
            node.value
        ) and not self.ignore_all_by_code_regex.match(node.value):
            self.mode = ModuleMode.IGNORE_ALL
            self.explicit_comment_line = self.location(node).start_line

        if self.is_generated_regex.search(node.value):
            self.is_generated = True


class EmptyContainerKind(str, Enum):
    LIST_LITERAL = "LIST_LITERAL"
    DICT_LITERAL = "DICT_LITERAL"
    LIST_CALL = "LIST_CALL"
    DICT_CALL = "DICT_CALL"
    SET_CALL = "SET_CALL"
    FROZENSET_CALL = "FROZENSET_CALL"


@dataclasses.dataclass(frozen=True)
class EmptyContainerInfo(json_mixins.SnakeCaseAndExcludeJsonMixin):
    kind: EmptyContainerKind
    location: Location


def _matches_names(targets: Sequence[libcst.AssignTarget]) -> bool:
    return all(isinstance(t.target, libcst.Name) for t in targets)


class EmptyContainerCollector(matchers.MatcherDecoratableVisitor):
    """
    Collects all empty containers in the module.
    """

    # An empty container is:
    # - an empty list literal
    # - an empty dict literal
    # - a call to set(), frozenset(), list(), or dict() with no arguments

    METADATA_DEPENDENCIES = (PositionProvider,)

    def __init__(self) -> None:
        super().__init__()
        self.empty_containers: List[EmptyContainerInfo] = []

    def location(self, node: libcst.CSTNode) -> Location:
        return Location.from_code_range(self.get_metadata(PositionProvider, node))

    def record_empty_container(self, kind: EmptyContainerKind, loc: Location) -> None:
        self.empty_containers.append(EmptyContainerInfo(kind=kind, location=loc))

    @matchers.visit(
        matchers.Assign(
            targets=matchers.MatchIfTrue(_matches_names),
            value=matchers.List(elements=matchers.MatchIfTrue(lambda x: len(x) == 0)),
        )
    )
    def record_empty_list(self, node: libcst.Assign) -> None:
        self.record_empty_container(
            EmptyContainerKind.LIST_LITERAL, self.location(node)
        )

    @matchers.visit(
        matchers.Assign(
            targets=matchers.MatchIfTrue(_matches_names),
            value=matchers.Dict(elements=matchers.MatchIfTrue(lambda x: len(x) == 0)),
        )
    )
    def record_empty_dict(self, node: libcst.Assign) -> None:
        self.record_empty_container(
            EmptyContainerKind.DICT_LITERAL, self.location(node)
        )

    @matchers.leave(
        matchers.Assign(
            targets=matchers.MatchIfTrue(_matches_names),
            value=matchers.Call(
                func=matchers.Name("list")
                | matchers.Name("dict")
                | matchers.Name("set")
                | matchers.Name("frozenset"),
                args=matchers.MatchIfTrue(lambda x: len(x) == 0),
            ),
        )
    )
    def record_constructor_call(self, node: libcst.Assign) -> None:
        func = libcst.ensure_type(node.value, libcst.Call)
        func_name = libcst.ensure_type(func.func, libcst.Name)
        if func_name.value == "list":
            kind = EmptyContainerKind.LIST_CALL
        elif func_name.value == "dict":
            kind = EmptyContainerKind.DICT_CALL
        elif func_name.value == "set":
            kind = EmptyContainerKind.SET_CALL
        elif func_name.value == "frozenset":
            kind = EmptyContainerKind.FROZENSET_CALL
        else:
            raise ValueError(f"Unexpected function call: {func_name}")
        self.record_empty_container(kind, self.location(node))


def collect_mode(
    module: libcst.MetadataWrapper,
    strict_by_default: bool,
    path: Path,
    ignored: bool = False,  # means the module was ignored in the pyre configuration
) -> ModuleModeInfo:
    is_test_regex = compile(r".*\/(test|tests)\/.*\.py$")
    visitor = ModuleModeCollector(strict_by_default)
    module.visit(visitor)
    mode = ModuleMode.IGNORE_ALL if ignored else visitor.mode
    return ModuleModeInfo(
        mode=mode,
        explicit_comment_line=visitor.explicit_comment_line,
        is_generated=visitor.is_generated,
        is_test=bool(is_test_regex.match(str(path))),
    )


def collect_functions(
    module: libcst.MetadataWrapper,
) -> Sequence[FunctionAnnotationInfo]:
    visitor = AnnotationCollector()
    module.visit(visitor)
    return visitor.functions


def collect_suppressions(
    module: libcst.MetadataWrapper,
) -> Sequence[TypeErrorSuppression]:
    visitor = SuppressionCollector()
    module.visit(visitor)
    return visitor.suppressions


def collect_empty_containers(
    module: libcst.MetadataWrapper,
) -> Sequence[EmptyContainerInfo]:
    visitor = EmptyContainerCollector()
    module.visit(visitor)
    return visitor.empty_containers


def module_from_code(code: str) -> Optional[libcst.MetadataWrapper]:
    try:
        raw_module = libcst.parse_module(code)
        return libcst.MetadataWrapper(raw_module)
    except Exception:
        LOG.exception("Error reading code at path %s.", code)
        return None


def module_from_path(path: Path) -> Optional[libcst.MetadataWrapper]:
    try:
        return module_from_code(path.read_text())
    except FileNotFoundError:
        return None


def _is_excluded(
    path: Path,
    excludes: Sequence[str],
) -> bool:
    try:
        return any(re.match(exclude_pattern, str(path)) for exclude_pattern in excludes)
    except re.error:
        LOG.warning("Could not parse `excludes`: %s", excludes)
        return False


def _should_ignore(
    path: Path,
    excludes: Sequence[str],
) -> bool:
    return (
        path.suffix != ".py"
        or path.name.startswith("__")
        or path.name.startswith(".")
        or _is_excluded(path, excludes)
    )


def find_module_paths(
    paths: Iterable[Path],
    excludes: Sequence[str],
) -> List[Path]:
    """
    Given a set of paths (which can be file paths or directory paths)
    where we want to collect data, return an iterable of all the module
    paths after recursively expanding directories, and ignoring directory
    exclusions specified in `excludes`.
    """

    def _get_paths_for_file(target_file: Path) -> Iterable[Path]:
        return [target_file] if not _should_ignore(target_file, excludes) else []

    def _get_paths_in_directory(target_directory: Path) -> Iterable[Path]:
        return (
            path
            for path in target_directory.glob("**/*.py")
            if not _should_ignore(path, excludes)
        )

    return sorted(
        set(
            itertools.chain.from_iterable(
                (
                    _get_paths_for_file(path)
                    if not path.is_dir()
                    else _get_paths_in_directory(path)
                )
                for path in paths
            )
        )
    )
