(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_check_invalid_constructor =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self) -> None:
                  return
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self) -> int:
                  return 0
            |}
           [
             "Incompatible constructor annotation [17]: `__init__` is annotated as "
             ^ "returning `int`, but it should return `None`.";
           ];
      (* TODO(T45018328): We should error here. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __new__(cls) -> None:
                  ...
            |}
           [];
    ]


let test_check_init =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  pass
            |}
           [
             "Uninitialized attribute [13]: Attribute `attribute` is declared in class `Foo` to \
              have "
             ^ "type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
            |}
           [
             "Uninitialized attribute [13]: Attribute `attribute` is declared in class `Foo` to \
              have "
             ^ "type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(renamed_self) -> None:
                  renamed_self.attribute = 0
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(renamed_self) -> None:
                  renamed_self.attribute = 0
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                x = 1
                def __init__(self) -> None:
                  self.x = "string"
                  self.y = self.x
                  self.z = 1
            |}
           [
             "Incompatible attribute type [8]: Attribute `x` declared in class `Foo` has type `int` "
             ^ "but is used as type `str`.";
             "Missing attribute annotation [4]: Attribute `y` of class `Foo` has type "
             ^ "`int` but no type is specified.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self) -> None:
                  self.attribute: bool = False
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int = 1
                def __init__(self) -> None:
                  pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                attribute_two: str
                def __init__(self) -> None:
                  pass
            |}
           [
             "Uninitialized attribute [13]: Attribute `attribute` is declared in class `Foo` to \
              have "
             ^ "type `int` but is never initialized.";
             "Uninitialized attribute [13]: Attribute `attribute_two` is declared in class `Foo` \
              to "
             ^ "have type `str` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  self.attribute = 0
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  self.attribute = 0
                def __enter__(self) -> "Foo":
                  return self
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  self.attribute = 0 if True else 1
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from builtins import condition
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  if condition():
                    self.attribute = 0
                  else:
                    self.attribute = 1
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  if False:
                    return None
                  self.attribute = 1
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from builtins import condition
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  if condition():
                    raise
                  self.attribute = 1
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from builtins import condition
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  self.attribute = unknown if condition() else unknown2
            |}
           [
             "Incompatible attribute type [8]: Attribute `attribute` declared in class `Foo` "
             ^ "has type `int` but is used as type `unknown`.";
             "Unbound name [10]: Name `unknown` is used but not defined in the current scope.";
             "Unbound name [10]: Name `unknown2` is used but not defined in the current scope.";
           ];
      (* No need to initialize properties. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self) -> None:
                  pass
                @property
                def foo(self) -> str:
                  return "asdf"
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  attribute = 0
            |}
           [
             "Uninitialized attribute [13]: Attribute `attribute` is declared in class `Foo` to \
              have "
             ^ "type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self) -> None:
                  self.attribute = 0
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Foo:
                attribute: typing.Optional[int]
                def __init__(self) -> None:
                  pass
            |}
           [
             "Uninitialized attribute [13]: Attribute `attribute` is declared in class `Foo` to \
              have "
             ^ "type `typing.Optional[int]` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Foo:
                attribute: typing.Optional[int]
                def __init__(self) -> None:
                  self.attribute = None
                  pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                attribute: int
                def __init__(self) -> None:
                  self.attribute = ""
            |}
           [
             "Incompatible attribute type [8]: Attribute `attribute` declared in class `Foo` has \
              type "
             ^ "`int` but is used as type `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self, x:int) -> None:
                  pass
              a = Foo("")
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.__init__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self, x: int) -> None:
                  self._a = x
                def a(self) -> int:
                  return self._a
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self, x: int) -> None:
                  self.a = x
                def a(self) -> int:
                  return self.a
            |}
           [
             "Incompatible attribute type [8]: Attribute `a` declared in class `C` has type "
             ^ "`BoundMethod[typing.Callable(C.a)[[Named(self, C)], int], C]` but is used as type \
                `int`.";
             "Incompatible return type [7]: Expected `int` but got "
             ^ "`BoundMethod[typing.Callable(C.a)[[Named(self, C)], int], C]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self, x: int, y: int) -> None:
                  self.x = x
                  self.y = y
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                def __init__(self, x: int, y: int, test: bool) -> None:
                  self.attribute = x
                  self.x = x
                  if test:
                    self.y = y
            |}
           [
             "Missing attribute annotation [4]: Attribute `y` of class `C` has type `int` but no \
              type is specified.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              def identity(x: int) -> int:
                return x
              class C:
                def __init__(self, x: int) -> None:
                  self._a = identity(x)
                def a(self) -> int:
                  return self._a
            |}
           [
             "Missing attribute annotation [4]: Attribute `_a`"
             ^ " of class `C` has type `int` but no type is specified.";
             "Incompatible return type [7]: Expected `int` but got `unknown`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors {|
               alias = int
            |} [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                class D:
                  pass
              B = C
              reveal_type(B.D)
            |}
           ["Revealed type [-1]: Revealed type for `B.D` is `typing.Type[C.D]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __new__(cls, x: int) -> None:
                  pass
              a: Foo = Foo("")
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.__new__`, for 1st positional argument, \
              expected `int` but got `str`.";
           ];
      (* Prefer init over new if both exist. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __new__(cls, x: int) -> None:
                  pass
                def __init__(self, x: str) -> None:
                  pass
              a: Foo = Foo("")
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Super:
                def __new__(cls, x: int) -> None: ...

              class C(Super):
                pass
              c: C = C("")
            |}
           [
             "Incompatible parameter type [6]: In call `Super.__new__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      (* We look at both __init__ and __new__ in the inheritance structure. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class SuperSuper:
                def __init__(self, x: str) -> None: ...
              class Super(SuperSuper):
                def __new__(cls, x: int) -> None: ...
              class C(Super):
                pass
              c: C = C("")
            |}
           [
             "Incompatible parameter type [6]: In call `Super.__new__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class SuperSuper:
                def __new__(self, x: str) -> None: ...
              class Super(SuperSuper):
                def __init__(cls, x: int) -> None: ...
              class C(Super):
                pass
              c: C = C("")
            |}
           [
             "Incompatible parameter type [6]: In call `Super.__init__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class A:
                foo:int = 3
              class B(A):
                foo = "string"
            |}
           [
             "Inconsistent override [15]: `foo` overrides attribute defined in `A` inconsistently. "
             ^ "Type `str` is not a subtype of the overridden attribute `int`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class A:
                foo:int = 3
              class B(A):
                foo = 100
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Optional
              def example() -> int: return 1
              class A:
                  x:Optional[int] = None
              class B(A):
                  x = example()
            |}
           [
             "Missing attribute annotation [4]:"
             ^ " Attribute `x` of class `B` has type `int` but no type is specified.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import ABCMeta
              class A(metaclass=ABCMeta):
                foo: int
                def __init__(self) -> None:
                   pass
              |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import ABCMeta
              class A(metaclass=ABCMeta):
                foo: int
              class B(A):
                pass
              |}
           [
             "Uninitialized attribute [13]: Attribute `foo` inherited from abstract class `A` in \
              class `B` to have type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import ABCMeta
              class A(metaclass=ABCMeta):
                foo: int

            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import ABC

              class A(ABC):
                  x: int
                  def __init__(self) -> None:
                      self.x = 1

              class B(A):
                  pass
            |}
           [];
    ]


