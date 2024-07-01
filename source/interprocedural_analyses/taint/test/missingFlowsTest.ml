(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Taint
open Interprocedural
open TestHelper

type expect_fixpoint = {
  expect: expectation list;
  iterations: int;
}

let assert_fixpoint
    ?models_source
    ~context
    ~missing_flows
    ~handle
    source
    ~expect:{ iterations = expect_iterations; expect }
  =
  let taint_configuration =
    TaintConfiguration.apply_missing_flows TaintConfiguration.Heap.default missing_flows
  in
  let {
    static_analysis_configuration;
    taint_configuration;
    taint_configuration_shared_memory;
    whole_program_call_graph;
    define_call_graphs;
    pyre_api;
    override_graph_heap;
    override_graph_shared_memory;
    initial_models;
    initial_callables;
    stubs;
    class_interval_graph_shared_memory;
    _;
  }
    =
    initialize
      ?models_source
      ~find_missing_flows:missing_flows
      ~taint_configuration
      ~handle
      ~context
      source
  in
  let { DependencyGraph.dependency_graph; callables_to_analyze; override_targets; _ } =
    DependencyGraph.build_whole_program_dependency_graph
      ~static_analysis_configuration
      ~prune:DependencyGraph.PruneMethod.None
      ~initial_callables
      ~call_graph:whole_program_call_graph
      ~overrides:override_graph_heap
  in
  let shared_models =
    TaintFixpoint.record_initial_models
      ~scheduler:(Test.mock_scheduler ())
      ~initial_models
      ~initial_callables:(FetchCallables.get_definitions initial_callables)
      ~stubs
      ~override_targets
  in
  let fixpoint_state =
    TaintFixpoint.compute
      ~scheduler:(Test.mock_scheduler ())
      ~scheduler_policy:(Scheduler.Policy.legacy_fixed_chunk_count ())
      ~pyre_api
      ~override_graph:
        (Interprocedural.OverrideGraph.SharedMemory.read_only override_graph_shared_memory)
      ~dependency_graph
      ~context:
        {
          TaintFixpoint.Context.taint_configuration = taint_configuration_shared_memory;
          pyre_api;
          class_interval_graph = class_interval_graph_shared_memory;
          define_call_graphs =
            Interprocedural.CallGraph.DefineCallGraphSharedMemory.read_only define_call_graphs;
          global_constants =
            GlobalConstants.SharedMemory.create () |> GlobalConstants.SharedMemory.read_only;
        }
      ~callables_to_analyze
      ~max_iterations:100
      ~epoch:TaintFixpoint.Epoch.initial
      ~shared_models
  in
  assert_bool
    "Call graph is empty!"
    (not (CallGraph.WholeProgramCallGraph.is_empty whole_program_call_graph));
  assert_equal
    ~msg:"Fixpoint iterations"
    expect_iterations
    (TaintFixpoint.get_iterations fixpoint_state)
    ~printer:Int.to_string;
  let get_model = TaintFixpoint.get_model fixpoint_state in
  let get_errors callable =
    TaintFixpoint.get_result fixpoint_state callable |> IssueHandle.SerializableMap.data
  in
  let () =
    List.iter ~f:(check_expectation ~pyre_api ~taint_configuration ~get_model ~get_errors) expect
  in
  let () = TaintFixpoint.cleanup fixpoint_state in
  ()


let test_obscure context =
  assert_fixpoint
    ~context
    ~missing_flows:Configuration.MissingFlowKind.Obscure
    ~handle:"test_obscure.py"
    ~models_source:{|
      def test_obscure.obscure(x): ...
    |}
    {|
      from builtins import _test_source, _test_sink, _user_controlled

      def obscure(x): ...

      def to_obscure_x(x, y):
        obscure(x)

      def to_obscure_y(x, y):
        obscure(y)

      def direct_issue():
        obscure(_test_source())

      def user_controlled():
        return _user_controlled()

      def indirect_issue():
        to_obscure_x(user_controlled(), 0)

      def non_issue():
        to_obscure_y(user_controlled(), 0)
        _test_sink(_test_source())
    |}
    ~expect:
      {
        expect =
          [
            outcome
              ~kind:`Function
              ~parameter_sinks:[{ name = "x"; sinks = [Sinks.NamedSink "Obscure"] }]
              "test_obscure.to_obscure_x";
            outcome
              ~kind:`Function
              ~parameter_sinks:[{ name = "y"; sinks = [Sinks.NamedSink "Obscure"] }]
              "test_obscure.to_obscure_y";
            outcome
              ~kind:`Function
              ~parameter_sinks:[{ name = "x"; sinks = [Sinks.NamedSink "Obscure"] }]
              "test_obscure.obscure";
            outcome
              ~kind:`Function
              ~errors:
                [
                  {
                    code = 9001;
                    pattern =
                      ".*Obscure flow.*Data from \\[Test\\] source(s) may reach an obscure model.*";
                  };
                ]
              "test_obscure.direct_issue";
            outcome
              ~kind:`Function
              ~errors:
                [
                  {
                    code = 9001;
                    pattern =
                      ".*Obscure flow.*Data from \\[UserControlled\\] source(s) may reach an \
                       obscure model.*";
                  };
                ]
              "test_obscure.indirect_issue";
            outcome ~kind:`Function ~errors:[] "test_obscure.non_issue";
          ];
        iterations = 2;
      }


let test_type context =
  assert_fixpoint
    ~context
    ~missing_flows:Configuration.MissingFlowKind.Type
    ~handle:"test_type.py"
    {|
      from builtins import _test_source, _test_sink, _user_controlled

      def to_unknown_callee_x(x, y, f):
        f(x)

      def to_unknown_callee_y(x, y, f):
        f(y)

      def direct_issue(f):
        f(_test_source())

      def user_controlled():
        return _user_controlled()

      def indirect_issue(f):
        to_unknown_callee_x(user_controlled(), 0, f)

      def non_issue(f):
        to_unknown_callee_y(user_controlled(), 0, f)
        _test_sink(_test_source())
    |}
    ~expect:
      {
        expect =
          [
            outcome
              ~kind:`Function
              ~parameter_sinks:[{ name = "x"; sinks = [Sinks.NamedSink "UnknownCallee"] }]
              "test_type.to_unknown_callee_x";
            outcome
              ~kind:`Function
              ~parameter_sinks:[{ name = "y"; sinks = [Sinks.NamedSink "UnknownCallee"] }]
              "test_type.to_unknown_callee_y";
            outcome
              ~kind:`Function
              ~errors:
                [
                  {
                    code = 9002;
                    pattern =
                      ".*Unknown callee flow.*Data from \\[Test\\] source(s) may flow to an \
                       unknown callee.*";
                  };
                ]
              "test_type.direct_issue";
            outcome
              ~kind:`Function
              ~errors:
                [
                  {
                    code = 9002;
                    pattern =
                      ".*Unknown callee flow.*Data from \\[UserControlled\\] source(s) may flow to \
                       an unknown callee.*";
                  };
                ]
              "test_type.indirect_issue";
            outcome ~kind:`Function ~errors:[] "test_type.non_issue";
          ];
        iterations = 2;
      }


let () = "missingFlows" >::: ["obscure" >:: test_obscure; "type" >:: test_type] |> Test.run
