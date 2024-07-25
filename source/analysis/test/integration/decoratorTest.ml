(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_check_nested =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
             from typing import Callable, Any

             def wraps(wrapped: Callable[..., Any]) -> Callable[..., Any]: ...

             def foo(f: Callable[[int], int]) -> Callable[[int], int]:
               @wraps(f)
               def decorated(x: int) -> int:
                 return f(x)
               return decorated
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
              from typing import Callable
              def decorator(x: Callable[[int], str]) -> Callable[[str], int]: ...

              def outer() -> None:
                  @decorator
                  def inner(x: int) -> str:
                      return "A"
                  reveal_type(inner)
            |}
           ["Revealed type [-1]: Revealed type for `inner` is `typing.Callable[[str], int]`."];
    ]


let test_check_contextmanager =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.contextmanager
              def f()->typing.Iterator[int]:
                yield 1

              def g()->int:
                with f() as number:
                  return number
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.contextmanager
              def f()->typing.Iterator[int]:
                yield 1

              def g()->str:
                with f() as number:
                  return number
            |}
           ["Incompatible return type [7]: Expected `str` but got `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.contextmanager
              def f() -> typing.Iterable[int]:
                yield 1

              def g() -> int:
                with f() as number:
                  return number
            |}
           [
             (* TODO(T27138096): Iterable should have attribute `__enter__`. *)
             "Undefined attribute [16]: `typing.Iterable` has no attribute `__enter__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.contextmanager
              def f() -> typing.Generator[int, None, None]:
                yield 1

              def g() -> int:
                with f() as number:
                  return number
            |}
           [];
      (* Decorators are chained properly. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              class C:
                @contextlib.contextmanager
                def f(self) -> typing.Iterator[int]:
                  yield 1
              def foo(c: C) -> str:
                with c.f() as manager:
                  return manager
                return ""
            |}
           ["Incompatible return type [7]: Expected `str` but got `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Iterator
              from contextlib import contextmanager
              @contextmanager
              def f(x: int) -> Iterator[None]:
                yield
              f()
            |}
           ["Missing argument [20]: Call `f` expects argument `x`."];
    ]


let test_check_asynccontextmanager =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.asynccontextmanager
              async def f() -> typing.AsyncIterator[int]:
                yield 1

              async def g() -> int:
                async with f() as number:
                  return number
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.asynccontextmanager
              async def f() -> typing.AsyncIterator[int]:
                yield 1

              async def g() -> str:
                async with f() as number:
                  return number
            |}
           ["Incompatible return type [7]: Expected `str` but got `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.asynccontextmanager
              async def f() -> typing.AsyncIterable[int]:
                yield 1

              async def g() -> int:
                async with f() as number:
                  return number
            |}
           [
             (* TODO(T41786660): AsyncIterable should have attribute `__aenter__` ? *)
             "Undefined attribute [16]: `typing.AsyncIterable` has no attribute `__aenter__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              @contextlib.asynccontextmanager
              async def f() -> typing.AsyncGenerator[int, None]:
                yield 1

              async def g() -> int:
                async with f() as number:
                  return number
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import contextlib
              class C:
                @contextlib.asynccontextmanager
                async def f(self) -> typing.AsyncIterator[int]:
                  yield 1
              async def foo(c: C) -> str:
                async with c.f() as value:
                  return value
                return ""
            |}
           ["Incompatible return type [7]: Expected `str` but got `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Iterator
              from contextlib import asynccontextmanager
              @asynccontextmanager
              def f(x: int) -> Iterator[None]:
                yield
              f()
            |}
           ["Missing argument [20]: Call `f` expects argument `x`."];
    ]


let test_check_click_command =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import click
              @click.command()
              @click.option('--flag', is_flag=True, help='Test flag')
              def main(flag: bool) -> bool:
                  return flag

              reveal_type(main)

              main()
            |}
           ["Revealed type [-1]: Revealed type for `test.main` is `click.core.Command`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import click
              @click.command()
              @click.argument('filename')
              def main(filename: str) -> str:
                  return filename

              main()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              import click
              def common_params(
                func: typing.Callable[[bool, int], int]
              ) -> typing.Callable[[bool, bool], int]:
                  @click.option('--foo', is_flag=True, help='Test flag')
                  @click.option('--bar', is_flag=True, help='Another test flag')
                  def wrapper(foo: bool, bar: bool) -> int:
                      bar_int = 1 if bar else 2
                      return func(foo, bar_int)
                  return wrapper

              @click.command()
              @common_params
              def main(foo: bool, bar: int) -> int:
                  return bar if foo else 0

              main()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import click

              @click.group()
              @click.pass_context
              def main(ctx: click.Context) -> None:
                  pass

              @main.command()
              @click.pass_context
              def run(ctx: click.Context, x: int) -> None:
                  pass

              @main.command()
              @click.pass_obj
              def run2(ctx: click.Context) -> None:
                  pass


              reveal_type(main)
              reveal_type(run)
              reveal_type(run2)

              # Pyre should not raise any errors on the arguments with the presence of the click decorators
              main()
              main(obj={})
              run(1)
              run(x=1)
              run2()
            |}
           [
             "Revealed type [-1]: Revealed type for `test.main` is `click.core.Group`.";
             "Revealed type [-1]: Revealed type for `test.run` is `click.core.Command`.";
             "Revealed type [-1]: Revealed type for `test.run2` is `click.core.Command`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import click
              import typing
              import contextlib

              @click.command()
              @contextlib.contextmanager
              def f() -> typing.Generator[int, None, None]:
                yield 1
              def g() -> None:
                reveal_type(f)
            |}
           ["Revealed type [-1]: Revealed type for `test.f` is `click.core.Command`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              def main(flag: bool) -> bool:
                  return flag

              main()
            |}
           ["Missing argument [20]: Call `main` expects argument `flag`."];
    ]


