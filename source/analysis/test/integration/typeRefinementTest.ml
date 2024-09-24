(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_assert_is_none =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import unittest
    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        self.assertIsNotNone(2)
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertIsNotNone(x)
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertIsNotNone(x, 'x should not be None')
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self, iter: typing.List[A]) -> None:
        a = None
        for i in iter:
          a = i
        self.assertIsNotNone(a)
        attribute = a.x
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    class Foo:
      def __init__(self) -> None:
        self.x = 1

    def foo(f: Foo) -> None:
      assert f.x is None
      reveal_type(f.x)
  |}
           ["Revealed type [-1]: Revealed type for `f.x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertTrue(x is not None)
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertTrue(x is not None, "x should not be None")
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertFalse(x is None)
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        x = a.x
        self.assertFalse(x is None, "x should not be None")
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from dataclasses import dataclass
    from typing import Optional, Final

    class NormalClass():
      x: Optional[int] = None

    class ClassWithFinalAttribute():
      def __init__(self, x: Optional[int]) -> None:
        self.x: Final[Optional[int]] = x

    @dataclass
    class UnfrozenDataClass():
      x: Optional[int]

    @dataclass(frozen=True)
    class FrozenDataClass():
      x: Optional[int]

    class ReadOnlyPropertyClass():
      state: bool = True
      @property
      def x(self) -> Optional[int]:
        self.state = not self.state
        if self.state:
          return None
        else:
          return 8

    def foo() -> None:
      normal_class: Final[NormalClass]
      class_with_final_attribute: Final[ClassWithFinalAttribute]
      unfrozen_dataclass: Final[UnfrozenDataClass]
      frozen_dataclass: Final[FrozenDataClass]
      read_only_property_class: Final[ReadOnlyPropertyClass]

      if normal_class.x is not None:
        reveal_type(normal_class.x)
      if class_with_final_attribute.x is not None:
        reveal_type(class_with_final_attribute.x)
      if unfrozen_dataclass.x is not None:
        reveal_type(unfrozen_dataclass.x)
      if frozen_dataclass.x is not None:
        reveal_type(frozen_dataclass.x)
      if read_only_property_class.x is not None:
        reveal_type(read_only_property_class.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `normal_class.x` is `Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `class_with_final_attribute.x` is \
              `Optional[int]` (inferred: `int`, final).";
             "Revealed type [-1]: Revealed type for `unfrozen_dataclass.x` is `Optional[int]` \
              (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `frozen_dataclass.x` is `Optional[int]` \
              (inferred: `int`, final).";
             "Revealed type [-1]: Revealed type for `read_only_property_class.x` is \
              `Optional[int]` (inferred: `int`, final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from dataclasses import dataclass
    from typing import Optional, Final

    class NormalClass():
      x: Optional[int] = None

    class ClassWithFinalAttribute():
      def __init__(self, x: Optional[int]) -> None:
        self.x: Final[Optional[int]] = x

    @dataclass
    class UnfrozenDataClass():
      x: Optional[int]

    @dataclass(frozen=True)
    class FrozenDataClass():
      x: Optional[int]

    class ReadOnlyPropertyClass():
      state: bool = True
      @property
      def x(self) -> Optional[int]:
        self.state = not self.state
        if self.state:
          return None
        else:
          return 8

    def interleaving_call() -> None: pass

    def foo() -> None:
      normal_class: Final[NormalClass] = ...
      class_with_final_attribute: Final[ClassWithFinalAttribute] = ...
      unfrozen_dataclass: Final[UnfrozenDataClass] = ...
      frozen_dataclass: Final[FrozenDataClass] = ...
      read_only_property_class: Final[ReadOnlyPropertyClass] = ...
      if normal_class.x is None:
        interleaving_call()
        reveal_type(normal_class.x)
      if class_with_final_attribute.x is None:
        interleaving_call()
        reveal_type(class_with_final_attribute.x)
      if unfrozen_dataclass.x is None:
        interleaving_call()
        reveal_type(unfrozen_dataclass.x)
      if frozen_dataclass.x is None:
        interleaving_call()
        reveal_type(frozen_dataclass.x)
      if read_only_property_class.x is None:
        interleaving_call()
        reveal_type(read_only_property_class.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `normal_class.x` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `class_with_final_attribute.x` is `None`.";
             "Revealed type [-1]: Revealed type for `unfrozen_dataclass.x` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `frozen_dataclass.x` is `None`.";
             "Revealed type [-1]: Revealed type for `read_only_property_class.x` is \
              `Optional[int]` (final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from dataclasses import dataclass
    from typing import Optional, Final

    class NormalClass():
      x: float = 3.14

    class ClassWithFinalAttribute():
      def __init__(self, x: float) -> None:
        self.x: Final[float] = x

    @dataclass
    class UnfrozenDataClass():
      x: float

    @dataclass(frozen=True)
    class FrozenDataClass():
      x: float

    class ReadOnlyPropertyClass():
      state: bool = True
      @property
      def x(self) -> float:
        self.state = not self.state
        if self.state:
          return 8.2
        else:
          return 8

    def interleaving_call() -> None: pass

    def foo() -> None:
      normal_class: Final[NormalClass] = ...
      class_with_final_attribute: Final[ClassWithFinalAttribute] = ...
      unfrozen_dataclass: Final[UnfrozenDataClass] = ...
      frozen_dataclass: Final[FrozenDataClass] = ...
      read_only_property_class: Final[ReadOnlyPropertyClass] = ...
      if isinstance(normal_class.x, int):
        interleaving_call()
        reveal_type(normal_class.x)
      if isinstance(class_with_final_attribute.x, int):
        interleaving_call()
        reveal_type(class_with_final_attribute.x)
      if isinstance(unfrozen_dataclass.x, int):
        interleaving_call()
        reveal_type(unfrozen_dataclass.x)
      if isinstance(frozen_dataclass.x, int):
        interleaving_call()
        reveal_type(frozen_dataclass.x)
      if isinstance(read_only_property_class.x, int):
        interleaving_call()
        reveal_type(read_only_property_class.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `normal_class.x` is `float`.";
             "Revealed type [-1]: Revealed type for `class_with_final_attribute.x` is `int`.";
             "Revealed type [-1]: Revealed type for `unfrozen_dataclass.x` is `float`.";
             "Revealed type [-1]: Revealed type for `frozen_dataclass.x` is `int`.";
             "Revealed type [-1]: Revealed type for `read_only_property_class.x` is `float` \
              (final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from dataclasses import dataclass
    from typing import Optional, Final

    @dataclass(frozen=True)
    class InnerFrozenDataClass():
      x: Optional[int]

    @dataclass(frozen=True)
    class FrozenDataClass():
      inner: InnerFrozenDataClass

    @dataclass
    class UnfrozenDataClass():
      inner: InnerFrozenDataClass

    def interleaving_call() -> None: pass

    def foo() -> None:
      unfrozen_dataclass: Final[UnfrozenDataClass] = ...
      frozen_dataclass: Final[FrozenDataClass] = ...
      if unfrozen_dataclass.inner.x is not None:
        interleaving_call()
        reveal_type(unfrozen_dataclass.inner.x)
      if frozen_dataclass.inner.x is not None:
        interleaving_call()
        reveal_type(frozen_dataclass.inner.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `unfrozen_dataclass.inner.x` is \
              `Optional[int]` (final).";
             "Revealed type [-1]: Revealed type for `frozen_dataclass.inner.x` is `Optional[int]` \
              (inferred: `int`, final).";
           ];
    ]


let test_assert_is =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Type
    class Foo:
      x: int = 1
    def foo(o: Type[object]) -> None:
      if (o is Foo):
        o.x
  |}
           [];
    ]


let test_check_global_refinement =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    def call() -> None: pass

    def foo() -> None:
      a = A(3)
      if a.x:
        reveal_type(a.x)
      if a.x:
        call()
        reveal_type(a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.x` is `typing.Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `a.x` is `typing.Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class A:
      def __init__(self, x: typing.Optional[int]) -> None:
        self.x = x

    class FakeTest(unittest.TestCase):
      def foo(self) -> None:
        a = A(3)
        self.assertIsNotNone(a.x)
        reveal_type(a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.x` is `typing.Optional[int]` (inferred: \
              `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    MY_GLOBAL: typing.Optional[int] = 1

    def call() -> None: pass

    def foo() -> None:
      if MY_GLOBAL:
        reveal_type(MY_GLOBAL)
        call()
        reveal_type(MY_GLOBAL)
  |}
           [
             "Revealed type [-1]: Revealed type for `MY_GLOBAL` is `typing.Optional[int]` \
              (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `MY_GLOBAL` is `typing.Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    x: typing.Optional[int] = 1

    def call() -> None: pass

    def foo() -> None:
      global x
      x = 1
      if x is not None:
        reveal_type(x)
        call()
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: \
              `typing_extensions.Literal[1]`).";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
           ];
    ]


