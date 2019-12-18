# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

from typing import Callable, Iterable

from .inspect_parser import extract_qualified_name
from .model import CallableModel, Model
from .model_generator import Configuration, Registry
from .view_generator import ViewGenerator


class RequestSpecificDataGenerator(ViewGenerator):
    def compute_models(
        self, functions_to_model: Iterable[Callable[..., object]]
    ) -> Iterable[Model]:
        view_models = set()
        for view_function in functions_to_model:
            qualified_name = extract_qualified_name(view_function)
            if qualified_name in Configuration.whitelisted_views:
                continue
            taint_kind = "TaintSource[RequestSpecificData]"
            try:
                model = CallableModel(
                    arg=taint_kind,
                    vararg=taint_kind,
                    kwarg=taint_kind,
                    callable_object=view_function,
                    whitelisted_parameters=Configuration.whitelisted_classes,
                )
                view_models.add(model)
            except ValueError:
                pass

        return sorted(view_models)


Registry.register(
    "get_request_specific_data", RequestSpecificDataGenerator, include_by_default=False
)