let test_check_constructors =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self) -> None:
                  pass
              def foo() -> Foo:
                return Foo()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self, i: int) -> None:
                  pass
              def foo() -> Foo:
                return Foo(10)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self, i: int) -> None:
                  pass
              def foo() -> Foo:
                return Foo('asdf')
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.__init__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Foo:
                def __init__(self, i: int, s: typing.Optional[str] = None) -> None:
                  pass
              def foo() -> None:
                Foo('asdf')
                Foo(1, 2)
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.__init__`, for 1st positional \
              argument, expected `int` but got `str`.";
             "Incompatible parameter type [6]: In call `Foo.__init__`, for 2nd positional \
              argument, expected `Optional[str]` but got `int`.";
           ];
      (* Check abstract methods *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              class Foo(metaclass=ABCMeta):
                @abstractmethod
                def bar(self) -> None:
                  pass
              def foo() -> None:
                Foo()
              |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `Foo` with \
              abstract method `bar`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              class Foo(metaclass=ABCMeta):
                @abstractmethod
                def bar(self) -> None:
                  pass
                @abstractmethod
                def foo(self) -> None:
                  pass
              def foo() -> None:
                Foo()
              |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `Foo` with \
              abstract methods `bar`, `foo`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              class A(metaclass=ABCMeta):
                  @abstractmethod
                  def a(self) -> None:
                      pass
                  @abstractmethod
                  def b(self) -> None:
                      pass
                  @abstractmethod
                  def c(self) -> None:
                      pass
                  @abstractmethod
                  def d(self) -> None:
                      pass
                  @abstractmethod
                  def e(self) -> None:
                      pass
                  @abstractmethod
                  def f(self) -> None:
                      pass
              class B(A):
                 pass
              def foo() -> None:
                B()
            |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `B` with `a`, \
              `b`, `c` and 3 additional abstract methods.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod
              class Foo():
                @abstractmethod
                def bar(self) -> None:
                  pass
              def foo() -> None:
                Foo()
              |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `Foo` with \
              abstract method `bar`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              class Foo(metaclass=ABCMeta):
                def bar(self) -> None:
                  pass
              def foo() -> None:
                Foo()
              |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              class A(metaclass=ABCMeta):
                @abstractmethod
                def f(self) -> None:
                    pass
              class B(A):
                 pass
              def foo() -> None:
                 B()
           |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `B` with \
              abstract method `f`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractproperty, ABCMeta
              class A(metaclass=ABCMeta):
                @abstractproperty
                def f(self) -> None:
                    pass
              class B(A):
                 pass
              def foo() -> None:
                 B()
           |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABCMeta
              from typing import override

              class A(metaclass=ABCMeta):
                  @abstractmethod
                  def h(self) -> None:
                      pass
                  @abstractmethod
                  def g(self) -> None:
                      pass
              class B(A):
                  @override
                  def g(self) -> None:
                      pass
              class C(B):
                  pass
              def foo() -> None:
                A()
                B()
                C()
            |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `A` with \
              abstract methods `g`, `h`.";
             "Invalid class instantiation [45]: Cannot instantiate abstract class `B` with \
              abstract method `h`.";
             "Invalid class instantiation [45]: Cannot instantiate abstract class `C` with \
              abstract method `h`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import ABCMeta, abstractmethod

              class A(metaclass=ABCMeta):
                  @property
                  @abstractmethod
                  def foo(self) -> int:
                      pass

              class B(A):
                  foo:int = 1
              B()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from abc import abstractmethod, ABC
              class Foo(ABC):
                @abstractmethod
                def bar(self) -> None:
                  pass
              def foo() -> None:
                Foo()
              |}
           [
             "Invalid class instantiation [45]: Cannot instantiate abstract class `Foo` with \
              abstract method `bar`.";
           ];
      (* Explicit call. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self, i: int) -> None:
                  pass
                def foo(self) -> None:
                  Foo.__init__(self, 'asdf')
            |}
           [
             "Incompatible parameter type [6]: In call `Foo.__init__`, for 2nd positional \
              argument, expected `int` but got `str`.";
           ];
      (* Super calls. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import override
              class Super:
                def foo(self, i: int) -> None:
                  pass
              class Foo(Super):
                @override
                def foo(self, i: int) -> None:
                  super().foo('asdf')
            |}
           [
             "Incompatible parameter type [6]: In call `Super.foo`, for 1st positional argument, \
              expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Super:
                def __init__(self, i: int) -> None:
                  pass
              class Foo(Super):
                def __init__(self, i: int) -> None:
                  super().__init__('asdf')
            |}
           [
             "Incompatible parameter type [6]: In call `Super.__init__`, for 1st positional \
              argument, expected `int` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from placeholder_stub import MadeUpClass
              class Foo(MadeUpClass):
                def __init__(self, i: int) -> None:
                  super().__init__('asdf')
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from placeholder_stub import MadeUpClass
              class Foo(MadeUpClass):
                pass
              def foo() -> None:
                Foo(7)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from placeholder_stub import MadeUpClass
              class Foo(MadeUpClass):
                pass
              def foo() -> int:
                return Foo()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from placeholder_stub import MadeUpClass
              class Foo(MadeUpClass):
                pass
              class Bar(Foo):
                pass
              def bar() -> int:
                return Bar()
            |}
           [];
      (* Check that subclasses of numeric types are instantiatable *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class CustomInt(int):
                def __init__(self, val: int) -> None: ...

              class CustomFloat(float):
                def __init__(self, val: float) -> None: ...

              class CustomComplex(float):
                def __init__(self, real: float, imaginary: float) -> None: ...

              def foo() -> None:
                custom_int = CustomInt(42)
                custom_float = CustomFloat(42.0)
                custom_complex = CustomComplex(42.0, 42.0)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Class:
                def __init__(self, i: int) -> None: ...
              def foo(x: typing.Type[Class]) -> Class:
                return x(7)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Class:
                def __init__(self, i: int) -> None: ...
              def foo(x: typing.Type[Clss]) -> Class:
                return x(7)
            |}
           ["Unbound name [10]: Name `Clss` is used but not defined in the current scope."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
              import typing
              def foo(x: typing.Type[typing.Any]) -> typing.Any:
                return x()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
              import typing
              def foo(x: typing.Type[typing.Any]) -> typing.Any:
                return x(42)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_strict_type_errors
           {|
              import typing
              class Class:
                def __init__(self, i: int) -> None: ...
              def foo(x: typing.Type[Clss]) -> Class:
                return x(7)
            |}
           ["Unbound name [10]: Name `Clss` is used but not defined in the current scope."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Class:
                def __init__(self, i: int) -> None:
                  ...
              def foo(x: typing.Callable[[int], Class]) -> None: ...
              foo(Class)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class Class:
                def __init__(self, i: int) -> None:
                  ...
              def foo(x: typing.Callable[[str], Class]) -> None: ...
              foo(Class)
            |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `typing.Callable[[str], Class]` but got `Type[Class]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Callable, Union, Type
              class Parent: pass
              class ChildA(Parent): pass
              class ChildB(Parent): pass
              def foo(x: Callable[[], Parent]) -> None: ...
              def bar(a: Type[Union[ChildA, ChildB]], b: Union[Type[ChildA], Type[ChildB]], c: Type[Parent]) -> None:
                foo(a)
                foo(b)
                foo(c)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                def __init__(self, x: int, y: str) -> None:
                  pass
              reveal_type(Foo.__call__)
            |}
           [
             "Revealed type [-1]: Revealed type for `test.Foo.__call__` is \
              `BoundMethod[typing.Callable(Foo.__init__)[[Named(self, Foo), Named(x, int), \
              Named(y, str)], Foo], Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class Foo:
                 x: str = ""
                 def __init__(self) -> None:
                     self.x: int = 1
             |}
           [
             "Illegal annotation target [35]: Target `self.x` cannot be annotated as it shadows \
              the class-level annotation of `str` with `int`.";
           ];
    ]


