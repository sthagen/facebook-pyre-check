(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_ignore_readonly =
  let assert_type_errors = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def foo(x: ReadOnly[Bar]) -> Bar:
                y: Bar = x
                z: ReadOnly[Bar] = y
                return z
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      (* The type checking analysis will check compatibility for the type wrapped by `ReadOnly`. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def foo(x: ReadOnly[Bar]) -> None:
                y: str = x
            |}
           [
             "Incompatible variable type [9]: y is declared to have type `str` but is used as type \
              `pyre_extensions.ReadOnly[Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing_extensions import Literal

              def foo(
                always_true: ReadOnly[Literal[True]],
                always_false: ReadOnly[Literal[False]]
              ) -> None:
                x: Literal[True] = always_true or False
                y: Literal[False] = always_false and True
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x is declared to have type \
              `typing_extensions.Literal[True]` but is used as type \
              `pyre_extensions.ReadOnly[typing_extensions.Literal[True]]`.";
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `typing_extensions.Literal[False]` but is used as type \
              `pyre_extensions.ReadOnly[typing_extensions.Literal[False]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              def foo(s: ReadOnly[str]) -> None:
                y: str = s.capitalize()
            |}
           [
             "ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `str.capitalize` may modify its object. Cannot call it on readonly expression `s` of \
              type `pyre_extensions.ReadOnly[str]`.";
           ];
      (* Verify the behavior of overload selection, when ordering is correct *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|

              from typing import overload, Self
              from pyre_extensions import ReadOnly

              class Bar:
                  @overload
                  def method_rw_ro(self) -> Self:
                      ...

                  @overload
                  def method_rw_ro(self: ReadOnly[Self]) -> ReadOnly[Self]:
                      ...


              def f(rw: Bar, ro: ReadOnly[Bar]) -> None:
                reveal_type(rw.method_rw_ro())
                reveal_type(ro.method_rw_ro())
            |}
           [
             "Missing overload implementation [42]: Overloaded function `Bar.method_rw_ro` must \
              have an implementation.";
             "Revealed type [-1]: Revealed type for `rw.method_rw_ro()` is `Bar`.";
             "Revealed type [-1]: Revealed type for `ro.method_rw_ro()` is \
              `pyre_extensions.ReadOnly[Bar]`.";
           ];
      (* Verify the behavior of overload selection, when ordering is incorrect *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|

              from typing import overload, Self
              from pyre_extensions import ReadOnly

              class Bar:
                  @overload
                  def method_ro_rw(self: ReadOnly[Self]) -> ReadOnly[Self]:
                      ...

                  @overload
                  def method_ro_rw(self) -> Self:
                      ...


              def f(rw: Bar, ro: ReadOnly[Bar]) -> None:
                reveal_type(rw.method_ro_rw())
                reveal_type(ro.method_ro_rw())
            |}
           [
             "Missing overload implementation [42]: Overloaded function `Bar.method_ro_rw` must \
              have an implementation.";
             "Incompatible overload [43]: The overloaded function `Bar.method_ro_rw` on line 12 \
              will never be matched. The signature `(self: \
              pyre_extensions.ReadOnly[_Self_test_Bar__]) -> \
              pyre_extensions.ReadOnly[_Self_test_Bar__]` is the same or broader.";
             "Revealed type [-1]: Revealed type for `rw.method_ro_rw()` is \
              `pyre_extensions.ReadOnly[Bar]`.";
             "Revealed type [-1]: Revealed type for `ro.method_ro_rw()` is \
              `pyre_extensions.ReadOnly[Bar]`.";
           ];
    ]


let test_readonly_configuration_flag =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def main() -> None:
                x: ReadOnly[Bar]
                y = x
                z: Bar = y
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: z is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      (* Test readonly violations at the top level. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              x: ReadOnly[Bar]
              y: Bar = x
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
    ]


let test_assignment =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def main() -> None:
                x: ReadOnly[Bar]
                y = x
                z: Bar = y
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: z is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def main() -> None:
                x = Bar()
                y = x
                z: ReadOnly[Bar] = y
            |}
           [];
      (* Treat constants, such as `42` or `...`, as assignable to mutable types. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                # This is treated as `some_attribute: Bar = ...`.
                some_attribute: Bar

              class Bar: ...

              def main() -> None:
                x: Bar = Bar()
            |}
           [
             "Uninitialized attribute [13]: Attribute `some_attribute` is declared in class `Foo` \
              to have type `Bar` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                mutable_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo

                x1: Bar = readonly_foo.mutable_attribute
                x2: Bar = mutable_foo.mutable_attribute
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Baz: ...

              class Bar:
                bar_attribute: Baz = Baz()

              class Foo:
                foo_attribute: Bar = Bar()

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo

                x1: Baz = readonly_foo.foo_attribute.bar_attribute
                x2: Baz = mutable_foo.foo_attribute.bar_attribute
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have type \
              `test.Baz` but is used as type `pyre_extensions.ReadOnly[test.Baz]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              class Foo:
                readonly_attribute: ReadOnly[Bar] = Bar()

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo

                x1: Bar = readonly_foo.readonly_attribute
                x2: Bar = mutable_foo.readonly_attribute
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible variable type [3001]: x2 is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      (* Handle attribute types that have both `ReadOnly[...]` and `Type[...]`. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import Type

              class Foo:
                some_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                readonly_type_foo: ReadOnly[Type[Foo]]
                type_readonly_foo: Type[ReadOnly[Foo]]
                x: Bar = readonly_type_foo.some_attribute
                y: Bar = type_readonly_foo.some_attribute
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                some_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                readonly_foo.some_attribute = Bar()
            |}
           [
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `some_attribute` since it is readonly.";
           ];
      (* It is ok to reassign to a readonly attribute of a mutable object, since we aren't actually
         modifying the value that has been marked as readonly. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                readonly_attribute: ReadOnly[Bar] = Bar()
                mutable_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                mutable_foo: Foo
                mutable_foo.readonly_attribute = Bar()
                mutable_foo.mutable_attribute = Bar()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              class Foo:
                readonly_attribute: ReadOnly[Bar] = Bar()
                mutable_attribute: Bar = Bar()

                def some_method(self) -> None:
                  self.readonly_attribute = Bar()
                  self.mutable_attribute = Bar()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              class Foo:
                def __init__(self, x: ReadOnly[Bar], some_bool: bool) -> None:
                  self.x = x

                  if some_bool:
                    self.x = Bar()
            |}
           [];
      (* TODO(T130377746): Recognize attribute for `ReadOnly[Type[Foo]]` when it is the target of an
         assignment. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import Type

              class Foo:
                some_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                readonly_type_foo: ReadOnly[Type[Foo]]
                readonly_type_foo.some_attribute = Bar()

                type_readonly_foo: Type[ReadOnly[Foo]]
                type_readonly_foo.some_attribute = Bar()
            |}
           [
             "Undefined attribute [16]: `pyre_extensions.ReadOnly[Type[Foo]]` has no attribute \
              `some_attribute`.";
           ];
      (* TODO(T130377746): Emit readonly violation error when assigning to attribute of
         `Type[ReadOnly[Foo]]`. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import Type

              class Foo:
                some_attribute: Bar = Bar()

              class Bar: ...

              def main() -> None:
                type_readonly_foo: Type[ReadOnly[Foo]]
                type_readonly_foo.some_attribute = Bar()
            |}
           [];
      (* Technically, reassigning to a variable doesn't mutate it. So, we don't emit an error in
         this case. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def main() -> None:
                x: ReadOnly[Bar] = Bar()
                x = Bar()
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Bar: ...

              def main(xs: List[ReadOnly[Bar]]) -> None:
                y: List[Bar] = xs
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `typing.List[test.Bar]` but is used as type \
              `typing.List[pyre_extensions.ReadOnly[test.Bar]]`.";
           ];
      (* We cannot assign to any attribute of a readonly object. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                mutable_attribute: Bar = Bar()

              class Bar: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                readonly_foo.mutable_attribute = Bar()
            |}
           [
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `mutable_attribute` since it is readonly.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                @property
                def some_property(self) -> str: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                reveal_type(readonly_foo.some_property)
            |}
           [
             "Revealed type [-1]: Revealed type for `readonly_foo.some_property` is \
              `pyre_extensions.ReadOnly[str]` (final).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                @property
                def some_property(self) -> str: ...

                @some_property.setter
                def some_property(self, value: str) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                readonly_foo.some_property = "hello"
            |}
           [
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `some_property` since it is readonly.";
           ];
    ]


let test_function_call =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_mutable_and_readonly(x: Bar, y: ReadOnly[Bar]) -> ReadOnly[Bar]: ...

              def main() -> None:
                x: ReadOnly[Bar]
                y: Bar = expect_mutable_and_readonly(x, x)
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_mutable_and_readonly`, for 1st positional argument, expected `test.Bar` \
              but got `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def foo(x: Foo) -> ReadOnly[Foo]: ...

              def main(x: Foo) -> None:
                y: Foo = foo(foo(x))
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Foo` but is used as type `pyre_extensions.ReadOnly[test.Foo]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call `test.foo`, for 1st \
              positional argument, expected `test.Foo` but got \
              `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_mutable(x: Bar) -> ReadOnly[Bar]: ...

              def main() -> None:
                x: ReadOnly[Bar]
                expect_mutable(x)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_mutable`, for 1st positional argument, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def return_readonly(self, x: Bar) -> ReadOnly[Bar]: ...

              class Bar: ...

              def main() -> None:
                foo: Foo
                x: ReadOnly[Bar]
                y: Bar = foo.return_readonly(x)
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.Foo.return_readonly`, for 1st positional argument, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def return_readonly(self, x: Bar) -> ReadOnly[Bar]: ...

              class Bar: ...

              def return_foo(x: Bar) -> Foo: ...

              def main() -> None:
                foo: Foo
                x: ReadOnly[Bar]
                y: Bar = return_foo(x).return_readonly(x)
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call `test.return_foo`, \
              for 1st positional argument, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.Foo.return_readonly`, for 1st positional argument, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def expect_readonly_self(self: ReadOnly[Foo], x: Bar) -> None: ...

              class Bar: ...

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo
                x: Bar
                readonly_foo.expect_readonly_self(x)
                mutable_foo.expect_readonly_self(x)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def expect_mutable_self(self, x: Bar) -> None: ...

              class Bar: ...

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo
                x: Bar
                readonly_foo.expect_mutable_self(x)
                mutable_foo.expect_mutable_self(x)
            |}
           [
             "ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `test.Foo.expect_mutable_self` may modify its object. Cannot call it on readonly \
              expression `readonly_foo` of type `pyre_extensions.ReadOnly[Foo]`.";
           ];
      (* A method with readonly `self` can be called on either mutable or readonly objects. However,
         the method itself cannot call other mutating methods. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           ~include_line_numbers:true
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def expect_mutable_self(self, x: Bar) -> None: ...

                def expect_readonly_self(self: ReadOnly["Foo"], x: Bar) -> None:
                  self.expect_mutable_self(x)

              class Bar: ...

              def main() -> None:
                readonly_foo: ReadOnly[Foo]
                mutable_foo: Foo
                x: Bar
                readonly_foo.expect_readonly_self(x)
                mutable_foo.expect_readonly_self(x)
            |}
           [
             "8: ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `test.Foo.expect_mutable_self` may modify its object. Cannot call it on readonly \
              expression `self` of type `pyre_extensions.ReadOnly[Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_positional_mutable_and_readonly(x: Bar, y: ReadOnly[Bar], /) -> None:
                reveal_type(x)
                reveal_type(y)

              def main(my_readonly: ReadOnly[Bar]) -> None:
                expect_positional_mutable_and_readonly(my_readonly, my_readonly)
            |}
           [
             "Revealed type [-1]: Revealed type for `x` is `Bar`.";
             "Revealed type [-1]: Revealed type for `y` is `pyre_extensions.ReadOnly[Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_positional_mutable_and_readonly`, for 1st positional argument, expected \
              `test.Bar` but got `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_keyword_only( *, x: Bar, y: ReadOnly[Bar]) -> None:
                reveal_type(x)
                reveal_type(y)

              def main(my_readonly: ReadOnly[Bar], my_mutable: Bar) -> None:
                expect_keyword_only(y=my_mutable, x=my_readonly)
            |}
           [
             "Revealed type [-1]: Revealed type for `x` is `Bar`.";
             "Revealed type [-1]: Revealed type for `y` is `pyre_extensions.ReadOnly[Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_keyword_only`, for argument `x`, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_kwargs( **kwargs: Bar) -> None: ...

              def main(my_readonly: ReadOnly[Bar], my_mutable: Bar, **kwargs: ReadOnly[Bar]) -> None:
                expect_kwargs(y=my_mutable, x=my_readonly)
                expect_kwargs( **kwargs)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_kwargs`, for argument `x`, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_kwargs`, for 1st positional argument, expected `test.Bar` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import Callable

              class Bar: ...

              def main(my_readonly: ReadOnly[Bar], undefined: Callable[..., ReadOnly[Bar]]) -> None:
                x: Bar = undefined(my_readonly)
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: x is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_mutable(x: object) -> None:
                # pyre-ignore[16]: `object` has no attribute `some_attribute`.
                x.some_attribute = 42

              def main(readonly: ReadOnly[Bar]) -> None:
                expect_mutable(readonly)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_mutable`, for 1st positional argument, expected `object` but got \
              `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              def expect_union(x: Bar | ReadOnly[str]) -> None: ...

              def main(readonly_string: ReadOnly[str]) -> None:
                expect_union(readonly_string)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Bar: ...

              def expect_list_mutable(xs: List[ReadOnly[Bar]]) -> None: ...

              def main(xs: List[Bar]) -> None:
                expect_list_mutable(xs)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_list_mutable`, for 1st positional argument, expected \
              `typing.List[pyre_extensions.ReadOnly[test.Bar]]` but got `typing.List[test.Bar]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Bar: ...

              def expect_list_list_mutable(xs: List[List[ReadOnly[Bar]]]) -> None: ...

              def main(xs: List[List[Bar]]) -> None:
                expect_list_list_mutable(xs)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_list_list_mutable`, for 1st positional argument, expected \
              `typing.List[typing.List[pyre_extensions.ReadOnly[test.Bar]]]` but got \
              `typing.List[typing.List[test.Bar]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly
              from typing import Union

              class Bar: ...

              def expect_union(xs: Union[Bar, str]) -> None: ...

              def main(readonly_Bar: ReadOnly[Bar] | ReadOnly[str]) -> None:
                expect_union(readonly_Bar)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_union`, for 1st positional argument, expected `typing.Union[str, \
              test.Bar]` but got `typing.Union[pyre_extensions.ReadOnly[str], \
              pyre_extensions.ReadOnly[test.Bar]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from typing import TypeVar
              from pyre_extensions import ReadOnly
              from typing_extensions import Self

              class Foo:
                  def mutable_method(self) -> None: ...

                  def readonly_method(self: ReadOnly[Self]) -> None:
                    self.mutable_method()
              |}
           [
             "ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `test.Foo.mutable_method` may modify its object. Cannot call it on readonly \
              expression `self` of type `pyre_extensions.ReadOnly[Variable[_Self_test_Foo__ (bound \
              to Foo)]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from typing import Awaitable, TypeVar, Callable
              from pyre_extensions import ParameterSpecification, ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              T = TypeVar("T")
              P = ParameterSpecification("P")

              def my_decorator(func: Callable[P, T]) -> Callable[P, T]: ...

              class Foo:
                  @classmethod
                  @my_decorator
                  async def some_classmethod(cls, x: str) -> None: ...

                  @my_decorator
                  async def some_method(self, x: str) -> None: ...

                  async def outer_method(self) -> None:
                    @readonly_entrypoint
                    def inner() -> None:
                      await self.some_method(42)
                      await self.some_classmethod(42)
            |}
           [
             "ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `test.Foo.some_method` may modify its object. Cannot call it on readonly expression \
              `self` of type `pyre_extensions.ReadOnly[Foo]`.\n\
              Note that this is a zone entrypoint and any captured variables are treated as \
              readonly. Wiki: \
              https://www.internalfb.com/intern/wiki/IG_Policy_Zones_User_Guide/Policy_Zone_APIs/Leak_Safety/ReadOnly_Propagation/";
             "Incompatible parameter type [6]: In call `Foo.some_method`, for 1st positional \
              argument, expected `str` but got `int`.";
             "Incompatible parameter type [6]: In call `Foo.some_classmethod`, for 1st positional \
              argument, expected `str` but got `int`.";
           ];
    ]


let test_await =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              async def return_readonly() -> ReadOnly[Bar]: ...

              async def main() -> None:
                y: Bar = await return_readonly()
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
    ]


