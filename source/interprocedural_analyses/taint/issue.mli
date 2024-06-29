(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
open Statement
open Domains
open Interprocedural

module Flow : sig
  type t = {
    source_taint: ForwardTaint.t;
    sink_taint: BackwardTaint.t;
  }
  [@@deriving show]

  val bottom : t

  val is_bottom : t -> bool

  val join : t -> t -> t
end

module LocationSet : Stdlib.Set.S with type elt = Location.WithModule.t

type t = {
  flow: Flow.t;
  handle: IssueHandle.t;
  locations: LocationSet.t;
  (* Only used to create the Pyre errors. *)
  define: Ast.Statement.Define.t Ast.Node.t;
}

val canonical_location : t -> Location.WithModule.t

val to_json
  :  taint_configuration:TaintConfiguration.Heap.t ->
  expand_overrides:OverrideGraph.SharedMemory.ReadOnly.t option ->
  is_valid_callee:
    (trace_kind:TraceKind.t option ->
    port:AccessPath.Root.t ->
    path:AccessPath.Path.t ->
    callee:Target.t ->
    bool) ->
  resolve_module_path:(Reference.t -> RepositoryPath.t option) ->
  t ->
  Yojson.Safe.t

val to_error : taint_configuration:TaintConfiguration.Heap.t -> t -> Error.t

(* A map from triggered sink kinds (which is a string) to their triggers. A triggered sink here
   means we found one source, and must find the other source, in order to file an issue for a
   multi-source. This map is created for each call site. *)
module TriggeredSinkForCall : sig
  type t

  val create : unit -> t

  val is_empty : t -> bool

  (* Turn the given partial sink into a triggered sink taint at certain location, based on what has
     triggered this partial sink. *)
  val create_triggered_sink_taint
    :  argument_location:Location.t ->
    call_info:CallInfo.t ->
    partial_sink:Sinks.PartialSink.t ->
    t ->
    BackwardTaint.t
end

(* A map from expressions to the triggered sinks that need to be propagated up in the backward
   analysis, because one of the partial sinks was fulfilled. This map is created during the forward
   analysis of a callable using `TriggeredSinkForCall` and is passed to the backward analysis. *)
module TriggeredSinkForBackward : sig
  type t

  val create : unit -> t

  val add : expression:Ast.Expression.t -> taint_tree:BackwardState.Tree.t -> t -> unit

  val get : expression:Ast.Expression.t -> t -> BackwardState.Tree.t
end

(* Accumulate flows and generate issues. *)
module Candidates : sig
  type issue = t

  type t

  val create : unit -> t

  (* Check for issues in flows from the `source_tree` to the `sink_tree`, updating
   * issue `candidates`. *)
  val check_flow
    :  t ->
    location:Location.WithModule.t ->
    sink_handle:IssueHandle.Sink.t ->
    source_tree:ForwardState.Tree.t ->
    sink_tree:BackwardState.Tree.t ->
    unit

  (* Check for issues for combined source rules.
   * For flows where both sources are present, this adds the flow to issue `candidates`.
   * If only one source is present, this creates a triggered sink in `triggered_sinks_for_call`.
   *)
  val check_triggered_flows
    :  t ->
    pyre_in_context:PyrePysaApi.InContext.t ->
    taint_configuration:TaintConfiguration.Heap.t ->
    triggered_sinks_for_call:TriggeredSinkForCall.t ->
    location:Location.WithModule.t ->
    sink_handle:IssueHandle.Sink.t ->
    source_tree:ForwardState.Tree.t ->
    sink_tree:BackwardState.Tree.t ->
    callee:Target.t ->
    port:AccessPath.Root.t ->
    unit

  val generate_issues
    :  t ->
    taint_configuration:TaintConfiguration.Heap.t ->
    define:Define.t Node.t ->
    issue IssueHandle.SerializableMap.t
end
