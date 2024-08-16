(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_check_implementation =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            from typing import overload, Literal

            @overload
            def f(x: int, y: str | None, z: Literal[True]) -> str: ...
            @overload
            def f(x: int, y: str | None = ..., *, z: Literal[True]) -> str: ...
            def f(x: int, y: str | None = None, z: bool = True) -> str | int:
                if z:
                    return "hello"
                return 1
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload
      @overload
      def foo() -> None:
          pass

      @overload
      def foo() -> None:
          pass
    |}
           [
             "Missing overload implementation [42]: Overloaded function `foo` must have an \
              implementation.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           ~handle:"stub.pyi"
           {|
      from typing import overload
      @overload
      def foo() -> None:
          pass

      @overload
      def foo() -> None:
          pass
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload
      @overload
      def foo() -> None:
          pass

      def foo() -> None:
          pass
    |}
           ["Incompatible overload [43]: At least two overload signatures must be present."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload
      @overload
      def foo(x: int) -> bool:
          pass

      @overload
      def foo(x: object) -> int:
          pass

      def foo(x: object) -> float:
          return 1
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
         from typing import overload

         @overload
         def foo(bar: object, x: object) -> int:
             pass

         @overload
         def foo(bar: int, x: int) -> str:
             pass

         @overload
         def foo(bar: str, x: str) -> object:
             pass

         def foo(bar: object, x: object) -> object: pass
       |}
           [
             "Incompatible overload [43]: The overloaded function `foo` on line 9 will never be \
              matched. The signature `(bar: object, x: object) -> int` is the same or broader.";
             "Incompatible overload [43]: The overloaded function `foo` on line 13 will never be \
              matched. The signature `(bar: object, x: object) -> int` is the same or broader.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
         from typing import overload

         @overload
         def foo(bar: int, x: int) -> str:
             pass

         @overload
         def foo(bar: str, x: str) -> object:
             pass

         @overload
         def foo(bar: object, x: object) -> int:
             pass

         def foo(bar: object, x: object) -> object: pass
       |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
         from typing import overload

         @overload
         def foo(bar: int, x: int) -> str:
             pass

         @overload
         def foo(bar: str, x: str, y: int) -> object:
             pass

         def foo(bar: object, x: object, y:object) -> object: pass
       |}
           [
             "Incompatible overload [43]: The implementation of `foo` does not accept all possible \
              arguments of overload defined on line `5`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload
      @overload
      def foo(bar: object) -> None:
        pass
      def foo(bar: int) -> None:
        pass
    |}
           [
             "Incompatible overload [43]: The implementation of `foo` does not accept all possible \
              arguments of overload defined on line `4`.";
             "Incompatible overload [43]: At least two overload signatures must be present.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload
      @overload
      def foo() -> None:
        pass
      def foo(bar: int) -> None:
        pass
    |}
           [
             "Incompatible overload [43]: The implementation of `foo` does not accept all possible \
              arguments of overload defined on line `4`.";
             "Incompatible overload [43]: At least two overload signatures must be present.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload

      @overload
      def f( **kwargs:int) -> int:
          pass

      def f( *args: int, **kwargs: int) -> int:
          return 1
    |}
           ["Incompatible overload [43]: At least two overload signatures must be present."];
      (* TODO(T65594835) Pyre should accept this, but does not recognize that if named-only
         arguments appear with default values in the implementation, any of the named arguments
         appearing in an overload is compatible. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Optional

      @overload
      def f(*, a: int) -> int: ...

      def f(*, b: Optional[int] = None, a: Optional[int] = None) -> int:
          return 5
    |}
           [
             "Incompatible overload [43]: The implementation of `f` does not accept all possible \
              arguments of overload defined on line `5`.";
             "Incompatible overload [43]: At least two overload signatures must be present.";
           ];
      (* TODO(T65594835) Pyre should accept this, but does not recognize that a `**kwargs: Any` in
         the implementation is compatible with any named-argument overload *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Any, overload

      @overload
      def f(*, a: int) -> int: ...

      def f(**kwargs: Any) -> int:
          return 5
    |}
           [
             "Incompatible overload [43]: The implementation of `f` does not accept all possible \
              arguments of overload defined on line `5`.";
             "Incompatible overload [43]: At least two overload signatures must be present.";
           ];
    ]


