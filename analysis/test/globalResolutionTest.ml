(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Ast
open Analysis
open Expression
open Statement
open Pyre
open Test
module StatementClass = Class
module Attribute = Annotated.Attribute
module Argument = Call.Argument

let ( !! ) concretes = List.map concretes ~f:(fun single -> Type.Parameter.Single single)

let last_statement_exn = function
  | { Source.statements; _ } when List.length statements > 0 -> List.last_exn statements
  | _ -> failwith "Could not parse last statement"


let test_superclasses context =
  let resolution =
    ScratchProject.setup
      ~context
      [
        ( "test.py",
          {|
      class Foo: pass
      class Bar: pass
      class SubFoo(Foo): pass
      class SubFooBar(Foo, Bar): pass
      class SubRecurse(SubFooBar): pass
      class SubRedundant(Foo, SubFooBar): pass
    |}
        );
      ]
    |> ScratchProject.build_global_resolution
  in
  let assert_successors target expected =
    let actual = GlobalResolution.successors ~resolution target in
    assert_equal
      ~printer:(List.fold ~init:"" ~f:(fun sofar next -> sofar ^ Type.Primitive.show next ^ " "))
      ~cmp:(List.equal Type.Primitive.equal)
      expected
      actual
  in
  assert_successors "test.Foo" ["object"];
  assert_successors "test.SubRedundant" ["test.SubFooBar"; "test.Foo"; "test.Bar"; "object"];
  assert_successors "test.SubFoo" ["test.Foo"; "object"];
  assert_successors "test.SubFooBar" ["test.Foo"; "test.Bar"; "object"];
  assert_successors "test.SubRecurse" ["test.SubFooBar"; "test.Foo"; "test.Bar"; "object"];
  ()


let test_get_decorator context =
  let assert_get_decorator source decorator expected =
    let resolution =
      ScratchProject.setup ~context ["__init__.py", source]
      |> ScratchProject.build_global_resolution
    in
    let assert_logic expected =
      match parse_last_statement source with
      | { Node.value = Statement.Class definition; _ } ->
          let actual =
            Node.create_with_default_location definition
            |> Node.map ~f:ClassSummary.create
            |> AstEnvironment.ReadOnly.get_decorator
                 (GlobalResolution.ast_environment resolution)
                 ~decorator
          in
          let equal_decorator left right =
            let open AstEnvironment.ReadOnly in
            String.equal left.name right.name
            && Option.equal
                 (List.equal (fun left right ->
                      Call.Argument.location_insensitive_compare left right = 0))
                 left.arguments
                 right.arguments
          in
          assert_equal
            ~printer:(List.to_string ~f:AstEnvironment.ReadOnly.show_decorator)
            ~cmp:(List.equal equal_decorator)
            expected
            actual
      | _ -> assert_true (List.is_empty expected)
    in
    assert_logic expected
  in
  assert_get_decorator "class A: pass" "decorator" [];
  assert_get_decorator
    {|
      @decorator
      class A:
        pass
    |}
    "decorator"
    [{ name = "decorator"; arguments = None }];
  assert_get_decorator {|
      @decorator.a.b
      class A:
        pass
    |} "decorator.a" [];
  assert_get_decorator {|
      @decorator
      class A:
        pass
    |} "decorator.a" [];
  assert_get_decorator
    {|
      @decorator.a.b
      class A:
        pass
    |}
    "decorator.a.b"
    [{ name = "decorator.a.b"; arguments = None }];
  assert_get_decorator
    {|
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator.a.b"
    [];
  assert_get_decorator
    {|
      @other.decorator
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator"
    [
      {
        name = "decorator";
        arguments =
          Some
            [
              { Argument.name = Some ~+"a"; value = +Expression.Name (Name.Identifier "b") };
              { Argument.name = Some ~+"c"; value = +Expression.Name (Name.Identifier "d") };
            ];
      };
    ];
  assert_get_decorator
    {|
      @decorator(a=b)
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator"
    [
      {
        name = "decorator";
        arguments =
          Some [{ Argument.name = Some ~+"a"; value = +Expression.Name (Name.Identifier "b") }];
      };
      {
        name = "decorator";
        arguments =
          Some
            [
              { Argument.name = Some ~+"a"; value = +Expression.Name (Name.Identifier "b") };
              { Argument.name = Some ~+"c"; value = +Expression.Name (Name.Identifier "d") };
            ];
      };
    ];
  assert_get_decorator
    (* `enum` imports `ABCMeta` from `abc`. *)
    {|
      @enum.ABCMeta
      class A:
        pass
    |}
    "abc.ABCMeta"
    [{ name = "abc.ABCMeta"; arguments = None }]


let test_constructors context =
  let assert_constructor source instantiated constructors =
    let instantiated = "test." ^ instantiated in
    let { ScratchProject.BuiltGlobalEnvironment.ast_environment; global_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
    in
    let resolution = GlobalResolution.create global_environment in
    let source =
      AstEnvironment.ReadOnly.get_source
        (AstEnvironment.read_only ast_environment)
        (Reference.create "test")
    in
    let source = Option.value_exn source in
    let instantiated =
      parse_single_expression instantiated
      |> GlobalResolution.parse_annotation ~validation:ValidatePrimitives resolution
    in
    match last_statement_exn source with
    | { Node.value = Statement.Class { name; _ }; _ } ->
        let callable =
          constructors
          >>| (fun constructors ->
                GlobalResolution.parse_annotation resolution (parse_single_expression constructors))
          |> Option.value ~default:Type.Top
        in
        let actual =
          Node.value name
          |> Reference.show
          |> GlobalResolution.constructor ~resolution ~instantiated
        in
        assert_equal ~printer:Type.show ~cmp:Type.equal callable actual
    | _ -> assert_unreached ()
  in
  (* Undefined constructors. *)
  assert_constructor
    "class Foo: pass"
    "Foo"
    (Some "typing.Callable('object.__init__')[[], test.Foo]");
  assert_constructor
    "class Foo: ..."
    "Foo"
    (Some "typing.Callable('object.__init__')[[], test.Foo]");

  (* Statement.Defined constructors. *)
  assert_constructor
    {|
      class Foo:
        def __init__(self, a: int) -> None: pass
    |}
    "Foo"
    (Some "typing.Callable('test.Foo.__init__')[[Named(a, int)], test.Foo]");
  assert_constructor
    {|
      class Foo:
        def __init__(self, a: int) -> None: pass
        @typing.overload
        def __init__(self, b: str) -> None: pass
    |}
    "Foo"
    (Some
       ( "typing.Callable('test.Foo.__init__')[[Named(a, int)], test.Foo]"
       ^ "[[[Named(b, str)], test.Foo]]" ));

  (* Generic classes. *)
  assert_constructor
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        def __init__(self) -> None: pass
    |}
    "Foo"
    (Some
       "typing.Callable('test.Foo.__init__')[[], \
        test.Foo[typing.TypeVar('test._K'),typing.TypeVar('test._V')]]");
  assert_constructor
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        def __init__(self, x:_K, y:_V) -> None: pass
    |}
    "Foo[int, str]"
    (Some "typing.Callable('test.Foo.__init__')[[Named(x, int), Named(y, str)], test.Foo[int, str]]");

  (* Constructors, both __init__ and __new__, are inherited from parents. *)
  assert_constructor
    {|
      class Parent:
        def __init__(self, x: int) -> None:
          pass
      class C(Parent):
        pass
    |}
    "C"
    (Some "typing.Callable('test.Parent.__init__')[[Named(x, int)], test.C]");
  assert_constructor
    {|
      class Parent:
        def __new__(self, x: str) -> None:
          pass
      class C(Parent):
        pass
    |}
    "C"
    (Some "typing.Callable('test.Parent.__new__')[[Named(x, str)], test.C]");
  assert_constructor
    {|
      T = typing.TypeVar('T', bound=C)
      class C:
        def __init__(self, x: int) -> None: pass
    |}
    "T"
    (Some "typing.Callable('test.C.__init__')[[Named(x, int)], test.T]");
  assert_constructor
    {|
      from dataclasses import dataclass
      @dataclass(frozen=True)
      class A:
          foo:int = 1
    |}
    "A"
    (Some "typing.Callable('test.A.__init__')[[Named(foo, int, default)], test.A]");
  ()


let test_is_protocol _ =
  let assert_is_protocol bases expected =
    let is_protocol bases =
      { StatementClass.name = + !&"Derp"; bases; body = []; decorators = [] }
      |> ClassSummary.create
      |> ClassSummary.is_protocol
    in
    assert_equal expected (is_protocol bases)
  in
  let parse = parse_single_expression in
  assert_is_protocol [] false;
  assert_is_protocol [{ Argument.name = None; value = parse "derp" }] false;
  assert_is_protocol [{ Argument.name = None; value = parse "typing.Protocol" }] true;
  assert_is_protocol [{ Argument.name = None; value = parse "typing_extensions.Protocol" }] true;
  assert_is_protocol [{ Argument.name = Some ~+"metaclass"; value = parse "abc.ABCMeta" }] false;
  assert_is_protocol [{ Argument.name = None; value = parse "typing.Protocol[T]" }] true;
  ()


let test_class_attributes context =
  let setup source =
    let { ScratchProject.BuiltGlobalEnvironment.global_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
    in
    GlobalResolution.create global_environment
  in
  let resolution =
    setup
      {|
        class Metaclass:
          def implicit(cls) -> int:
            return 0

        class Attributes(metaclass=Metaclass):
          def bar(self) -> int:
            pass
          def baz(self, x:int) -> int:
            pass
          def baz(self, x:str) -> str:
            pass
        class foo():
          def __init__(self):
            self.implicit: int = 1
          first: int
          second: int
          third: int = 1
          class_attribute: typing.ClassVar[int]
      |}
  in
  let create_simple_attribute
      ?(annotation = Type.integer)
      ?(class_attribute = false)
      ?(initialized = Attribute.Explicitly)
      ~parent
      name
    =
    Annotated.Attribute.create
      ~abstract:false
      ~annotation
      ~original_annotation:annotation
      ~async:false
      ~class_attribute
      ~defined:true
      ~initialized
      ~name
      ~parent
      ~visibility:ReadWrite
      ~property:false
      ~static:false
  in
  (* Test `Class.attributes`. *)
  let assert_attributes definition attributes =
    let attribute_list_equal = List.equal Attribute.equal_instantiated in
    let print_attributes attributes =
      let print_attribute attribute =
        Annotated.Attribute.sexp_of_instantiated attribute |> Sexp.to_string_hum
      in
      List.map attributes ~f:print_attribute |> String.concat ~sep:", "
    in
    let print format definition =
      Format.fprintf
        format
        "%s"
        (Sexp.to_string_hum [%message (definition : Attribute.instantiated list)])
    in
    assert_equal
      ~cmp:attribute_list_equal
      ~printer:print_attributes
      ~pp_diff:(diff ~print)
      ( GlobalResolution.attributes ~resolution definition
      |> (fun a -> Option.value_exn a)
      |> List.map ~f:(GlobalResolution.instantiate_attribute ~resolution) )
      attributes
  in
  let constructor =
    Type.Callable.create
      ~name:(Reference.create "test.foo.__init__")
      ~parameters:(Defined [])
      ~annotation:Any
      ()
  in
  assert_attributes
    "test.foo"
    [
      create_simple_attribute
        ~parent:"test.foo"
        ~annotation:constructor
        ~initialized:Implicitly
        "__init__";
      create_simple_attribute
        ~parent:"test.foo"
        ~class_attribute:true
        ~initialized:NotInitialized
        "class_attribute";
      create_simple_attribute ~parent:"test.foo" ~initialized:NotInitialized "first";
      create_simple_attribute ~parent:"test.foo" ~initialized:Implicitly "implicit";
      create_simple_attribute ~parent:"test.foo" ~initialized:NotInitialized "second";
      create_simple_attribute ~parent:"test.foo" "third";
    ];

  (*(* Test 'attribute' *)*)
  let resolution =
    setup
      {|
        class Metaclass:
          def implicit(cls) -> int:
            return 0

        class Attributes(metaclass=Metaclass):
          def bar(self) -> int:
            pass
          def baz(self, x:int) -> int:
            pass
          def baz(self, x:str) -> str:
            pass
          @property
          def property(self) -> str:
            pass

        @dataclass
        class Parent:
          inherited: int

        @dataclass
        class DC(Parent):
          x: int
          y: str

        class NT(typing.NamedTuple):
          x: int
          y: str
      |}
  in
  let assert_attribute ~parent ~parent_instantiated_type ~attribute_name ~expected_attribute =
    let instantiated, class_attributes =
      if Type.is_meta parent_instantiated_type then
        Type.single_parameter parent_instantiated_type, true
      else
        parent_instantiated_type, false
    in
    let actual_attribute =
      GlobalResolution.attribute_from_class_name
        parent
        ~transitive:true
        ~class_attributes
        ~resolution
        ~name:attribute_name
        ~instantiated
    in
    let cmp =
      let equal = Attribute.equal_instantiated in
      Option.equal equal
    in
    let printer = Option.value_map ~default:"None" ~f:Attribute.show_instantiated in
    assert_equal ~cmp ~printer expected_attribute actual_attribute
  in
  let create_expected_attribute
      ?(property = false)
      ?(visibility = Attribute.ReadWrite)
      ?(parent = "test.Attributes")
      ?(initialized = Annotated.Attribute.Implicitly)
      ?(defined = true)
      name
      callable
    =
    let annotation = parse_callable callable in
    Some
      (Annotated.Attribute.create
         ~annotation
         ~original_annotation:annotation
         ~abstract:false
         ~async:false
         ~class_attribute:false
         ~defined
         ~initialized
         ~name
         ~parent
         ~property
         ~visibility
         ~static:false)
  in
  assert_attribute
    ~parent:"test.Attributes"
    ~parent_instantiated_type:(Type.Primitive "Attributes")
    ~attribute_name:"bar"
    ~expected_attribute:
      (create_expected_attribute "bar" "typing.Callable('test.Attributes.bar')[[], int]");
  assert_attribute
    ~parent:"test.Attributes"
    ~parent_instantiated_type:(Type.Primitive "Attributes")
    ~attribute_name:"baz"
    ~expected_attribute:
      (create_expected_attribute
         "baz"
         "typing.Callable('test.Attributes.baz')[[Named(x, int)], int]");
  assert_attribute
    ~parent:"test.Attributes"
    ~parent_instantiated_type:(Type.meta (Type.Primitive "Attributes"))
    ~attribute_name:"implicit"
    ~expected_attribute:
      (create_expected_attribute
         ~parent:"test.Metaclass"
         "implicit"
         "typing.Callable('test.Metaclass.implicit')[[], int]");
  assert_attribute
    ~parent:"test.Attributes"
    ~parent_instantiated_type:(Type.meta (Type.Primitive "Attributes"))
    ~attribute_name:"property"
    ~expected_attribute:
      (create_expected_attribute ~property:true ~visibility:(ReadOnly Unrefinable) "property" "str");
  assert_attribute
    ~parent:"test.Attributes"
    ~parent_instantiated_type:(Type.Primitive "Nonsense")
    ~attribute_name:"property"
    ~expected_attribute:
      (create_expected_attribute ~property:true ~visibility:(ReadOnly Unrefinable) "property" "str");
  assert_attribute
    ~parent:"test.DC"
    ~parent_instantiated_type:(Type.Primitive "test.DC")
    ~attribute_name:"x"
    ~expected_attribute:
      (create_expected_attribute
         ~parent:"test.DC"
         ~visibility:ReadWrite
         ~initialized:Implicitly
         "x"
         "int");
  assert_attribute
    ~parent:"test.DC"
    ~parent_instantiated_type:(Type.Primitive "test.DC")
    ~attribute_name:"inherited"
    ~expected_attribute:
      (create_expected_attribute
         ~parent:"test.Parent"
         ~visibility:ReadWrite
         ~initialized:Implicitly
         "inherited"
         "int");
  assert_attribute
    ~parent:"test.NT"
    ~parent_instantiated_type:(Type.Primitive "test.NT")
    ~attribute_name:"x"
    ~expected_attribute:
      (create_expected_attribute
         ~parent:"test.NT"
         ~visibility:ReadWrite
         ~initialized:Implicitly
         "x"
         "int");
  ()


let test_typed_dictionary_attributes context =
  let assert_attributes sources ~class_name ~expected_attributes =
    let project = ScratchProject.setup ~context sources in
    let resolution = ScratchProject.build_resolution project in
    let resolution = Resolution.global_resolution resolution in
    let attributes =
      GlobalResolution.attributes
        ~resolution
        ~class_attributes:true
        ~transitive:true
        ~include_generated_attributes:true
        class_name
    in
    assert_equal
      ~printer:[%show: (string * string) list option]
      expected_attributes
      (Option.map
         ~f:
           (List.map ~f:(fun attribute ->
                Annotated.Attribute.name attribute, Annotated.Attribute.parent attribute))
         attributes)
  in
  assert_attributes
    ["foo.py", "class Foo:\n  x: int\n"]
    ~class_name:"foo.Foo"
    ~expected_attributes:
      (Some
         [
           "x", "foo.Foo";
           "__class__", "object";
           "__delattr__", "object";
           "__doc__", "object";
           "__eq__", "object";
           "__format__", "object";
           "__getattribute__", "object";
           "__hash__", "object";
           "__init__", "object";
           "__ne__", "object";
           "__new__", "object";
           "__reduce__", "object";
           "__repr__", "object";
           "__setattr__", "object";
           "__sizeof__", "object";
           "__str__", "object";
           "__call__", "type";
           "__name__", "type";
         ]);
  assert_attributes
    ["test.py", "class Movie(TypedDictionary):\n  name: str\n  year: int"]
    ~class_name:"test.Movie"
    ~expected_attributes:
      (* The fields `name` and `year` are not present. *)
      (Some
         [
           "__init__", "test.Movie";
           "__getitem__", "test.Movie";
           "__setitem__", "test.Movie";
           "get", "test.Movie";
           "setdefault", "test.Movie";
           "update", "test.Movie";
           "__iter__", "TypedDictionary";
           "__len__", "TypedDictionary";
           "copy", "TypedDictionary";
           "__contains__", "typing.Mapping";
           "items", "typing.Mapping";
           "keys", "typing.Mapping";
           "values", "typing.Mapping";
           "__class__", "object";
           "__delattr__", "object";
           "__doc__", "object";
           "__eq__", "object";
           "__format__", "object";
           "__getattribute__", "object";
           "__hash__", "object";
           "__ne__", "object";
           "__new__", "object";
           "__reduce__", "object";
           "__repr__", "object";
           "__setattr__", "object";
           "__sizeof__", "object";
           "__str__", "object";
           "__call__", "type";
           "__name__", "type";
         ]);
  ()


let test_typed_dictionary_individual_attributes context =
  let assert_attribute ~parent_name ~attribute_name ~expected_attribute =
    let sources =
      [
        ( "test.py",
          {|
            class Movie(TypedDictionary):
              name: str
              year: int
            class ChildMovie(Movie):
              rating: int
            class NonTotalMovie(TypedDictionary, NonTotalTypedDictionary):
              name: str
              year: int
            class EmptyNonTotalMovie(TypedDictionary, NonTotalTypedDictionary): ...
            class RegularClass: ...

            class Base(TypedDictionary):
              required: int
            class NonTotalChild(Base, total=False):
              non_required: str
          |}
        );
      ]
    in
    let project = ScratchProject.setup ~context sources in
    let resolution = ScratchProject.build_resolution project in
    let resolution = Resolution.global_resolution resolution in
    let attribute =
      GlobalResolution.attribute_from_class_name
        ~transitive:true
        ~class_attributes:false
        ~resolution
        parent_name
        ~name:attribute_name
        ~instantiated:(Type.Primitive parent_name)
    in
    assert_equal ~printer:[%show: Attribute.instantiated option] expected_attribute attribute
  in
  let create_expected_attribute
      ?(property = false)
      ?(visibility = Attribute.ReadWrite)
      ?(parent = "test.Attributes")
      ?(initialized = Annotated.Attribute.Implicitly)
      ?(defined = true)
      ~annotation
      name
    =
    Some
      (Annotated.Attribute.create
         ~annotation
         ~original_annotation:annotation
         ~abstract:false
         ~async:false
         ~class_attribute:false
         ~defined
         ~initialized
         ~name
         ~parent
         ~property
         ~visibility
         ~static:false)
  in
  assert_attribute
    ~parent_name:"test.RegularClass"
    ~attribute_name:"non_existent"
    ~expected_attribute:
      (create_expected_attribute
         "non_existent"
         ~parent:"test.RegularClass"
         ~annotation:Type.Top
         ~defined:false
         ~initialized:Annotated.Attribute.NotInitialized);
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"non_existent"
    ~expected_attribute:
      (create_expected_attribute
         "non_existent"
         ~parent:"test.Movie"
         ~annotation:Type.Top
         ~defined:false
         ~initialized:Annotated.Attribute.NotInitialized);
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"name"
    ~expected_attribute:
      (create_expected_attribute
         "name"
         ~parent:"test.Movie"
         ~annotation:Type.Top
         ~defined:false
         ~initialized:Annotated.Attribute.NotInitialized);
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"year"
    ~expected_attribute:
      (create_expected_attribute
         "year"
         ~parent:"test.Movie"
         ~annotation:Type.Top
         ~defined:false
         ~initialized:Annotated.Attribute.NotInitialized);
  assert_attribute
    ~parent_name:"test.ChildMovie"
    ~attribute_name:"year"
    ~expected_attribute:
      (create_expected_attribute
         "year"
         ~parent:"test.ChildMovie"
         ~annotation:Type.Top
         ~defined:false
         ~initialized:Annotated.Attribute.NotInitialized);
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"__getitem__"
    ~expected_attribute:
      (create_expected_attribute
         "__getitem__"
         ~parent:"test.Movie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named
                    (Reference.create_from_list
                       [Type.TypedDictionary.class_name ~total:true; "__getitem__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.string;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.Named
                              {
                                Type.Record.Callable.RecordParameter.name = "k";
                                annotation = Type.Literal (Type.String "name");
                                default = false;
                              };
                          ];
                    };
                    {
                      Type.Record.Callable.annotation = Type.integer;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.Named
                              {
                                Type.Record.Callable.RecordParameter.name = "k";
                                annotation = Type.Literal (Type.String "year");
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit =
                  Some
                    {
                      Type.Record.Callable.implicit_annotation = Type.Primitive "test.Movie";
                      name = "self";
                    };
              }));
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"__init__"
    ~expected_attribute:
      (create_expected_attribute
         "__init__"
         ~parent:"test.Movie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named (Reference.create_from_list ["__init__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.Movie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$name";
                                annotation = Type.string;
                                default = false;
                              };
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$year";
                                annotation = Type.integer;
                                default = false;
                              };
                          ];
                    };
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.Movie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.PositionalOnly
                              {
                                index = 0;
                                annotation = Type.Primitive "test.Movie";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit = None;
              }));
  assert_attribute
    ~parent_name:"test.ChildMovie"
    ~attribute_name:"__init__"
    ~expected_attribute:
      (create_expected_attribute
         "__init__"
         ~parent:"test.ChildMovie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named (Reference.create_from_list ["__init__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.ChildMovie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$rating";
                                annotation = Type.integer;
                                default = false;
                              };
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$name";
                                annotation = Type.string;
                                default = false;
                              };
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$year";
                                annotation = Type.integer;
                                default = false;
                              };
                          ];
                    };
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.ChildMovie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.PositionalOnly
                              {
                                index = 0;
                                annotation = Type.Primitive "test.ChildMovie";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit = None;
              }));
  assert_attribute
    ~parent_name:"test.NonTotalMovie"
    ~attribute_name:"__init__"
    ~expected_attribute:
      (create_expected_attribute
         "__init__"
         ~parent:"test.NonTotalMovie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named (Reference.create_from_list ["__init__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.NonTotalMovie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$name";
                                annotation = Type.string;
                                default = true;
                              };
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$year";
                                annotation = Type.integer;
                                default = true;
                              };
                          ];
                    };
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.NonTotalMovie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.PositionalOnly
                              {
                                index = 0;
                                annotation = Type.Primitive "test.NonTotalMovie";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit = None;
              }));
  assert_attribute
    ~parent_name:"test.EmptyNonTotalMovie"
    ~attribute_name:"__init__"
    ~expected_attribute:
      (create_expected_attribute
         "__init__"
         ~parent:"test.EmptyNonTotalMovie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named (Reference.create_from_list ["__init__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.EmptyNonTotalMovie";
                      parameters = Type.Record.Callable.Defined [];
                    };
                    {
                      Type.Record.Callable.annotation = Type.Primitive "test.EmptyNonTotalMovie";
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.PositionalOnly
                              {
                                index = 0;
                                annotation = Type.Primitive "test.EmptyNonTotalMovie";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit = None;
              }));
  assert_attribute
    ~parent_name:"test.Movie"
    ~attribute_name:"update"
    ~expected_attribute:
      (create_expected_attribute
         "update"
         ~parent:"test.Movie"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named
                    (Reference.create_from_list ["TypedDictionary"; "update"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      Type.Record.Callable.annotation = Type.none;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$name";
                                annotation = Type.string;
                                default = true;
                              };
                            Type.Record.Callable.RecordParameter.KeywordOnly
                              {
                                Type.Record.Callable.RecordParameter.name = "$parameter$year";
                                annotation = Type.integer;
                                default = true;
                              };
                          ];
                    };
                    {
                      Type.Record.Callable.annotation = Type.none;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.PositionalOnly
                              {
                                index = 0;
                                annotation = Type.Primitive "test.Movie";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit = Some { implicit_annotation = Type.Primitive "test.Movie"; name = "self" };
              }));
  assert_attribute
    ~parent_name:"test.NonTotalChild"
    ~attribute_name:"pop"
    ~expected_attribute:
      (create_expected_attribute
         "pop"
         ~parent:"test.NonTotalChild"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named
                    (Reference.create_from_list ["NonTotalTypedDictionary"; "pop"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      annotation = Type.string;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.Named
                              {
                                name = "k";
                                annotation = Type.literal_string "non_required";
                                default = false;
                              };
                          ];
                    };
                    {
                      annotation =
                        Union [Type.string; Type.Variable (Type.Variable.Unary.create "_T")];
                      parameters =
                        Defined
                          [
                            Type.Record.Callable.RecordParameter.Named
                              {
                                name = "k";
                                annotation = Type.literal_string "non_required";
                                default = false;
                              };
                            Type.Record.Callable.RecordParameter.Named
                              {
                                name = "default";
                                annotation = Type.Variable (Type.Variable.Unary.create "_T");
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit =
                  Some
                    {
                      Type.Record.Callable.implicit_annotation = Type.Primitive "test.NonTotalChild";
                      name = "self";
                    };
              }));
  assert_attribute
    ~parent_name:"test.NonTotalChild"
    ~attribute_name:"__delitem__"
    ~expected_attribute:
      (create_expected_attribute
         "__delitem__"
         ~parent:"test.NonTotalChild"
         ~annotation:
           (Type.Callable
              {
                Type.Record.Callable.kind =
                  Type.Record.Callable.Named
                    (Reference.create_from_list ["NonTotalTypedDictionary"; "__delitem__"]);
                implementation =
                  {
                    Type.Record.Callable.annotation = Type.Top;
                    parameters = Type.Record.Callable.Undefined;
                  };
                overloads =
                  [
                    {
                      annotation = Type.none;
                      parameters =
                        Type.Record.Callable.Defined
                          [
                            Type.Record.Callable.RecordParameter.Named
                              {
                                name = "k";
                                annotation = Type.literal_string "non_required";
                                default = false;
                              };
                          ];
                    };
                  ];
                implicit =
                  Some
                    {
                      Type.Record.Callable.implicit_annotation = Type.Primitive "test.NonTotalChild";
                      name = "self";
                    };
              }));
  ()


let test_constraints context =
  let assert_constraints ~target ~instantiated ?parameters source expected =
    let { ScratchProject.BuiltGlobalEnvironment.global_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
    in
    let resolution = GlobalResolution.create global_environment in
    let constraints =
      GlobalResolution.constraints ~target ~resolution ?parameters ~instantiated ()
    in
    let expected =
      List.map expected ~f:(fun (variable, value) -> Type.Variable.UnaryPair (variable, value))
    in
    assert_equal
      ~printer:TypeConstraints.Solution.show
      ~cmp:TypeConstraints.Solution.equal
      (TypeConstraints.Solution.create expected)
      constraints
  in
  let int_and_foo_string_union =
    Type.Union [Type.parametric "test.Foo" !![Type.string]; Type.integer]
  in
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![int_and_foo_string_union])
    {|
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_V]):
        pass
    |}
    [Type.Variable.Unary.create "test._V", int_and_foo_string_union];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.Primitive "test.Foo")
    {|
      class Foo:
        pass
    |}
    [];

  (* Consequence of the special case we need to remove *)
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.Bottom])
    {|
      _T = typing.TypeVar('_T')
      class Foo(typing.Generic[_T]):
        pass
    |}
    [];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer; Type.float])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        pass
    |}
    [
      Type.Variable.Unary.create "test._K", Type.integer;
      Type.Variable.Unary.create "test._V", Type.float;
    ];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer; Type.float])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        pass
    |}
    [
      Type.Variable.Unary.create "test._K", Type.integer;
      Type.Variable.Unary.create "test._V", Type.float;
    ];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.Primitive "test.Foo")
    {|
      _T = typing.TypeVar('_T')
      class Bar(typing.Generic[_T]):
        pass
      class Foo(Bar[int]):
        pass
    |}
    [];
  assert_constraints
    ~target:"test.Bar"
    ~instantiated:(Type.Primitive "test.Foo")
    {|
      _T = typing.TypeVar('_T')
      class Bar(typing.Generic[_T]):
        pass
      class Foo(Bar[int]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  assert_constraints
    ~target:"test.Bar"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_V]):
        pass
      class Foo(typing.Generic[_K], Bar[_K]):
        pass
    |}
    [Type.Variable.Unary.create "test._V", Type.integer];
  assert_constraints
    ~target:"test.Bar"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer; Type.float])
    {|
      _T = typing.TypeVar('_T')
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_T]):
        pass
      class Baz(typing.Generic[_T]):
        pass
      class Foo(typing.Generic[_K, _V], Bar[_K], Baz[_V]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  assert_constraints
    ~target:"test.Baz"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer; Type.float])
    {|
      _T = typing.TypeVar('_T')
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_T]):
        pass
      class Baz(typing.Generic[_T]):
        pass
      class Foo(typing.Generic[_K, _V], Bar[_K], Baz[_V]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.float];
  assert_constraints
    ~target:"test.Iterator"
    ~instantiated:(Type.parametric "test.Iterator" !![Type.integer])
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  assert_constraints
    ~target:"test.Iterator"
    ~instantiated:(Type.parametric "test.Iterable" !![Type.integer])
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
      class Iterable(Iterator[_T]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  assert_constraints
    ~target:"test.Iterator"
    ~instantiated:
      (Type.parametric "test.Iterable" !![Type.parametric "test.Iterable" !![Type.integer]])
    ~parameters:!![Type.parametric "test.Iterable" !![Type.variable "test._T"]]
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
      class Iterable(Iterator[_T]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  assert_constraints
    ~target:"test.Foo"
    ~parameters:!![Type.parametric "test.Foo" !![Type.variable "test._T"]]
    ~instantiated:(Type.parametric "test.Bar" !![Type.parametric "test.Bar" !![Type.integer]])
    {|
      _V = typing.TypeVar('_V', covariant=True)
      class Foo(typing.Generic[_V]):
        pass
      _V2 = typing.TypeVar('_V2')
      class Bar(Foo[_V2]):
        pass
    |}
    [Type.Variable.Unary.create "test._T", Type.integer];
  let t_bound =
    Type.Variable.Unary.create
      ~constraints:(Type.Variable.Bound (Type.Primitive "test.Bound"))
      "test.T_Bound"
  in
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.Primitive "test.Bound"])
    {|
      class Bound:
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [t_bound, Type.Primitive "test.Bound"];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.Primitive "test.UnderBound"])
    {|
      class Bound:
        pass
      class UnderBound(Bound):
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [t_bound, Type.Primitive "test.UnderBound"];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.Primitive "test.OverBound"])
    {|
      class Bound:
        pass
      class OverBound():
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [];
  let t_explicit =
    Type.Variable.Unary.create
      ~constraints:(Type.Variable.Explicit [Type.integer; Type.string])
      "test.T_Explicit"
  in
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.integer])
    {|
      T_Explicit = typing.TypeVar('T_Explicit', int, str)
      class Foo(typing.Generic[T_Explicit]):
        pass
    |}
    [t_explicit, Type.integer];
  assert_constraints
    ~target:"test.Foo"
    ~instantiated:(Type.parametric "test.Foo" !![Type.bool])
    {|
      T_Explicit = typing.TypeVar('T_Explicit', int, str)
      class Foo(typing.Generic[T_Explicit]):
        pass
    |}
    []


