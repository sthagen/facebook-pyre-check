(* Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Pyre
open Core
open OUnit2
open Test
open TestHelper
module Callable = Interprocedural.Callable

let assert_model ?source ?rules ~context ~model_source ~expect () =
  let source =
    match source with
    | None -> model_source
    | Some source -> source
  in
  let { ScratchProject.BuiltGlobalEnvironment.global_environment; _ } =
    ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
  in
  let configuration =
    let rules =
      match rules with
      | Some rules -> rules
      | None -> []
    in
    Taint.TaintConfiguration.
      {
        empty with
        sources = ["TestTest"];
        sinks = ["TestSink"; "OtherSink"];
        features = ["special"];
        rules;
      }
  in
  let models =
    let source = Test.trim_extra_indentation model_source in
    let resolution =
      let global_resolution = Analysis.GlobalResolution.create global_environment in
      TypeCheck.resolution global_resolution ()
    in
    let rule_filter =
      match rules with
      | Some rules -> Some (List.map rules ~f:(fun { Taint.TaintConfiguration.code; _ } -> code))
      | None -> None
    in
    let { Taint.Model.models; errors } =
      Taint.Model.parse ~resolution ?rule_filter ~source ~configuration Callable.Map.empty
    in
    assert_bool
      (Format.sprintf "Models have parsing errors: %s" (List.to_string errors ~f:ident))
      (List.is_empty errors);
    models
  in
  let get_model callable =
    let message = Format.asprintf "Model %a missing" Interprocedural.Callable.pp callable in
    Callable.Map.find models callable |> Option.value_exn ?here:None ?error:None ~message, false
    (* obscure *)
  in
  let environment =
    Analysis.TypeEnvironment.create global_environment |> Analysis.TypeEnvironment.read_only
  in
  List.iter ~f:(check_expectation ~environment ~get_model) expect


open Taint

let test_source_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "TestTest"] "test.taint"]
    ();
  assert_model
    ~model_source:"os.environ: TaintSource[TestTest] = ..."
    ~expect:[outcome ~kind:`Object ~returns:[Sources.NamedSource "TestTest"] "os.environ"]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: TaintSource[TestTest] = ..."
    ~expect:
      [outcome ~kind:`Object ~returns:[Sources.NamedSource "TestTest"] "django.http.Request.GET"]
    ();
  assert_model
    ~model_source:"def test.taint() -> TaintSource[Test, UserControlled]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Test; Sources.UserControlled] "test.taint"]
    ();
  assert_model
    ~model_source:"os.environ: TaintSink[Test] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~sink_parameters:[{ name = "$global"; sinks = [Sinks.Test] }]
          "os.environ";
      ]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f(x) -> TaintSource[Test, ViaValueOf[x]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Test] "test.f"]
    ();
  assert_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:{|
      @property
      def test.C.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`Method ~returns:[Sources.Test] "test.C.foo"]
    ();
  assert_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:
      {|
      @foo.setter
      def test.C.foo(self, value) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`PropertySetter ~returns:[Sources.Test] "test.C.foo"]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f(x) -> AppliesTo[0, TaintSource[Test]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Test] "test.f"]
    ();
  assert_model
    ~source:
      {|
        import abc
        class C:
          @abc.abstractproperty
          def foo(self) -> int:
            return self.x
          @foo.setter
          def foo(self, value) -> None:
            self.x = value
        |}
    ~model_source:{|
        @property
        def test.C.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`Method ~returns:[Sources.Test] "test.C.foo"]
    ();

  ()


let test_sink_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:{|
        def test.sink(parameter: TaintSink[TestSink]):
          ...
      |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0, parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter1"; sinks = [Sinks.Test] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.Test] };
              { name = "parameter1"; sinks = [Sinks.Test] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.Test] };
              { name = "parameter1"; sinks = [Sinks.Test] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.both(parameter0: TaintSink[Demo]) -> TaintSource[Demo]: ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~returns:[Sources.Demo]
          ~sink_parameters:[{ name = "parameter0"; sinks = [Sinks.Demo] }]
          "test.both";
      ]
    ();
  assert_model
    ~model_source:
      "def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test, \
       ViaValueOf[parameter0]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.Test] };
              { name = "parameter1"; sinks = [Sinks.Test] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.xss(parameter: TaintSink[XSS]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.XSS] }]
          "test.xss";
      ]
    ();
  assert_model
    ~model_source:"def test.multiple(parameter: TaintSink[XSS, Demo]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.Demo; Sinks.XSS] }]
          "test.multiple";
      ]
    ();
  assert_model
    ~model_source:"def test.multiple(parameter: AppliesTo[1, TaintSink[XSS, Demo]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.Demo; Sinks.XSS] }]
          "test.multiple";
      ]
    ()


let test_class_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~source:
      {|
        class Sink:
          def Sink.method(parameter): ...
          def Sink.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.Sink(TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.Sink.method";
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              { name = "first"; sinks = [Sinks.NamedSink "TestSink"] };
              { name = "second"; sinks = [Sinks.NamedSink "TestSink"] };
            ]
          "test.Sink.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class Sink:
          def Sink.method(parameter): ...
          def Sink.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.Sink(TaintSink[TestSink], TaintSink[OtherSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              {
                name = "parameter";
                sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"];
              };
            ]
          "test.Sink.method";
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              { name = "first"; sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"] };
              { name = "second"; sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"] };
            ]
          "test.Sink.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class SinkAndSource:
          def SinkAndSource.method(parameter): ...
      |}
    ~model_source:"class test.SinkAndSource(TaintSink[TestSink], TaintSource[TestTest]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          ~returns:[Sources.NamedSource "TestTest"]
          "test.SinkAndSource.method";
      ]
    ();

  assert_model
    ~source:
      {|
        class Source:
          def Source.method(parameter): ...
          def Source.method_with_multiple_parameters(first, second): ...
          Source.attribute = ...
      |}
    ~model_source:{|
        class test.Source(TaintSource[UserControlled]): ...
      |}
    ~expect:
      [
        outcome ~kind:`Method ~returns:[Sources.UserControlled] "test.Source.method";
        outcome
          ~kind:`Method
          ~returns:[Sources.UserControlled]
          "test.Source.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class AnnotatedSink:
          def AnnotatedSink.method(parameter: int) -> None: ...
      |}
    ~model_source:"class test.AnnotatedSink(TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.AnnotatedSink.method";
      ]
    ();
  assert_model
    ~source:
      {|
         class AnnotatedSource:
          def AnnotatedSource.method(parameter: int) -> None: ...
      |}
    ~model_source:"class test.AnnotatedSource(TaintSource[UserControlled]): ..."
    ~expect:[outcome ~kind:`Method ~returns:[Sources.UserControlled] "test.AnnotatedSource.method"]
    ();
  assert_model
    ~source:
      {|
         class SourceWithDefault:
          def SourceWithDefault.method(parameter: int = 1) -> None: ...
      |}
    ~model_source:"class test.SourceWithDefault(TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.Test] }]
          "test.SourceWithDefault.method";
      ]
    ();
  assert_model
    ~source:
      {|
         class Source:
           @classmethod
           def Source.method(cls, parameter: int) -> None: ...
      |}
    ~model_source:"class test.Source(TaintSource[UserControlled]): ..."
    ~expect:[outcome ~kind:`Method ~returns:[Sources.UserControlled] "test.Source.method"]
    ();
  assert_model
    ~source:
      {|
         class Source:
           @property
           def Source.prop(self) -> int: ...
      |}
    ~model_source:"class test.Source(TaintSource[UserControlled]): ..."
    ~expect:[outcome ~kind:`Method ~returns:[Sources.UserControlled] "test.Source.prop"]
    ();
  assert_model
    ~source:
      {|
        class SkipMe:
          def SkipMe.method(parameter): ...
          def SkipMe.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.SkipMe(SkipAnalysis): ..."
    ~expect:
      [
        outcome ~kind:`Method ~analysis_mode:Taint.Result.SkipAnalysis "test.SkipMe.method";
        outcome
          ~kind:`Method
          ~analysis_mode:Taint.Result.SkipAnalysis
          "test.SkipMe.method_with_multiple_parameters";
      ]
    ()


let test_taint_in_taint_out_models context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ();
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: AppliesTo[1, TaintInTaintOut]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_taint_in_taint_out_models_alternate context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut[LocalReturn]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_taint_in_taint_out_update_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.update(self, arg1: TaintInTaintOut[Updates[self]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["arg1 updates parameter 0"] "test.update"]
    ();
  assert_model
    ~model_source:"def test.update(self, arg1, arg2: TaintInTaintOut[Updates[self, arg1]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~tito_parameters:["arg2 updates parameter 0"; "arg2 updates parameter 1"]
          "test.update";
      ]
    ();
  assert_model
    ~model_source:"def test.update(self: TaintInTaintOut[LocalReturn, Updates[arg1]], arg1): ..."
    ~expect:
      [outcome ~kind:`Function ~tito_parameters:["self"; "self updates parameter 1"] "test.update"]
    ()


let test_union_models context =
  assert_model
    ~context
    ~model_source:"def test.both(parameter: Union[TaintInTaintOut, TaintSink[XSS]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.XSS] }]
          ~tito_parameters:["parameter"]
          "test.both";
      ]
    ()


let test_source_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.source() -> TaintSource[Test, Via[special]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Test] "test.source"]
    ()


let test_sink_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.sink(parameter: TaintSink[Test, Via[special]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.Test] }]
          "test.sink";
      ]
    ()


let test_tito_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut[Via[special]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_attach_features context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.source() -> AttachToSource[Via[special]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Attach] "test.source"]
    ();
  assert_model
    ~model_source:"def test.sink(arg: AttachToSink[Via[special]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "arg"; sinks = [Sinks.Attach] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.tito(arg: AttachToTito[Via[special]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["arg"] "test.tito"]
    ()


let test_invalid_models context =
  let assert_invalid_model ?path ?source ~model_source ~expect () =
    let source =
      match source with
      | Some source -> source
      | None ->
          {|
              unannotated_global = source()
              def test.sink(parameter) -> None: pass
              def test.sink_with_optional(parameter, firstOptional=1, secondOptional=2) -> None: pass
              def test.source() -> None: pass
              def function_with_args(normal_arg, __anonymous_arg, *args) -> None: pass
              def function_with_kwargs(normal_arg, **kwargs) -> None: pass
              def anonymous_only(__arg1, __arg2, __arg3) -> None: pass
              def anonymous_with_optional(__arg1, __arg2, __arg3=2) -> None: pass
              class C:
                unannotated_class_variable = source()
            |}
    in
    let resolution =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_resolution
    in
    let configuration =
      TaintConfiguration.
        {
          empty with
          sources = ["A"; "B"];
          sinks = ["X"; "Y"];
          features = ["featureA"; "featureB"];
          rules = [];
        }
    in
    let error_message =
      let path = path >>| Path.create_absolute ~follow_symbolic_links:false in
      Model.parse
        ~resolution
        ~configuration
        ?path
        ~source:(Test.trim_extra_indentation model_source)
        Callable.Map.empty
      |> fun { Taint.Model.errors; _ } -> List.hd errors |> Option.value ~default:"no failure"
    in
    assert_equal ~printer:ident expect error_message
  in
  let assert_valid_model ?source ~model_source () =
    assert_invalid_model ?source ~model_source ~expect:"no failure" ()
  in
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[X, Unsupported]) -> TaintSource[A]: ..."
    ~expect:"Invalid model for `test.sink`: Unsupported taint sink `Unsupported`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[UserControlled]): ..."
    ~expect:"Invalid model for `test.sink`: Unsupported taint sink `UserControlled`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: SkipAnalysis): ..."
    ~expect:"Invalid model for `test.sink`: SkipAnalysis annotation must be in return position"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[X, Y, LocalReturn]): ..."
    ~expect:"Invalid model for `test.sink`: Invalid TaintSink annotation `LocalReturn`"
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> TaintSource[Invalid]: ..."
    ~expect:"Invalid model for `test.source`: Unsupported taint source `Invalid`"
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> TaintInTaintOut: ..."
    ~expect:"Invalid model for `test.source`: Invalid return annotation: TaintInTaintOut"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintInTaintOut[Test]): ..."
    ~expect:"Invalid model for `test.sink`: Invalid TaintInTaintOut annotation `Test`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:
      "Invalid model for `test.sink`: Unrecognized taint annotation `InvalidTaintDirection[Test]`"
    ();

  assert_invalid_model
    ~model_source:"def not_in_the_environment(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:
      "Invalid model for `not_in_the_environment`: Modeled entity is not part of the environment!"
    ();
  assert_invalid_model
    ~model_source:"def not_in_the_environment.derp(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:
      "Invalid model for `not_in_the_environment.derp`: Modeled entity is not part of the \
       environment!"
    ();

  assert_invalid_model
    ~model_source:"def test.sink(): ..."
    ~expect:
      "Invalid model for `test.sink`: Model signature parameters do not match implementation `def \
       sink(parameter: unknown) -> None: ...`. Reason(s): missing named parameters: `parameter`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): missing named parameters: \
       `parameter`."
    ();
  assert_valid_model ~model_source:"def test.sink_with_optional(parameter): ..." ();
  assert_valid_model ~model_source:"def test.sink_with_optional(parameter, firstOptional): ..." ();
  assert_valid_model
    ~model_source:"def test.sink_with_optional(parameter, firstOptional, secondOptional): ..."
    ();
  assert_invalid_model
    ~model_source:
      "def test.sink_with_optional(parameter, firstOptional, secondOptional, thirdOptional): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): unexpected named parameter: \
       `thirdOptional`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, firstBad, secondBad): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): unexpected named parameter: \
       `firstBad`; unexpected named parameter: `secondBad`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, *args): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): unexpected star parameter."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, **kwargs): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): unexpected star star parameter."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(__parameter): ..."
    ~expect:
      "Invalid model for `test.sink_with_optional`: Model signature parameters do not match \
       implementation `def sink_with_optional(parameter: unknown, firstOptional: unknown = ..., \
       secondOptional: unknown = ...) -> None: ...`. Reason(s): missing named parameters: \
       `parameter`; unexpected positional only parameter: `__parameter`."
    ();
  assert_valid_model
    ~model_source:"def test.function_with_args(normal_arg, __random_name, named_arg, *args): ..."
    ();
  assert_valid_model
    ~model_source:"def test.function_with_args(normal_arg, __random_name, *args): ..."
    ();
  assert_valid_model
    ~model_source:
      "def test.function_with_args(normal_arg, __random_name, __random_name_2, *args): ..."
    ();
  assert_valid_model ~model_source:"def test.function_with_kwargs(normal_arg, **kwargs): ..." ();
  assert_valid_model
    ~model_source:"def test.function_with_kwargs(normal_arg, crazy_arg, **kwargs): ..."
    ();
  assert_valid_model ~model_source:"def test.anonymous_only(__a1, __a2, __a3): ..." ();
  assert_valid_model ~model_source:"def test.anonymous_with_optional(__a1, __a2): ..." ();
  assert_valid_model ~model_source:"def test.anonymous_with_optional(__a1, __a2, __a3=...): ..." ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: Any): ..."
    ~expect:"Invalid model for `test.sink`: Unrecognized taint annotation `Any`"
    ();
  assert_invalid_model
    ~path:"broken_model.pysa"
    ~model_source:"def test.sink(parameter: Any): ..."
    ~expect:
      "Invalid model for `test.sink` defined in `broken_model.pysa:1`: Unrecognized taint \
       annotation `Any`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[Test, Via[bad_feature]]): ..."
    ~expect:"Invalid model for `test.sink`: Unrecognized Via annotation `bad_feature`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[Updates[self]]): ..."
    ~expect:"Invalid model for `test.sink`: No such parameter `self`"
    ();
  assert_valid_model ~model_source:"test.unannotated_global: TaintSink[Test]" ();
  assert_invalid_model
    ~model_source:"test.missing_global: TaintSink[Test]"
    ~expect:
      "Invalid model for `test.missing_global`: Modeled entity is not part of the environment!"
    ();
  assert_valid_model ~model_source:"test.C.unannotated_class_variable: TaintSink[Test]" ();
  assert_invalid_model
    ~model_source:"test.C.missing: TaintSink[Test]"
    ~expect:"Invalid model for `test.C.missing`: Modeled entity is not part of the environment!"
    ();
  assert_invalid_model
    ~model_source:
      {|
      class test.ClassSinkWithMethod(TaintSink[TestSink]):
          def method(self): ...
      |}
    ~expect:"Invalid model for `test.ClassSinkWithMethod`: Class model must have a body of `...`."
    ();

  (* Attach syntax. *)
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToSink): ..."
    ~expect:"Invalid model for `test.sink`: Unrecognized taint annotation `AttachToSink`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToSink[feature]): ..."
    ~expect:
      "Invalid model for `test.sink`: All parameters to `AttachToSink` must be of the form \
       `Via[feature]`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToTito[feature]): ..."
    ~expect:
      "Invalid model for `test.sink`: All parameters to `AttachToTito` must be of the form \
       `Via[feature]`."
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> AttachToSource[feature]: ..."
    ~expect:
      "Invalid model for `test.source`: All parameters to `AttachToSource` must be of the form \
       `Via[feature]`."
    ();

  (* Multiple features. *)
  assert_valid_model
    ~model_source:"def test.sink(parameter: AttachToSink[Via[featureA, featureB]]): ..."
    ();

  (* Default values must be `...`. *)
  assert_invalid_model
    ~model_source:"def test.sink(parameter = TaintSink[Test]): ..."
    ~expect:
      "Invalid model for `test.sink`: Default values of parameters must be `...`. Did you mean to \
       write `parameter: TaintSink[Test]`?"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter = 1): ..."
    ~expect:
      "Invalid model for `test.sink`: Default values of parameters must be `...`. Did you mean to \
       write `parameter: 1`?"
    ();

  (* ViaValueOf models must specify existing parameters. *)
  assert_invalid_model
    ~model_source:
      "def test.sink(parameter) -> TaintSource[Test, ViaValueOf[nonexistent_parameter]]: ..."
    ~expect:"Invalid model for `test.sink`: No such parameter `nonexistent_parameter`"
    ();
  assert_invalid_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:
      {|
      @property
      def test.C.foo(self, value) -> TaintSource[Test]: ...
    |}
    ~expect:
      "Invalid model for `test.C.foo`: Model signature parameters do not match implementation \
       `(self: C) -> int`. Reason(s): unexpected named parameter: `value`."
    ();
  assert_invalid_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value: int) -> None:
        self.x = value
    |}
    ~model_source:{|
      @foo.setter
      def test.C.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:
      "Invalid model for `test.C.foo`: Model signature parameters do not match implementation \
       `(self: C, value: int) -> None`. Reason(s): missing named parameters: `value`."
    ();
  assert_invalid_model
    ~model_source:
      {|
      @decorated
      def accidental_decorator_passed_in() -> TaintSource[Test]: ...
    |}
    ~expect:
      "Invalid model for `accidental_decorator_passed_in`: Unexpected decorators found when \
       parsing model: `decorated`"
    ();
  assert_invalid_model
    ~source:
      {|
      class C:
        @property
        def foo(self) -> int: ...
        @foo.setter
        def foo(self, value) -> None: ...
    |}
    ~model_source:
      {|
      @wrong_name.setter
      def test.C.foo(self, value: TaintSink[Test]): ...
    |}
    ~expect:
      "Invalid model for `test.C.foo`: Unexpected decorators found when parsing model: \
       `wrong_name.setter`"
    ();
  assert_valid_model
    ~source:
      {|
      class C:
        @property
        def foo(self) -> int: ...
        @foo.setter
        def foo(self, value) -> None: ...
    |}
    ~model_source:
      {|
      @foo.setter
      def test.C.foo(self, value: TaintSink[Test]): ...
    |}
    ();
  assert_invalid_model
    ~model_source:
      {|
      def unittest.TestCase.assertIsNotNone(self, x: TaintSink[Test]): ...
    |}
    ~expect:
      "Invalid model for `unittest.TestCase.assertIsNotNone`: The modelled function is an imported \
       function `unittest.case.TestCase.assertIsNotNone`, please model it directly."
    ();
  assert_invalid_model
    ~model_source:
      {|
        def test.sink(parameter: TaintSink[Test, Via[a-feature]]):
          ...
    |}
    ~expect:
      "Invalid model for `test.sink`: Invalid expression for breadcrumb: (Expression.Expression.Call\n\
      \   { Expression.Call.callee = a.__sub__;\n\
      \     arguments = [{ Expression.Call.Argument.name = None; value = feature }]\n\
      \     })"
    ()


let test_demangle_class_attributes _ =
  let assert_demangle ~expected name =
    assert_equal expected (Model.demangle_class_attribute name)
  in
  assert_demangle ~expected:"a.B" "a.B";
  assert_demangle ~expected:"a.B" "a.__class__.B";

  (* We require `__class__` to directly precede the attribute of the `.`-separated names. *)
  assert_demangle ~expected:"a.B.__class__" "a.B.__class__";
  assert_demangle ~expected:"a.__class__.B.C" "a.__class__.B.C"


let test_filter_by_rules context =
  let assert_model = assert_model ~context in
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "TestTest"] "test.taint"]
    ();
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.sources = [Sources.Test];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[] "test.taint"]
    ();
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint(x: TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "x"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.taint";
      ]
    ();
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.Test];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint(x: TaintSink[TestSink]): ..."
    ~expect:[outcome ~kind:`Function ~sink_parameters:[] "test.taint"]
    ()


let () =
  "taint_model"
  >::: [
         "attach_features" >:: test_attach_features;
         "source_models" >:: test_source_models;
         "sink_models" >:: test_sink_models;
         "class_models" >:: test_class_models;
         "taint_in_taint_out_models" >:: test_taint_in_taint_out_models;
         "taint_in_taint_out_models_alternate" >:: test_taint_in_taint_out_models_alternate;
         "taint_in_taint_out_update_models" >:: test_taint_in_taint_out_update_models;
         "taint_union_models" >:: test_union_models;
         "source_breadcrumbs" >:: test_source_breadcrumbs;
         "sink_breadcrumbs" >:: test_sink_breadcrumbs;
         "tito_breadcrumbs" >:: test_tito_breadcrumbs;
         "invalid_models" >:: test_invalid_models;
         "demangle_class_attributes" >:: test_demangle_class_attributes;
         "filter_by_rules" >:: test_filter_by_rules;
       ]
  |> Test.run