let test_infer_constructor_attributes =
  test_list
    [
      (* We infer basic constructors. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                pass
              class D:
                def __init__(self) -> None:
                  self.x = C()
                def foo(self) -> int:
                  return self.x
            |}
           ["Incompatible return type [7]: Expected `int` but got `C`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class C:
                pass
              class D:
                def __init__(self) -> None:
                  # We trust the callee blindly without examining the arguments for inference.
                  self.x = C(1,2,3,4)
                def foo(self) -> int:
                  return self.x
            |}
           [
             "Too many arguments [19]: Call `object.__init__` expects 0 positional arguments, 4 were"
             ^ " provided.";
             "Incompatible return type [7]: Expected `int` but got `C`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class A:
                  def __init__(self, x: int) -> None:
                      self.y = x
                      self.x = x
                      self._x = x
                      self.__x = x
              def foo(a: A) -> None:
                reveal_type(a.y)
                reveal_type(a.x)
                reveal_type(a._x)
                reveal_type(a.__x)
             |}
           [
             "Revealed type [-1]: Revealed type for `a.y` is `int`.";
             "Revealed type [-1]: Revealed type for `a.x` is `int`.";
             "Revealed type [-1]: Revealed type for `a._x` is `int`.";
             (* Private attribute throws undefined attribute error. *)
             "Revealed type [-1]: Revealed type for `a.__x` is `unknown`.";
             "Undefined attribute [16]: `A` has no attribute `__x`. `__x` looks like a private \
              attribute, which is not accessible from outside its parent class.";
           ];
    ]