let test_parameters =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(my_mutable: Foo, my_readonly: ReadOnly[Foo]) -> None:
                y: Foo = my_readonly
                y2: ReadOnly[Foo] = my_mutable
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Foo` but is used as type `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              def main(unannotated) -> None:
                y: int = unannotated
            |}
           ["Missing parameter annotation [2]: Parameter `unannotated` has no type specified."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(x: ReadOnly[Foo], /, y: ReadOnly[Foo], *, z: ReadOnly[Foo]) -> None:
                y1: Foo = x
                y2: Foo = y
                y3: Foo = z
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y1 is declared to have type \
              `test.Foo` but is used as type `pyre_extensions.ReadOnly[test.Foo]`.";
             "ReadOnly violation - Incompatible variable type [3001]: y2 is declared to have type \
              `test.Foo` but is used as type `pyre_extensions.ReadOnly[test.Foo]`.";
             "ReadOnly violation - Incompatible variable type [3001]: y3 is declared to have type \
              `test.Foo` but is used as type `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(*args: ReadOnly[Foo], **kwargs: ReadOnly[Foo]) -> None:
                reveal_type(args)
                reveal_type(kwargs)
            |}
           [
             "Revealed type [-1]: Revealed type for `args` is \
              `typing.Tuple[pyre_extensions.ReadOnly[Foo], ...]`.";
             "Revealed type [-1]: Revealed type for `kwargs` is `typing.Dict[str, \
              pyre_extensions.ReadOnly[Foo]]`.";
           ];
      (* Check for errors in constructing the default value of a parameter. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def return_readonly() -> ReadOnly[Foo]: ...

              def expect_mutable(x: Foo) -> Foo: ...

              def main(x: Foo = expect_mutable(return_readonly())) -> None:
                pass
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_mutable`, for 1st positional argument, expected `test.Foo` but got \
              `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
      (* Don't consider `x` in scope for the default value of parameter `y`. We don't need to emit
         an error here, because the type checking analysis will. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def foo(x: ReadOnly[Foo], y: Foo = x) -> None:
                pass
            |}
           [
             "Incompatible variable type [9]: y is declared to have type `Foo` but is used as type \
              `unknown`.";
             "Unbound name [10]: Name `x` is used but not defined in the current scope.";
           ];
    ]