let test_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Optional
              def overloaded() -> Optional[int]:
                pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              @typing.overload
              def overloaded() -> int:
                pass
            |}
           [
             "Incompatible overload [43]: At least two overload signatures must be present.";
             "Missing overload implementation [42]: Overloaded function `overloaded` must have an \
              implementation.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import overload
              @overload
              def overloaded() -> int:
                pass
            |}
           [
             "Incompatible overload [43]: At least two overload signatures must be present.";
             "Missing overload implementation [42]: Overloaded function `overloaded` must have an \
              implementation.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Derp:
                @property
                async def get_int(self) -> int:
                  return 5

                def test(self) -> int:
                  x = await self.get_int
                  return x
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable
              def my_decorator(f: Callable[[int], int]) -> Callable[[int], int]:
                return f
              @my_decorator
              def f(x: int) -> int:
                return x
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              @my_decorator
              def f(x: int) -> int:
                return x
            |}
           [
             "Invalid decoration [56]: Pyre was not able to infer the type of the decorator \
              `my_decorator`.";
             "Unbound name [10]: Name `my_decorator` is used but not defined in the current scope.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any
              def my_decorator(x: int) -> Any: ...
              @my_decorator(1)
              def f(x: int) -> int:
                return x
              reveal_type(f)
            |}
           [
             "Missing return annotation [3]: Return type must be specified as type other than `Any`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any
              def my_decorator(x: int) -> Any: ...
              @my_decorator(1 + "foo")
              def f(x: int) -> int:
                return x
            |}
           [
             "Missing return annotation [3]: Return type must be specified as type other than `Any`.";
             "Invalid decoration [56]: Pyre was not able to infer the type of argument `1 + \
              \"foo\"` to decorator factory `test.my_decorator`.";
             "Unsupported operand [58]: `+` is not supported for operand types `int` and `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import overload, Callable
              @overload
              def overloaded_decorator(f: Callable[[int], int]) -> Callable[[str], int]: ...
              @overload
              def overloaded_decorator(f: Callable[[int], str]) -> Callable[[bool], float]: ...
              def overloaded_decorator(f: object) -> object: ...

              @overloaded_decorator
              def foo(x: int) -> int:
                return x

              @overloaded_decorator
              def bar(x: int) -> str:
                return "A"

              reveal_type(foo)
              reveal_type(bar)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[str], int]`.";
             "Revealed type [-1]: Revealed type for `test.bar` is `typing.Callable[[bool], float]`.";
           ];
    ]


let test_check_user_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              def decorate(f: typing.Callable[[int], str]) -> typing.Callable[[str], int]:
                ...
              @decorate
              def f(x: int) -> str:
                return str(x)
              reveal_type(f)
            |}
           ["Revealed type [-1]: Revealed type for `test.f` is `typing.Callable[[str], int]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              meta_type = typing.Callable[[typing.Callable[[int], str]], typing.Callable[[str], str]]
              def meta_decorate(f: typing.Any) -> meta_type:
                ...
              @meta_decorate
              def decorate(f: typing.Callable[[int], str]) -> typing.Callable[[str], int]:
                ...

              @decorate
              def f(x: int) -> str:
                return str(x)
              reveal_type(f)
            |}
           [
             "Missing parameter annotation [2]: Parameter `f` must have a type other than `Any`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Callable[[str], str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")

              # lets AstLintRule ignore these no_op implementations
              def decorate(f: typing.Callable[['C', T], None]) -> typing.Callable[['C', T], None]:
                ...

              class C:
                @decorate
                def f(self, x: int) -> None: # registered type is typing.Callable[[C, int], None]
                  pass

              class D(C):
                @typing.override
                def f(self, y: int) -> None:
                  pass
              reveal_type(C.f)
              reveal_type(D.f)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.C.f` is `typing.Callable[[C, int], None]`.";
             "Revealed type [-1]: Revealed type for `test.D.f` is \
              `typing.Callable(D.f)[[Named(self, D), Named(y, int)], None]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              def synchronize(
                coroutine: typing.Callable[..., typing.Coroutine[typing.Any, typing.Any, T]]
              ) -> typing.Callable[..., T]: ...

              @synchronize
              async def am_i_async(x: int) -> str:
                return str(x)

              reveal_type(am_i_async)
            |}
           [
             "Missing parameter annotation [2]: Parameter `coroutine` must have a type that does \
              not contain `Any`.";
             "Revealed type [-1]: Revealed type for `test.am_i_async` is `typing.Callable[..., \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable
              def not_a_decorator(x: int) -> str: ...

              @not_a_decorator
              def function_returning_callable() -> Callable[[int], str]:
               ...

              reveal_type(function_returning_callable)
            |}
           [
             "Invalid decoration [56]: While applying decorator `test.not_a_decorator`: In call \
              `test.not_a_decorator`, for 1st positional argument, expected `int` but got \
              `typing.Callable(test.function_returning_callable)[[], typing.Callable[[int], \
              str]]`.";
             "Revealed type [-1]: Revealed type for `test.function_returning_callable` is \
              `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable
              def happens_to_return_a_match(f: object) -> Callable[[int], str]:
                def inner(x: int, /) -> str:
                 return "A"
                return inner

              @happens_to_return_a_match
              def foo(x: int, /) -> str:
                return "B"

              reveal_type(foo)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable(foo)[[int], \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           ~other_sources:
             [
               { handle = "indirect.py"; source = "from actual import decorator as indirected" };
               {
                 handle = "actual.py";
                 source =
                   {|
                      def decorator(x: object) -> int:
                        return 42
                    |};
               };
             ]
           {|
              import indirect
              @indirect.indirected
              def foo() -> str:
                return "B"

              reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `int`."];
      (* Avoid infinite looping *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              @bar
              def foo() -> None:
                pass
              @foo
              def bar() -> None:
                pass
              reveal_type(foo)
              reveal_type(bar)
            |}
           [
             (* Neither of these error because the error only comes up on each others' inner
                application. Not super concerned about that, mostly just don't want to hang the type
                checker *)
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
             "Revealed type [-1]: Revealed type for `test.bar` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable
              def f(x: object) -> int:
                return 42

              local_global: Callable[[object], int] = f

              @local_global
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           ~other_sources:
             [
               {
                 handle = "other.py";
                 source =
                   {|
                      from typing import Callable
                      def f(x: object) -> int:
                        return 42

                      foreign_global: Callable[[object], int] = f
                    |};
               };
             ]
           {|
              from other import foreign_global

              @foreign_global
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class D:
                def __init__(self, x: object) -> None:
                  pass

              @D
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `D`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class H:
                def method(self, x: object) -> int:
                  return 42

              h: H = H()

              @h.method
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `int`."];
    ]


let test_check_callable_class_decorators =
  test_list
    [
      (* This should not work because that's a __call__ on the *instance* not the class. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              class synchronize:
                def __call__(
                   self,
                   coroutine: typing.Callable[..., typing.Coroutine[typing.Any, typing.Any, T]]
                ) -> typing.Callable[..., T]: ...

              @synchronize
              async def am_i_async(x: int) -> str:
                return str(x)
              reveal_type(am_i_async)
            |}
           [
             "Missing parameter annotation [2]: Parameter `coroutine` must have a type that does \
              not contain `Any`.";
             "Invalid decoration [56]: While applying decorator `test.synchronize`: PositionalOnly \
              call expects 0 positional arguments, 1 was provided.";
             "Revealed type [-1]: Revealed type for `test.am_i_async` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              R = typing.TypeVar("R")
              P = typing.ParamSpec("P")
              def my_decorator(f: typing.Callable[P, R]) -> typing.Callable[P, R]: ...

              @my_decorator
              def foo(x: T) -> T: ...
            |}
           [
             "Invalid decoration [56]: Pyre doesn't yet support decorators with ParamSpec applied \
              to generic functions Please add # pyre-ignore[56] to `test.my_decorator`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              class synchronize:
                @typing.overload
                def __call__(
                   self,
                   coroutine: typing.Callable[..., typing.Coroutine[typing.Any, typing.Any, T]]
                ) -> typing.Callable[..., T]: ...
                @typing.overload
                def __call__(self, coroutine: int) -> int: ...
                def __call__(self, coroutine: typing.Any) -> typing.Any: ...

              s: synchronize = synchronize()
              @s
              async def am_i_async(x: int) -> str:
                return str(x)
              reveal_type(am_i_async)
            |}
           [
             "Missing parameter annotation [2]: Parameter `coroutine` must have a type other than \
              `Any`.";
             "Missing return annotation [3]: Return type must be specified as type other than \
              `Any`.";
             "Revealed type [-1]: Revealed type for `test.am_i_async` is `typing.Callable[..., \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              class synchronize:
                @typing.overload
                def __call__(
                   self,
                   coroutine: typing.Callable[..., typing.Coroutine[typing.Any, typing.Any, T]]
                ) -> typing.Callable[..., T]: ...
                @typing.overload
                def __call__(self, coroutine: int) -> int: ...
                def __call__(self, coroutine: typing.Any) -> typing.Any: ...

              @synchronize()
              async def am_i_async(x: int) -> str:
                return str(x)
              reveal_type(am_i_async)
            |}
           [
             "Missing parameter annotation [2]: Parameter `coroutine` must have a type other than \
              `Any`.";
             "Missing return annotation [3]: Return type must be specified as type other than \
              `Any`.";
             "Revealed type [-1]: Revealed type for `test.am_i_async` is `typing.Callable[..., \
              str]`.";
           ];
      (* accessing metaclass methods via the class *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              T = typing.TypeVar("T")
              class m:
                def __call__(
                   self,
                   coroutine: typing.Callable[..., typing.Coroutine[typing.Any, typing.Any, T]]
                ) -> typing.Callable[..., T]: ...

              class synchronize(metaclass=m):
                pass

              @synchronize
              async def am_i_async(x: int) -> str:
                return str(x)
              reveal_type(am_i_async)
            |}
           [
             "Missing parameter annotation [2]: Parameter `coroutine` must have a type that does \
              not contain `Any`.";
             "Revealed type [-1]: Revealed type for `test.am_i_async` is `typing.Callable[..., \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class H:
                def __call__(self, x: object) -> int:
                  return 42

              h: H = H()

              @h
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Meta(type):
                def __call__(self, x: object) -> str:
                  return "lol"

              class H(metaclass=Meta):
                @classmethod
                def __call__(self, x: object) -> int:
                  return 42

              @H
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `str`."];
    ]


let test_decorator_factories =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory() -> Callable[[Callable[[str], int]], Callable[[], str]]:
                 def decorator(func: Callable[[str], int]) -> Callable[[], str]:
                     def inner() -> str:
                         return str(func("foo"))
                     return inner
                 return decorator

             @decorator_factory()
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], str]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(name: str) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             @decorator_factory("literal")
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], str]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(name: str) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             @decorator_factory(f"{1+2}")
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], str]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(name: str) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             @decorator_factory(name="literal")
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], str]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(index: int) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             @decorator_factory(3 + 4)
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           [
             "Invalid decoration [56]: Pyre was not able to infer the type of argument `3 + 4` to \
              decorator factory `test.decorator_factory`.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(index: int) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             global_value = 3

             @decorator_factory(global_value)
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], str]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable, overload

             @overload
             def decorator_factory(x: int) -> Callable[[object], Callable[[], int]]: ...
             @overload
             def decorator_factory(x: str) -> Callable[[object], Callable[[], str]]: ...
             def decorator_factory(x: object) -> Callable[[object], Callable[[], object]]: ...

             @decorator_factory(1)
             def foo(name: str) -> int:
                 return len(name)

             @decorator_factory("A")
             def bar(name: str) -> int:
                 return len(name)

             reveal_type(foo)
             reveal_type(bar)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[], int]`.";
             "Revealed type [-1]: Revealed type for `test.bar` is `typing.Callable[[], str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable, overload
              import enum

              class StringEnum(enum.Enum, str):
                pass

              class Foo(StringEnum):
                A = "A"

              class Bar(StringEnum):
                A = "BarA"

              @overload
              def decorator_factory(e: Foo) -> Callable[[object], int]: ...
              @overload
              def decorator_factory(e: Bar) -> Callable[[object], str]: ...

              @decorator_factory(Foo.A)
              def f(x: str) -> bool:
                return True

              @decorator_factory(Bar.A)
              def g(x: str) -> bool:
                return True

              reveal_type(f)
              reveal_type(g)
            |}
           [
             "Missing overload implementation [42]: Overloaded function `decorator_factory` must \
              have an implementation.";
             "Revealed type [-1]: Revealed type for `test.f` is `int`.";
             "Revealed type [-1]: Revealed type for `test.g` is `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           ~other_sources:
             [
               {
                 handle = "second.py";
                 source =
                   {|
                        import enum

                        class StringEnum(enum.Enum, str):
                          pass

                        class Foo(StringEnum):
                          A = "A"
                    |};
               };
               {
                 handle = "other.py";
                 source = {|
                      from second import Foo
                    |};
               };
             ]
           {|
              from typing import Callable, TypeVar
              from other import Foo

              T = TypeVar("T")

              def df(x: T) -> Callable[[object], T]: ...

              @df(Foo.A)
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.bar` is \
              `typing_extensions.Literal[second.Foo.A]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable, TypeVar

              class C:
                def __call__(self, x: object) -> str:
                  return "lol"

              def df() -> C:
                return C()

              @df()
              def bar() -> None:
                pass

              reveal_type(bar)
            |}
           ["Revealed type [-1]: Revealed type for `test.bar` is `str`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              not_a_factory: int = 42

              @not_a_factory(1, 2)
              def foo(x: int) -> None:
                pass

              reveal_type(foo)
            |}
           [
             "Invalid decoration [56]: Decorator factory `not_a_factory` could not be called, \
              because its type `int` is not callable.";
             "Call error [29]: `int` is not a function.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any

              maybe_a_factory: Any

              @maybe_a_factory(1, 2)
              def foo(x: int) -> None:
                pass

              reveal_type(foo)
            |}
           [
             "Missing global annotation [5]: Globally accessible variable `maybe_a_factory` must \
              be specified as type other than `Any`.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def decorator_factory(name: str) -> Callable[[Callable[[str], int]], Callable[[], str]]: ...

             @decorator_factory(42)
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           [
             "Invalid decoration [56]: While applying decorator factory `test.decorator_factory`: \
              In call `test.decorator_factory`, for 1st positional argument, expected `str` but \
              got `int`.";
             "Incompatible parameter type [6]: In call `decorator_factory`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable, List, TypeVar
              T = TypeVar('T')
              class IntList(List[int]): ...
              class StrList(List[str]): ...

              def decorator_factory(x: List[T]) -> Callable[[Callable[[str], T]], Callable[[], T]]: ...

              @decorator_factory(x=IntList())
              def foo_a(x: str) -> str:
                  return ""

              @decorator_factory(x=StrList())
              def foo_b(x: int) -> int:
                  return 1
            |}
           [
             "Invalid decoration [56]: While applying decorator `test.decorator_factory(...)`: In \
              anonymous call, for 1st positional argument, expected `typing.Callable[[str], int]` \
              but got `typing.Callable(test.foo_a)[[Named(x, str)], str]`.";
             "Invalid decoration [56]: While applying decorator `test.decorator_factory(...)`: In \
              anonymous call, for 1st positional argument, expected `typing.Callable[[str], str]` \
              but got `typing.Callable(test.foo_b)[[Named(x, int)], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
                from typing import Callable, List

                def expand(input: List[float]) -> Callable[[Callable[[int], int]], Callable[[int], str]]:
                    ...

                @expand([1, 2])
                def test_foo(x: int) -> int:
                    return x
                reveal_type(test_foo)

                @expand([])
                def test_bar(x: int) -> int:
                  return x
                reveal_type(test_bar)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.test_foo` is `typing.Callable[[int], \
              str]`.";
             "Revealed type [-1]: Revealed type for `test.test_bar` is `typing.Callable[[int], \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable, Tuple, Optional

             def factory(x: Tuple[int, Optional[str]]) -> Callable[[Callable[[], None]], int]: ...

             @factory((1, None))
             def bar() -> None: ...
            |}
           [];
    ]


let test_general_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def to_int(x: object) -> int: ...

             @to_int
             def foo(name: str) -> int:
                 return len(name)

             reveal_type(foo)
            |}
           ["Revealed type [-1]: Revealed type for `test.foo` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
             from typing import Callable

             def to_int(x: object) -> int: ...

             class H:
               @to_int
               def foo(name: str) -> int:
                     return len(name)

             def f() -> None:
               a = H.foo
               reveal_type(a)
               b = H().foo
               reveal_type(b)
            |}
           [
             "Revealed type [-1]: Revealed type for `a` is `int`.";
             "Revealed type [-1]: Revealed type for `b` is `int`.";
           ];
    ]