let test_newtype =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class C():
                def __init__(self, a: int, b: str) -> None: pass
              T = typing.NewType('T', C)
              def foo() -> T:
                return T(C(7, "A"))
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import typing
              class C():
                def __init__(self, a: int, b: str) -> None: pass
              T = typing.NewType('T', C)
              def foo() -> T:
                return T(7, "A")
            |}
           [
             "Too many arguments [19]: Call `T.__init__` expects 1 positional argument, 2 were \
              provided.";
           ];
    ]


let test_init_subclass =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str) -> None:
                    cls.swallow = swallow
                    super().__init_subclass__()

              class Quest(QuestBase, swallow="african"):
                  pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str) -> None:
                    cls.swallow = swallow
                    super().__init_subclass__()

              class Quest(QuestBase, swallow="african", swallow="african"):
                  pass
            |}
           [
             "Unexpected keyword [28]: Unexpected keyword argument `swallow` to call \
              `QuestBase.__init_subclass__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, bird: str) -> None:
                    pass

              class Quest(QuestBase, swallow="african"):
                  pass
            |}
           [
             "Unexpected keyword [28]: Unexpected keyword argument `swallow` to call \
              `QuestBase.__init_subclass__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str, coconut: str) -> None:
                    pass

              class Quest(QuestBase, swallow="african"):
                  pass
            |}
           ["Missing argument [20]: Call `QuestBase.__init_subclass__` expects argument `coconut`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str) -> None:
                    pass

              class Quest(QuestBase, swallow="african", coconut=0):
                  pass
            |}
           [
             "Unexpected keyword [28]: Unexpected keyword argument `coconut` to call \
              `QuestBase.__init_subclass__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                pass

              class Quest(QuestBase, swallow="african"):
                  pass
            |}
           [
             "Unexpected keyword [28]: Unexpected keyword argument `swallow` to call \
              `object.__init_subclass__`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str) -> None:
                    cls.swallow = swallow
                    super().__init_subclass__()

              class Quest(QuestBase, swallow="african"):
                  pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              class QuestBase:
                swallow: str = ""
                def __init_subclass__(cls, swallow: str) -> None:
                    cls.swallow = swallow
                    super().__init_subclass__()

              class Quest(QuestBase):
                  pass
            |}
           ["Missing argument [20]: Call `QuestBase.__init_subclass__` expects argument `swallow`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any
              class QuestBase:
                def __init_subclass__(cls, **kwargs: Any) -> None:
                    pass

              class Quest(QuestBase):
                pass

              class Quest2(QuestBase, arbitrary="string"):
                pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Any
              class QuestBase:
                def __init_subclass__(cls, **kwargs: Any) -> None:
                    pass

              class Quest(QuestBase):
                pass

              class SubQuest(Quest, arbitrary="string"):
                pass
            |}
           [];
    ]