let test_reveal_type =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(my_mutable: Foo, my_readonly: ReadOnly[Foo]) -> None:
                y1 = my_readonly
                y2 = my_mutable
                reveal_type(y1)
                reveal_type(y2)
            |}
           [
             "Revealed type [-1]: Revealed type for `y1` is `pyre_extensions.ReadOnly[Foo]`.";
             "Revealed type [-1]: Revealed type for `y2` is `Foo`.";
           ];
    ]


let test_format_string =
  let assert_type_errors_including_readonly = assert_type_errors ~enable_readonly_analysis:false in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors_including_readonly
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_mutable(x: Foo) -> ReadOnly[Foo]: ...

              def main(my_readonly: ReadOnly[Foo], my_mutable: Foo) -> None:
                s = f"hello, {expect_mutable(my_readonly)}, {expect_mutable(my_mutable)}"
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.expect_mutable`, for 1st positional argument, expected `test.Foo` but got \
              `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
    ]


let test_generic_types =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Generic, List, TypeVar

              T = TypeVar("T")

              def identity(x: T) -> T: ...

              class Bar: ...

              def main(readonly: ReadOnly[Bar]) -> None:
                y = identity(readonly)
                reveal_type(y)
            |}
           ["Revealed type [-1]: Revealed type for `y` is `pyre_extensions.ReadOnly[Bar]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Generic, List, TypeVar

              T = TypeVar("T")

              class Foo(Generic[T]):
                def get_element(self) -> T: ...

              class Bar: ...

              def main(foo: Foo[ReadOnly[Bar]]) -> None:
                x = foo.get_element()
                reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Bar]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Bar: ...

              def main(xs: List[ReadOnly[Bar]]) -> None:
                x = xs[0]
                reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Bar]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Bar: ...

              def main(xs: List[ReadOnly[Bar]]) -> None:
                x = xs[0]
                reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Bar]`."];
    ]


let test_refinement =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Optional

              class Foo: ...

              def main(optional_readonly: ReadOnly[Optional[Foo]]) -> None:
                if optional_readonly:
                  reveal_type(optional_readonly)
                else:
                  reveal_type(optional_readonly)
            |}
           [
             "Revealed type [-1]: Revealed type for `optional_readonly` is \
              `Optional[pyre_extensions.ReadOnly[Foo]]` (inferred: \
              `pyre_extensions.ReadOnly[Foo]`).";
             "Revealed type [-1]: Revealed type for `optional_readonly` is \
              `Optional[pyre_extensions.ReadOnly[Foo]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Optional

              class Foo: ...

              def main(optional_readonly: ReadOnly[Optional[Foo]]) -> None:
                x = optional_readonly if optional_readonly else Foo()
                reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Foo]`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Base: ...

              class Child(Base): ...

              class Foo: ...

              def main(x: ReadOnly[Base | Foo]) -> None:
                if isinstance(x, Child):
                  reveal_type(x)
                else:
                  reveal_type(x)
            |}
           [
             "Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Child]`.";
             "Revealed type [-1]: Revealed type for `x` is \
              `typing.Union[pyre_extensions.ReadOnly[Base], pyre_extensions.ReadOnly[Foo]]`.";
           ];
      (* If the variable has type `Top`, don't pollute the output with `ReadOnly` type. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from unknown_module import Foo

              variable_with_type_top: Foo

              def main() -> None:
                reveal_type(variable_with_type_top)

                if isinstance(variable_with_type_top, str):
                  reveal_type(variable_with_type_top)
            |}
           [
             (* This is merely one way to get a variable of type Top. *)
             "Undefined import [21]: Could not find a module corresponding to import \
              `unknown_module`.";
             "Undefined or invalid type [11]: Annotation `Foo` is not defined as a type.";
             "Revealed type [-1]: Revealed type for `variable_with_type_top` is `unknown`.";
             "Revealed type [-1]: Revealed type for `variable_with_type_top` is `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              class Bar: ...

              def main(x: ReadOnly[Foo] | Bar) -> None:
                if isinstance(x, Foo):
                  reveal_type(x)
                else:
                  reveal_type(x)
            |}
           [
             "Revealed type [-1]: Revealed type for `x` is `pyre_extensions.ReadOnly[Foo]`.";
             "Revealed type [-1]: Revealed type for `x` is `Bar`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              class Bar: ...

              def main(x: ReadOnly[Foo] | Bar) -> None:
                if not isinstance(x, Foo):
                  reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `Bar`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Optional
              from pyre_extensions import ReadOnly

              class Bar: ...

              class Foo:
                optional_attribute: Optional[Bar] = None

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                if readonly_foo.optional_attribute is not None:
                  reveal_type(readonly_foo.optional_attribute)
            |}
           [
             "Revealed type [-1]: Revealed type for `readonly_foo.optional_attribute` is \
              `Optional[pyre_extensions.ReadOnly[Bar]]` (inferred: \
              `pyre_extensions.ReadOnly[Bar]`).";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Optional
              from pyre_extensions import ReadOnly

              class Bar:
                def some_method(self: ReadOnly[Bar]) -> None: ...

              class Foo:
                optional_attribute: Optional[Bar] = None

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                if readonly_foo.optional_attribute is not None and readonly_foo.optional_attribute.some_method():
                  pass
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Optional
              from typing_extensions import Self

              class Bar:
                some_attribute: str = ""

              class Foo:
                bar: Optional[Bar] = None

                def some_method(self: ReadOnly[Self]) -> None:
                  y = self.bar.some_attribute if self.bar else ""
                  reveal_type(y)
            |}
           ["Revealed type [-1]: Revealed type for `y` is `pyre_extensions.ReadOnly[str]`."];
    ]