let test_invalid_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            @dec
            def foo() -> None:
              pass
            reveal_type(foo)

            |}
           [
             "Invalid decoration [56]: Pyre was not able to infer the type of the decorator `dec`.";
             "Unbound name [10]: Name `dec` is used but not defined in the current scope.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            from typing import overload

            @overload
            @dec
            def bar(x: int) -> int: ...

            @overload
            @dec
            def bar(x: str) -> str: ...

            # pyre-ignore[56] we locate the error on the implementation if it exists
            @dec
            def bar(x: object) -> object:
              return x

            reveal_type(bar)

            |}
           [
             "Unbound name [10]: Name `dec` is used but not defined in the current scope.";
             "Revealed type [-1]: Revealed type for `test.bar` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            from typing import overload

            @overload
            # pyre-ignore[56] if there is no overload, we locate it on the top overload
            @dec
            def baz(x: int) -> int: ...

            @overload
            @dec
            def baz(x: str) -> str: ...

            reveal_type(baz)

            |}
           [
             "Unbound name [10]: Name `dec` is used but not defined in the current scope.";
             "Missing overload implementation [42]: Overloaded function `baz` must have an \
              implementation.";
             "Revealed type [-1]: Revealed type for `test.baz` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any
              def my_decorator(x: int) -> int:
                return x
              @my_decorator(1)
              def f(x: int) -> int:
                return x
              reveal_type(f)
            |}
           [
             "Invalid decoration [56]: Decorator `test.my_decorator(...)` could not be called, \
              because its type `int` is not callable.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
           ];
    ]


