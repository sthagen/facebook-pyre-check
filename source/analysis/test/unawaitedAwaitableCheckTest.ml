(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Analysis
open Test

let assert_awaitable_errors ~context =
  let check ~environment ~source =
    UnawaitedAwaitableCheck.check_module_TESTING_ONLY
      ~type_environment:(TypeEnvironment.read_only environment)
      source
  in
  assert_errors ~context ~check


let test_forward context =
  let assert_awaitable_errors = assert_awaitable_errors ~context in
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      unawaited = awaitable()
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `unawaited` is never awaited."];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      await awaited
    |}
    [];

  (* Assert. *)
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      _ = await awaited
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      assert (await awaited)
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      assert awaited
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `awaited` is never awaited."];

  (* Delete. *)
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      if "moon_is_high":
        del (await awaited)
    |}
    [];

  (* Raise. *)
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[Exception]: ...
      awaited = awaitable()
      raise (await awaited)
    |}
    [];

  (* Return. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable() -> typing.Awaitable[int]:
        awaited = awaitable()
        return awaited
    |}
    [];

  (* Yield. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        yield awaited
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        yield (await awaited)
    |}
    [];

  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        yield from (await awaited)
    |}
    [];

  (* Tuples. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        yield (await awaited, 3)
    |}
    [];

  (* Any is not an awaitable. *)
  assert_awaitable_errors
    {|
    from typing import Any
    def returns_any() -> Any: ...
    async def foo() -> None:
      x = returns_any()
      return
    |}
    [];
  assert_awaitable_errors
    {|
    from typing import Any
    async def foo(param: Any) -> None:
      return
    |}
    [];

  (* Boolean operators. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        await awaited or Exception("You must await.")
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        awaited = awaitable()
        1 and (2 and (await awaited))
    |}
    [];

  (* We view parameters which flow into a call as having been awaited. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def takes_awaitable(x: typing.Awaitable[int]): ...
      def meta_awaitable():
        awaited = awaitable()
        await takes_awaitable(awaited)
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def takes_awaitable(x: typing.Awaitable[int]): ...
      def meta_awaitable():
        await takes_awaitable(awaitable())
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def takes_awaitable(x: typing.Awaitable[int]): ...
      def meta_awaitable():
        await takes_awaitable({ "a": awaitable(), "b": awaitable()})
    |}
    [];

  (* Comparison operators. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        return (await awaited) > 2
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable() -> bool:
        awaited = awaitable()
        return 0 == (await awaited)
    |}
    [];

  (* Container literals. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        return [1, await awaited, 2]
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        return {1, await awaited, 2}
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        return {await awaited: 1, 2: 2}
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        return {"foo": [await awaited]}
    |}
    [];

  (* Lambdas. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      async def meta_awaitable():
        awaited = awaitable()
        lambda x: (await awaited) or 42
    |}
    [];

  (* Starred expressions. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[typing.Iterable[int]]: ...
      async def meta_awaitable():
        awaited = awaitable()
        [1, *(await awaited)]
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[typing.Dict[int, str]]: ...
      async def meta_awaitable():
        awaited = awaitable()
        {1: "x", **(await awaited)}
    |}
    [];

  (* Ternaries. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      1 if (await awaited) else 2
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      (await awaited) if 1 else 2
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      1 if 2 else (await awaited)
    |}
    [];

  (* Unary operators. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      -(not (await awaited))
    |}
    [];

  (* Yield. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      yield (await awaited) if 1 > 2 else False
    |}
    [];

  (* Comprehensions. *)
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      [i for i in await awaited]
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      [(await awaited) for i in [1, 2, 3]]
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      {(await awaited) for i in [1, 2, 3]}
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      {i: (await awaited) for i in [1, 2, 3]}
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      awaited = awaitable()
      ((await awaited) for i in [1, 2, 3])
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      def other_awaitable() -> typing.Awaitable[int]: ...
      unawaited = awaitable()
      other_unawaited = other_awaitable()
      if True > False:
        unawaited = other_unawaited
    |}
    [
      "Unawaited awaitable [1001]: Awaitable assigned to `unawaited` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `unawaited`, `other_unawaited` is never \
       awaited.";
    ];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      def other_awaitable() -> typing.Awaitable[int]: ...
      unawaited = awaitable()
      other_unawaited = other_awaitable()
      unawaited = other_unawaited
      await unawaited
    |}
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      def other_awaitable() -> typing.Awaitable[int]: ...
      unawaited = awaitable()
      other_unawaited = other_awaitable()
      if 1 > 2:
        unawaited = other_unawaited
      await unawaited
    |}
    [];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      def other_awaitable() -> typing.Awaitable[int]: ...
      unawaited = awaitable()
      other_unawaited = other_awaitable()
      if 1 > 2:
        unawaited = other_unawaited
      await other_unawaited
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `unawaited` is never awaited."];
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...
      def foo():
        awaitable()
    |}
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];

  (* Ensure that we don't crash when attempting to await a non-simple name. *)
  assert_awaitable_errors
    {|
      class C:
        def awaitable(self) -> typing.Awaitable[int]: ...

      def foo():
        await C().awaitable()
    |}
    [];
  assert_awaitable_errors
    {|
       async def awaitable() -> typing.Tuple[int, int]: ...
       import asyncio
       async def foo() -> int:
         a = awaitable()
         b = awaitable()
         _, c = await asyncio.gather(a, b)
    |}
    [];
  assert_awaitable_errors
    {|
       async def awaitable() -> typing.Tuple[int, int]: ...
       import asyncio
       async def foo() -> int:
         a = awaitable()
         b = awaitable()
         _, c = await asyncio.gather(a, b)
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> int: ...
      async def foo():
        a, b = awaitable(), awaitable()
        await a
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `b` is never awaited."];
  assert_awaitable_errors
    {|
      async def awaitable() -> int: ...
      async def foo():
        a, b = awaitable(), awaitable()
        await b
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `a` is never awaited."];
  assert_awaitable_errors
    {|
      async def awaitable() -> int: ...
      async def foo():
        [a, (b, [c, d], e)] = (awaitable(), (awaitable(), (awaitable(), awaitable()), awaitable()))
    |}
    [
      "Unawaited awaitable [1001]: Awaitable assigned to `a` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `b` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `c` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `d` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `e` is never awaited.";
    ];
  assert_awaitable_errors
    {|
      async def awaitable() -> int: ...
      async def foo():
        a, *b, c = awaitable(), awaitable(), awaitable()
        await a
    |}
    [
      "Unawaited awaitable [1001]: `test.awaitable()` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `c` is never awaited.";
    ];

  (* We don't validate that every expression in a starred one is awaited. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> int: ...
      async def foo():
        a, *b, c = awaitable(), awaitable(), awaitable()
        await asyncio.gather(a, c)
    |}
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];

  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable() -> typing.Tuple[typing.Awaitable[int], int]:
        awaited = awaitable()
        return awaited, 1
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      class C:
        a = awaitable()
        def await_the_awaitable(self):
          await self.a
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `test.C.a` is never awaited."];
  assert_awaitable_errors
    {|
      import typing
      class C:
        async def foo() -> typing.Awaitable[int]: ...
      def foo(c: C):
       await c.foo()
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        d = {
          awaitable(): 2,
          3: awaitable(),
        }
    |}
    [
      "Unawaited awaitable [1001]: Awaitable assigned to `d` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `d` is never awaited.";
    ];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        d = {
          awaitable(): 2,
          3: awaitable(),
        }
        await d
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        l = [1, {2: awaitable()}]
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `l` is never awaited."];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        l = [1, {2: awaitable()}]
        await l
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        l = [awaitable(), awaitable()]
        await asyncio.gather( *l)
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        l = [awaitable(), awaitable()]
        await asyncio.gather(awaitable(), *l)
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        l = [awaitable(), awaitable()]
        await asyncio.gather(l if l is not None else awaitable())
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      async def foo() -> None:
        [] + [awaitable()]
    |}
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];

  (* We don't error on methods for classes that are awaitable themselves. *)
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      class C(typing.Awaitable[int]):
        def __init__(self) -> None:
          self.x = awaitable()
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      async def awaitable() -> int: ...
      class C(typing.Awaitable[int]):
        pass
      class D(C):
        def __init__(self) -> None:
          self.x = awaitable()
    |}
    [];
  assert_awaitable_errors
    {|
      import typing
      T = TypeVar("T")
      async def awaitable() -> int: ...
      class C(typing.Awaitable[T], typing.Generic[T]):
        def __init__(self) -> None:
          self.x = awaitable()
    |}
    [];

  (* Multiple assignment targets. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        x = y = await awaitable()
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        x = y = awaitable()
        a = b = c = awaitable()
    |}
    [
      "Unawaited awaitable [1001]: Awaitable assigned to `y`, `x` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `c`, `b`, `a` is never awaited.";
    ];

  (* Walrus operator. *)
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        x = y := await awaitable()
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        x = (y := awaitable())
    |}
    (* TODO(T53600647): Mention y in the error message. *)
    ["Unawaited awaitable [1001]: Awaitable assigned to `x` is never awaited."];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        if y := await awaitable():
          pass
    |}
    [];
  assert_awaitable_errors
    {|
      async def awaitable() -> typing.Awaitable[int]: ...
      def meta_awaitable():
        if y := awaitable():
          pass
    |}
    (* TODO(T53600647): Mention y in the error message. *)
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];
  assert_awaitable_errors
    {|
      async def awaitable() -> bool: ...

      def foo():
        if awaitable():
          pass
    |}
    ["Unawaited awaitable [1001]: `test.awaitable()` is never awaited."];
  ()