let test_dictionary_constructor =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            from typing import Optional, Dict
            def expand(x: Optional[Dict[str, int]] = None) -> None:
              new_dict = {
                  **x,
                  "param": 7,
              }
              reveal_type(new_dict)
            |}
           [
             "Invalid argument [32]: Keyword argument `x` has type `Optional[Dict[str, int]]` but \
              must be a mapping.";
             "Revealed type [-1]: Revealed type for `new_dict` is `unknown`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
            from typing import Dict, Mapping
            def combine(x: Dict[str, int], y: Mapping[float, bool]) -> None:
              new_dict = {
                  **x,
                  True: "A",
                  **y,
              }
              reveal_type(new_dict)
            |}
           [
             "Revealed type [-1]: Revealed type for `new_dict` is `Dict[typing.Union[float, str], \
              typing.Union[int, str]]`.";
           ];
    ]


let test_register_buffer_attribute =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import torch
              import torch.nn as nn

              class Foo(nn.Module):
                def __init__(self) -> None:
                  super(Foo, self).__init__()
                  self.register_buffer("foo", torch.zeros(10, 20))
                  self.register_buffer("foo_persistent", torch.zeros(10, 20), persistent=False)
                  self.register_buffer("none_buffer", None)

                def bar(self) -> None:
                  reveal_type(self.foo)
                  reveal_type(self.foo_persistent)
                  reveal_type(self.none_buffer)

              def baz() -> None:
                y = Foo().foo
                reveal_type(y)
            |}
           [
             "Missing attribute annotation [4]: Attribute `none_buffer` of class `Foo` has type \
              `None` but no type is specified.";
             "Revealed type [-1]: Revealed type for `self.foo` is `torch.Tensor`.";
             "Revealed type [-1]: Revealed type for `self.foo_persistent` is `torch.Tensor`.";
             "Revealed type [-1]: Revealed type for `self.none_buffer` is `unknown`.";
             "Revealed type [-1]: Revealed type for `y` is `torch.Tensor`.";
           ];
      (* No spurious "uninitialized attribute" error if someone also explicitly declares the
         attribute. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import torch
              import torch.nn as nn

              class Foo(nn.Module):
                foo: torch.Tensor

                def __init__(self) -> None:
                  super(Foo, self).__init__()
                  self.register_buffer("foo", torch.zeros(10, 20))

                def bar(self) -> None:
                  reveal_type(self.foo)
            |}
           ["Revealed type [-1]: Revealed type for `self.foo` is `torch.Tensor`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import torch
              import torch.nn as nn

              def not_a_literal() -> str: ...

              class Foo(nn.Module):
                def __init__(self) -> None:
                  super(Foo, self).__init__()
                  self.register_buffer("foo", "not a tensor or None")

                def bar(self) -> None:
                  reveal_type(self.foo)
            |}
           [
             "Incompatible attribute type [8]: Attribute `foo` declared in class `Foo` has type \
              `Tensor` but is used as type `str`.";
             "Revealed type [-1]: Revealed type for `self.foo` is `torch.Tensor`.";
           ];
      (* TODO(T80453653): We shouldn't respect `register_buffer` in non-Modules. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              import torch
              class NotAModule:
                def __init__(self) -> None:
                  super(NotAModule, self).__init__()
                  self.register_buffer("foo", torch.zeros(10, 20))

                def bar(self) -> None:
                  reveal_type(self.foo)
            |}
           ["Revealed type [-1]: Revealed type for `self.foo` is `torch.Tensor`."];
    ]