let test_six_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           ~other_sources:
             [
               {
                 handle = "six.py";
                 source =
                   {|
                        def add_metaclass(cls: object) -> object: ...
                    |};
               };
             ]
           {|
              import six

              class MetaMake(type):
                def __getattr__(cls, key: str) -> str: ...

              @six.add_metaclass(MetaMake)
              class Make(object):
                existent: int = 1

              def foo() -> None:
                y = Make.existent
                reveal_type(y)

                z = Make.non_existent
                reveal_type(z)
            |}
           [
             "Revealed type [-1]: Revealed type for `y` is `int`.";
             "Revealed type [-1]: Revealed type for `z` is `str`.";
           ];
    ]


let test_loosely_typed_decorators =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any

              def my_decorator() -> Any: ...

              @my_decorator()
              def f(x: int) -> int: ...

              reveal_type(f)
            |}
           [
             "Missing return annotation [3]: Return type must be specified as type other than `Any`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable

              def my_decorator(x: int) -> Callable[[Callable[[int], int]], Callable[[int], int]]: ...

              @my_decorator(1 + "foo")
              def f(x: int) -> int: ...

              reveal_type(f)
            |}
           [
             "Invalid decoration [56]: Pyre was not able to infer the type of argument `1 + \
              \"foo\"` to decorator factory `test.my_decorator`.";
             "Unsupported operand [58]: `+` is not supported for operand types `int` and `str`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable

              def my_decorator() -> Callable: ...

              @my_decorator()
              def f(x: int) -> int: ...

              reveal_type(f)
            |}
           [
             "Invalid type parameters [24]: Generic type `Callable` expects 2 type parameters.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable, TypeVar

              F = TypeVar("F")

              def my_decorator() -> Callable[[F], F]: ...

              @my_decorator()
              def f(x: int) -> int: ...

              def undecorated(x: int) -> int: ...

              reveal_type(my_decorator())
              reveal_type(my_decorator()(undecorated))
              reveal_type(f)
            |}
           [
             "Invalid type variable [34]: The type variable `Variable[F]` isn't present in the \
              function's parameters.";
             "Revealed type [-1]: Revealed type for `test.my_decorator()` is \
              `typing.Callable[[Variable[F]], Variable[F]]`.";
             "Revealed type [-1]: Revealed type for `test.my_decorator()(test.undecorated)` is \
              `typing.Callable(undecorated)[[Named(x, int)], int]`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Callable(f)[[Named(x, \
              int)], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable

              LooselyTypedCallable = Callable[..., int]

              def my_decorator() -> Callable[[LooselyTypedCallable], LooselyTypedCallable]: ...

              @my_decorator()
              def f(x: int) -> int: ...

              reveal_type(f)
            |}
           ["Revealed type [-1]: Revealed type for `test.f` is `typing.Callable[..., int]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any, Callable

              LooselyTypedCallable = Callable[..., int]

              def good_decorator() -> Callable[
                [Callable[[int], int]],
                Callable[[int], int]
              ]: ...

              def bad_decorator() -> Any: ...

              @bad_decorator()
              @good_decorator()
              def f(x: int) -> int: ...

              @good_decorator()
              @bad_decorator()
              def g(x: int) -> int: ...

              reveal_type(f)
              reveal_type(g)
            |}
           [
             "Missing return annotation [3]: Return type must be specified as type other than `Any`.";
             "Revealed type [-1]: Revealed type for `test.f` is `typing.Any`.";
             "Revealed type [-1]: Revealed type for `test.g` is `typing.Callable[[int], int]`.";
           ];
    ]


