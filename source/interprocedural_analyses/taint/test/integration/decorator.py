# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# flake8: noqa

from builtins import __test_sink, __test_source
from typing import Awaitable, Callable


def with_logging(f: Callable[[int], None]) -> Callable[[int], None]:
    def inner(x: int) -> None:
        __test_sink(x)
        f(x)

    return inner


@with_logging
def foo(x: int) -> None:
    print(x)


def with_logging_no_sink(f: Callable[[int], None]) -> Callable[[int], None]:
    def inner(x: int) -> None:
        f(x)

    return inner


@with_logging_no_sink
def foo_with_sink(x: int) -> None:
    __test_sink(x)
    print(x)


def with_logging_async(
    f: Callable[[str], Awaitable[None]]
) -> Callable[[str], Awaitable[None]]:
    async def inner(y: str) -> None:
        try:
            result = await f(y)
        except Exception:
            __test_sink(y)

    return inner


@with_logging_async
async def foo_async(x: str) -> None:
    print(x)


def main() -> None:
    foo(__test_source())
    foo_with_sink(__test_source())
    await foo_async(__test_source())