let test_check_local_refinement =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if (y := x):
        reveal_type(x)
        reveal_type(y)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
             "Revealed type [-1]: Revealed type for `y` is `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if (y := x) is not None:
        reveal_type(x)
        reveal_type(y)
      if (y := x) is None:
        reveal_type(x)
        reveal_type(y)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
             "Revealed type [-1]: Revealed type for `y` is `int`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
             "Revealed type [-1]: Revealed type for `y` is `None`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Union[int, str, None]) -> None:
      if x:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Union[None, int, str]` \
              (inferred: `typing.Union[int, str]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Union[int, str, None]) -> None:
      if x is None:
        x = 42
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Union[None, int, str]` \
              (inferred: `typing.Union[int, str]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    import unittest
    class FakeTest(unittest.TestCase):
      def foo(self, x: typing.Optional[int]) -> None:
        self.assertIsNotNone(x)
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    x: typing.Optional[int] = 1

    def foo(test: bool) -> None:
      if test:
        x = 1
      else:
        x = None
      if x:
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing_extensions.Literal[1]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo() -> None:
      x: typing.Optional[int]
      if x is not None:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[str]) -> typing.Optional[str]:
      d = {"a": "a"}
      if x in d:
        reveal_type(x)
        return d[x]
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[str]` (inferred: `str`).";
           ];
      (* We don't actually care about the errors here, just that this terminates *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  def f(y):
    while True:
        if y in (None, []):
            pass
        if True:
            pass
  |}
           [
             "Missing return annotation [3]: Return type is not specified.";
             "Missing parameter annotation [2]: Parameter `y` has no type specified.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
        from typing import Tuple
        def foo(x: Tuple[int, ...], y) -> None:
            reveal_type(x)
            if not isinstance(x, type(y)):
                reveal_type(x)
                return
            reveal_type(x)
      |}
           [
             "Missing parameter annotation [2]: Parameter `y` has no type specified.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Tuple[int, ...]`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Tuple[int, ...]`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Tuple[int, ...]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
        from typing import Any, Tuple
        def foo(x: int) -> None:
            reveal_type(x)
            if isinstance(x, type(Any)):
                return
            reveal_type(x)
      |}
           [
             "Revealed type [-1]: Revealed type for `x` is `int`.";
             "Revealed type [-1]: Revealed type for `x` is `int`.";
           ];
    ]


let test_check_if_else_clause =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Literal

    def foo(x: Literal["a", "b"]) -> None:
      if x != "a":
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing_extensions.Literal['b']`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from enum import Enum
    class Color(Enum):
      RED = 1
      BLUE = 2

    def foo(x: Color) -> None:
      if x == Color.RED:
        reveal_type(x)
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing_extensions.Literal[Color.RED]`.";
             "Revealed type [-1]: Revealed type for `x` is `Color`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: int) -> None:
      if x == 1:
        reveal_type(x)
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing_extensions.Literal[1]`.";
             "Revealed type [-1]: Revealed type for `x` is `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: bool) -> None:
      if x:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[True]`).";
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[False]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: bool) -> None:
      if not x:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[False]`).";
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[True]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: bool) -> None:
      if x:
        return
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[False]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: bool) -> None:
      if not x:
        return
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `bool` (inferred: \
              `typing_extensions.Literal[True]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x is None:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `None`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: \
              `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x is not None:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `x` is `None`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if not x:
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: \
              `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x is None:
        return
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x:
        return
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if x is not None:
        return
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `None`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.Optional[int]) -> None:
      if not x:
        return
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from enum import Enum
    class Color(Enum):
      RED = 1
      BLUE = 2

    def foo(x: Color | None) -> None:
      if x in [Color.RED, Color.BLUE]:
        reveal_type(x)
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[Color]` (inferred: \
              `typing.Union[typing_extensions.Literal[Color.BLUE], \
              typing_extensions.Literal[Color.RED]]`).";
             "Revealed type [-1]: Revealed type for `x` is `typing.Optional[Color]`.";
           ];
    ]