let test_classmethod_decorator =
  test_list
    [
      (* Ensure that a decorated classmethod preserves its callable name. That way, error messages
         show the name of the function being called instead of "anonymous call". *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Callable
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(func: Callable[P, T]) -> Callable[P, T]: ...

              class Foo:
                  @classmethod
                  @my_decorator
                  def some_classmethod(cls, x: str) -> None: ...

                  @my_decorator
                  def some_method(self, x: str) -> None: ...

              async def main() -> None:
                  Foo.some_classmethod(42)
                  Foo().some_method(42)
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.some_classmethod`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Incompatible parameter type [6]: In call `Foo.some_method`, for 1st positional \
              argument, expected `str` but got `int`.";
           ];
      (* The decorator here changes the signature to accept a positional `Type[Foo]`. So, we don't
         preserve the callable name. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Type, Callable, Concatenate
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(
                func: Callable[Concatenate[Type[Foo], P], T]
              ) -> Callable[Concatenate[Type[Foo], P], T]: ...

              class Foo:
                  @classmethod
                  @my_decorator
                  def some_classmethod(cls, x: str) -> None: ...

              async def main() -> None:
                  y = Foo.some_classmethod(42)
                  reveal_type(Foo.some_classmethod)
            |}
           [
             "Incompatible parameter type [6]: In anonymous call, for 1st positional argument, \
              expected `str` but got `int`.";
             "Revealed type [-1]: Revealed type for `test.Foo.some_classmethod` is \
              `typing.ClassMethod[typing.Callable[[Type[Foo], Named(x, str)], None]]` (inferred: \
              `BoundMethod[typing.Callable[[Type[Foo], Named(x, str)], None], Type[Foo]]`).";
           ];
      (* The decorator here changes the signature, so we don't preserve the callable name. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Type, Callable, Concatenate
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(
                func: Callable[Concatenate[Type[Foo], int, P], T]
              ) -> Callable[Concatenate[Type[Foo], P], T]: ...

              class Foo:
                  @classmethod
                  @my_decorator
                  def some_classmethod(cls, y: int, x: str) -> None: ...

              async def main() -> None:
                  Foo.some_classmethod(42)
                  reveal_type(Foo.some_classmethod)
            |}
           [
             "Incompatible parameter type [6]: In anonymous call, for 1st positional argument, \
              expected `str` but got `int`.";
             "Revealed type [-1]: Revealed type for `test.Foo.some_classmethod` is \
              `typing.ClassMethod[typing.Callable[[Type[Foo], Named(x, str)], None]]` (inferred: \
              `BoundMethod[typing.Callable[[Type[Foo], Named(x, str)], None], Type[Foo]]`).";
           ];
      (* Preserve the function name if a decorator expects and preserves `Awaitable`. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Awaitable, TypeVar, Callable
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(func: Callable[P, Awaitable[T]]) -> Callable[P, Awaitable[T]]: ...

              class Foo:
                  @classmethod
                  @my_decorator
                  async def some_classmethod(cls, x: str) -> None: ...

                  @my_decorator
                  async def some_method(self, x: str) -> None: ...

              async def main() -> None:
                  await Foo.some_classmethod(42)
                  await Foo().some_method(42)
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.some_classmethod`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Incompatible parameter type [6]: In call `Foo.some_method`, for 1st positional \
              argument, expected `str` but got `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Callable, Awaitable
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              class MyDecorator:
                def __call__(
                    self, fn: Callable[P, Awaitable[T]]
                ) -> Callable[P, Awaitable[T]]: ...

              def my_decorator() -> MyDecorator: ...

              class Foo:
                @classmethod
                @my_decorator()
                async def some_classmethod(cls, x: str) -> None: ...

                @my_decorator()
                async def some_method(self, x: str) -> None: ...

              async def main() -> None:
                await Foo.some_classmethod(42)
                await Foo().some_method(42)
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.some_classmethod`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Incompatible parameter type [6]: In call `Foo.some_method`, for 1st positional \
              argument, expected `str` but got `int`.";
           ];
    ]