let test_initial context =
  (* Technically, just defining this function will not cause a `RuntimeWarning`.

     However, calling this function *will* cause a `RuntimeWarning`.

     So, our emitting an unawaited-awaitable error in the function definition is the same as our
     emitting an incompatible-variable error for a function where we assign `x: str = 1`. As a
     static type checker, we have to be conservative. *)
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable(x: typing.Awaitable[int]) -> int:
        return 0
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `x` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable(x: typing.Awaitable[int]) -> int:
        return (await x)
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable( *x: typing.Awaitable[int]) -> int:
        return 0
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `x` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      import typing
      import asyncio
      async def awaitable( *x: typing.Awaitable[int]) -> int:
        value, *_others = asyncio.gather( *x)
        return value
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable( **x: typing.Awaitable[int]) -> int:
        return 0
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `x` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      import typing
      import asyncio
      async def awaitable( **d: typing.Awaitable[int]) -> int:
        value, *_others = await_list(d.values())
        return value
    |}
    []


let test_state context =
  assert_awaitable_errors
    ~context
    {|
      def awaitable() -> typing.Awaitable[int]: ...

      if True:
        unawaited = awaitable()
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `unawaited` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      def awaitable() -> typing.Awaitable[int]: ...

      unawaited = awaitable()
      if True:
        await unawaited
    |}
    []


