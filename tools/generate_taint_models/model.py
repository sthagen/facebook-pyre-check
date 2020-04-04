# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

import abc
import ast
import inspect
import logging
import types
from enum import Enum, auto
from typing import Callable, Iterable, List, Mapping, NamedTuple, Optional, Set, Union

import _ast
from tools.pyre.api import query
from typing_extensions import Final

from .inspect_parser import extract_annotation, extract_name, extract_qualified_name


FunctionDefinition = Union[_ast.FunctionDef, _ast.AsyncFunctionDef]

LOG: logging.Logger = logging.getLogger(__name__)


class Model(abc.ABC):
    def __lt__(self, other: "Model") -> bool:
        return str(self) < str(other)

    @abc.abstractmethod
    def __eq__(self) -> int:
        ...

    @abc.abstractmethod
    def __hash__(self) -> int:
        ...


class ArgumentKind(Enum):
    ARG = auto()
    VARARG = auto()
    KWARG = auto()


class Parameter(NamedTuple):
    name: str
    annotation: Optional[str]
    kind: ArgumentKind

    def __eq__(self, other: "Parameter") -> bool:
        if not isinstance(other, self.__class__):
            return False
        return self.name == other.name


class RawCallableModel(Model):
    callable_name: str
    parameters: List[Parameter]
    parameter_type_whitelist: Optional[Iterable[str]]
    parameter_name_whitelist: Optional[Set[str]]
    returns: Optional[str] = None

    def __init__(
        self,
        arg: Optional[str] = None,
        vararg: Optional[str] = None,
        kwarg: Optional[str] = None,
        returns: Optional[str] = None,
        parameter_type_whitelist: Optional[Iterable[str]] = None,
        parameter_name_whitelist: Optional[Set[str]] = None,
    ) -> None:
        self.arg = arg
        self.vararg = vararg
        self.kwarg = kwarg
        self.returns = returns

        self.parameter_type_whitelist = parameter_type_whitelist
        self.parameter_name_whitelist = parameter_name_whitelist

        callable_name = self._get_fully_qualified_callable_name()
        # Object construction should fail if any child class passes in a None.
        if not callable_name or "-" in callable_name:
            raise ValueError("The callable is not supported")

        self.callable_name = callable_name
        self.parameters = self._generate_parameters()

    @abc.abstractmethod
    def _generate_parameters(self) -> List["Parameter"]:
        ...

    @abc.abstractmethod
    def _get_fully_qualified_callable_name(self) -> Optional[str]:
        ...

    def __str__(self) -> str:
        serialized_parameters = []

        name_whitelist = self.parameter_name_whitelist
        type_whitelist = self.parameter_type_whitelist
        for parameter_name, annotation, kind in self.parameters:
            should_annotate = True
            if name_whitelist is not None and parameter_name in name_whitelist:
                should_annotate = False

            if type_whitelist is not None and annotation in type_whitelist:
                should_annotate = False

            if should_annotate:
                if kind == ArgumentKind.KWARG:
                    taint = self.kwarg
                elif kind == ArgumentKind.VARARG:
                    taint = self.vararg
                else:  # kind == ArgumentKind.ARG:
                    taint = self.arg
            else:
                taint = None

            # * parameters indicate kwargs after the parameter position, and can't be
            # tainted. Example: `def foo(x, *, y): ...`
            if parameter_name != "*" and taint:
                serialized_parameters.append(f"{parameter_name}: {taint}")
            else:
                serialized_parameters.append(parameter_name)

        returns = self.returns
        if returns:
            return_annotation = f" -> {returns}"
        else:
            return_annotation = ""

        return (
            f"def {self.callable_name}({', '.join(serialized_parameters)})"
            f"{return_annotation}: ..."
        )

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, RawCallableModel):
            return False
        return (
            self.callable_name == other.callable_name
            and self.parameters == other.parameters
        )

    # Need to explicitly define this(despite baseclass) as we are overriding eq
    def __hash__(self) -> int:
        parameter_names_string = ",".join(
            map(lambda parameter: parameter.name, self.parameters)
        )
        return hash((self.callable_name, parameter_names_string))


class CallableModel(RawCallableModel):
    callable_object: Callable[..., object]

    def __init__(
        self,
        callable_object: Callable[..., object],
        arg: Optional[str] = None,
        vararg: Optional[str] = None,
        kwarg: Optional[str] = None,
        returns: Optional[str] = None,
        parameter_type_whitelist: Optional[Iterable[str]] = None,
        parameter_name_whitelist: Optional[Set[str]] = None,
    ) -> None:
        self.callable_object = callable_object
        super().__init__(
            arg=arg,
            vararg=vararg,
            kwarg=kwarg,
            returns=returns,
            parameter_type_whitelist=parameter_type_whitelist,
            parameter_name_whitelist=parameter_name_whitelist,
        )

    def _generate_parameters(self) -> List[Parameter]:
        view_parameters: Mapping[str, inspect.Parameter] = {}
        callable_object = self.callable_object
        if isinstance(callable_object, types.FunctionType):
            view_parameters = inspect.signature(callable_object).parameters
        elif isinstance(callable_object, types.MethodType):
            # pyre-ignore: Too dynamic
            view_parameters = inspect.signature(callable_object.__func__).parameters

        parameters: List[Parameter] = []
        for parameter in view_parameters.values():
            if parameter.kind == inspect.Parameter.VAR_KEYWORD:
                kind = ArgumentKind.KWARG
            elif parameter.kind == inspect.Parameter.VAR_POSITIONAL:
                kind = ArgumentKind.VARARG
            else:
                kind = ArgumentKind.ARG

            parameters.append(
                Parameter(extract_name(parameter), extract_annotation(parameter), kind)
            )

        return parameters

    def _get_fully_qualified_callable_name(self) -> Optional[str]:
        return extract_qualified_name(self.callable_object)