let test_generic__new__ =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Generic, Iterable, TypeVar, overload

              _T_co = TypeVar("_T_co", covariant=True)
              _T1 = TypeVar("_T1")
              _T2 = TypeVar("_T2")

              class zip(Generic[_T_co]):
                @overload
                def __new__(cls, iter1: Iterable[_T1]) -> zip[tuple[_T1]]: ...
                @overload
                def __new__(cls, iter1: Iterable[_T1], iter2: Iterable[_T2]) -> zip[tuple[_T1, _T2]]: ...

              def main(x1: list[str], x2: list[int]) -> None:
                x3 = zip(x1)
                x4 = zip(x1, x2)
                reveal_type(x3)
                reveal_type(x4)
            |}
           [
             "Missing overload implementation [42]: Overloaded function `zip.__new__` must have an \
              implementation.";
             "Revealed type [-1]: Revealed type for `x3` is `zip[typing.Tuple[str]]`.";
             "Revealed type [-1]: Revealed type for `x4` is `zip[typing.Tuple[str, int]]`.";
           ];
    ]


let () =
  "constructor"
  >::: [
         test_check_invalid_constructor;
         test_check_init;
         test_check_constructors;
         test_infer_constructor_attributes;
         test_newtype;
         test_init_subclass;
         test_dictionary_constructor;
         test_register_buffer_attribute;
         test_generic__new__;
       ]
  |> Test.run
