# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# flake8: noqa

from builtins import _test_sink, _test_source
from typing import List, Tuple


def create_zipped_source() -> zip[Tuple[int, int]]:
    x: List[int] = [_test_source(), 1]
    y = [2, 3]
    return zip(x, y)


def zipped_source_access_path() -> int:
    # TODO(T134884591): False positive
    x = [_test_source(), 1]
    y = [2, 3]
    return list(zip(x, y))[1][0]


def create_zipped_source_with_all_tainted() -> zip[Tuple[int, int, int]]:
    x = [_test_source()]
    y = [_test_source()]
    z = [_test_source()]
    return zip(x, y, z)


def zipped_element_to_sink(x: int) -> None:
    l1 = [x]
    l2 = [1]

    for x, y in zip(l1, l2):
        _test_sink(x)


def zipped_element_not_flowing_to_sink(x) -> None:
    l1 = [x]
    l2 = [1]

    for x, y in zip(l1, l2):
        _test_sink(y)


class Woot:
    def taint_self(self, item):
        ...


def push_pop_no_taint() -> List[int]:
    x = []
    x.append(_test_source())
    x.pop()
    return x


def push_pop_taint() -> List[int]:
    x = []
    x.append(_test_source())
    x.append(1)
    x.pop()
    return x


def setitem() -> None:
    x = [""] * 10
    x[2] = _test_source()
    _test_sink(x[2])
    _test_sink(x[3])


def setitem_wrapper(x: List[int]) -> None:
    # TODO(T165056052): Model source on parameter
    x[0] = _test_source()


def setitem_no_wrapper(x: List[int]) -> None:
    x = []
    x[0] = _test_source()


def setitem_wrapper_issue() -> None:
    # TODO(T165056297): False Negative from the fact that we have an empty model for setitem_wrapper
    x: List[int] = []
    setitem_wrapper(x)
    _test_sink(x[0])