let test_captured_variable_for_specially_decorated_functions =
  test_list
    [
      (* Parameter captured in a nested zone entrypoint should be marked as readonly. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              class Bar: ...

              class Foo:
                x: Bar = Bar()

              def main(parameter: Foo) -> None:

                @readonly_entrypoint
                def nested() -> None:
                  reveal_type(parameter)
                  parameter.x = Bar()

                not_captured = parameter
                reveal_type(not_captured)
            |}
           [
             "Revealed type [-1]: Revealed type for `parameter` is `pyre_extensions.ReadOnly[Foo]`.";
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `x` since it is readonly.\n\
              Note that this is a zone entrypoint and any captured variables are treated as \
              readonly. Wiki: \
              https://www.internalfb.com/intern/wiki/IG_Policy_Zones_User_Guide/Policy_Zone_APIs/Leak_Safety/ReadOnly_Propagation/";
             "Revealed type [-1]: Revealed type for `not_captured` is `Foo`.";
           ];
      (* Outer local variable should be marked as readonly within the entrypoint. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              class Bar: ...

              class Foo:
                x: Bar = Bar()

              def main() -> None:
                local_variable: Foo = Foo()

                @readonly_entrypoint
                def nested() -> None:
                  reveal_type(local_variable)
                  local_variable.x = Bar()
            |}
           [
             "Revealed type [-1]: Revealed type for `local_variable` is \
              `pyre_extensions.ReadOnly[Foo]`.";
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `x` since it is readonly.\n\
              Note that this is a zone entrypoint and any captured variables are treated as \
              readonly. Wiki: \
              https://www.internalfb.com/intern/wiki/IG_Policy_Zones_User_Guide/Policy_Zone_APIs/Leak_Safety/ReadOnly_Propagation/";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              class Bar: ...

              class Foo:
                x: Bar = Bar()

              def main() -> None:
                local_variable = Foo()

                @readonly_entrypoint
                def nested() -> None:
                  reveal_type(local_variable)
                  local_variable.x = Bar()
            |}
           [
             "Missing annotation for captured variable [53]: Captured variable `local_variable` is \
              not annotated.";
             "Revealed type [-1]: Revealed type for `local_variable` is `typing.Any`.";
           ];
      (* `self` captured in a nested entrypoint should be marked as readonly. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              class Bar: ...

              class Foo:
                x: Bar = Bar()

                def some_method(self) -> None:

                  @readonly_entrypoint
                  def nested() -> None:
                    reveal_type(self)
                    self.x = Bar()
            |}
           [
             "Revealed type [-1]: Revealed type for `self` is `pyre_extensions.ReadOnly[Foo]`.";
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `x` since it is readonly.\n\
              Note that this is a zone entrypoint and any captured variables are treated as \
              readonly. Wiki: \
              https://www.internalfb.com/intern/wiki/IG_Policy_Zones_User_Guide/Policy_Zone_APIs/Leak_Safety/ReadOnly_Propagation/";
           ];
      (* `cls` captured in a nested entrypoint should be marked as readonly. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              class Bar: ...

              class Foo:
                x: Bar = Bar()

                @classmethod
                def some_classmethod(cls) -> None:

                  @readonly_entrypoint
                  def nested() -> None:
                    reveal_type(cls)
                    cls.x = Bar()
            |}
           [
             "Revealed type [-1]: Revealed type for `cls` is \
              `pyre_extensions.ReadOnly[typing.Type[Foo]]`.";
             (* TODO(T130377746): Recognize attribute for `ReadOnly[Type[Foo]]` when it is the
                target of an assignment. *)
             "Undefined attribute [16]: `pyre_extensions.ReadOnly[typing.Type[Foo]]` has no \
              attribute `x`.";
           ];
      (* TODO(T130377746): We should error when calling a readonly callable. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import readonly_entrypoint

              some_global: str = ""

              def main() -> None:
                def other_nested() -> None:
                  some_global += "foo"

                @readonly_entrypoint
                def nested() -> None:
                  reveal_type(other_nested)
                  other_nested()
            |}
           [
             "Revealed type [-1]: Revealed type for `other_nested` is \
              `pyre_extensions.ReadOnly[typing.Callable(main.other_nested)[[], None]]`.";
           ];
    ]


