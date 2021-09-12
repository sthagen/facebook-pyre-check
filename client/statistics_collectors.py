# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import dataclasses
from collections import defaultdict
from enum import Enum
from re import compile
from typing import Any, Dict, List, Pattern, Sequence

import libcst as cst
from libcst.metadata import CodeRange, PositionProvider


@dataclasses.dataclass(frozen=True)
class AnnotationInfo:
    node: cst.CSTNode
    is_annotated: bool
    code_range: CodeRange


class FunctionAnnotationKind(Enum):
    NOT_ANNOTATED = 0
    PARTIALLY_ANNOTATED = 1
    FULLY_ANNOTATED = 2

    @staticmethod
    def from_function_data(
        is_return_annotated: bool,
        annotated_parameter_count: int,
        is_method_or_classmethod: bool,
        parameters: Sequence[cst.Param],
    ) -> "FunctionAnnotationKind":
        if is_return_annotated and annotated_parameter_count == len(parameters):
            return FunctionAnnotationKind.FULLY_ANNOTATED

        if is_return_annotated:
            return FunctionAnnotationKind.PARTIALLY_ANNOTATED

        has_untyped_self_parameter = is_method_or_classmethod and (
            len(parameters) > 0 and parameters[0].annotation is None
        )

        # Note: Untyped self parameters don't count towards making the function
        # partially-annotated. This is because, if there is no return type, we
        # will skip typechecking that function. So, even though `self` is
        # considered an implicitly-annotated parameter, we expect at least one
        # explicitly-annotated parameter for the function to be typechecked.
        threshold_for_partial_annotation = 1 if has_untyped_self_parameter else 0

        if annotated_parameter_count > threshold_for_partial_annotation:
            return FunctionAnnotationKind.PARTIALLY_ANNOTATED

        return FunctionAnnotationKind.NOT_ANNOTATED


@dataclasses.dataclass(frozen=True)
class FunctionAnnotationInfo:
    node: cst.CSTNode
    annotation_kind: FunctionAnnotationKind
    code_range: CodeRange

    @property
    def is_annotated(self) -> bool:
        return self.annotation_kind != FunctionAnnotationKind.NOT_ANNOTATED

    @property
    def is_partially_annotated(self) -> bool:
        return self.annotation_kind == FunctionAnnotationKind.PARTIALLY_ANNOTATED

    @property
    def is_fully_annotated(self) -> bool:
        return self.annotation_kind == FunctionAnnotationKind.FULLY_ANNOTATED


