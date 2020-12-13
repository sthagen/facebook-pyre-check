# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from functools import lru_cache


def foo(x):
    return 0


def barfoo(x):
    return 0


class C:
    def foo(self, x):
        return 0

    def positional_method(self, x):
        return 0


def two_parameters(x, y):
    return 0


def three_parameters(x, y, z):
    return 0


def positional_a(x):
    return 0


def positional_b(y):
    return 0


class Base:
    def foo(self, x):
        return 0


class NotBase:
    def foo(self, x):
        return 0


class Child(Base):
    def bar(self, y):
        return 0


class GrandChild(Child):
    def baz(self, z):
        return 0


@lru_cache(maxsize=1)
def positional_decorated(x, y) -> int:
    ...