let test_return_type =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(x: ReadOnly[Foo]) -> Foo:
                return x
            |}
           [
             "ReadOnly violation - Incompatible return type [3004]: Expected `test.Foo` but got \
              `pyre_extensions.ReadOnly[test.Foo]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import List

              class Foo: ...

              def main(x: List[ReadOnly[Foo]]) -> List[Foo]:
                return x
            |}
           [
             "ReadOnly violation - Incompatible return type [3004]: Expected \
              `typing.List[test.Foo]` but got `typing.List[pyre_extensions.ReadOnly[test.Foo]]`.";
           ];
    ]


let test_ignored_module =
  (* Get errors with unnecessary errors filtered out, which is what end-users see. *)
  let assert_filtered_type_errors = assert_default_type_errors in
  test_list
    [
      (* Don't error when calling a "mutating" method on a readonly object from an ignored module.
         This allows us to gradually annotate the methods in that module as `ReadOnly`. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_filtered_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_module_to_ignore import Foo

              def main(foo: ReadOnly[Foo]) -> None:
                foo.some_method(42)
            |}
           [];
      (* Don't error when passing a readonly argument to a method or function defined in an ignored
         module. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_filtered_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_module_to_ignore import Foo

              def main(readonly_int: ReadOnly[int]) -> None:
                Foo().some_method(readonly_int)
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_filtered_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_module_to_ignore import some_function

              def main(readonly_int: ReadOnly[int]) -> None:
                some_function(readonly_int)
            |}
           [];
      (* Show errors in user-defined code that uses types from the ignored module. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_filtered_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_module_to_ignore import Foo

              def user_function_expects_mutable_foo(foo: Foo) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                user_function_expects_mutable_foo(readonly_foo)
            |}
           [
             "ReadOnly violation - Incompatible parameter type [3002]: In call \
              `test.user_function_expects_mutable_foo`, for 1st positional argument, expected \
              `readonly_module_to_ignore.Foo` but got \
              `pyre_extensions.ReadOnly[readonly_module_to_ignore.Foo]`.";
           ];
    ]