let test_metaclasses context =
  let assert_metaclass ~source ~target metaclass =
    let target = "test." ^ target in
    let metaclass =
      if metaclass = "type" then
        metaclass
      else
        "test." ^ metaclass
    in
    let { ScratchProject.BuiltGlobalEnvironment.ast_environment; global_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
    in
    let source =
      AstEnvironment.ReadOnly.get_source
        (AstEnvironment.read_only ast_environment)
        (Reference.create "test")
    in
    let source = Option.value_exn source in
    let { Source.statements; _ } = source in
    let target =
      let target = function
        | { Node.location; value = Statement.Class ({ StatementClass.name; _ } as definition) }
          when Reference.show (Node.value name) = target ->
            { Node.location; value = definition } |> Node.map ~f:ClassSummary.create |> Option.some
        | _ -> None
      in
      List.find_map ~f:target statements
    in
    let resolution = GlobalResolution.create global_environment in
    match target with
    | Some target ->
        assert_equal (Type.Primitive metaclass) (GlobalResolution.metaclass ~resolution target)
    | None -> assert_unreached ()
  in
  assert_metaclass ~source:{|
       class C:
         pass
    |} ~target:"C" "type";
  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class C(metaclass=Meta):
        pass
    |}
    ~target:"C"
    "Meta";
  assert_metaclass
    ~source:
      {|
      class Meta:
        pass
      class C(metaclass=Meta):
        pass
      class D(C):
        pass
    |}
    ~target:"D"
    "Meta";
  assert_metaclass
    ~source:
      {|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class C(metaclass=Meta):
        pass
      class Other(metaclass=MoreMeta):
        pass
      class D(C, Other):
        pass
    |}
    ~target:"D"
    "MoreMeta";
  assert_metaclass
    ~source:
      {|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class C(metaclass=Meta):
        pass
      class Other(metaclass=MoreMeta):
        pass
      class D(Other, C):
        pass
    |}
    ~target:"D"
    "MoreMeta";

  (* If we don't have a "most derived metaclass", pick an arbitrary one. *)
  assert_metaclass
    ~source:
      {|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class OtherMeta(Meta):
        pass
      class C(metaclass=MoreMeta):
        pass
      class Other(metaclass=OtherMeta):
        pass
      class D(Other, C):
        pass
    |}
    ~target:"D"
    "OtherMeta";
  assert_metaclass
    ~source:
      {|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class OtherMeta(Meta):
        pass
      class C(metaclass=MoreMeta):
        pass
      class Other(metaclass=OtherMeta):
        pass
      class D(C, Other):
        pass
    |}
    ~target:"D"
    "MoreMeta"


let test_overrides context =
  let resolution =
    ScratchProject.setup
      ~context
      [
        ( "test.py",
          {|
      class Foo:
        def foo(): pass
      class Bar(Foo):
        pass
      class Baz(Bar):
        def foo(): pass
        def baz(): pass
    |}
        );
      ]
    |> ScratchProject.build_global_resolution
  in
  assert_is_none (GlobalResolution.overrides "test.Baz" ~resolution ~name:"baz");
  let overrides = GlobalResolution.overrides "test.Baz" ~resolution ~name:"foo" in
  assert_is_some overrides;
  assert_equal ~cmp:String.equal (Attribute.name (Option.value_exn overrides)) "foo";
  assert_equal (Option.value_exn overrides |> Attribute.parent) "test.Foo"


let test_extract_type_parameter context =
  let resolution =
    ScratchProject.setup
      ~context
      [
        ( "test.py",
          {|
         from typing import TypeVar, Generic, List, Protocol
         T = TypeVar('T')
         U = TypeVar('U')
         class Derp: ...
         class Foo(Generic[T]): ...
         class Bar(Foo[T]): ...
         class Baz(Foo[T], Generic[T, U]): ...

         class MyProtocol(Protocol[T]):
           def derp(self) -> T: ...
         class MyIntProtocol:
           def derp(self) -> int: ...
         class MyStrProtocol:
           def derp(self) -> str: ...
         class MyGenericProtocol(Generic[T]):
           def derp(self) -> T: ...
         class NotMyProtocol:
           def herp(self) -> int: ...
        
         ListOfInt = List[int]
       |}
        );
      ]
    |> ScratchProject.build_global_resolution
  in
  let parse_annotation annotation =
    annotation
    (* Preprocess literal TypedDict syntax. *)
    |> parse_single_expression ~preprocess:true
    |> GlobalResolution.parse_annotation resolution
  in
  let assert_extracted ~expected ~as_name annotation =
    let actual =
      GlobalResolution.extract_type_parameters resolution ~source:annotation ~target:as_name
    in
    assert_equal
      ~cmp:[%equal: Type.t list option]
      ~printer:(function
        | Some annotations -> List.to_string ~f:Type.show annotations
        | None -> "EXTRACTION FAILED")
      expected
      actual
  in
  let list_name =
    (* Change me in case the canonical name for list type changes *)
    "list"
  in

  assert_extracted Type.Any ~as_name:"test.Derp" ~expected:None;
  assert_extracted Type.Top ~as_name:"test.Derp" ~expected:None;
  assert_extracted Type.Bottom ~as_name:"test.Derp" ~expected:None;
  assert_extracted (Type.list Type.integer) ~as_name:"test.Derp" ~expected:None;
  assert_extracted (parse_annotation "test.Derp") ~as_name:"test.Derp" ~expected:None;

  assert_extracted
    (parse_annotation "test.Foo[int]")
    ~as_name:"test.Foo"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.Bar[str]")
    ~as_name:"test.Foo"
    ~expected:(Some [Type.string]);
  assert_extracted
    (parse_annotation "test.Baz[int, str]")
    ~as_name:"test.Foo"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.Baz[str, int]")
    ~as_name:"test.Foo"
    ~expected:(Some [Type.string]);
  assert_extracted
    (parse_annotation "test.Baz[int, str]")
    ~as_name:"test.Baz"
    ~expected:(Some [Type.integer; Type.string]);

  assert_extracted Type.integer ~as_name:list_name ~expected:None;
  assert_extracted (parse_annotation "test.Foo[int]") ~as_name:list_name ~expected:None;
  assert_extracted
    (parse_annotation "typing.List[int]")
    ~as_name:list_name
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.ListOfInt")
    ~as_name:list_name
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.ListOfInt")
    ~as_name:"typing.Sequence"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.ListOfInt")
    ~as_name:"typing.Iterable"
    ~expected:(Some [Type.integer]);

  assert_extracted
    (parse_annotation "test.MyIntProtocol")
    ~as_name:"test.MyProtocol"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "test.MyStrProtocol")
    ~as_name:"test.MyProtocol"
    ~expected:(Some [Type.string]);
  assert_extracted
    (parse_annotation "test.MyGenericProtocol[float]")
    ~as_name:"test.MyProtocol"
    ~expected:(Some [Type.float]);
  assert_extracted (parse_annotation "test.NotMyProtocol") ~as_name:"test.MyProtocol" ~expected:None;

  assert_extracted
    (parse_annotation "typing.Dict[int, str]")
    ~as_name:"typing.Iterable"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "typing.Dict[int, str]")
    ~as_name:"typing.Mapping"
    ~expected:(Some [Type.integer; Type.string]);
  assert_extracted
    (parse_annotation "typing.Mapping[int, str]")
    ~as_name:"typing.Iterable"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "typing.Generator[int, str, float]")
    ~as_name:"typing.Iterator"
    ~expected:(Some [Type.integer]);
  assert_extracted
    (parse_annotation "typing.Coroutine[typing.Any, typing.Any, typing.Any]")
    ~as_name:"typing.Awaitable"
    ~expected:(Some [Type.Any]);
  assert_extracted
    (parse_annotation "typing.Coroutine[int, str, float]")
    ~as_name:"typing.Awaitable"
    ~expected:(Some [Type.float]);

  assert_extracted (Type.list Type.Any) ~as_name:list_name ~expected:(Some [Type.Any]);
  assert_extracted
    (Type.list Type.object_primitive)
    ~as_name:list_name
    ~expected:(Some [Type.object_primitive]);
  (* TODO (T63159626): Should be [Top] *)
  assert_extracted (Type.list Type.Top) ~as_name:list_name ~expected:None;
  (* TODO (T63159626): Should be [Bottom] *)
  assert_extracted (Type.list Type.Bottom) ~as_name:list_name ~expected:None;
  ()


let () =
  "class"
  >::: [
         "attributes" >:: test_class_attributes;
         "typed_dictionary_attributes" >:: test_typed_dictionary_attributes;
         "typed_dictionary_individual_attributes" >:: test_typed_dictionary_individual_attributes;
         "constraints" >:: test_constraints;
         "constructors" >:: test_constructors;
         "get_decorator" >:: test_get_decorator;
         "is_protocol" >:: test_is_protocol;
         "metaclasses" >:: test_metaclasses;
         "superclasses" >:: test_superclasses;
         "overrides" >:: test_overrides;
         "extract_type_parameter" >:: test_extract_type_parameter;
       ]
  |> Test.run
