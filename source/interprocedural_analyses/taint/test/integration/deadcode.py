# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from builtins import _test_sink, _test_source

# TODO(T182207981): Find issues in unreachable places

def early_return_no_sink(x):
    return
    _test_sink(x)


def early_return_no_source():
    x = _test_source()
    return
    return x


def early_return_no_issue():
    return
    _test_sink(_test_source())


def early_return_no_issue_if(x):
    if x:
        return
    else:
        return
    _test_sink(_test_source())


def early_return_no_issue_for_else(x):
    for _ in x:
        return
    else:
        return
    _test_sink(_test_source()) # TODO(T182089507): Handle for loop deadcode false positive


def early_return_no_issue_while():
    while True:
        return
    _test_sink(_test_source())


def early_break_no_issue_for():
    for _ in range(5):
        break
        _test_sink(_test_source())


def early_break_no_issue_while():
    while True:
        break
        _test_sink(_test_source())


def early_continue_no_issue_for():
    for _ in range(5):
        continue
        _test_sink(_test_source())


def early_raise_no_issue():
    raise RuntimeError("Error")
    _test_sink(_test_source())


class EarlyReturns():
    def __init__(self, y):
        return
        self.x = _test_source()
        _test_sink(y)


def early_return_no_issue_class():
    object = EarlyReturns(_test_source())
    _test_sink(object.x)