class AnnotationCollector(cst.CSTVisitor):
    METADATA_DEPENDENCIES = (PositionProvider,)
    path: str = ""

    def __init__(self) -> None:
        self.returns: List[AnnotationInfo] = []
        self.globals: List[AnnotationInfo] = []
        self.parameters: List[AnnotationInfo] = []
        self.attributes: List[AnnotationInfo] = []
        self.functions: List[FunctionAnnotationInfo] = []
        self.class_definition_depth = 0
        self.function_definition_depth = 0
        self.static_function_definition_depth = 0
        self.line_count = 0

    def in_class_definition(self) -> bool:
        return self.class_definition_depth > 0

    def in_function_definition(self) -> bool:
        return self.function_definition_depth > 0

    def in_static_function_definition(self) -> bool:
        return self.static_function_definition_depth > 0

    def _is_method_or_classmethod(self) -> bool:
        return self.in_class_definition() and not self.in_static_function_definition()

    def _is_self_or_cls(self, index: int) -> bool:
        return index == 0 and self._is_method_or_classmethod()

    def _code_range(self, node: cst.CSTNode) -> CodeRange:
        return self.get_metadata(PositionProvider, node)

    def _check_parameter_annotations(self, parameters: Sequence[cst.Param]) -> int:
        annotated_parameter_count = 0
        for index, parameter in enumerate(parameters):
            is_annotated = parameter.annotation is not None or self._is_self_or_cls(
                index
            )
            self.parameters.append(
                AnnotationInfo(parameter, is_annotated, self._code_range(parameter))
            )
            if is_annotated:
                annotated_parameter_count += 1
        return annotated_parameter_count

    def visit_FunctionDef(self, node: cst.FunctionDef) -> None:
        for decorator in node.decorators:
            decorator_node = decorator.decorator
            if isinstance(decorator_node, cst.Name):
                if decorator_node.value == "staticmethod":
                    self.static_function_definition_depth += 1
                    break
        self.function_definition_depth += 1

        if node.returns is None:
            code_range = self._code_range(node.whitespace_before_colon)
            return_is_annotated = False
        else:
            code_range = self._code_range(node.returns)
            return_is_annotated = True
        self.returns.append(AnnotationInfo(node, return_is_annotated, code_range))
        annotated_parameter_count = self._check_parameter_annotations(
            node.params.params
        )

        annotation_kind = FunctionAnnotationKind.from_function_data(
            return_is_annotated,
            annotated_parameter_count,
            self._is_method_or_classmethod(),
            parameters=node.params.params,
        )
        code_range = self._code_range(node.body)
        self.functions.append(FunctionAnnotationInfo(node, annotation_kind, code_range))

    def leave_FunctionDef(self, original_node: cst.FunctionDef) -> None:
        self.function_definition_depth -= 1
        for decorator in original_node.decorators:
            decorator_node = decorator.decorator
            if isinstance(decorator_node, cst.Name):
                if decorator_node.value == "staticmethod":
                    self.static_function_definition_depth -= 1
                    break

    def visit_Assign(self, node: cst.Assign) -> None:
        if self.in_function_definition():
            return
        implicitly_annotated_literal = False
        if isinstance(node.value, cst.BaseNumber) or isinstance(
            node.value, cst.BaseString
        ):
            implicitly_annotated_literal = True
        implicitly_annotated_value = False
        if isinstance(node.value, cst.Name) or isinstance(node.value, cst.Call):
            # An over-approximation of global values that do not need an explicit
            # annotation. Erring on the side of reporting these as annotated to
            # avoid showing false positives to users.
            implicitly_annotated_value = True
        code_range = self._code_range(node)
        if self.in_class_definition():
            is_annotated = implicitly_annotated_literal or implicitly_annotated_value
            self.attributes.append(AnnotationInfo(node, is_annotated, code_range))
        else:
            is_annotated = implicitly_annotated_literal or implicitly_annotated_value
            self.globals.append(AnnotationInfo(node, is_annotated, code_range))

    def visit_AnnAssign(self, node: cst.AnnAssign) -> None:
        if self.in_function_definition():
            return
        code_range = self._code_range(node)
        if self.in_class_definition():
            self.attributes.append(AnnotationInfo(node, True, code_range))
        else:
            self.globals.append(AnnotationInfo(node, True, code_range))

    def visit_ClassDef(self, node: cst.ClassDef) -> None:
        self.class_definition_depth += 1

    def leave_ClassDef(self, original_node: cst.ClassDef) -> None:
        self.class_definition_depth -= 1

    def leave_Module(self, original_node: cst.Module) -> None:
        file_range = self.get_metadata(PositionProvider, original_node)
        self.line_count = file_range.end.line


class StatisticsCollector(cst.CSTVisitor):
    def build_json(self) -> Dict[str, int]:
        return {}


class AnnotationCountCollector(StatisticsCollector, AnnotationCollector):
    def annotated_returns(self) -> List[AnnotationInfo]:
        return [r for r in self.returns if r.is_annotated]

    def annotated_globals(self) -> List[AnnotationInfo]:
        return [g for g in self.globals if g.is_annotated]

    def annotated_parameters(self) -> List[AnnotationInfo]:
        return [p for p in self.parameters if p.is_annotated]

    def annotated_attributes(self) -> List[AnnotationInfo]:
        return [a for a in self.attributes if a.is_annotated]

    def partially_annotated_functions(self) -> List[FunctionAnnotationInfo]:
        return [f for f in self.functions if f.is_partially_annotated]

    def fully_annotated_functions(self) -> List[FunctionAnnotationInfo]:
        return [f for f in self.functions if f.is_fully_annotated]

    def build_json(self) -> Dict[str, int]:
        return {
            "return_count": len(self.returns),
            "annotated_return_count": len(self.annotated_returns()),
            "globals_count": len(self.globals),
            "annotated_globals_count": len(self.annotated_globals()),
            "parameter_count": len(self.parameters),
            "annotated_parameter_count": len(self.annotated_parameters()),
            "attribute_count": len(self.attributes),
            "annotated_attribute_count": len(self.annotated_attributes()),
            "partially_annotated_function_count": (
                len(self.partially_annotated_functions())
            ),
            "fully_annotated_function_count": len(self.fully_annotated_functions()),
            "line_count": self.line_count,
        }