let test_assert_contains_none =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.List[typing.Optional[int]]) -> None:
      assert None not in x
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.List[typing.Optional[int]]` \
              (inferred: `typing.List[int]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def bar(i: typing.Optional[int]) -> bool:
      return i is not None

    def foo(x: typing.List[typing.Optional[int]]) -> None:
      x = [1, 2, 3, 4, None, 5]
      y = [i for i in x if bar(i)]
      assert None not in y
      reveal_type(y)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `typing.List[int]`."];
      (* Invalid assertions *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    def foo(x: None) -> None:
      assert None not in x
  |}
           ["Unsupported operand [58]: `not in` is not supported for right operand type `None`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    def foo(x: Derp) -> None:
      assert None not in x
  |}
           ["Unbound name [10]: Name `Derp` is used but not defined in the current scope."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
    import typing
    def foo(x: typing.Any) -> None:
      assert None not in x
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Any`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    def foo(x: typing.List[Derp]) -> None:
      assert None not in x
      reveal_type(x)
  |}
           [
             "Unbound name [10]: Name `Derp` is used but not defined in the current scope.";
             "Revealed type [-1]: Revealed type for `x` is `unknown`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
    import typing
    def foo(x: typing.List[typing.Any]) -> None:
      assert None not in x
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.List[typing.Any]`."];
    ]


