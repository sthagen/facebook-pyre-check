# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from builtins import _test_sink, _test_source


def goes_to_sink(arg):
    _test_sink(arg)


def has_tito(arg):
    return arg


def higher_order_function(f, arg):
    f(arg)


def test_higher_order_function():
    higher_order_function(goes_to_sink, _test_source())


class C:
    def method_to_sink(self, arg):
        _test_sink(arg)

    def self_to_sink(self):
        _test_sink(self)


def higher_order_method(c: C, arg):
    higher_order_function(c.method_to_sink, arg)  # Expect an issue (False negative)


def test_higher_order_method():
    higher_order_method(C(), _test_source())


def test_higher_order_method_self():
    c: C = _test_source()
    higher_order_function(c.self_to_sink)


def higher_order_function_and_sink(f, arg):
    f(arg)
    _test_sink(arg)


def test_higher_order_function_and_sink():
    higher_order_function_and_sink(goes_to_sink, _test_source())


def test_higher_order_tito(x):
    # no tito because higher_order_function does not return.
    return higher_order_function(has_tito, x)


def apply(f, x):
    return f(x)


def test_apply_tito(x):
    return apply(has_tito, x)


def source_through_tito():
    x = _test_source()
    y = apply(has_tito, x)
    return y


def test_apply_source():
    return apply(_test_source, 0)


def sink_after_apply(f):
    _test_sink(f())


def test_parameterized_target_in_issue_handle():
    sink_after_apply(_test_source)


def apply_without_return(f, x) -> None:
    f(x)


def test_apply_without_return():
    apply_without_return(_test_sink, _test_source())  # Issue
    apply_without_return(str, _test_source())  # No issue


class Callable:
    def __init__(self, value):
        self.value = value

    def __call__(self):
        return


def callable_class():
    c = Callable(_test_source())
    # Even if c is a callable, we should still propagate the taint on it.
    _test_sink(c)


def sink_args(*args):
    for arg in args:
        _test_sink(arg)


def test_location(x: int, y: Callable, z: int):
    sink_args(x, y, z)


def conditional_apply(f, g, cond: bool, x: int):
    if cond:
        return f(x)
    else:
        return g(x)


def safe():
    return 0


def test_conditional_apply_forward():
    _test_sink(conditional_apply(_test_source, safe, True, 0))
    # TODO(T136838558): Handle conditional higher order functions.
    _test_sink(conditional_apply(_test_source, safe, False, 0))
    # TODO(T136838558): Handle conditional higher order functions.
    _test_sink(conditional_apply(safe, _test_source, True, 0))
    _test_sink(conditional_apply(safe, _test_source, False, 0))


def test_conditional_apply_backward(x):
    conditional_apply(_test_sink, safe, True, x)
    # TODO(T136838558): Handle conditional higher order functions.
    conditional_apply(_test_sink, safe, False, x)
    # TODO(T136838558): Handle conditional higher order functions.
    conditional_apply(safe, _test_sink, True, x)
    conditional_apply(safe, _test_sink, False, x)


class CallableSource:
    def __init__(self):
        pass

    def __call__(self) -> str:
        return _test_source()


def test_callable_class_to_obscure():
    def obscure_tito(x): ...

    c = CallableSource()
    return obscure_tito(c)  # Expecting taint since obscure_tito could call the callable


def test_callable_class_to_perfect_tito():
    def perfect_tito(x: CallableSource) -> CallableSource:
        return x

    c = CallableSource()
    return perfect_tito(c)  # Expecting no taint since we see the body of perfect_tito


def test_duplicate_issues_in_different_parameterized_callables(f, flag: bool):
    def sink_wrapper(f, arg):
        _test_sink(arg)

    def foo(x: str) -> None:
        return

    def bar(x: str) -> None:
        return

    x = foo
    if flag:
        x = bar

    sink_wrapper(
        x, _test_source()
    )  # Expect one issue instead of two, due to sharing the same traces

    def sink_wrapper2(arg):
        _test_sink(arg)

    y = _test_sink
    if flag:
        y = sink_wrapper2
    apply(y, _test_source())  # Expect one issue but two sink traces


# Expect no issues due to duplicating issues with the non-parameterized root callable
test_duplicate_issues_in_different_parameterized_callables(print, _test_source())


def test_callable_default_value(f = _test_source) -> None:
    _test_sink(f())  # TODO(T225702991): False negative