let test_typechecking_errors_are_prioritized =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_mutable_int(x: ReadOnly[Foo]) -> None: ...

              def main(s: str) -> None:
                expect_mutable_int(s)
            |}
           [
             "Incompatible parameter type [6]: In call `expect_mutable_int`, for 1st positional \
              argument, expected `pyre_extensions.ReadOnly[Foo]` but got `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo:
                def expect_mutable_self(self, x: int) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                readonly_foo.expect_mutable_self("hello")
                readonly_foo.non_existent_method("hello")
            |}
           [
             "ReadOnly violation - Calling mutating method on readonly type [3005]: Method \
              `test.Foo.expect_mutable_self` may modify its object. Cannot call it on readonly \
              expression `readonly_foo` of type `pyre_extensions.ReadOnly[Foo]`.";
             "Incompatible parameter type [6]: In call `Foo.expect_mutable_self`, for 1st \
              positional argument, expected `int` but got `str`.";
             "Undefined attribute [16]: `Foo` has no attribute `non_existent_method`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Bar: ...

              class Foo:
                x: Bar = Bar()

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                readonly_foo.x = "wrong type"
            |}
           [
             "Incompatible attribute type [8]: Attribute `x` declared in class `Foo` has type \
              `pyre_extensions.ReadOnly[Bar]` but is used as type `str`.";
             "ReadOnly violation - Assigning to readonly attribute [3003]: Cannot assign to \
              attribute `x` since it is readonly.";
           ];
    ]