class CountCollector(StatisticsCollector):
    def __init__(self, regex: str) -> None:
        self.counts: Dict[str, int] = defaultdict(int)
        self.regex: Pattern[str] = compile(regex)

    def visit_Comment(self, node: cst.Comment) -> None:
        match = self.regex.match(node.value)
        if match:
            code_group = match.group(1)
            if code_group:
                codes = code_group.strip("[] ").split(",")
            else:
                codes = ["No Code"]
            for code in codes:
                self.counts[code.strip()] += 1

    def build_json(self) -> Dict[str, int]:
        return dict(self.counts)


class FixmeCountCollector(CountCollector):
    def __init__(self) -> None:
        super().__init__(r".*# *pyre-fixme(\[(\d* *,? *)*\])?")


class IgnoreCountCollector(CountCollector):
    def __init__(self) -> None:
        super().__init__(r".*# *pyre-ignore(\[(\d* *,? *)*\])?")


class StrictCountCollector(StatisticsCollector):
    def __init__(self, strict_by_default: bool) -> None:
        self.is_strict: bool = False
        self.is_unsafe: bool = False
        self.strict_count: int = 0
        self.unsafe_count: int = 0
        self.strict_by_default: bool = strict_by_default
        self.unsafe_regex: Pattern[str] = compile(r" ?#+ *pyre-unsafe")
        self.strict_regex: Pattern[str] = compile(r" ?#+ *pyre-strict")
        self.ignore_all_regex: Pattern[str] = compile(r" ?#+ *pyre-ignore-all-errors")
        self.ignore_all_by_code_regex: Pattern[str] = compile(
            r" ?#+ *pyre-ignore-all-errors\[[0-9]+[0-9, ]*\]"
        )

    def is_unsafe_module(self) -> bool:
        if self.is_unsafe:
            return True
        elif self.is_strict or self.strict_by_default:
            return False
        return True

    def visit_Module(self, node: cst.Module) -> None:
        self.is_strict = False
        self.is_unsafe = False

    def visit_Comment(self, node: cst.Comment) -> None:
        if self.strict_regex.match(node.value):
            self.is_strict = True
            return
        if self.unsafe_regex.match(node.value):
            self.is_unsafe = True
            return
        if self.ignore_all_regex.match(
            node.value
        ) and not self.ignore_all_by_code_regex.match(node.value):
            self.is_unsafe = True

    def leave_Module(self, original_node: cst.Module) -> None:
        if self.is_unsafe_module():
            self.unsafe_count += 1
        else:
            self.strict_count += 1

    def build_json(self) -> Dict[str, int]:
        return {"unsafe_count": self.unsafe_count, "strict_count": self.strict_count}


class CodeQualityIssue:
    def __init__(
        self, code_range: CodeRange, path: str, category: str, message: str
    ) -> None:
        self.category: str = category
        self.detail_message: str = message
        self.line: int = code_range.start.line
        self.line_end: int = code_range.end.line
        self.column: int = code_range.start.column
        self.column_end: int = code_range.end.column
        self.path: str = path

    def build_json(self) -> Dict[str, Any]:
        return {
            "category": self.category,
            "detail_message": self.detail_message,
            "line": self.line,
            "line_end": self.line_end,
            "column": self.column,
            "column_end": self.column_end,
            "path": self.path,
        }


class FunctionsCollector(cst.CSTVisitor):
    METADATA_DEPENDENCIES = (PositionProvider,)
    path: str = ""

    def __init__(self) -> None:
        self.issues: List[CodeQualityIssue] = []

    def visit_FunctionDef(self, node: cst.FunctionDef) -> None:
        return_is_annotated = node.returns is not None
        if not return_is_annotated:
            code_range = self.get_metadata(PositionProvider, node)
            issue = CodeQualityIssue(
                code_range,
                self.path,
                "PYRE_MISSING_ANNOTATIONS",
                "This function is missing a return annotation. \
                Bodies of unannotated functions are not typechecked by Pyre.",
            )
            self.issues.append(issue)


class StrictIssueCollector(StrictCountCollector):
    METADATA_DEPENDENCIES = (PositionProvider,)
    path: str = ""
    issues: List[CodeQualityIssue] = []

    def _create_issue(self, node: cst.Module) -> None:
        file_range = self.get_metadata(PositionProvider, node)
        code_range = CodeRange(start=file_range.start, end=file_range.start)
        issue = CodeQualityIssue(
            code_range, self.path, "PYRE_STRICT", "Unsafe Pyre file."
        )
        self.issues.append(issue)

    def leave_Module(self, original_node: cst.Module) -> None:
        if self.is_unsafe_module():
            self._create_issue(original_node)