class FunctionDefinitionModel(RawCallableModel):
    definition: FunctionDefinition
    qualifier: Optional[str] = None

    def __init__(
        self,
        definition: FunctionDefinition,
        qualifier: Optional[str] = None,
        arg: Optional[str] = None,
        vararg: Optional[str] = None,
        kwarg: Optional[str] = None,
        returns: Optional[str] = None,
        parameter_type_whitelist: Optional[Iterable[str]] = None,
        parameter_name_whitelist: Optional[Set[str]] = None,
    ) -> None:
        self.definition = definition
        self.qualifier = qualifier
        super().__init__(
            arg=arg,
            vararg=vararg,
            kwarg=kwarg,
            returns=returns,
            parameter_type_whitelist=parameter_type_whitelist,
            parameter_name_whitelist=parameter_name_whitelist,
        )

    @staticmethod
    def _get_annotation(ast_arg: ast.arg) -> Optional[str]:
        annotation = ast_arg.annotation
        if annotation and isinstance(annotation, _ast.Name):
            return annotation.id
        else:
            return None

    def _generate_parameters(self) -> List[Parameter]:
        parameters: List[Parameter] = []
        function_arguments = self.definition.args

        for ast_arg in function_arguments.args:
            parameters.append(
                Parameter(
                    ast_arg.arg,
                    FunctionDefinitionModel._get_annotation(ast_arg),
                    ArgumentKind.ARG,
                )
            )

        keyword_only_parameters = function_arguments.kwonlyargs
        if len(keyword_only_parameters) > 0:
            parameters.append(
                Parameter(name="*", annotation=None, kind=ArgumentKind.ARG)
            )
            for parameter in keyword_only_parameters:
                parameters.append(
                    Parameter(
                        parameter.arg,
                        FunctionDefinitionModel._get_annotation(parameter),
                        ArgumentKind.ARG,
                    )
                )

        vararg_parameters = function_arguments.vararg
        if isinstance(vararg_parameters, ast.arg):
            parameters.append(
                Parameter(
                    f"*{vararg_parameters.arg}",
                    FunctionDefinitionModel._get_annotation(vararg_parameters),
                    ArgumentKind.VARARG,
                )
            )

        kwarg_parameters = function_arguments.kwarg
        if isinstance(kwarg_parameters, ast.arg):
            parameters.append(
                Parameter(
                    f"**{kwarg_parameters.arg}",
                    FunctionDefinitionModel._get_annotation(kwarg_parameters),
                    ArgumentKind.KWARG,
                )
            )

        return parameters

    def _get_fully_qualified_callable_name(self) -> Optional[str]:
        qualifier = f"{self.qualifier}." if self.qualifier else ""
        fn_name = self.definition.name
        return qualifier + fn_name


class PyreFunctionDefinitionModel(RawCallableModel):
    definition: query.Define

    def __init__(
        self,
        definition: query.Define,
        arg: Optional[str] = None,
        vararg: Optional[str] = None,
        kwarg: Optional[str] = None,
        returns: Optional[str] = None,
        parameter_type_whitelist: Optional[Iterable[str]] = None,
        parameter_name_whitelist: Optional[Set[str]] = None,
    ) -> None:
        self.definition = definition
        super().__init__(
            arg=arg,
            vararg=vararg,
            kwarg=kwarg,
            returns=returns,
            parameter_type_whitelist=parameter_type_whitelist,
            parameter_name_whitelist=parameter_name_whitelist,
        )

    def _generate_parameters(self) -> List[Parameter]:
        parameters: List[Parameter] = []

        for parameter in self.definition.parameters:
            if "**" in parameter.name:
                kind = ArgumentKind.KWARG
            elif "*" in parameter.name:
                kind = ArgumentKind.VARARG
            else:
                kind = ArgumentKind.ARG
            parameters.append(
                Parameter(
                    name=parameter.name, annotation=parameter.annotation, kind=kind
                )
            )

        return parameters

    def _get_fully_qualified_callable_name(self) -> Optional[str]:
        return self.definition.name


class AssignmentModel(Model):
    annotation: str
    target: str

    def __init__(self, annotation: str, target: str) -> None:
        if "-" in target:
            raise ValueError("The target is not supported")
        self.annotation = annotation
        self.target = target

    def __str__(self) -> str:
        return f"{self.target}: {self.annotation} = ..."

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, AssignmentModel):
            return False
        return self.target == other.target

    def __hash__(self) -> int:
        return hash(self.target)


class ClassModel(Model):
    class_name: str
    annotation: str

    def __init__(self, class_name: str, annotation: str) -> None:
        self.class_name = class_name
        self.annotation = annotation

    def __str__(self) -> str:
        return f"class {self.class_name}({self.annotation}): ..."

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, ClassModel):
            return False
        return self.class_name == other.class_name

    def __hash__(self) -> int:
        return hash(self.class_name)
