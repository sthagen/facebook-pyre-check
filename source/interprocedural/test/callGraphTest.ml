(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Data_structures
open OUnit2
open Ast
open Analysis
open Test
open Interprocedural
open CallGraph

let assert_call_graph_of_define
    ?(object_targets = [])
    ~source
    ~define_name
    ~expected
    ?(cmp = DefineCallGraph.equal)
    ()
    context
  =
  let expected =
    let parse_location location =
      let parse_position position =
        let line_and_column = String.split ~on:':' position in
        {
          Location.line = Int.of_string (List.nth_exn line_and_column 0);
          column = Int.of_string (List.nth_exn line_and_column 1);
        }
      in
      let positions = String.split ~on:'-' location in
      {
        Location.start = parse_position (List.nth_exn positions 0);
        stop = parse_position (List.nth_exn positions 1);
      }
    in
    List.fold
      expected
      ~init:DefineCallGraph.empty
      ~f:(fun call_graph_of_define (location, callees) ->
        DefineCallGraph.add call_graph_of_define ~location:(parse_location location) ~callees)
  in
  let define, test_source, pyre_api, configuration =
    let find_define = function
      | { Node.value = define; _ }
        when String.equal (Statement.Define.name define |> Reference.show) define_name ->
          Some define
      | _ -> None
    in
    let project = Test.ScratchProject.setup ~context ["test.py", source] in
    let { ScratchProject.BuiltTypeEnvironment.sources; _ } =
      ScratchProject.build_type_environment project
    in
    let test_source =
      List.find_map_exn
        sources
        ~f:(fun ({ Source.module_path = { ModulePath.qualifier; _ }; _ } as source) ->
          Option.some_if (String.equal (Reference.show qualifier) "test") source)
    in
    ( List.find_map_exn
        (Preprocessing.defines ~include_nested:true ~include_toplevels:true test_source)
        ~f:find_define,
      test_source,
      ScratchProject.pyre_pysa_read_only_api project,
      ScratchProject.configuration_of project )
  in
  let static_analysis_configuration = Configuration.StaticAnalysis.create configuration () in
  let override_graph_heap = OverrideGraph.Heap.from_source ~pyre_api ~source:test_source in
  let override_graph_shared_memory = OverrideGraph.SharedMemory.from_heap override_graph_heap in
  let () =
    assert_equal
      ~cmp
      ~printer:DefineCallGraph.show
      expected
      (CallGraph.call_graph_of_define
         ~static_analysis_configuration
         ~pyre_api
         ~override_graph:
           (Some (Interprocedural.OverrideGraph.SharedMemory.read_only override_graph_shared_memory))
         ~attribute_targets:(Target.HashSet.of_list object_targets)
         ~qualifier:(Reference.create "test")
         ~define)
  in
  let () = OverrideGraph.SharedMemory.cleanup override_graph_shared_memory in
  ()


let test_call_graph_of_define =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
     def foo():
         bar()

     def bar():
         pass
  |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:4-3:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo(c: C):
         c.m()

     class C:
       def m(self):
         pass
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:4-3:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.C"
                               (Target.create_method (Reference.create "test.C.m"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo():
       if 1 > 2:
         f = bar
       else:
         f = baz
       f()
     def baz() -> int: ...
     def bar() -> bool: ...
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:2-7:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.bool)
                               (Target.Function { name = "test.bar"; kind = Normal });
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
               ( "3:5-3:10",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__le__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"int"
                                     ~return_type:(Some ReturnType.bool)
                                     (Target.Method
                                        {
                                          class_name = "int";
                                          method_name = "__le__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__gt__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"int"
                                     ~return_type:(Some ReturnType.bool)
                                     (Target.Method
                                        {
                                          class_name = "int";
                                          method_name = "__gt__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo():
       if 1 > 2:
         f = bar
       else:
         f = None
       f()
     def bar(): ...
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:5-3:10",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__le__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"int"
                                     ~return_type:(Some ReturnType.bool)
                                     (Target.Method
                                        {
                                          class_name = "int";
                                          method_name = "__le__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__gt__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"int"
                                     ~return_type:(Some ReturnType.bool)
                                     (Target.Method
                                        {
                                          class_name = "int";
                                          method_name = "__gt__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "7:2-7:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     from typing import Optional

     def foo(c: Optional[C]):
       c.m()
     class C:
       def m():
         ...

      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.C"
                               (Target.create_method (Reference.create "test.C.m"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     from typing import Optional

     def foo(c: C):
       c.m()
     class C:
       def m():
         ...
     class D(C):
       def m():
         ...
     class E(D):
       def m():
         ...
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.C"
                               (Target.create_override (Reference.create "test.C.m"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     from typing import Optional

     def foo(d: D):
       d.m()
     class C:
       def m():
         ...
     class D(C):
       pass
     class E(D):
       def m():
         ...
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.D"
                               (Target.create_method (Reference.create "test.C.m"));
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.D"
                               (Target.create_method (Reference.create "test.E.m"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    class C:
      def __call__(self, a: int): ...
    def foo(c: C):
       c(1)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:3-5:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~implicit_dunder_call:true
                               ~receiver_class:"test.C"
                               (Target.create_method (Reference.create "test.C.__call__"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    class C:
      @staticmethod
      def __call__(a: int) -> bool: ...
    def foo(c: C):
       c(1)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:3-6:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_dunder_call:true
                               ~return_type:(Some ReturnType.bool)
                               (Target.create_method (Reference.create "test.C.__call__"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    class C:
      def __call__(self, a: int) -> bool: ...
    def foo(c: C):
       c.__call__(1)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:3-5:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.bool)
                               ~receiver_class:"test.C"
                               (Target.create_method (Reference.create "test.C.__call__"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    from typing import Protocol
    class C(Protocol):
      def __call__(self, a: int) -> bool: ...
    def foo(c: C):
       c(1)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:3-6:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~implicit_dunder_call:true
                               ~return_type:(Some ReturnType.bool)
                               ~receiver_class:"test.C"
                               (Target.create_method (Reference.create "test.C.__call__"));
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       class C:
         def __init__(self, a): ...
       def foo():
         C()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.any)
                               (Target.Method
                                  { class_name = "test.C"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.any)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
       def foo(x: str) -> int:
         return int(x)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "int"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       class C:
         def __new__(cls, a): ...
       def foo():
         C()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.any)
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.any)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "test.C"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       from unknown import A
       class B(A):
         def __init__(self, a): ...
       def foo():
         B()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.any)
                               (Target.Method
                                  { class_name = "test.B"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.any)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       from unknown import A
       class B(A):
         def __new__(cls, a): ...
       def foo():
         B()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.any)
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.any)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "test.B"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class C:
          @property
          def p(self) -> int: ...
          @p.setter
          def p(self, v: int) -> None: ...
        def foo(c: C):
          c.p = c.p
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "8:2-8:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.none)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "p"; kind = PropertySetter });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
               ( "8:8-8:11",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.integer)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "p"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class C:
          @staticmethod
          def f(a: int) -> int: ...
        def foo():
          C.f()
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class C:
          @classmethod
          def f(cls, a: int) -> int: ...
        def foo(c: C):
          C.f()
          c.f()
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
               ( "7:2-7:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~index:1
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    # Original code: https://fburl.com/code/k6hypgar
    class A:
      def foo(self):
        raise NotImplementedError
    class B(A):
      # The type of B.foo would be different without the if-else here.
      if 1 == 1:
        @classmethod
        def foo(cls) -> None:
          pass
      else:
        @classmethod
        def foo(cls) -> None:
          pass

    def bar():
      B.foo()
  |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "18:2-18:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~is_class_method:true
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from abc import abstractmethod
      class A:
        def f(self):
            return self.g()

        @abstractmethod
        def g(self):
            pass

      class B(A):
        def g(self):
            pass
      |}
           ~define_name:"test.A.f"
           ~expected:
             [
               ( "5:13-5:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.A"
                               (Target.Override
                                  { class_name = "test.A"; method_name = "g"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
        def foo():
          1 > 2
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:2-3:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.bool)
                               ~receiver_class:"int"
                               (Target.Method
                                  { class_name = "int"; method_name = "__gt__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class C:
        def __repr__(self) -> str: ...

      def foo(c: C):
        repr(c)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "__repr__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from functools import partial
      def f(a, b):
        ...

      def foo():
        partial(f, 1)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:2-7:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [CallTarget.create (Target.Function { name = "test.f"; kind = Normal })]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from builtins import to_callable_target

      @to_callable_target
      def callable_target(arg):
        pass

      def foo():
        callable_target.async_schedule(1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:2-9:35",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.callable_target"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from builtins import to_callable_target

      class Foo:
        @to_callable_target
        def callable_target(arg):
          pass

      def bar(foo: Foo):
        foo.callable_target(1)
      |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "10:2-10:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~implicit_dunder_call:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"TestCallableTarget"
                               (Target.Method
                                  {
                                    class_name = "TestCallableTarget";
                                    method_name = "__call__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      def foo(x=bar()):
        pass

      def bar():
        pass
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "2:10-2:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class C:
        def f(self, x: int) -> int:
          return x

      class D(C):
        def f(self, x: int) -> int:
          return x

        def g(self) -> None:
          super().f(1)
      |}
           ~define_name:"test.D.g"
           ~expected:
             [
               ( "11:4-11:11",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "super"; method_name = "__init__"; kind = Normal });
                           ]
                         ())) );
               ( "11:4-11:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class C:
        def f(self, x: int) -> int:
          return x

      class D(C):
        def f(self, x: int) -> int:
          return x

      def foo(c: C):
        C.f(c, 1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "11:2-11:11",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class C:
        @classmethod
        def f(cls, x: int) -> int:
          return x
        @classmethod
        def g(cls):
          pass

      class D(C):
        @classmethod
        def f(cls, x: int) -> int:
          return x

      def foo(c: C):
        C.f(c, 1)
        D.f()
        D.g()
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "16:2-16:11",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
               ( "17:2-17:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~receiver_class:"test.D"
                               (Target.Method
                                  { class_name = "test.D"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
               ( "18:2-18:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~is_class_method:true
                               ~receiver_class:"test.D"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "g"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def hof(f, arg) -> bool:
        f(arg)

      def bar(x) -> int:
        pass

      def foo():
        hof(bar, 1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:2-9:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.bool)
                               (Target.Function { name = "test.hof"; kind = Normal });
                           ]
                         ~higher_order_parameters:
                           (HigherOrderParameterMap.from_list
                              [
                                {
                                  index = 0;
                                  call_targets =
                                    [
                                      CallTarget.create
                                        ~return_type:(Some ReturnType.integer)
                                        (Target.Function { name = "test.bar"; kind = Normal });
                                    ];
                                  unresolved = false;
                                };
                              ])
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def hof(f, g, arg) -> bool:
        f(arg)
        g(arg)

      def foo(x) -> int:
        pass

      def bar(x) -> int:
        pass

      def test():
        hof(foo, bar, 1)
      |}
           ~define_name:"test.test"
           ~expected:
             [
               ( "13:2-13:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.bool)
                               (Target.Function { name = "test.hof"; kind = Normal });
                           ]
                         ~higher_order_parameters:
                           (HigherOrderParameterMap.from_list
                              [
                                {
                                  index = 0;
                                  call_targets =
                                    [
                                      CallTarget.create
                                        ~return_type:(Some ReturnType.integer)
                                        (Target.Function { name = "test.foo"; kind = Normal });
                                    ];
                                  unresolved = false;
                                };
                                {
                                  index = 1;
                                  call_targets =
                                    [
                                      CallTarget.create
                                        ~return_type:(Some ReturnType.integer)
                                        (Target.Function { name = "test.bar"; kind = Normal });
                                    ];
                                  unresolved = false;
                                };
                              ])
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      _magic_enum = property

      class Enum:
        @_magic_enum
        def value(self): ...

      class Permission(Enum):
        @property
        def action_name(self) -> bool:
          if len(self.value):
              return True
          return False
      |}
           ~define_name:"test.Permission.action_name"
           ~expected:
             [
               ( "11:7-11:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "len"; kind = Normal });
                           ]
                         ~higher_order_parameters:
                           (HigherOrderParameterMap.from_list
                              [
                                {
                                  index = 0;
                                  call_targets =
                                    [
                                      CallTarget.create
                                        ~implicit_receiver:true
                                        (Target.Method
                                           {
                                             class_name = "test.Enum";
                                             method_name = "value";
                                             kind = Normal;
                                           });
                                    ];
                                  unresolved = false;
                                };
                              ])
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      def test():
        return map(lambda x: x, [0])
      |}
           ~define_name:"test.test"
           ~expected:
             [
               ( "3:9-3:30",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "map"; method_name = "__init__"; kind = Normal });
                           ]
                         ~higher_order_parameters:
                           (HigherOrderParameterMap.from_list
                              [{ index = 0; call_targets = []; unresolved = true }])
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class Builder:
            def __init__(self) -> None:
                self._saved: Optional[str] = None
                self._not_saved: Optional[str] = None

            def set_saved(self, saved: str) -> "Builder":
                self._saved = saved
                return self

            def set_not_saved(self, not_saved: str) -> "Builder":
                self._not_saved = not_saved
                return self

        def foo():
            builder = Builder()
            builder.set_not_saved("true").set_saved("false")
   |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "16:14-16:23",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    class_name = "test.Builder";
                                    method_name = "__init__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "17:4-17:33",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.Builder"
                               (Target.Method
                                  {
                                    class_name = "test.Builder";
                                    method_name = "set_not_saved";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "17:4-17:52",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.Builder"
                               (Target.Method
                                  {
                                    class_name = "test.Builder";
                                    method_name = "set_saved";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from functools import lru_cache
      @lru_cache()
      def f() -> int:
        return 0

      def foo():
        f()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "8:2-8:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Imprecise call graph due to `@lru_cache` and inner functions. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from functools import lru_cache
      class C:
        @lru_cache()
        def m(self, x: int) -> int:
          return x

      def foo(c: C):
        c.m(1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:2-9:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "m"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from functools import lru_cache

      def foo():
        @lru_cache()
        def inner() -> int:
          return 0

        inner()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:2-9:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               ~implicit_receiver:true
                               ~implicit_dunder_call:true
                               ~receiver_class:"functools._lru_cache_wrapper"
                               (Target.Method
                                  {
                                    class_name = "functools._lru_cache_wrapper";
                                    method_name = "__call__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    class C:
        def run(self) -> str:
            return ""

    def foo() -> None:
        cs: List[C] = [C()]
        result = [c.run() for c in cs]
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:19-7:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ())) );
               ( "8:14-8:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "run"; kind = Normal });
                           ]
                         ())) );
               ( "8:31-8:33",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.Iterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      (* Ensure we don't infinite loop when resolving callable classes. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
    from typing import Any, Target
    def to_c(callable: Target[..., Any]) -> C:
      ...

    class C:
      @to_c
      def __call__(self) -> "C":
        return self

    def foo(c: C) -> None:
      c()
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "12:2-12:5",
                 LocationCallees.Singleton (ExpressionCallees.from_call (CallCallees.unresolved ()))
               );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:
             {|
        from contextlib import ContextManager
        def foo():
          with to_cm() as my_int:
            pass
        def to_cm() -> ContextManager[int]: ...
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "4:7-4:14",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__enter__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:(Some ReturnType.integer)
                                     ~receiver_class:"contextlib.ContextManager"
                                     (Target.Method
                                        {
                                          class_name = "contextlib.ContextManager";
                                          method_name = "__enter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "to_cm",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     (Target.Function { name = "test.to_cm"; kind = Normal });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      (* Only the last attribute is a setter for chained property setter calls. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class C:
          @property
          def p(self) -> "C":
            ...
          @p.setter
          def p(self, new_value: "C") -> None:
            ...

        def foo(c: C):
          c.p.p = c
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "11:2-11:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.any)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "p"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
               ( "11:2-11:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.none)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "p"; kind = PropertySetter });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        from typing import Protocol
        class C(Protocol):
          def f(self) -> int: ...

        def foo(c: C):
          c.f()
          C.f(c)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:2-7:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
               ( "8:2-8:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               ~return_type:(Some ReturnType.integer)
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class C:
        @property
        def foo(self) -> int:
          ...

      class D:
        @property
        def foo(self) -> bool:
          ...

      class E:
        foo: int = 1

      def uses_foo(c_or_d: C | D, c_or_e: C | E):
        x = c_or_d.foo
        y = c_or_e.foo
    |}
           ~define_name:"test.uses_foo"
           ~expected:
             [
               ( "16:6-16:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.integer)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "foo"; kind = Normal });
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.bool)
                              (Target.Method
                                 { class_name = "test.D"; method_name = "foo"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
               ( "17:6-17:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~index:1
                              ~return_type:(Some ReturnType.integer)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "foo"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = true;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import TypeVar
      class C:
        @property
        def foo(self) -> int:
          ...

      class D:
        @property
        def foo(self) -> int:
          ...

      TCOrD = TypeVar("TCOrD", C, D)
      def uses_foo(c_or_d: TCOrD):
        x = c_or_d.foo
    |}
           ~define_name:"test.uses_foo"
           ~expected:
             [
               ( "15:6-15:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.integer)
                              (Target.Method
                                 { class_name = "test.C"; method_name = "foo"; kind = Normal });
                            CallTarget.create
                              ~implicit_receiver:true
                              ~return_type:(Some ReturnType.integer)
                              (Target.Method
                                 { class_name = "test.D"; method_name = "foo"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
        class C:
          @classmethod
          def foo(cls):
            pass
        d = {
          "a": C,
          "b": C,
        }
        def calls_d_method(s: str):
          d[s].foo()
      |}
           ~define_name:"test.calls_d_method"
           ~expected:
             [
               ( "11:2-11:3",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.d")];
                        nonlocal_targets = [];
                      }) );
               ( "11:2-11:6",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"dict"
                               (Target.Method
                                  {
                                    class_name = "dict";
                                    method_name = "__getitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "11:2-11:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~is_class_method:true
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.C"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       import typing
       def foo() -> typing.Dict[str, int]:
         return {"a": 0}
       def bar():
         return 1
       def baz():
         return "b"
       def fun(d: typing.Dict[str, int], e: typing.Dict[str, typing.Dict[str, int]]):
         foo()["a"] = bar()
         d[baz()] = bar()
         e["a"]["b"] = 0
      |}
           ~define_name:"test.fun"
           ~expected:
             [
               ( "10:2-10:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "10:2-10:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call_with_empty_attribute
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"dict"
                               (Target.Method
                                  {
                                    class_name = "dict";
                                    method_name = "__setitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "10:15-10:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
               ( "11:2-11:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call_with_empty_attribute
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"dict"
                               ~index:1
                               (Target.Method
                                  {
                                    class_name = "dict";
                                    method_name = "__setitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "11:4-11:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
               ( "11:13-11:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
               ( "12:2-12:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"dict"
                               (Target.Method
                                  {
                                    class_name = "dict";
                                    method_name = "__getitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "12:2-12:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call_with_empty_attribute
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"dict"
                               ~index:2
                               (Target.Method
                                  {
                                    class_name = "dict";
                                    method_name = "__setitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def outer(x: int) -> None:
        def inner(x: int) -> None:
          print(x)

        inner(x)
  |}
           ~define_name:"test.outer"
           ~expected:
             [
               ( "6:2-6:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               (Target.Function { name = "$local_test?outer$inner"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class Foo:
        def outer(self, x: int) -> None:
          def inner(x: int) -> None:
            pass

          inner(x)
  |}
           ~define_name:"test.Foo.outer"
           ~expected:
             [
               ( "7:4-7:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               (Target.Function
                                  { name = "$local_test?Foo?outer$inner"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     class C:
       def m(self) -> str:
         return "world"

     def foo(c: C) -> str:
       return f"hello {c.m()}"
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:9-7:25",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "7:18-7:23",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "$__str__$",
                          ExpressionCallees.from_string_format
                            (StringFormatCallees.from_stringify_targets
                               [
                                 CallTarget.create
                                   ~implicit_receiver:true
                                   ~receiver_class:"str"
                                   (Target.Method
                                      { class_name = "str"; method_name = "__str__"; kind = Normal });
                               ]) );
                        ( "m",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"test.C"
                                     (Target.Method
                                        { class_name = "test.C"; method_name = "m"; kind = Normal });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     class C:
       @property
       def attribute(self) -> Callable[[], int]:
         return lambda: 0

     def foo(c: C) -> str:
       return c.attribute()
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "8:9-8:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets =
                          [
                            CallTarget.create
                              ~implicit_receiver:true
                              (Target.Method
                                 { class_name = "test.C"; method_name = "attribute"; kind = Normal });
                          ];
                        global_targets = [];
                        is_attribute = false;
                      }) );
               ( "8:9-8:22",
                 LocationCallees.Singleton (ExpressionCallees.from_call (CallCallees.unresolved ()))
               );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo() -> None:
       pass
     def bar() -> None:
       pass
     def test(x) -> str:
       try:
         return foo()
       finally:
         bar(x)
      |}
           ~define_name:"test.test"
           ~expected:
             [
               ( "8:11-8:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "10:4-10:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo() -> None:
       pass
     def bar() -> None:
       pass
     def test(x) -> str:
       try:
         raise Exception()
       finally:
         bar(x)
      |}
           ~define_name:"test.test"
           ~expected:
             [
               ( "8:10-8:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    class_name = "BaseException";
                                    method_name = "__init__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "10:4-10:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* TODO(T105570363): Resolve calls with mixed function and methods. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:
             {|
      class Foo:
        def bar(self) -> None:
          pass

      def baz(self) -> None:
        pass

      def f(foo: Foo):
        for g in [foo.bar, baz]:
          g()
  |}
           ~define_name:"test.f"
           ~expected:
             [
               ( "10:11-10:25",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "11:4-11:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ~unresolved:true
                         ())) );
             ]
           ();
      (* TODO(T105570363): Resolve calls with mixed function and constructors. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:
             {|
      class Foo:
        pass

      def bar(self) -> None:
        pass

      def f():
        for g in [Foo, bar]:
          g()
  |}
           ~define_name:"test.f"
           ~expected:
             [
               ( "9:11-9:21",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "10:4-10:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ~unresolved:true
                         ())) );
             ]
           ();
      (* Well-typed decorators are 'safely' ignored (when not inlined). *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      @timer("bar")
      def foo(x: int) -> int:
        return x

      def caller() -> None:
        foo(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "20:2-20:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      class Foo:
        @timer("bar")
        def bar(self, x: int) -> int:
          return x

      def caller(foo: Foo) -> None:
        foo.bar(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "21:2-21:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.Foo"
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Partially-typed decorators are 'safely' ignored (when not inlined). *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      _T = TypeVar("_T")

      class Timer:
        def __call__(self, func: Callable[..., _T]) -> Callable[..., _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      @timer("bar")
      def foo(x: int) -> int:
        return x

      def caller() -> None:
        foo(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "17:2-17:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      _T = TypeVar("_T")

      class Timer:
        def __call__(self, func: Callable[..., _T]) -> Callable[..., _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      class Foo:
        @timer("bar")
        def bar(self, x: int) -> int:
          return x

      def caller(foo: Foo) -> None:
        foo.bar(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "18:2-18:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Untyped decorators are 'safely' ignored (when not inlined). *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def timer(name: str):
        pass

      @timer("bar")
      def foo(x: int) -> int:
        return x

      def caller() -> None:
        foo(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "10:2-10:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def timer(name: str):
        pass

      class Foo:
        @timer("bar")
        def bar(self, x: int) -> int:
          return x

      def caller(foo: Foo) -> None:
        foo.bar(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "11:2-11:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Well-typed decorators with @classmethod or @staticmethod. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      class Foo:
        @classmethod
        @timer("bar")
        def bar(cls, x: int) -> int:
          return x

      def caller() -> None:
        Foo.bar(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "22:2-22:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~receiver_class:"test.Foo"
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      class Foo:
        @staticmethod
        @timer("bar")
        def bar(x: int) -> int:
          return x

      def caller() -> None:
        Foo.bar(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "22:2-22:12",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      from pyre_extensions import ParameterSpecification

      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      class Foo:
        @classmethod
        @timer("bar")
        def bar(cls, x: int) -> int:
          return x

        @classmethod
        def caller(cls) -> None:
          cls.bar(1)
    |}
           ~define_name:"test.Foo.caller"
           ~expected:
             [
               ( "23:4-23:14",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~is_class_method:true
                               ~receiver_class:"test.Foo"
                               (Target.Method
                                  { class_name = "test.Foo"; method_name = "bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Decorators with type errors. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Callable, TypeVar
      _T = TypeVar("_T")
      _TParams = ParameterSpecification("_TParams")

      class Timer:
        def __call__(self, func: Callable[_TParams, _T]) -> Callable[_TParams, _T]:
          return func

      def timer(name: str) -> Timer:
        return Timer()

      @timer(1) # Intended type error here.
      def foo(x: int) -> int:
        return x

      def caller() -> None:
        foo(1)
    |}
           ~define_name:"test.caller"
           ~expected:
             [
               ( "18:2-18:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Resolving __call__ via __getattr__ when a union including self type is involved. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from __future__ import annotations
      from typing import Union

      class CallViaGetattr:
        def __getattr__(self, name: str) -> Union[None, CallViaGetattr]:
          return None

      def baz(x: CallViaGetattr) -> None:
        y = print(x.attribute)
    |}
           ~define_name:"test.baz"
           ~expected:
             [
               ( "10:6-10:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [CallTarget.create (Target.Function { name = "print"; kind = Normal })]
                         ())) );
             ]
           ();
      (* Detecting a __call__ picked up via __getattr__ redirection *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from __future__ import annotations
      from typing import Union

      class CallableClass:
        def __call__(self) -> None:
          return None

      class CallViaGetattr:
        def __getattr__(self, name: str) -> Union[None, CallableClass]:
          return CallableClass()

      def baz(x: CallViaGetattr) -> None:
        y = print(x.attribute)
    |}
           ~define_name:"test.baz"
           ~expected:
             [
               ( "14:6-14:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [CallTarget.create (Target.Function { name = "print"; kind = Normal })]
                         ~higher_order_parameters:
                           (HigherOrderParameterMap.from_list
                              [
                                {
                                  index = 0;
                                  call_targets =
                                    [
                                      CallTarget.create
                                        ~implicit_receiver:true
                                        ~implicit_dunder_call:true
                                        ~receiver_class:"test.CallableClass"
                                        (Target.Method
                                           {
                                             class_name = "test.CallableClass";
                                             method_name = "__call__";
                                             kind = Normal;
                                           });
                                    ];
                                  unresolved = false;
                                };
                              ])
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.Token.token"]
           ~source:
             {|
      class Token:
        token: str = ""

      class Token2:
        token2: str = ""

      def foo(obj: Token, obj2: Token2):
        return obj.token, obj2.token2
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:9-9:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets = [];
                        global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.Token.token")];
                        is_attribute = true;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.A.attribute"; Target.Object "test.C.attribute"]
           ~source:
             {|
      from typing import Union

      class A:
        attribute: str = ""

      class B:
        attribute: str = ""

      class C:
        attribute: str = ""

      def foo(obj: Union[A, B, C]):
        return obj.attribute
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "14:9-14:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets = [];
                        global_targets =
                          [
                            CallTarget.create ~return_type:None (Target.Object "test.A.attribute");
                            CallTarget.create ~return_type:None (Target.Object "test.C.attribute");
                          ];
                        is_attribute = true;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.Token.token"]
           ~source:
             {|
      from typing import Optional

      class Token:
        token: str = ""

      class Request:
        access_token: Optional[Token] = None

      def foo(request: Request):
        return request.access_token.token
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "11:9-11:35",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets = [];
                        global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.Token.token")];
                        is_attribute = true;
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.Token.token"]
           ~source:
             {|
      class Token:
        token: str = ""

      def foo(obj: Token):
        return getattr(obj, "token", None)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:9-6:36",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "getattr",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     (Target.Function { name = "getattr"; kind = Normal });
                                 ]
                               ()) );
                        ( "token",
                          ExpressionCallees.from_attribute_access
                            {
                              AttributeAccessCallees.property_targets = [];
                              global_targets =
                                [
                                  CallTarget.create
                                    ~return_type:None
                                    (Target.Object "test.Token.token");
                                ];
                              is_attribute = true;
                            } );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.Token.token"]
           ~source:
             {|
      class Token:
        token: str = ""

      def foo(obj: Token, x: str):
        return obj.__setattr__(obj, "token", x)
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:9-6:41",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.Token"
                               (Target.Method
                                  {
                                    class_name = "object";
                                    method_name = "__setattr__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class Test:
        def __setattr__(self, name: str, value):
          return

      def foo(obj: Test):
        obj.attribute = "value"
    |}
           ~define_name:"test.foo"
           ~expected:[] (* TODO(T137969662): We should see a call to `Test.__setattr__` *)
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      x = "x"

      def foo():
        return x
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:9-5:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.x")];
                        nonlocal_targets = [];
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def foo(a: int, b: float, c: str, d: typing.List[int], e):
        w = [1, 2, 3]
        x = 1
        y = "str"
        z = 2.3
        return f"{a}{b}{c}{d}{w}{x}{y}{z}{e}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "7:9-7:39",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "7:12-7:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"int"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "7:15-7:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"float"
                             ~index:1
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "7:18-7:19",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"str"
                             (Target.Method
                                { class_name = "str"; method_name = "__str__"; kind = Normal });
                         ])) );
               ( "7:21-7:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~index:2
                             ~receiver_class:"list"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "7:24-7:25",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~index:3
                             ~receiver_class:"list"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "7:27-7:28",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~index:4
                             ~receiver_class:"int"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "7:30-7:31",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~index:1
                             ~receiver_class:"str"
                             (Target.Method
                                { class_name = "str"; method_name = "__str__"; kind = Normal });
                         ])) );
               ( "7:33-7:34",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~index:5
                             ~receiver_class:"float"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def bar(x):
        y = f"{x}" f"{x}"
        if bar(f"{x}"):
          return True
        else:
          return True
    |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "3:6-3:19",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "4:5-4:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.none)
                               (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
               ( "4:9-4:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           (* No duplicate targets, even if visiting both `if` and `if not`. *)
                           CallTarget.create
                             ~return_type:None
                             ~index:1
                             Target.ArtificialTargets.format_string;
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      def foo(x: object):
        return f"{x}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "3:12-3:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112761296): Probably wrong call resolution *)
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"object"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      def foo(x: object):
        return f"{x}:{x}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:19",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "3:12-3:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112761296): Probably wrong call resolution *)
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"object"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "3:16-3:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112761296): Probably wrong call resolution *)
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"object"
                             ~index:1
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      def foo(x: Any):
        return f"{x}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               (* TODO(T112761296): Probably wrong call resolution. Expect an additional call
                  target. *)
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class A:
        def __str__(self): return "stringified"

      def foo():
        a = A()
        "hello %s" % a
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:6-6:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
               ( "7:2-7:16",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             (* TODO(T146836847): Missing the stringify callee. *)
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"str"
                               (Target.Method
                                  { class_name = "str"; method_name = "__mod__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:{|
      def foo(e: Exception):
        f"{e}"
        f"{type(e)}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:2-3:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "3:5-3:6",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"Exception"
                             (Target.Method
                                {
                                  class_name = "BaseException";
                                  method_name = "__str__";
                                  kind = Normal;
                                });
                         ])) );
               ( "4:2-4:14",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create
                             ~return_type:None
                             ~index:1
                             Target.ArtificialTargets.format_string;
                         ])) );
               ( "4:5-4:12",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "$__str__$",
                          ExpressionCallees.from_string_format
                            (StringFormatCallees.from_stringify_targets
                               [
                                 (* TODO(T112761296): Probably wrong call resolution *)
                                 CallTarget.create
                                   ~index:1
                                   (Target.Method
                                      {
                                        class_name = "BaseException";
                                        method_name = "__str__";
                                        kind = Normal;
                                      });
                               ]) );
                        ( "type",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~new_targets:
                                 [
                                   CallTarget.create
                                     ~is_static_method:true
                                     (Target.Method
                                        {
                                          class_name = "type";
                                          method_name = "__new__";
                                          kind = Normal;
                                        });
                                 ]
                               ~init_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     (Target.Method
                                        {
                                          class_name = "type";
                                          method_name = "__init__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def foo(error_type: typing.Union[str, typing.Type[Exception]]):
        return f"{error_type}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "3:12-3:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112761296): Wrong call resolution *)
                           CallTarget.create
                             (Target.Function { name = "BaseException.__str__"; kind = Normal });
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"str"
                             (Target.Method
                                { class_name = "str"; method_name = "__str__"; kind = Normal });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def foo(error_type: typing.Type[Exception]):
        return f"{error_type}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "3:12-3:22",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112761296): Wrong call resolution *)
                           CallTarget.create
                             (Target.Method
                                {
                                  class_name = "BaseException";
                                  method_name = "__str__";
                                  kind = Normal;
                                });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:
             {|
      class A:
        def __str__(self):
          return "A"
      class B:
        pass
      def foo(x: typing.Union[A, B]):
        f"{x.__class__}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "8:2-8:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "8:5-8:16",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "$__str__$",
                          ExpressionCallees.from_string_format
                            (StringFormatCallees.from_stringify_targets
                               [
                                 (* TODO(T112761296): Probably wrong call resolution *)
                                 CallTarget.create
                                   (Target.Function { name = "object.__str__"; kind = Normal });
                                 CallTarget.create
                                   (Target.Function { name = "test.A.__str__"; kind = Normal });
                               ]) );
                        ( "__class__",
                          ExpressionCallees.from_attribute_access
                            {
                              AttributeAccessCallees.property_targets =
                                [
                                  CallTarget.create
                                    ~implicit_receiver:true
                                    (Target.Method
                                       {
                                         class_name = "object";
                                         method_name = "__class__";
                                         kind = Normal;
                                       });
                                ];
                              global_targets = [];
                              is_attribute = false;
                            } );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:
             {|
      class A:
        def __str__(self):
          return "A"
      def foo(x: A):
        f"{x.__class__}"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "6:2-6:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "6:5-6:16",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "$__str__$",
                          ExpressionCallees.from_string_format
                            (StringFormatCallees.from_stringify_targets
                               [
                                 (* TODO(T112761296): Probably wrong call resolution *)
                                 CallTarget.create
                                   (Target.Method
                                      {
                                        class_name = "test.A";
                                        method_name = "__str__";
                                        kind = Normal;
                                      });
                               ]) );
                        ( "__class__",
                          ExpressionCallees.from_attribute_access
                            {
                              AttributeAccessCallees.property_targets =
                                [
                                  CallTarget.create
                                    ~implicit_receiver:true
                                    (Target.Method
                                       {
                                         class_name = "object";
                                         method_name = "__class__";
                                         kind = Normal;
                                       });
                                ];
                              global_targets = [];
                              is_attribute = false;
                            } );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~cmp:DefineCallGraph.equal_ignoring_types
           ~source:{|
      def foo(e: Exception):
        return str(e) + "hello"
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:9-3:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    class_name = "BaseException";
                                    method_name = "__str__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "3:9-3:25",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "str"; method_name = "__add__"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo():
         pass

     def bar():
         pass

     def baz():
         foo()
         foo()
         bar()
         foo()
         bar()
  |}
           ~define_name:"test.baz"
           ~expected:
             [
               ( "9:4-9:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:0
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "10:4-10:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "11:4-11:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:0
                               (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
               ( "12:4-12:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:2
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "13:4-13:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               (Target.Function { name = "test.bar"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
     def foo(x=None, y=None):
         pass

     def bar():
         foo(foo(), foo(foo()))
  |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "6:4-6:26",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:3
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "6:8-6:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:0
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "6:15-6:25",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:2
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
               ( "6:19-6:24",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Union

      class A:
          def foo():
              pass

      class B(A):
          pass

      class C(A):
          pass

      def test(x: Union[B, C]):
          x.foo()
          if isinstance(x, C):
              x.foo()
          else:
              x.foo()

          if isinstance(x, B):
              x.foo()
  |}
           ~define_name:"test.test"
           ~expected:
             [
               ( "15:4-15:11",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:0
                               ~receiver_class:"test.B"
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:0
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
               ( "16:7-16:23",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:0
                               ~return_type:(Some ReturnType.bool)
                               (Target.Function { name = "isinstance"; kind = Normal });
                           ]
                         ())) );
               ( "17:8-17:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                                 (* Assigned index is 2 instead of 1, because we use the control
                                    flow graph traversal order. *)
                               ~index:2
                               ~receiver_class:"test.C"
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
               ( "19:8-19:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:1
                               ~receiver_class:"test.B"
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
               ( "21:7-21:23",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             (* Assigned index is 2 instead of 1, because we visit the if statement
                                twice. *)
                             CallTarget.create
                               ~index:2
                               ~return_type:(Some ReturnType.bool)
                               (Target.Function { name = "isinstance"; kind = Normal });
                           ]
                         ())) );
               ( "22:8-22:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:3
                               ~receiver_class:"test.B"
                               (Target.Method
                                  { class_name = "test.A"; method_name = "foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Test the return type when using type variables. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       import typing

       def bar(l: typing.List[int]):
         return l.__iter__().__next__()
      |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "5:9-5:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.any)
                               ~receiver_class:"list"
                               (Target.Method
                                  { class_name = "list"; method_name = "__iter__"; kind = Normal });
                           ]
                         ())) );
               ( "5:9-5:32",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"typing.Iterator"
                               (Target.Method
                                  {
                                    class_name = "typing.Iterator";
                                    method_name = "__next__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       import typing

       def bar(l: typing.List[int]):
         return l[0]
      |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "5:9-5:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"list"
                               (Target.Method
                                  {
                                    class_name = "list";
                                    method_name = "__getitem__";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       from typing import Union, overload

       @overload
       def foo(x: int) -> int:
         ...

       @overload
       def foo(x: str) -> str:
         ...

       def foo(x: Union[int, str]) -> Union[int, str]:
         return x

       def bar():
         return foo(0)
      |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "16:9-16:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       import typing

       T = typing.TypeVar("T")

       def foo(x: T) -> T:
         return T

       def bar():
         return foo(0)
      |}
           ~define_name:"test.bar"
           ~expected:
             [
               ( "10:9-10:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.foo"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      (* Nested defines. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       def baz(x: int) -> int:
         return x

       def foo():
         def bar(x: int) -> int:
           return baz(x)

         return bar
      |}
           ~define_name:"$local_test?foo$bar"
           ~expected:
             [
               ( "7:11-7:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       def baz(x: int) -> int:
         return x

       def foo():
         if 1 < 2:
           def bar(x: int) -> int:
             return baz(x)

           return bar
         else:
           return None
      |}
           ~define_name:"$local_test?foo$bar"
           ~expected:
             [
               ( "8:13-8:19",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~return_type:(Some ReturnType.integer)
                               (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       def decorator(function):
           return function

       class Base:
           @decorator
           def query(self, arg):
               return arg

       class Child(Base):
           pass

       class SubChild(Child):
           def query(self, arg):
               return arg

       def foo(base: Base, child: Child):
           base.query(1)
           child.query(1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "18:4-18:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Override
                                  {
                                    Target.class_name = "test.Base";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "19:4-19:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:1
                               (Target.Method
                                  {
                                    Target.class_name = "test.Base";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    Target.class_name = "test.SubChild";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       def decorator(function):
           return function

       class BaseA:
           @decorator
           def query(self, arg):
               return arg

       class BaseB:
           pass

       class BaseC:
           @decorator
           def query(self, arg):
               return arg

       class Child(BaseB, BaseA, BaseC):
           pass

       def foo(base: BaseA, child: Child):
           base.query(1)
           child.query(1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "22:4-22:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    Target.class_name = "test.BaseA";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "23:4-23:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:1
                               (Target.Method
                                  {
                                    (* Not `test.BaseC`, because `A` is the first parent class of
                                       `Child`. *)
                                    Target.class_name = "test.BaseA";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from abc import abstractclassmethod
      from typing import TypeVar, Generic
      TInput = TypeVar("TInput")

      class C(Generic[TInput]):
        @abstractclassmethod
        def f(cls, arg: TInput) -> TInput:
          raise NotImplementedError()
        @classmethod
        def g(cls, arg: TInput):
          cls.f(arg)
      |}
           ~define_name:"test.C.g"
           ~expected:
             [
               ( "12:4-12:14",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~is_class_method:true
                               (Target.Method
                                  { class_name = "test.C"; method_name = "f"; kind = Normal });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Generic, TypeVar

      T = TypeVar("T")
      def decorator(function):
          return function

      class A(Generic[T]):
          @decorator
          def query(self, arg: T) -> T:
              pass
      class B(A[int]):
          pass
      class C(A[int]):
          def query(self, arg: int) -> int:
              return arg
      class D(B):
          def query(self, arg: int) -> int:
              pass

      def foo(base: A[int], child_b: B, child_c: C, child_d: D):
          base.query(1)
          child_b.query(1)
          child_c.query(1)
          child_d.query(1)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "22:4-22:17",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Override
                                  {
                                    Target.class_name = "test.A";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "23:4-23:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                             (* TODO(T118125320): Return type is None, which is incorrect *)
                               ~implicit_receiver:true
                               ~index:1
                               (Target.Method
                                  {
                                    Target.class_name = "test.A";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                             CallTarget.create
                             (* TODO(T118125320): Return type is None, which is incorrect *)
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    Target.class_name = "test.D";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "24:4-24:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.C"
                               (Target.Method
                                  {
                                    Target.class_name = "test.C";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
               ( "25:4-25:20",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~return_type:(Some ReturnType.integer)
                               ~receiver_class:"test.D"
                               ~index:1
                               (Target.Method
                                  {
                                    Target.class_name = "test.D";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      from typing import Generic, TypeVar

      T = TypeVar("T")
      def decorator(function):
          return function

      class A(Generic[T]):
          @decorator
          def query(self, arg: T) -> None:
              pass
      class B(A[int]):
          pass

      def foo(base: A[T], arg: T) -> None:
          base.query(arg)
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "16:4-16:19",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  {
                                    Target.class_name = "test.A";
                                    method_name = "query";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       def foo(l: typing.AsyncIterator[int | str]):
         async for x in l:
           pass
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "3:17-3:18",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call_with_empty_attribute
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       class A:
         def f(self) -> typing.List[int]:
           return [1, 2]
       def g() -> A:
         return A()
       def id(arg):
         return arg
       def foo(l0: typing.AsyncIterator[int], l1: typing.List[int], l2: typing.AsyncIterable[int]):
         x = [x async for x in l0]
         x = [x for x in l1]  # List comprehension
         x = [x async for x in l2]  # List comprehension
         x = [x for x in g().f()]  # Iterator as a compound AST node
         x = {x for x in l1}  # Set comprehension
         x = {x async for x in l2}  # Set comprehension
         x = {x:0 for x in l1}  # Dictionary comprehension
         x = {x:0 async for x in l2}  # Dictionary comprehension
         x = (x for x in l1) # Generator comprehension
         x = (x async for x in l2)  # Generator comprehension
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "10:24-10:26",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "11:18-11:20",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.Iterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "12:24-12:26",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterable"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterable";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.AsyncIterator"
                                     ~index:1
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "13:18-13:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [CallTarget.create (Target.Function { name = "test.g"; kind = Normal })]
                         ())) );
               ( "13:18-13:25",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     ~index:1
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.Iterator"
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~index:1
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "f",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"test.A"
                                     (Target.Method
                                        { class_name = "test.A"; method_name = "f"; kind = Normal });
                                 ]
                               ()) );
                      ]) );
               ( "14:18-14:20",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     ~index:2
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.Iterator"
                                     ~index:2
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "15:24-15:26",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterable"
                                     ~index:1
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterable";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.AsyncIterator"
                                     ~index:2
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "16:20-16:22",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     ~index:3
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.Iterator"
                                     ~index:3
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "17:26-17:28",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterable"
                                     ~index:2
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterable";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.AsyncIterator"
                                     ~index:3
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "18:18-18:20",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__iter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"list"
                                     ~index:4
                                     (Target.Method
                                        {
                                          class_name = "list";
                                          method_name = "__iter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__next__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.Iterator"
                                     ~index:4
                                     (Target.Method
                                        {
                                          class_name = "typing.Iterator";
                                          method_name = "__next__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "19:24-19:26",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterable"
                                     ~index:3
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterable";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~return_type:
                                       (Some
                                          {
                                            ReturnType.is_boolean = false;
                                            is_integer = true;
                                            is_float = true;
                                            is_enumeration = false;
                                          })
                                     ~receiver_class:"typing.AsyncIterator"
                                     ~index:4
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
       class A:
         def foo(self): pass
       class B:
         def foo(self): pass
       def f(l: typing.AsyncIterator[A], x: B):
         ([x async for x in l], x.foo())
      |}
           ~define_name:"test.f"
           ~expected:
             [
               ( "7:21-7:22",
                 LocationCallees.Compound
                   (SerializableStringMap.of_alist_exn
                      [
                        ( "__aiter__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__aiter__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                        ( "__anext__",
                          ExpressionCallees.from_call
                            (CallCallees.create
                               ~call_targets:
                                 [
                                   CallTarget.create
                                     ~implicit_receiver:true
                                     ~receiver_class:"typing.AsyncIterator"
                                     (Target.Method
                                        {
                                          class_name = "typing.AsyncIterator";
                                          method_name = "__anext__";
                                          kind = Normal;
                                        });
                                 ]
                               ()) );
                      ]) );
               ( "7:25-7:32",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"test.B"
                               (Target.Method
                                  {
                                    Target.class_name = "test.B";
                                    method_name = "foo";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class Object:
        pass

      x = Object()
      y = Object()

      def foo():
        x.bar = ""
        y.bar = ""

        baz(x)
        baz(y)

      def baz(x: Object):
        pass
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "9:2-9:3",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~index:0 ~return_type:None (Target.Object "test.x")];
                        nonlocal_targets = [];
                      }) );
               ( "10:2-10:3",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~index:0 ~return_type:None (Target.Object "test.y")];
                        nonlocal_targets = [];
                      }) );
               ( "12:2-12:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:0
                               (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
               ( "12:6-12:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~index:1 ~return_type:None (Target.Object "test.x")];
                        nonlocal_targets = [];
                      }) );
               ( "13:2-13:8",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~index:1
                               (Target.Function { name = "test.baz"; kind = Normal });
                           ]
                         ())) );
               ( "13:6-13:7",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~index:1 ~return_type:None (Target.Object "test.y")];
                        nonlocal_targets = [];
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      class Object:
        pass

      x = Object()

      def foo():
        return x.bar
    |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "8:9-8:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.x")];
                        nonlocal_targets = [];
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.A.B"]
           ~source:
             {|
      from typing import Any, MutableMapping
      from typing_extensions import Self
      from pyre_extensions import ReadOnly

      class A:
        B: MutableMapping[str, Any] = {}

        def __init__(self) -> None:
          self.B: MutableMapping[str, Any] = {}

        def self_readonly(self: ReadOnly[Self]) -> None:
          self.B.get("")
     |}
           ~define_name:"test.A.self_readonly"
           ~expected:
             [
               ( "13:4-13:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets = [];
                        global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.A.B")];
                        is_attribute = true;
                      }) );
               ( "13:4-13:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"typing.MutableMapping"
                               ~return_type:(Some ReturnType.none)
                               (Target.Method
                                  {
                                    class_name = "typing.Mapping";
                                    method_name = "get";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~object_targets:[Target.Object "test.A.B"]
           ~source:
             {|
      from typing import Any, MutableMapping
      from typing_extensions import Self
      from pyre_extensions import ReadOnly

      class A:
        def __init__(self) -> None:
          self.B: MutableMapping[str, Any] = {}

        def self_untyped(self) -> None:
          self.B.get("")
    |}
           ~define_name:"test.A.self_untyped"
           ~expected:
             [
               ( "11:4-11:10",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_attribute_access
                      {
                        AttributeAccessCallees.property_targets = [];
                        global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.A.B")];
                        is_attribute = true;
                      }) );
               ( "11:4-11:18",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~call_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~receiver_class:"typing.MutableMapping"
                               ~return_type:(Some ReturnType.none)
                               (Target.Method
                                  {
                                    class_name = "typing.Mapping";
                                    method_name = "get";
                                    kind = Normal;
                                  });
                           ]
                         ())) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:{|
      x = ""
      def foo():
        global x
        x = "str"
      |}
           ~define_name:"test.foo"
           ~expected:
             [
               ( "5:2-5:3",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.global_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.x")];
                        nonlocal_targets = [];
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def outer():
        x = ""
        def inner():
          nonlocal x
          x = "str"
      |}
           ~define_name:"$local_test?outer$inner"
           ~expected:
             [
               ( "6:4-6:5",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.nonlocal_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.outer.x")];
                        global_targets = [];
                      }) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source:
             {|
      def outer():
        x = ""
        def inner():
          y = x
      |}
           ~define_name:"$local_test?outer$inner"
           ~expected:
             [
               ( "5:8-5:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_identifier
                      {
                        IdentifierCallees.nonlocal_targets =
                          [CallTarget.create ~return_type:None (Target.Object "test.outer.x")];
                        global_targets = [];
                      }) );
             ]
           ();
    ]


let test_call_graph_of_define_foo_and_bar =
  let source =
    {|
      class A:
        def __str__(self):
          return "A"

      class B:
        def __repr__(self):
          return "B"

      class C:
        def __str__(self):
          return "C"
        def __repr__(self):
          return "C"

      class D:
        def foo():
          pass

      def foo():
        a = A()
        b = B()
        c = C()
        d = D()
        return f"{a}hello{b}world{c}{d}"

      def bar(x: typing.Union[A, B, C, D]):
        return f"{x}"
    |}
  in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source
           ~define_name:"test.foo"
           ~expected:
             [
               ( "21:6-21:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
               ( "22:6-22:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:1
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~index:1
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
               ( "23:6-23:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:2
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~index:2
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
               ( "24:6-24:9",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_call
                      (CallCallees.create
                         ~init_targets:
                           [
                             CallTarget.create
                               ~implicit_receiver:true
                               ~index:3
                               (Target.Method
                                  { class_name = "object"; method_name = "__init__"; kind = Normal });
                           ]
                         ~new_targets:
                           [
                             CallTarget.create
                               ~index:3
                               ~is_static_method:true
                               (Target.Method
                                  { class_name = "object"; method_name = "__new__"; kind = Normal });
                           ]
                         ())) );
               ( "25:9-25:34",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "25:12-25:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.A"
                             (Target.Method
                                { class_name = "test.A"; method_name = "__str__"; kind = Normal });
                         ])) );
               ( "25:20-25:21",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.B"
                             (Target.Method
                                { class_name = "test.B"; method_name = "__repr__"; kind = Normal });
                         ])) );
               ( "25:28-25:29",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.C"
                             (Target.Method
                                { class_name = "test.C"; method_name = "__str__"; kind = Normal });
                         ])) );
               ( "25:31-25:32",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.D"
                             (Target.Method
                                { class_name = "object"; method_name = "__repr__"; kind = Normal });
                         ])) );
             ]
           ();
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_call_graph_of_define
           ~source
           ~define_name:"test.bar"
           ~expected:
             [
               ( "28:9-28:15",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_f_string_targets
                         [
                           CallTarget.create ~return_type:None Target.ArtificialTargets.format_string;
                         ])) );
               ( "28:12-28:13",
                 LocationCallees.Singleton
                   (ExpressionCallees.from_string_format
                      (StringFormatCallees.from_stringify_targets
                         [
                           (* TODO(T112028293): Properly resolve `__str__` calls on union-typed
                              variables *)
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.B"
                             (Target.Method
                                { class_name = "object"; method_name = "__str__"; kind = Normal });
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.D"
                             (Target.Method
                                { class_name = "object"; method_name = "__str__"; kind = Normal });
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.A"
                             (Target.Method
                                { class_name = "test.A"; method_name = "__str__"; kind = Normal });
                           CallTarget.create
                             ~implicit_receiver:true
                             ~receiver_class:"test.C"
                             (Target.Method
                                { class_name = "test.C"; method_name = "__str__"; kind = Normal });
                         ])) );
             ]
           ();
    ]


let test_return_type_from_annotation =
  let assert_from_annotation annotation expected context =
    let project = Test.ScratchProject.setup ~context [] in
    let pyre_api = Test.ScratchProject.pyre_pysa_read_only_api project in
    let actual = ReturnType.from_annotation ~pyre_api annotation in
    assert_equal ~printer:ReturnType.show ~cmp:ReturnType.equal expected actual
  in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           Type.bool
           {
             ReturnType.is_boolean = true;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           Type.enumeration
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = true;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           Type.integer
           {
             ReturnType.is_boolean = false;
             is_integer = true;
             is_float = true;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.optional Type.bool)
           {
             ReturnType.is_boolean = true;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.optional Type.enumeration)
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = true;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.optional Type.integer)
           {
             ReturnType.is_boolean = false;
             is_integer = true;
             is_float = true;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           Type.none
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           Type.Any
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable Type.bool)
           {
             ReturnType.is_boolean = true;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable Type.enumeration)
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = true;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable Type.integer)
           {
             ReturnType.is_boolean = false;
             is_integer = true;
             is_float = true;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable (Type.optional Type.bool))
           {
             ReturnType.is_boolean = true;
             is_integer = false;
             is_float = false;
             is_enumeration = false;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable (Type.optional Type.enumeration))
           {
             ReturnType.is_boolean = false;
             is_integer = false;
             is_float = false;
             is_enumeration = true;
           };
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_from_annotation
           (Type.awaitable (Type.optional Type.integer))
           {
             ReturnType.is_boolean = false;
             is_integer = true;
             is_float = true;
             is_enumeration = false;
           };
    ]


let () =
  "interproceduralCallGraph"
  >::: [
         test_call_graph_of_define;
         test_call_graph_of_define_foo_and_bar;
         test_return_type_from_annotation;
       ]
  |> Test.run