let test_check_inferred_return_type =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Union
      from typing_extensions import Literal

      @overload
      def g( *, make_int: Literal[True]) -> int: ...
      @overload
      def g( *, make_int: bool = ...) -> bool: ...

      def g(make_int: bool = ...) -> Union[int, bool]: ...

      some_bool: bool
      x1: bool = g()
      x2: bool = g(make_int=some_bool)
      x3: bool = g(make_int=False)
      x4: int = g(make_int=True)
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Union
      from typing_extensions import Literal

      @overload
      def g( *, make_int: Literal[True], make_int2: bool = ...) -> int: ...
      @overload
      def g( *, make_int: bool = ..., make_int2: Literal[True]) -> int: ...
      @overload
      def g( *, make_int: bool = ..., make_int2: bool = ...) -> bool: ...

      def g(make_int: bool = ..., make_int2: bool = ...) -> Union[int, bool]: ...

      some_bool: bool
      x1: bool = g()
      x2: int = g(make_int=True)
      x3: bool = g(make_int=False)
      x4: bool = g(make_int=some_bool)
      x5: int = g(make_int2=True)
      x6: bool = g(make_int2=False)
      x7: bool = g(make_int2=some_bool)
      x8: int = g(make_int=True, make_int2=True)
      x9: int = g(make_int=True, make_int2=False)
      x10: int = g(make_int=True, make_int2=some_bool)
      x11: int = g(make_int=False, make_int2=True)
      x12: bool = g(make_int=False, make_int2=False)
      x13: bool = g(make_int=False, make_int2=some_bool)
      x14: int = g(make_int=some_bool, make_int2=True)
      x15: bool = g(make_int=some_bool, make_int2=False)
      x16: bool = g(make_int=some_bool, make_int2=some_bool)
    |}
           [];
    ]


let test_check_decorated_overloads =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Callable
      def decorator(x: object) -> Callable[[int], int]: ...

      @overload
      @decorator
      def foo(a: str) -> str: ...

      @overload
      @decorator
      def foo(a: bool) -> bool: ...

      @decorator
      def foo(a: object) -> int:
        return 1

      reveal_type(foo)
    |}
           [
             "Incompatible overload [43]: The return type of overloaded function `foo` (`str`) is \
              incompatible with the return type of the implementation (`int`).";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[int], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Callable
      def decoratorA(x: object) -> Callable[[int], int]: ...
      def decoratorB(x: object) -> Callable[[int], int]: ...

      @overload
      @decoratorA
      def foo(a: str) -> str: ...

      @overload
      @decoratorB
      def foo(a: bool) -> bool: ...

      @decoratorB
      def foo(a: object) -> object:
        return 1

      reveal_type(foo)
    |}
           [
             "Incompatible overload [43]: This definition does not have the same decorators as the \
              preceding overload(s).";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Callable
      def decorator(x: object) -> Callable[[int], int]: ...

      @decorator
      @overload
      def foo(a: str) -> str: ...

      @overload
      @decorator
      def foo(a: bool) -> bool: ...

      @decorator
      def foo(a: object) -> object:
        return 1

      reveal_type(foo)
    |}
           [
             "Incompatible overload [43]: The @overload decorator must be the topmost decorator if \
              present.";
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[int], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Callable, TypeVar

      TReturn = TypeVar("TReturn")

      def decorator(f: Callable[[str], TReturn]) -> Callable[[int], TReturn]: ...

      @overload
      @decorator
      def foo(a: bool) -> int: ...

      @overload
      @decorator
      def foo(a: str) -> bool: ...

      @overload
      @decorator
      def foo(a: int) -> str: ...

      @decorator
      def foo(a: object) -> object: ...

      reveal_type(foo)
    |}
           [
             (* We "select" the relevant overload *)
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[int], bool]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import overload, Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      TParams = ParameterSpecification("TParams")
      TReturn = TypeVar("TReturn")

      def decorator(f: Callable[TParams, TReturn]) -> Callable[TParams, TReturn]: ...

      @overload
      @decorator
      def foo(a: bool) -> int: ...

      @overload
      @decorator
      def foo(a: str) -> bool: ...

      @overload
      @decorator
      def foo(a: int) -> str: ...

      @decorator
      def foo(a: object) -> object: ...

      reveal_type(foo)
    |}
           [
             (* But when you "crack the egg" of an overloaded callable, it's not sound to assume it
                comes back together. When multiple overloads match, we select the first one *)
             "Revealed type [-1]: Revealed type for `test.foo` is `typing.Callable[[Named(a, \
              bool)], int]`.";
           ];
    ]


let test_typing_extensions_overloads =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing_extensions import overload

      @overload
      def foo(a: str) -> str: ...

      @overload
      def foo(a: bool) -> bool: ...

      def foo(a: object) -> object: ...

      reveal_type(foo("hello"))
      reveal_type(foo(True))
    |}
           [
             "Revealed type [-1]: Revealed type for `test.foo(\"hello\")` is `str`.";
             "Revealed type [-1]: Revealed type for `test.foo(True)` is `bool`.";
           ];
    ]


let () =
  "overload"
  >::: [
         test_check_implementation;
         test_check_inferred_return_type;
         test_check_decorated_overloads;
         test_typing_extensions_overloads;
       ]
  |> Test.run