let test_weaken_readonly_literals =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_list(x: ReadOnly[list[Foo]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                expect_readonly_list([readonly_foo, readonly_foo])
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_list(x: ReadOnly[list[list[Foo]]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                expect_readonly_list([[readonly_foo], [readonly_foo]])
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_set(x: ReadOnly[set[Foo]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                expect_readonly_set({readonly_foo, readonly_foo})
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_set(x: ReadOnly[set[set[Foo]]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                expect_readonly_set({{readonly_foo}, {readonly_foo}})
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_dict(x: ReadOnly[dict[str, Foo]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo], readonly_str: ReadOnly[str]) -> None:
                expect_readonly_dict({ "foo": readonly_foo, "bar": readonly_foo})
                expect_readonly_dict({ readonly_str: readonly_foo, readonly_str: readonly_foo})
                expect_readonly_dict({ readonly_str: x for x in [readonly_foo, readonly_foo]})
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def expect_readonly_nested_dict(x: ReadOnly[dict[Foo, dict[str, Foo]]]) -> None: ...

              def main(readonly_foo: ReadOnly[Foo], readonly_str: ReadOnly[str]) -> None:
                expect_readonly_nested_dict({ Foo(): { "foo": readonly_foo }})
            |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                xs = [readonly_foo, readonly_foo]
                reveal_type(xs)
            |}
           [
             "Revealed type [-1]: Revealed type for `xs` is \
              `pyre_extensions.ReadOnly[typing.List[Foo]]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class Foo: ...

              def main(readonly_list: ReadOnly[list[Foo]]) -> None:
                xs = [x for x in readonly_list]
                reveal_type(xs)
            |}
           [
             "Revealed type [-1]: Revealed type for `xs` is \
              `pyre_extensions.ReadOnly[typing.List[Foo]]`.";
           ];
    ]


(* Some error messages emit line and column number as -1:-1, which makes the errors unsuppressable
   and prevents diffs from landing.

   Ensure that readonly doesn't emit errors like those. *)
let test_error_message_has_non_any_location =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           ~include_line_numbers:true
           {|
              from pyre_extensions import ReadOnly

              class FooWithCustomEqualityCheck:
                def __eq__(self, other: object) -> bool: ...

              def main(
                readonly_foo: ReadOnly[FooWithCustomEqualityCheck],
                mutable_foo: FooWithCustomEqualityCheck
              ) -> None:
                readonly_foo == readonly_foo
                readonly_foo == mutable_foo
                mutable_foo == readonly_foo
            |}
           [
             "11: Unsupported operand [58]: `==` is not supported for operand types \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]` and \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]`.";
             "11: Unsupported operand [58]: `==` is not supported for operand types \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]` and \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]`.";
             "12: Unsupported operand [58]: `==` is not supported for operand types \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]` and \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]`.";
             "13: Unsupported operand [58]: `==` is not supported for operand types \
              `FooWithCustomEqualityCheck` and \
              `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]`.";
           ];
      (* Test that fixmes are able to suppress the error. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly

              class FooWithCustomEqualityCheck:
                def __eq__(self, other: object) -> bool: ...

              def main(
                readonly_foo: ReadOnly[FooWithCustomEqualityCheck],
                mutable_foo: FooWithCustomEqualityCheck
              ) -> None:
                # pyre-ignore[58]: `==` is not supported for operand types
                # `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]` and
                # `pyre_extensions.ReadOnly[FooWithCustomEqualityCheck]`.
                readonly_foo == readonly_foo
            |}
           [];
    ]


let test_allowlisted_classes_are_not_readonly =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import MySafeReadOnlyClass

              def main(readonly_object: ReadOnly[MySafeReadOnlyClass]) -> None:
                reveal_type(readonly_object)
                reveal_type(readonly_object.some_attribute)
            |}
           [
             "Revealed type [-1]: Revealed type for `readonly_object` is `MySafeReadOnlyClass`.";
             "Revealed type [-1]: Revealed type for `readonly_object.some_attribute` is `str`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import MySafeReadOnlyClass

              def main(readonly_object: ReadOnly[str | bool | MySafeReadOnlyClass]) -> None:
                reveal_type(readonly_object)
            |}
           [
             "Revealed type [-1]: Revealed type for `readonly_object` is \
              `typing.Union[MySafeReadOnlyClass, bool, pyre_extensions.ReadOnly[str]]`.";
           ];
      (* Looking up an attribute of `MySafeReadOnlyClass` even from a readonly object is treated as
         mutable. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import MySafeReadOnlyClass

              class Foo:
                some_attribute: MySafeReadOnlyClass = MySafeReadOnlyClass()

              def main(readonly_foo: ReadOnly[Foo]) -> None:
                reveal_type(readonly_foo.some_attribute)
            |}
           [
             "Revealed type [-1]: Revealed type for `readonly_foo.some_attribute` is \
              `MySafeReadOnlyClass`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Any

              def main(x: ReadOnly[int], y: ReadOnly[bool]) -> None:
                reveal_type(x)
                reveal_type(y)
            |}
           [
             "Revealed type [-1]: Revealed type for `x` is `int`.";
             "Revealed type [-1]: Revealed type for `y` is `bool`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import TypeVar

              T = TypeVar("T")

              def lookup(d: ReadOnly[dict[str, T]], key: str) -> ReadOnly[T]: ...

              def main(d: ReadOnly[dict[str, int]]) -> None:
                  x = lookup(d, "foo")
                  reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from typing import Any, TypeVar

              T = TypeVar("T")

              def lookup(d: ReadOnly[dict[str, T]], key: str) -> ReadOnly[T]: ...

              def main(d: ReadOnly[dict[str, Any]]) -> None:
                  x = lookup(d, "foo")
                  reveal_type(x)
            |}
           ["Revealed type [-1]: Revealed type for `x` is `typing.Any`."];
    ]


let test_allowlisted_generic_integer_classes =
  test_list
    [
      (* This tests the allowlist behavior on specific unusual pattern used for id types. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from pyre_extensions import ReadOnly
              from readonly_stubs_for_testing import MySafeReadOnlyIdType

              def takes_default_visibility(not_read_only: MySafeReadOnlyIdType[int]) -> None:
                reveal_type(not_read_only)

              def main(read_only: ReadOnly[MySafeReadOnlyIdType[int]]) -> None:
                takes_default_visibility(read_only)
                reveal_type(read_only)
            |}
           [
             "Revealed type [-1]: Revealed type for `not_read_only` is `MySafeReadOnlyIdType[int]`.";
             "Revealed type [-1]: Revealed type for `read_only` is `MySafeReadOnlyIdType[int]`.";
           ];
    ]


let test_typing_PyreReadOnly =
  (* In order to safely patch typeshed so that some stdlib methods are read-only, we rely on a
     made-up, stub-only `typing._PyreReadOnly_` class. This test verifies that it behaves
     equivalently to (and interoperates with) `pyre_extensions.ReadOnly` *)
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|

              from typing import _PyreReadOnly_
              from pyre_extensions import ReadOnly

              class Bar: ...

              def foo(x: _PyreReadOnly_[Bar]) -> Bar:
                y: Bar = x
                z: ReadOnly[Bar] = y
                return z
            |}
           [
             "ReadOnly violation - Incompatible variable type [3001]: y is declared to have type \
              `test.Bar` but is used as type `pyre_extensions.ReadOnly[test.Bar]`.";
           ];
    ]


let test_no_pyre_extensions =
  let assert_type_errors = assert_type_errors ~include_pyre_extensions:false in
  test_list
    [
      (* TODO(T200918328): [len(x)] should be an error. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors {|
        def f(x: int) -> int:
          return len(x)
      |} [];
    ]


let () =
  "readOnly"
  >::: [
         test_ignore_readonly;
         test_readonly_configuration_flag;
         test_assignment;
         test_function_call;
         test_await;
         test_parameters;
         test_reveal_type;
         test_format_string;
         test_generic_types;
         test_refinement;
         test_captured_variable_for_specially_decorated_functions;
         test_return_type;
         test_ignored_module;
         test_typechecking_errors_are_prioritized;
         test_weaken_readonly_literals;
         test_error_message_has_non_any_location;
         test_allowlisted_classes_are_not_readonly;
         test_allowlisted_generic_integer_classes;
         test_typing_PyreReadOnly;
         test_no_pyre_extensions;
       ]
  |> Test.run