let test_attribute_access context =
  assert_awaitable_errors
    ~context
    {|
      import typing
      class C(typing.Awaitable[int]):
        async def method(self) -> int: ...
      def awaitable() -> C: ...

      async def foo() -> None:
        await awaitable().method()
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      class C(typing.Awaitable[int]):
        async def method(self) -> int: ...
      def awaitable() -> C: ...

      async def foo() -> None:
        unawaited = awaitable()
        await unawaited.method()
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      class C(typing.Awaitable[int]):
        async def method(self) -> int: ...
      def awaitable() -> C: ...

      async def foo() -> None:
        unawaited = awaitable()
        unawaited.method()
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `unawaited` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      import typing
      class C(typing.Awaitable[int]):
        def method(self) -> C: ...
        async def other(self) -> int: ...
      def awaitable() -> C: ...

      async def foo() -> None:
        unawaited = awaitable()
        await unawaited.method().other()
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      class C(typing.Awaitable[int]):
        def method(self) -> C: ...
        async def other(self) -> int: ...
      def awaitable() -> C: ...

      async def foo() -> None:
        unawaited = awaitable().method()
        await unawaited.other()
    |}
    [];

  (* If we can't resolve the type of the method as being an awaitable, be unsound and assume the
     method awaits the awaitable. *)
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> None:
        await awaitable().method()
    |}
    []


