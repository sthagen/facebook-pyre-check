(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Test

let test_transform_environment context =
  let assert_equivalent_attributes = assert_equivalent_attributes ~context in
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        ...
    |}
    [
      {|
        class Foo:
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      if 1 > 2:
        @dataclass
        class Foo:
          ...
    |}
    [
      {|
        class Foo:
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        def foo() -> None:
          pass
    |}
    [
      {|
        # spacer
        class Foo:
          def foo() -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclasses.dataclass
      class Foo:
        def foo() -> None:
          pass
    |}
    [
      {|
        @spacer
        class Foo:
          def foo() -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
           pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        def __init__(self) -> None:
          pass
        def __repr__(self) -> str:
          pass
    |}
    [
      {|
       class Foo:
         def __init__(self) -> None:
           pass
         def __repr__(self) -> str:
           pass
         def __eq__(self, o: object) -> bool:
           pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name = 'abc'
    |}
    [
      {|
        class Foo:
          name: unknown = 'abc'
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
    |}
    [
      {|
        class Foo:
          name: str
          def __init__(self, name: str) -> None:
            self.name = name
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
        age: int
    |}
    [
      {|
        class Foo:
          name: str
          age: int
          def __init__(self, name: str, age: int) -> None:
            self.name = name
            self.age = age
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
        age: int
        def __init__(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          name: str
          age: int
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
        age = 3
    |}
    [
      {|
        class Foo:
          name: str
          age: unknown = 3
          def __init__(self, name: str) -> None:
            self.name = name
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
        age: int = 3
    |}
    [
      {|
        class Foo:
          name: str
          age: int = 3
          def __init__(self, name: str, age: int = 3) -> None:
            self.name = name
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class Foo:
        name: str
        age: typing.List[int]
        parent: typing.Tuple['int', 'str']
    |}
    [
      {|
        class Foo:
          name: str
          age: typing.List[int]
          parent: typing.Tuple['int', 'str']
          def __init__(self, name: str, age: typing.List[int], parent: typing.Tuple['int', 'str']) -> None:
            self.name = name
            self.age = age
            self.parent = parent
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];

  (* Dataclass boolean arguments *)
  assert_equivalent_attributes
    {|
      @dataclass(init = False)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass(repr = False)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __init__(self) -> None:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass(eq = False)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass(order = True)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
          def __lt__(self, o: object) -> bool:
            pass
          def __le__(self, o: object) -> bool:
            pass
          def __gt__(self, o: object) -> bool:
            pass
          def __ge__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass(eq = False, order = True)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __lt__(self, o: object) -> bool:
            pass
          def __le__(self, o: object) -> bool:
            pass
          def __gt__(self, o: object) -> bool:
            pass
          def __ge__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass(frozen = True)
      class Foo:
        def foo(self) -> None:
          pass
    |}
    [
      {|
        class Foo:
          def foo(self) -> None:
            pass
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];

  (* Dataclass inheritance *)
  assert_equivalent_attributes
    {|
      @dataclass
      class C(Base):
        z: int = 10
        x: int = 15
      @dataclass
      class Base:
        x: typing.Any = 15.0
        y: int = 0
        z: str = "a"
    |}
    [
      {|
        class C(Base):
          z: int = 10
          x: int = 15
          def __init__(self, x: int = 15, y: int = 0, z: int = 10) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class Base:
          x: typing.Any = 15.0
          y: int = 0
          z: str = "a"
          def __init__(self, x: typing.Any = 15.0, y: int = 0, z: str = "a") -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class C(Base):
        z: int = 10
        x: int = 15
      @dataclass
      class Base:
        x: typing.Any = 15.0
        y: int = 0
        z: str = "a"
    |}
    [
      {|
        class C(Base):
          z: int = 10
          x: int = 15
          def __init__(self, x: int = 15, y: int = 0, z: int = 10) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class Base:
          x: typing.Any = 15.0
          y: int = 0
          z: str = "a"
          def __init__(self, x: typing.Any = 15.0, y: int = 0, z: str = "a") -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class C(Base):
        z: int = 10
        x = 15
      @dataclass
      class Base:
        x: typing.Any = 15.0
        y: int = 0
    |}
    [
      {|
        class C(Base):
          z: int = 10
          x: unknown = 15
          def __init__(self, x: typing.Any = 15.0, y: int = 0, z: int = 10) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class Base:
          x: typing.Any = 15.0
          y: int = 0
          def __init__(self, x: typing.Any = 15.0, y: int = 0) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class C(Base):
        z: int = 10
        x: int
      @dataclass
      class Base:
        x: str = "a"
        y: int = 0
    |}
    [
      {|
        class C(Base):
          z: int = 10
          x: int
          def __init__(self, x: int = "a", y: int = 0, z: int = 10) -> None:
           self.x = x
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class Base:
          x: str = "a"
          y: int = 0
          def __init__(self, x: str = "a", y: int = 0) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class C(B):
        z: int = 10
        x: int = 15
      class B(Base):
        z: str = "a"
        y: int = 20
      @dataclass
      class Base:
        x: typing.Any = 15.0
        y: int = 0
    |}
    [
      {|
        class C(B):
          z: int = 10
          x: int = 15
          def __init__(self, x: int = 15, y: int = 0, z: int = 10) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class B(Base):
          z: str = "a"
          y: int = 20
      |};
      {|
        class Base:
          x: typing.Any = 15.0
          y: int = 0
          def __init__(self, x: typing.Any = 15.0, y: int = 0) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class C1(B1, A1):
        z: int = 10
      @dataclass
      class B1:
        y: int = 5
      @dataclass
      class A1:
        x: int = 15
    |}
    [
      {|
        class C1(B1, A1):
          z: int = 10
          def __init__(self, x: int = 15, y: int = 5, z: int = 10) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class B1:
          y: int = 5
          def __init__(self, y: int = 5) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class A1:
          x: int = 15
          def __init__(self, x: int = 15) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      class NotDataClass:
        x: int = 15
      @dataclass
      class DataClass(NotDataClass):
        y: int = 5
    |}
    [
      {|
        class NotDataClass:
          x: int = 15
      |};
      {|
        class DataClass(NotDataClass):
          y: int = 5
          def __init__(self, y: int = 5) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int
        init_variable: dataclasses.InitVar[str]
    |}
    [
      {|
        class A:
          x: int
          init_variable: dataclasses.InitVar[str]
          def __init__(self, x: int, init_variable: str) -> None:
            self.x = x
            self.init_variable = init_variable
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];

  (* Dataclass field init disabler *)
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=False)
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=False)
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=True)
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=True)
          def __init__(self, x: int) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=True, default=1)
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=True, default=1)
          def __init__(self, x: int = 1) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=True, default_factory=foo)
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=True, default_factory=foo)
          def __init__(self, x: int = foo()) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    (* NOTE: Ideally we'd like to warn about this somehow *)
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=False, default=1)
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=False, default=1)
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ];
  assert_equivalent_attributes
    {|
      @dataclass
      class A:
        x: int = dataclasses.field(init=False)
      @dataclass
      class B:
        y: str = "abc"
    |}
    [
      {|
        # spacer
        class A:
          x: int = dataclasses.field(init=False)
          def __init__(self) -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
      {|
        class B:
          y: str = "abc"
          def __init__(self, y: str = "abc") -> None:
            pass
          def __repr__(self) -> str:
            pass
          def __eq__(self, o: object) -> bool:
            pass
      |};
    ]


let () =
  "dataClass"
  >::: ["transform_environment" >: test_case ~length:Long test_transform_environment]
  |> Test.run
