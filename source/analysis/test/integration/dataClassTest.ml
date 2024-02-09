(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_check_data_class context =
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Foo():
        x: int = 1
      def boo() -> None:
          b = Foo('a')
    |}
    [
      "Incompatible parameter type [6]: In call `Foo.__init__`, for 1st positional argument, \
       expected `int` but got `str`.";
    ]
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Foo():
        x: int = 1
      def boo() -> None:
          b = Foo(4,5)
    |}
    [
      "Too many arguments [19]: Call `Foo.__init__` expects 1 positional argument, "
      ^ "2 were provided.";
    ]
    context;
  assert_type_errors
    {|
      import dataclasses
      @dataclasses.dataclass
      class Foo():
        x: int = 1
      def boo() -> None:
          b = Foo(4,5)
    |}
    [
      "Too many arguments [19]: Call `Foo.__init__` expects 1 positional argument, "
      ^ "2 were provided.";
    ]
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Foo():
        x = 1
      def boo() -> None:
          b = Foo(2)
    |}
    [
      "Missing attribute annotation [4]: Attribute `x` of class `Foo` has type `int` "
      ^ "but no type is specified.";
      "Too many arguments [19]: Call `Foo.__init__` expects 0 positional arguments, 1 was"
      ^ " provided.";
    ]
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Foo():
        x: int = 1
      def boo() -> None:
          b = Foo()
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Foo():
        dangan: int
      def boo() -> None:
          b = Foo(1)
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class Base():
        x: int
      class Child(Base):
        pass
      def boo() -> None:
          b = Child(1)
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      from typing import Dict, Any
      @dataclass(frozen=False)
      class Base:
        x: str

        def __init__(
            self,
            *,
            x: str,
        ) -> None:
            self.x = x

        def as_dict(self) -> Dict[str, Any]:
            x = self.x
            return {
                "x": x,
            }
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      from typing import Dict, Any
      @dataclass(frozen=True)
      class Base:
        x: float
      @dataclass(frozen=True)
      class Child(Base):
        x: int = 1
        y: str
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      from placeholder_stub import X
      @dataclass
      class Foo(X):
        x: int = 1
      def boo() -> None:
          b = Foo(1)
    |}
    []
    context;
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass(frozen=True)
      class F:
        x = 1
    |}
    [
      "Missing attribute annotation [4]: Attribute `x` of class `F` has type `int` but no type is \
       specified.";
    ]
    context;
  assert_type_errors
    {|
      from typing import ClassVar
      from dataclasses import dataclass
      @dataclass
      class A:
        x: ClassVar[int] = 42
        y: str = "a"
      A("a")
    |}
    []
    context;
  (* Actually a test of descriptors to make sure it doesn't infinitely loop *)
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass
      class D:
        x: C = C()
      @dataclass
      class C:
        x: D = D()
      def foo() -> None:
        reveal_type(D().x)
        reveal_type(D().x.x.x)
    |}
    [
      "Revealed type [-1]: Revealed type for `test.D().x` is `C`.";
      "Revealed type [-1]: Revealed type for `test.D().x.x.x` is `C`.";
    ]
    context;
  ()


let test_check_attr =
  assert_type_errors
    ~other_sources:
      [
        {
          handle = "attr/__init__.pyi";
          source =
            {|
        import typing
        _T = typing.TypeVar("T")
        class Attribute(typing.Generic[_T]):
          name: str
          default: Optional[_T]
          validator: Optional[_ValidatorType[_T]]
        def s( *args, **kwargs) -> typing.Any: ...
        def ib(default: _T) -> _T: ...
      |};
        };
      ]
    {|
      import typing
      import attr
      @attr.s
      class C:
        x: typing.Optional[int] = attr.ib(default=None)
        @x.validator
        def check(self, attribute: attr.Attribute[int], value: typing.Optional[int]) -> None:
          pass
    |}
    []


let test_check_keyword_only context =
  assert_type_errors
    {|
      from dataclasses import dataclass
      @dataclass(kw_only=True)
      class A:
        x: int
      reveal_type(A.__init__)
    |}
    [
      "Revealed type [-1]: Revealed type for `test.A.__init__` is \
       `typing.Callable(A.__init__)[[Named(self, A), KeywordOnly(x, int)], None]`.";
    ]
    context;
  ()


let test_check_keyword_only_preprocessed context =
  assert_type_errors
    {|
      from dataclasses import dataclass, KW_ONLY
      @dataclass
      class A:
        x: int
        _: KW_ONLY
        y: int
      reveal_type(A.__init__)
    |}
    [
      "Revealed type [-1]: Revealed type for `test.A.__init__` is \
       `typing.Callable(A.__init__)[[Named(self, A), Named(x, int), KeywordOnly(y, int, default)], \
       None]`.";
    ]
    context;
  ()


let () =
  "dataclass"
  >::: [
         "check_dataclass" >:: test_check_data_class;
         "check_attr" >:: test_check_attr;
         "kw_only" >:: test_check_keyword_only;
         "kw_only_preprocessed" >:: test_check_keyword_only_preprocessed;
       ]
  |> Test.run
