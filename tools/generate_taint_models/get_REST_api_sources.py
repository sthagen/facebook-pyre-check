# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict


from typing import Callable, Iterable, List, Optional

from .function_tainter import taint_functions
from .model import Model
from .model_generator import Configuration, ModelGenerator, Registry
from .view_generator import DjangoUrls, django_urls_from_configuration, get_all_views


class RESTApiSourceGenerator(ModelGenerator):
    def __init__(
        self,
        django_urls: Optional[DjangoUrls] = None,
        whitelisted_classes: Optional[List[str]] = None,
        whitelisted_views: Optional[List[str]] = None,
        taint_annotation: str = "TaintSource[UserControlled]",
    ) -> None:
        self.whitelisted_classes: List[str] = (
            whitelisted_classes or Configuration.whitelisted_classes
        )
        self.django_urls: Optional[
            DjangoUrls
        ] = django_urls or django_urls_from_configuration()
        self.whitelisted_views: List[
            str
        ] = whitelisted_views or Configuration.whitelisted_views
        self.taint_annotation = taint_annotation

    def gather_functions_to_model(self) -> Iterable[Callable[..., object]]:
        django_urls = self.django_urls
        if django_urls is None:
            return []
        return get_all_views(django_urls)

    def compute_models(
        self, functions_to_model: Iterable[Callable[..., object]]
    ) -> Iterable[Model]:
        return taint_functions(
            functions_to_model,
            whitelisted_classes=self.whitelisted_classes,
            whitelisted_views=self.whitelisted_views,
            taint_annotation=self.taint_annotation,
        )


Registry.register(
    "get_REST_api_sources", RESTApiSourceGenerator, include_by_default=True
)
