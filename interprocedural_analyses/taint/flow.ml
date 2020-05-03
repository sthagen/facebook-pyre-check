(* Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Configuration
open Domains

type flow = {
  source_taint: ForwardTaint.t;
  sink_taint: BackwardTaint.t;
}
[@@deriving show]

type flows = flow list [@@deriving show]

type candidate = {
  flows: flows;
  location: Location.WithModule.t;
}

type partitioned_flow = {
  source_partition: (Sources.t, ForwardTaint.t) Map.Poly.t;
  sink_partition: (Sinks.t, BackwardTaint.t) Map.Poly.t;
}

type issue = {
  code: int;
  flow: flow;
  features: Features.SimpleSet.t;
  issue_location: Location.WithModule.t;
  define: Statement.Define.t Node.t;
}

type triggered_sinks = String.Hash_set.t

(* Compute all flows from paths in ~source tree to corresponding paths in ~sink tree, while avoiding
   duplication as much as possible.

   Strategy:

   Let F and B for forward and backward taint respectively. For each path p in B from the root to
   some node with non-empty taint T, we match T with the join of taint in the upward and downward
   closure from node at path p in F. *)
let generate_source_sink_matches ~location ~source_tree ~sink_tree =
  let make_source_sink_matches { BackwardState.Tree.path; tip = sink_taint; _ } matches =
    let source_taint = ForwardState.Tree.collapse (ForwardState.Tree.read path source_tree) in
    if ForwardTaint.is_bottom source_taint then
      matches
    else
      { source_taint; sink_taint } :: matches
  in
  let flows =
    if ForwardState.Tree.is_empty source_tree then
      []
    else
      BackwardState.Tree.fold
        BackwardState.Tree.RawPath
        ~init:[]
        ~f:make_source_sink_matches
        sink_tree
  in
  { location; flows }


type flow_state = {
  matched: flows;
  rest: flows;
}

let get_issue_features { source_taint; sink_taint } =
  let source_features =
    ForwardTaint.fold
      Features.SimpleSet.Self
      ~f:Features.SimpleSet.join
      ~init:Features.SimpleSet.bottom
      source_taint
  in
  let sink_features =
    BackwardTaint.fold
      Features.SimpleSet.Self
      ~f:Features.SimpleSet.join
      ~init:Features.SimpleSet.bottom
      sink_taint
  in
  Features.SimpleSet.sequence_join source_features sink_features


let generate_issues ~define { location; flows } =
  let partitions =
    let partition { source_taint; sink_taint } =
      {
        source_partition =
          ForwardTaint.partition ForwardTaint.leaf source_taint ~f:(fun leaf -> Some leaf);
        sink_partition =
          BackwardTaint.partition BackwardTaint.leaf sink_taint ~f:(fun leaf -> Some leaf);
      }
    in
    List.map flows ~f:partition
  in
  let apply_rule { Rule.sources; sinks; code; _ } =
    let get_source_taint { source_partition; _ } =
      let add_source_taint source_taint source =
        match Map.Poly.find source_partition source with
        | Some taint -> ForwardTaint.join source_taint taint
        | None -> source_taint
      in
      List.fold sources ~f:add_source_taint ~init:ForwardTaint.bottom
    in
    let get_sink_taint { sink_partition; _ } =
      let add_sink_taint sink_taint sink =
        match Map.Poly.find sink_partition sink with
        | Some taint -> BackwardTaint.join sink_taint taint
        | None -> sink_taint
      in
      List.fold sinks ~f:add_sink_taint ~init:BackwardTaint.bottom
    in
    let fold_source_taint taint partition = ForwardTaint.join taint (get_source_taint partition) in
    let fold_sink_taint taint partition = BackwardTaint.join taint (get_sink_taint partition) in
    let flow =
      {
        source_taint = List.fold partitions ~init:ForwardTaint.bottom ~f:fold_source_taint;
        sink_taint = List.fold partitions ~init:BackwardTaint.bottom ~f:fold_sink_taint;
      }
    in
    if ForwardTaint.is_bottom flow.source_taint || BackwardTaint.is_bottom flow.sink_taint then
      None
    else
      let features = get_issue_features flow in
      let issue = { code; flow; features; issue_location = location; define } in
      Some issue
  in
  let configuration = Configuration.get () in
  List.filter_map ~f:apply_rule configuration.rules


let sinks_regexp = Str.regexp_string "{$sinks}"

let sources_regexp = Str.regexp_string "{$sources}"

let get_name_and_detailed_message { code; flow; _ } =
  let configuration = Configuration.get () in
  match List.find ~f:(fun { code = rule_code; _ } -> code = rule_code) configuration.rules with
  | None -> failwith "issue with code that has no rule"
  | Some { name; message_format; _ } ->
      let sources =
        Domains.ForwardTaint.leaves flow.source_taint
        |> List.map ~f:Sources.show
        |> String.concat ~sep:", "
      in
      let sinks =
        Domains.BackwardTaint.leaves flow.sink_taint
        |> List.map ~f:Sinks.show
        |> String.concat ~sep:", "
      in
      let message =
        Str.global_replace sources_regexp sources message_format
        |> Str.global_replace sinks_regexp sinks
      in
      name, message


let generate_error ({ code; issue_location; define; _ } as issue) =
  let configuration = Configuration.get () in
  match List.find ~f:(fun { code = rule_code; _ } -> code = rule_code) configuration.rules with
  | None -> failwith "issue with code that has no rule"
  | Some _ ->
      let name, detail = get_name_and_detailed_message issue in
      let kind = { Interprocedural.Error.name; messages = [detail]; code } in
      Interprocedural.Error.create ~location:issue_location ~define ~kind


let to_json ~filename_lookup callable issue =
  let callable_name = Interprocedural.Callable.external_target_name callable in
  let _, detail = get_name_and_detailed_message issue in
  let message = detail in
  let source_traces =
    Domains.ForwardTaint.to_external_json ~filename_lookup issue.flow.source_taint
  in
  let sink_traces = Domains.BackwardTaint.to_external_json ~filename_lookup issue.flow.sink_taint in
  let features =
    let get_feature_json { Abstract.OverUnderSetDomain.element; in_under } breadcrumbs =
      let open Features.Simple in
      match element with
      | Breadcrumb breadcrumb ->
          let breadcrumb_json = Features.Breadcrumb.to_json breadcrumb ~on_all_paths:in_under in
          breadcrumb_json :: breadcrumbs
      | _ -> breadcrumbs
    in
    Features.SimpleSet.fold
      Features.SimpleSet.ElementAndUnder
      ~f:get_feature_json
      ~init:[]
      issue.features
  in
  let traces =
    `List
      [
        `Assoc ["name", `String "forward"; "roots", source_traces];
        `Assoc ["name", `String "backward"; "roots", sink_traces];
      ]
  in
  let {
    Location.WithPath.path;
    start = { line; column = start_column };
    stop = { column = stop_column; _ };
  }
    =
    Location.WithModule.instantiate ~lookup:filename_lookup issue.issue_location
  in
  let callable_line = Ast.(Location.line issue.define.location) in
  `Assoc
    [
      "callable", `String callable_name;
      "callable_line", `Int callable_line;
      "code", `Int issue.code;
      "line", `Int line;
      "start", `Int start_column;
      "end", `Int stop_column;
      "filename", `String path;
      "message", `String message;
      "traces", traces;
      "features", `List features;
    ]


let code_metadata () =
  let configuration = Configuration.get () in
  `Assoc
    (List.map configuration.rules ~f:(fun rule -> Format.sprintf "%d" rule.code, `String rule.name))


let compute_triggered_sinks ~triggered_sinks ~location ~source_tree ~sink_tree =
  let partial_sinks_to_taint =
    BackwardState.Tree.collapse sink_tree
    |> BackwardTaint.partition BackwardTaint.leaf ~f:(function
           | Sinks.PartialSink { Sinks.kind; label } -> Some { Sinks.kind; label }
           | _ -> None)
  in
  if not (Map.Poly.is_empty partial_sinks_to_taint) then
    let sources =
      source_tree
      |> ForwardState.Tree.partition ForwardTaint.leaf ~f:(fun source -> Some source)
      |> Map.Poly.keys
    in
    let add_triggered_sinks (triggered, candidates) sink =
      let add_triggered_sinks_for_source source =
        Configuration.get_triggered_sink ~partial_sink:sink ~source
        |> function
        | Some (Sinks.TriggeredPartialSink triggered_sink) ->
            if Hash_set.mem triggered_sinks (Sinks.show_partial_sink sink) then
              (* We have both pairs, let's check the flow directly for this sink being triggered. *)
              let candidate =
                generate_source_sink_matches
                  ~location
                  ~source_tree
                  ~sink_tree:
                    (BackwardState.Tree.create_leaf
                       (BackwardTaint.singleton ~location (Sinks.TriggeredPartialSink sink)))
              in
              None, Some candidate
            else
              Some triggered_sink, None
        | _ -> None, None
      in
      let new_triggered, new_candidates =
        List.map sources ~f:add_triggered_sinks_for_source
        |> List.unzip
        |> fun (triggered_sinks, candidates) ->
        List.filter_opt triggered_sinks, List.filter_opt candidates
      in
      List.rev_append new_triggered triggered, List.rev_append new_candidates candidates
    in
    partial_sinks_to_taint |> Core.Map.Poly.keys |> List.fold ~f:add_triggered_sinks ~init:([], [])
  else
    [], []