let test_staticmethod_decorator =
  test_list
    [
      (* Ensure that a decorated staticmethod preserves its callable name. That way, error messages
         show the name of the function being called instead of "anonymous call". *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Callable
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(func: Callable[P, T]) -> Callable[P, T]: ...

              class Foo:
                  @staticmethod
                  @my_decorator
                  def some_staticmethod(x: str) -> None: ...

                  @my_decorator
                  def some_method(self, x: str) -> None: ...

              async def main() -> None:
                  Foo.some_staticmethod(42)
                  Foo().some_method(42)
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.some_staticmethod`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Incompatible parameter type [6]: In call `Foo.some_method`, for 1st positional \
              argument, expected `str` but got `int`.";
           ];
      (* The decorator here changes the signature to accept a positional `int` instead of a named
         `y: int`. So, we don't preserve the callable name. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Type, Callable, Concatenate
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(
                func: Callable[Concatenate[int, P], T]
              ) -> Callable[Concatenate[int, P], T]: ...

              class Foo:
                  @staticmethod
                  @my_decorator
                  def some_staticmethod(y: int, x: str) -> None: ...

              async def main() -> None:
                  y = Foo.some_staticmethod(99, 99)
                  reveal_type(Foo.some_staticmethod)
            |}
           [
             "Incompatible parameter type [6]: In anonymous call, for 2nd positional argument, \
              expected `str` but got `int`.";
             "Revealed type [-1]: Revealed type for `test.Foo.some_staticmethod` is \
              `typing.StaticMethod[typing.Callable[[int, Named(x, str)], None]]` (inferred: \
              `typing.Callable[[int, Named(x, str)], None]`).";
           ];
      (* The decorator here changes the signature, so we don't preserve the callable name. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import TypeVar, Type, Callable, Concatenate
              from pyre_extensions import ParameterSpecification

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(
                func: Callable[Concatenate[int, P], T]
              ) -> Callable[P, T]: ...

              class Foo:
                  @staticmethod
                  @my_decorator
                  def some_staticmethod(y: int, x: str) -> None: ...

              async def main() -> None:
                  Foo.some_staticmethod(42)
                  reveal_type(Foo.some_staticmethod)
            |}
           [
             "Incompatible parameter type [6]: In anonymous call, for 1st positional argument, \
              expected `str` but got `int`.";
             "Revealed type [-1]: Revealed type for `test.Foo.some_staticmethod` is \
              `typing.StaticMethod[typing.Callable[[Named(x, str)], None]]` (inferred: \
              `typing.Callable[[Named(x, str)], None]`).";
           ];
    ]


let test_named_callable_against_decorator_factory =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from typing import Callable, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(self, f: Callable[P, R]) -> Callable[P, R]: ...

              def expect_my_decorator(f: MyDecorator) -> None: ...

              def some_decorator(f: Callable[P, R]) -> Callable[P, R]: ...

              def main() -> None:
                  expect_my_decorator(some_decorator)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from typing import Callable, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(self, f: Callable[P, R]) -> Callable[P, R]: ...

              def outer(name: str) -> MyDecorator:
                  def inner(f: Callable[P, R]) -> Callable[P, R]:
                    def _decorated( *args: P.args, **kwargs: P.kwargs) -> R:
                      return f( *args, **kwargs)

                    return _decorated

                  return inner
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from typing import Awaitable, Callable, Concatenate, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(
                    self, f: Callable[Concatenate[int, P], str]
                  ) -> Callable[Concatenate[int, P], str]: ...

              def foo() -> MyDecorator:
                  def decorator(
                      f: Callable[Concatenate[int, P], str]
                  ) -> Callable[Concatenate[int, P], str]: ...

                  return decorator
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from typing import Awaitable, Callable, Concatenate, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(
                    self, f: Callable[Concatenate[int, str, P], str]
                  ) -> Callable[Concatenate[int, str, P], str]: ...

              def foo() -> MyDecorator:
                  def decorator(
                      f: Callable[Concatenate[int, P], str]
                  ) -> Callable[Concatenate[int, P], str]: ...

                  return decorator
            |}
           [
             "Incompatible return type [7]: Expected `MyDecorator` but got \
              `typing.Callable($local_test?foo$decorator)[[Named(f, \
              typing.Callable[typing.Concatenate[int, test.P], str])], \
              typing.Callable[typing.Concatenate[int, test.P], str]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from pyre_extensions.type_variable_operators import Concatenate
              from typing import Awaitable, Callable, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(
                    self, f: Callable[Concatenate[int, str, P], str]
                  ) -> Callable[Concatenate[int, str, P], str]: ...

              def foo() -> MyDecorator:
                  def decorator(
                      f: Callable[Concatenate[int, P], str]
                  ) -> Callable[Concatenate[int, P], str]: ...

                  return decorator
            |}
           [
             "Incompatible return type [7]: Expected `MyDecorator` but got \
              `typing.Callable($local_test?foo$decorator)[[Named(f, \
              typing.Callable[typing.Concatenate[int, test.P], str])], \
              typing.Callable[typing.Concatenate[int, test.P], str]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ParameterSpecification
              from typing_extensions import Concatenate
              from typing import Awaitable, Callable, TypeVar, Protocol

              P = ParameterSpecification("P")
              R = TypeVar("R")

              class MyDecorator(Protocol):
                  def __call__(
                    self, f: Callable[Concatenate[int, str, P], str]
                  ) -> Callable[Concatenate[int, str, P], str]: ...

              def foo() -> MyDecorator:
                  def decorator(
                      f: Callable[Concatenate[int, P], str]
                  ) -> Callable[Concatenate[int, P], str]: ...

                  return decorator
            |}
           [
             "Incompatible return type [7]: Expected `MyDecorator` but got \
              `typing.Callable($local_test?foo$decorator)[[Named(f, \
              typing.Callable[typing.Concatenate[int, test.P], str])], \
              typing.Callable[typing.Concatenate[int, test.P], str]]`.";
           ];
    ]


let () =
  "decorator"
  >::: [
         test_check_nested;
         test_check_contextmanager;
         test_check_asynccontextmanager;
         test_check_click_command;
         test_check_user_decorators;
         test_check_callable_class_decorators;
         test_decorators;
         test_decorator_factories;
         test_general_decorators;
         test_invalid_decorators;
         test_six_decorators;
         test_loosely_typed_decorators;
         test_classmethod_decorator;
         test_staticmethod_decorator;
         test_named_callable_against_decorator_factory;
       ]
  |> Test.run