let test_aliases context =
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> None:
        a = [awaitable()]
        b = [1]
        c = a + b
        await c
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> None:
        a = [awaitable()]
        b = [1]
        c = a + b
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `c`, `a` is never awaited."];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> None:
        a = [1]
        b = [awaitable()]
        c = a + b
        await c
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      from typing import Awaitable

      async def awaitable() -> int: ...

      class C:
        x: Awaitable[int] = ...

        def my_method(self) -> None:
          self.x = awaitable()
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `self.x` is never awaited."];
  ()


let test_return context =
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      def foo() -> typing.Awaitable[int]:
        return awaitable()
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      def foo() -> typing.Awaitable[int]:
        x = [awaitable()]
        y = [awaitable()]
        return (x + y)
    |}
    []


let test_assign context =
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> int:
        d = {}
        d["bar"] = awaitable()
        d["foo"] = awaitable()
    |}
    [
      "Unawaited awaitable [1001]: Awaitable assigned to `d` is never awaited.";
      "Unawaited awaitable [1001]: Awaitable assigned to `d` is never awaited.";
    ];
  assert_awaitable_errors
    ~context
    {|
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> int:
        d = {}
        d["bar"] = awaitable()
        d["foo"] = awaitable()
        await d
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      import asyncio
      import typing
      async def awaitable() -> typing.Awaitable[int]: ...
      async def foo() -> int:
        d = {}
        d["bar"] = awaitable()
        d["foo"] = "not awaitable"
        await asyncio.gather( *d.values())
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      async def foo() -> int:
        return 0
      async def bar() -> None:
        async with foo():
          return
    |}
    [];
  assert_awaitable_errors
    ~context
    {|
      async def foo() -> int:
        return 0
      async def bar() -> None:
        with foo():
          return
    |}
    ["Unawaited awaitable [1001]: `test.foo()` is never awaited."]


let test_globals context =
  assert_awaitable_errors
    ~context
    {|
      from typing import Awaitable

      MY_GLOBAL: Awaitable[int] = ...

      async def awaitable() -> Awaitable[int]: ...

      async def foo() -> int:
        MY_GLOBAL = awaitable()
    |}
    ["Unawaited awaitable [1001]: Awaitable assigned to `MY_GLOBAL` is never awaited."];
  ()


let test_if context =
  let assert_awaitable_errors = assert_awaitable_errors ~context in
  (* TODO(T79853064): This should emit an error about the awaitable sometimes not being awaited. *)
  assert_awaitable_errors
    {|
      def awaitable() -> typing.Awaitable[int]: ...

      def foo(b: bool) -> None:
        unawaited = awaitable()

        if b:
          await unawaited
    |}
    [];
  ()


let () =
  "awaitableCheck"
  >::: [
         "forward" >:: test_forward;
         "initial" >:: test_initial;
         "state" >:: test_state;
         "attribute_access" >:: test_attribute_access;
         "aliases" >:: test_aliases;
         "assign" >:: test_assign;
         "return" >:: test_return;
         "globals" >:: test_globals;
         "if" >:: test_if;
       ]
  |> Test.run