let test_check_callable =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Dict, Optional
    class CallableClass:
      def __call__(self, x:int) -> str:
        return "A"
    def foo(x: Dict[int, Optional[CallableClass]]) -> None:
      y = x[0]
      if callable(y):
        z = y
        reveal_type(z)
      else:
        reveal_type(y)
  |}
           [
             "Revealed type [-1]: Revealed type for `z` is `CallableClass`.";
             "Revealed type [-1]: Revealed type for `y` is `None`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    class CallableClass:
      def __call__(self, x:int) -> str:
        return "A"
    class CallableClassChild(CallableClass):
      ...
    def foo(x: CallableClassChild) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `CallableClassChild`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Dict, Callable, Optional
    def foo(x: Dict[int, Optional[Callable[[], int]]]) -> None:
      ret = x[0]
      if callable(ret):
        reveal_type(ret)
      else:
        reveal_type(ret)
      reveal_type(ret)
  |}
           [
             "Revealed type [-1]: Revealed type for `ret` is `typing.Callable[[], int]`.";
             "Revealed type [-1]: Revealed type for `ret` is `None`.";
             "Revealed type [-1]: Revealed type for `ret` is `Optional[typing.Callable[[], int]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Callable
    def foo(x: Union[Callable[[], int], int]) -> None:
      if callable(x):
        reveal_type(x)
      else:
        y = x
        reveal_type(y)
      reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Callable[[], int]`.";
             "Revealed type [-1]: Revealed type for `y` is `int`.";
             "Revealed type [-1]: Revealed type for `x` is `Union[typing.Callable[[], int], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Callable
    def foo(x: Callable[[], int]) -> None:
      if callable(x):
        reveal_type(x)
      else:
        y = x
        reveal_type(y)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Callable[[], int]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Type
    class Constructable:
      def __init__(self, x:int) -> None:
        return
    def foo(x: Union[int, Type[Constructable]]) -> None:
      if callable(x):
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `Type[Constructable]`.";
             "Revealed type [-1]: Revealed type for `x` is `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Callable
    def foo(x: Union[Callable[[int], str], int]) -> None:
      if not callable(x):
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `int`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Callable[[int], str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Callable
    def foo(x: Callable[[], int]) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `typing.Callable[[], int]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    def foo(x: int) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    def foo(x: object) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `y` is `typing.Callable[..., object]`.";
             "Revealed type [-1]: Revealed type for `x` is `object`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    def foo(x: object) -> None:
      if callable(x):
        reveal_type(x)
      else:
        reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Callable[..., object]`.";
             "Revealed type [-1]: Revealed type for `x` is `object`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Any
    def foo(x: Any) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           [
             "Missing parameter annotation [2]: Parameter `x` must have a type other than `Any`.";
             "Revealed type [-1]: Revealed type for `y` is `typing.Callable[..., object]`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    class Test:
      ...
    def foo(x: Test) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `Test`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Any, Union
    def foo(x: Union[int, Any]) -> None:
      if callable(x):
        y = x
        reveal_type(y)
      else:
        reveal_type(x)
  |}
           [
             "Missing parameter annotation [2]: Parameter `x` must have a type other than `Any`.";
             "Revealed type [-1]: Revealed type for `y` is `typing.Callable[..., object]`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
           ];
    ]


let test_check_final_attribute_refinement =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Final, Optional

    class Boo: ...

    class Baz:
      z: Final[Optional[Boo]] = None

    class Bar:
      y: Final[Optional[Baz]] = None

    class Foo:
      x: Final[Optional[Bar]] = None

    def bar(foo: Foo) -> None:
      assert (foo.x and foo.x.y and foo.x.y.z)
      reveal_type(foo.x)
      reveal_type(foo.x.y)
      reveal_type(foo.x.y.z)

    def bar2(foo: Foo) -> None:
      # This produces the same underlying Assert as above after normalization.
      if not foo.x or not foo.x.y:
        pass
      else:
        reveal_type(foo.x)
        reveal_type(foo.x.y)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.x` is `Optional[Bar]` (inferred: `Bar`, \
              final).";
             "Revealed type [-1]: Revealed type for `foo.x.y` is `Optional[Baz]` (inferred: `Baz`, \
              final).";
             "Revealed type [-1]: Revealed type for `foo.x.y.z` is `Optional[Boo]` (inferred: \
              `Boo`, final).";
             "Revealed type [-1]: Revealed type for `foo.x` is `Optional[Bar]` (inferred: `Bar`, \
              final).";
             "Revealed type [-1]: Revealed type for `foo.x.y` is `Optional[Baz]` (inferred: `Baz`, \
              final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    from dataclasses import dataclass
    def expects_str(x: str) -> None:
      pass

    @dataclass(frozen=True)
    class Actor:
      name: Optional[str]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    def foo(a: Actor) -> None:
      if a.name is not None:
        expects_str(a.name)
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional, Final
    def expects_str(x: str) -> None:
      pass

    class Actor:
      name: Final[Optional[str]]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    def foo(a: Actor) -> None:
      if a.name is not None:
        expects_str(a.name)
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    def expects_str(x: str) -> None:
      pass

    class Actor:
      name: Optional[str]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    def foo(a: Actor) -> None:
      if a.name is not None:
        expects_str(a.name)

      if a.name is not None:
        expects_str("unrelated call")
        expects_str(a.name)
  |}
           [
             "Incompatible parameter type [6]: In call `expects_str`, for 1st positional argument, \
              expected `str` but got `Optional[str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    from dataclasses import dataclass
    def expects_str(x: str) -> None:
      pass

    @dataclass(frozen=True)
    class Actor:
      name: Optional[str]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    def foo(a: Actor) -> None:
      if a.name is not None:
        a = Actor(None)
        expects_str(a.name)
  |}
           [
             "Incompatible parameter type [6]: In call `expects_str`, for 1st positional argument, \
              expected `str` but got `Optional[str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    from dataclasses import dataclass
    def expects_str(x: str) -> None:
      pass

    @dataclass(frozen=True)
    class Actor:
      name: Optional[str]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    def foo(a: Actor) -> None:
      if a.name is not None:
        a = Actor(None)
        if a.name:
          reveal_type(a.name)
        reveal_type(a.name)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.name` is `Optional[str]` (inferred: `str`, \
              final).";
             "Revealed type [-1]: Revealed type for `a.name` is `Optional[str]` (final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    from dataclasses import dataclass

    @dataclass(frozen=True)
    class Base:
      name: Optional[str]
      def __init__(self, name: Optional[str]) -> None:
        self.name = name

    @dataclass(frozen=True)
    class ChildA(Base):
      name: Optional[str]
      age: int
      def __init__(self, name: Optional[str]) -> None:
        self.name = name
        self.age = 0

    @dataclass(frozen=True)
    class ChildB(Base):
      name: Optional[str]
      year: int
      def __init__(self, name: Optional[str]) -> None:
        self.name = name
        self.year = 2020

    def expects_non_optional_and_a(x: str, y: ChildA) -> None:
      pass
    def expects_non_optional_and_b(x: str, y: ChildB) -> None:
      pass

    def foo(o: Base) -> None:
      if o.name:
        if isinstance(o, ChildA):
          expects_non_optional_and_a(o.name, o)
        if isinstance(o, ChildB):
          expects_non_optional_and_b(o.name, o)
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union
    from dataclasses import dataclass
    def expects_int(x: int) -> None:
      pass

    @dataclass(frozen=True)
    class Foo:
      x: Union[int, str]
      def __init__(self, x: Union[int, str]) -> None:
        self.x = x

    def f(a: Foo) -> None:
      if isinstance(a.x, int):
        expects_int(a.x)
  |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union
    from dataclasses import dataclass
    def expects_int(x: int) -> None:
      pass

    @dataclass(frozen=True)
    class Foo:
      x: Union[int, str]
      def __init__(self, x: Union[int, str]) -> None:
        self.x = x

    def f(a: Foo) -> None:
      if isinstance(a.x, int):
        a = Foo("bar")
        expects_int(a.x)
  |}
           [
             "Incompatible parameter type [6]: In call `expects_int`, for 1st positional argument, \
              expected `int` but got `Union[int, str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union
    from dataclasses import dataclass
    def expects_int(x: int) -> None:
      pass

    @dataclass(frozen=True)
    class Foo:
      x: Union[int, str]
      def __init__(self, x: Union[int, str]) -> None:
        self.x = x

    def f(a: Foo) -> None:
      if type(a.x) is int:
        expects_int(a.x)
      reveal_type(a.x)
  |}
           ["Revealed type [-1]: Revealed type for `a.x` is `Union[int, str]` (final)."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Callable
    from dataclasses import dataclass
    def expects_int(x: int) -> None:
      pass

    @dataclass(frozen=True)
    class Foo:
      x: Union[int, Callable[[], int]]
      def __init__(self, x: Union[int, Callable[[], int]]) -> None:
        self.x = x

    def f(a: Foo) -> None:
      if callable(a.x):
        reveal_type(a.x)
      reveal_type(a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.x` is `typing.Callable[[], int]`.";
             "Revealed type [-1]: Revealed type for `a.x` is `Union[typing.Callable[[], int], \
              int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Union, Callable
    from dataclasses import dataclass
    def expects_int(x: int) -> None:
      pass

    @dataclass(frozen=True)
    class Foo:
      x: Union[int, Callable[[], int]]
      def __init__(self, x: Union[int, Callable[[], int]]) -> None:
        self.x = x

    def f(a: Foo) -> None:
      if callable(a.x):
        a = Foo(42)
        reveal_type(a.x)
      reveal_type(a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.x` is `Union[typing.Callable[[], int], \
              int]` (final).";
             "Revealed type [-1]: Revealed type for `a.x` is `Union[typing.Callable[[], int], \
              int]` (final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import NamedTuple, Optional
  from dataclasses import dataclass

  class Foo(NamedTuple):
      value: Optional[int]
      other: int = 1

  def f() -> None:
      foo = Foo(value=1)
      reveal_type(foo.value)
      if foo.value:
          reveal_type(foo.value)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.value` is `Optional[int]` (final).";
             "Revealed type [-1]: Revealed type for `foo.value` is `Optional[int]` (inferred: \
              `int`, final).";
           ];
    ]


let test_check_temporary_refinement =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    MY_GLOBAL = 1.0

    def arbitrary_call() -> None:
      pass

    def test() -> None:
      reveal_type(MY_GLOBAL)
      global MY_GLOBAL
      MY_GLOBAL = 1
      reveal_type(MY_GLOBAL)
      arbitrary_call()
      reveal_type(MY_GLOBAL)
  |}
           [
             "Revealed type [-1]: Revealed type for `MY_GLOBAL` is `float`.";
             "Revealed type [-1]: Revealed type for `MY_GLOBAL` is `float` (inferred: \
              `typing_extensions.Literal[1]`).";
             "Revealed type [-1]: Revealed type for `MY_GLOBAL` is `float`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    def takes_non_optional_int(input: int) -> None:
      pass

    def test(foo: Foo) -> None:
      reveal_type(foo.attribute)
      foo.attribute = 1
      reveal_type(foo.attribute)
      takes_non_optional_int(foo.attribute)
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `typing_extensions.Literal[1]`).";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      @property
      def attribute(self) -> Optional[int]:
        pass
      @attribute.setter
      def attribute(self, value: Optional[int]) -> None:
        pass

    def test(foo: Foo) -> None:
      reveal_type(foo.attribute)
      foo.attribute = 1
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

      def __getattr__(self, value: str) -> int:
        return 1

    def test(foo: Foo) -> None:
      reveal_type(foo.attribute)
      foo.attribute = 1
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    class Bar:
      def unrelated_call(self) -> None:
        pass

    def test(foo: Foo) -> None:
      reveal_type(foo.attribute)
      foo.attribute = 1
      reveal_type(foo.attribute)
      bar = Bar()
      reveal_type(foo.attribute)
      if not foo.attribute:
        return
      reveal_type(foo.attribute)
      bar.unrelated_call()
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `typing_extensions.Literal[1]`).";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    def interleaving_call() -> None: pass

    def test(foo: Foo) -> None:
      reveal_type(foo.attribute)
      if not foo.attribute:
        return
      local_copy = foo.attribute
      interleaving_call()
      reveal_type(foo.attribute)
      reveal_type(local_copy)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `local_copy` is `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    class Bar:
      foo: Optional[Foo] = Foo()

    def interleaving_call() -> None: pass

    def test(bar: Bar) -> None:
      if bar.foo.attribute is not None:
        return
      reveal_type(bar.foo)
      reveal_type(bar.foo.attribute)

      if bar.foo and bar.foo.attribute:
        reveal_type(bar.foo.attribute)
  |}
           [
             "Undefined attribute [16]: `Optional` has no attribute `attribute`.";
             "Revealed type [-1]: Revealed type for `bar.foo` is `Optional[Foo]`.";
             "Revealed type [-1]: Revealed type for `bar.foo.attribute` is `unknown`.";
             "Revealed type [-1]: Revealed type for `bar.foo.attribute` is `Optional[int]` \
              (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    def interleaving_call() -> None: pass

    def test(foo: Foo) -> None:
      if not foo.attribute:
        return interleaving_call()
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    class Bar:
      attribute: Optional[int] = 1

    def interleaving_call() -> None:
      pass

    def test(foo: Foo, bar: Bar) -> None:
      if not foo.attribute or not bar.attribute:
        return
      reveal_type(foo.attribute)
      reveal_type(bar.attribute)

      interleaving_call()

      if not foo.attribute and not bar.attribute:
        return
      reveal_type(foo.attribute)
      reveal_type(bar.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `bar.attribute` is `Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]`.";
             "Revealed type [-1]: Revealed type for `bar.attribute` is `Optional[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      attribute: Optional[int] = 1

    def interleaving_call() -> None:
      pass

    def test(foo: Foo) -> None:
      if not foo.attribute or interleaving_call():
        return
      reveal_type(foo.attribute)

    def test_two(foo: Foo) -> None:
      if interleaving_call() or not foo.attribute:
        return
      reveal_type(foo.attribute)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `int`).";
             "Revealed type [-1]: Revealed type for `foo.attribute` is `Optional[int]` (inferred: \
              `int`).";
           ];
      (* Sanity check composite refinement checks *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo:
      a: Optional[int] = 1
      b: Optional[int] = 1

    def interleaving_call() -> None: pass

    def test(foo: Foo) -> None:
      if not foo.a or not foo.b:
        return
      reveal_type(foo.a)
      reveal_type(foo.b)

      interleaving_call()
      if foo.a is None or foo.b is None:
        return
      reveal_type(foo.a)
      reveal_type(foo.b)
  |}
           [
             "Revealed type [-1]: Revealed type for `foo.a` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `foo.b` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `foo.a` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `foo.b` is `Optional[int]` (inferred: `int`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    def test(a: Optional[int], b: Optional[int]) -> None:
      if not a or not b:
        return
      reveal_type(a)
      reveal_type(b)

    def test_two(a: Optional[int], b: Optional[int]) -> None:
      if a is None or b is None:
        return
      reveal_type(a)
      reveal_type(b)
  |}
           [
             "Revealed type [-1]: Revealed type for `a` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `b` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `a` is `Optional[int]` (inferred: `int`).";
             "Revealed type [-1]: Revealed type for `b` is `Optional[int]` (inferred: `int`).";
           ];
      (* Make sure that refining globals from other modules is always temporary *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import TypedDict

    def foo() -> None: ...

    if isinstance(TypedDict, int):
        reveal_type(TypedDict)  # temporary refinement is permitted
        foo()
        reveal_type(TypedDict)  # but it is cleared as it should be
  |}
           [
             "Revealed type [-1]: Revealed type for `typing.TypedDict` is `int`.";
             "Revealed type [-1]: Revealed type for `typing.TypedDict` is `object`.";
           ];
      (* Check whether the order of temporary / non-temporary refinements matters *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    class A:
        x: object = ""

    class B(A):
        pass


    def foo(a: A) -> None:
        if isinstance(a, B):
            if isinstance(a.x, int):
                reveal_type(a)
                reveal_type(a.x)
        if isinstance(a.x, int):
            if isinstance(a, B):
                reveal_type(a)
                reveal_type(a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a` is `B`.";
             "Revealed type [-1]: Revealed type for `a.x` is `int`.";
             "Revealed type [-1]: Revealed type for `a` is `B`.";
             "Revealed type [-1]: Revealed type for `a.x` is `int`.";
           ];
      (* Tests illustrating whether an assignment properly wipes out the attribute subtree *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  import typing
  class A:
      a: typing.Optional[A] = None
      x: object = ""

  class B(A):
      pass

  def f(a: A) -> None:
      b = B()
      if a.a is not None:
          if isinstance(a.a.x, int):
              reveal_type(a.a.x)
              a.a = b
              reveal_type(a.a)
              reveal_type(a.a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.a.x` is `int`.";
             "Revealed type [-1]: Revealed type for `a.a` is `typing.Optional[A]` (inferred: `B`).";
             "Revealed type [-1]: Revealed type for `a.a.x` is `object`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  import typing
  class A:
      a: typing.Optional[A] = None
      x: typing.Final[object] = ""

  class B(A):
      pass

  def f(a: A) -> None:
      if a.a is not None:
          if isinstance(a.a.x, int):
              reveal_type(a.a.x)
              a.a = B()
              reveal_type(a.a)
              reveal_type(a.a.x)
  |}
           [
             "Revealed type [-1]: Revealed type for `a.a.x` is `int`.";
             "Revealed type [-1]: Revealed type for `a.a` is `typing.Optional[A]` (inferred: `B`).";
             "Revealed type [-1]: Revealed type for `a.a.x` is `object` (final).";
           ];
    ]


let test_check_is_typeddict =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  import typing

  class MovieTypedDict(typing.TypedDict):
    ...

  x = MovieTypedDict
  if typing.is_typeddict(x):
    y = x
    reveal_type(y)
  else:
    reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `typing.Type[MovieTypedDict]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import is_typeddict, TypedDict

  class MovieTypedDict(TypedDict):
    ...

  x = MovieTypedDict
  if is_typeddict(tp=x):
    y = x
    reveal_type(y)
  else:
    reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `typing.Type[MovieTypedDict]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import TypedDict, is_typeddict, Dict, Optional

  class NotTypedDict:
    ...

  x = NotTypedDict
  if is_typeddict(x):
    y = x
    reveal_type(y)
  else:
    reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Type[NotTypedDict]`."];
      (* Type[Optional[A]] is never A since it is not a concrete type. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import TypedDict, is_typeddict, Dict, Optional

  class MovieTypedDict(TypedDict):
    ...

  x = Optional[MovieTypedDict]
  if is_typeddict(x):
    y = x
    reveal_type(y)
  else:
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Type[Optional[MovieTypedDict]]`."];
      (* TODO(T131953571) Support Type[parametric types] *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import TypedDict, is_typeddict, Dict, Union

  class MovieTypedDict(TypedDict):
    ...
  class BookTypedDict(TypedDict):
    ...

  x = Union[MovieTypedDict, BookTypedDict]
  if is_typeddict(x):
    reveal_type(x)
  else:
    reveal_type(x)
  |}
           [
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import TypedDict, is_typeddict, Dict, Union

  class MovieTypedDict(TypedDict):
    ...
  class Child(MovieTypedDict):
    ...

  x = Child
  if is_typeddict(x):
    y = x
    reveal_type(y)
  else:
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `typing.Type[Child]`."];
      (* is_typeddict checks for Type[ConcreteTypedDict], not ConcreteTypedDict. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import is_typeddict, TypedDict

  class MovieTypedDict(TypedDict):
    ...

  def foo(x: MovieTypedDict) -> None:
    if is_typeddict(x):
      y = x
      reveal_type(y)
    else:
      reveal_type(x)
  |}
           ["Revealed type [-1]: Revealed type for `x` is `MovieTypedDict`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import is_typeddict, TypedDict, Any

  def foo(x: Any) -> None:
    if is_typeddict(x):
      reveal_type(x)
    else:
      reveal_type(x)
  |}
           [
             "Missing parameter annotation [2]: Parameter `x` must have a type other than `Any`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
             "Revealed type [-1]: Revealed type for `x` is `typing.Any`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
  from typing import is_typeddict, TypedDict, Type, Any

  def foo(x: Type[Any]) -> None:
    if is_typeddict(x):
      reveal_type(x)
    else:
      reveal_type(x)
  |}
           [
             "Missing parameter annotation [2]: Parameter `x` must have a type that does not \
              contain `Any`.";
             "Revealed type [-1]: Revealed type for `x` is `Type[typing.Any]`.";
             "Revealed type [-1]: Revealed type for `x` is `Type[typing.Any]`.";
           ];
    ]


let test_ternary_expression =
  test_list
    [
      (* The type of `self` in the ternary condition is `Self (bound to Foo)`. We should be able to
         refine `self.bar` to be `str` in the if-branch. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional
    from typing_extensions import Self

    class Foo:
      bar: Optional[str] = None

      def some_method(self) -> Self:
        y = self.bar.capitalize() if self.bar else ""
        reveal_type(y)

        return self
  |}
           ["Revealed type [-1]: Revealed type for `y` is `str`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Type, Optional

    class Foo:
      bar: Optional[str] = None

    def main(x: Type[Foo]) -> None:
        y = x.bar.capitalize() if x.bar else ""
        reveal_type(y)
  |}
           ["Revealed type [-1]: Revealed type for `y` is `str`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Any, Optional

    class Foo1:
      bar: Optional[str] = None

    class Foo2:
      bar: Optional[str] = None

    def main(x: Any) -> None:
        y = x.bar.capitalize() if x.bar else ""
        reveal_type(y)
  |}
           [
             "Missing parameter annotation [2]: Parameter `x` must have a type other than `Any`.";
             "Revealed type [-1]: Revealed type for `y` is `typing.Any`.";
           ];
      (* TODO(T159930161): Refine attribute of union in ternary expression. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Optional

    class Foo1:
      bar: Optional[str] = None

    class Foo2:
      bar: Optional[str] = None

    def main(my_union: Foo1 | Foo2) -> None:
        y = my_union.bar.capitalize() if my_union.bar else ""
        reveal_type(y)
  |}
           [
             "Undefined attribute [16]: `Optional` has no attribute `capitalize`.";
             "Revealed type [-1]: Revealed type for `y` is `typing.Any`.";
           ];
    ]


let () =
  "refinement"
  >::: [
         test_assert_is_none;
         test_assert_is;
         test_check_global_refinement;
         test_check_local_refinement;
         test_check_if_else_clause;
         test_assert_contains_none;
         test_check_callable;
         test_check_final_attribute_refinement;
         test_check_temporary_refinement;
         test_check_is_typeddict;
         test_ternary_expression;
       ]
  |> Test.run
