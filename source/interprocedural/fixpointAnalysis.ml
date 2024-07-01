(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* FixpointAnalysis: implements a generic global fixpoint analysis, which infers
 * a set of invariants across a source code.
 *
 * This is mainly used by the taint analysis, but could be used for any
 * interprocedural analysis (e.g, type inference, correctness analysis, etc..).
 *
 * A model describes the invariants of a function or method, and must have an
 * abstract domain structure (join, widening, less or equal, etc..).
 *
 * Given a set of initial models, this performs iterations to propagate invariants
 * across functions, until reaching a fixpoint (i.e, invariants are stables).
 *)

open Core
open Ast
open Pyre
open Statement
module PyrePysaApi = Analysis.PyrePysaApi

(** Represents the set of information that must be propagated from callees to callers during an
    interprocedural analysis, within the global fixpoint. Each iteration should produce a model for
    each callable (function, method). This must have an abstract domain structure (e.g, join, widen,
    less_or_equal, etc.) *)
module type MODEL = sig
  type t [@@deriving show]

  val join : iteration:int -> t -> t -> t

  val widen : iteration:int -> callable:Target.t -> previous:t -> next:t -> t

  val less_or_equal : callable:Target.t -> left:t -> right:t -> bool

  (** Transform the model before joining into the override model. *)
  val for_override_model : callable:Target.t -> t -> t
end

(** Represents the result of the analysis.

    Each iteration should produce results for each callable (function, method). Results from the
    previous iterations are discarded. This is usually used for a set of errors. In the taint
    analysis, this represents valid issues. *)
module type RESULT = sig
  type t

  val empty : t
end

type expensive_callable = {
  time_to_analyze_in_ms: int;
  callable: Target.t;
}

module type LOGGER = sig
  val initial_models_stored : timer:Timer.t -> unit

  val reached_maximum_iteration_exception
    :  iteration:int ->
    callables_to_analyze:Target.t list ->
    exn

  (** This is called at the beginning of each iteration. *)
  val iteration_start
    :  iteration:int ->
    callables_to_analyze:Target.t list ->
    number_of_callables:int ->
    unit

  (** This is called at the end of each iteration. *)
  val iteration_end
    :  iteration:int ->
    expensive_callables:expensive_callable list ->
    number_of_callables:int ->
    timer:Timer.t ->
    unit

  (** This is called after a worker makes progress on an iteration. *)
  val iteration_progress
    :  iteration:int ->
    callables_processed:int ->
    number_of_callables:int ->
    unit

  val is_expensive_callable : callable:Target.t -> timer:Timer.t -> bool

  (** This is called after analyzing an override target (i.e, joining models of overriding methods). *)
  val override_analysis_end : callable:Target.t -> timer:Timer.t -> unit

  val on_analyze_define_exception : iteration:int -> callable:Target.t -> exn:exn -> unit

  val on_approaching_max_iterations
    :  max_iterations:int ->
    current_iteration:int ->
    ('a, Format.formatter, unit, unit, unit, unit) format6 ->
    'a
end

(** Must be implemented to compute a global fixpoint. *)
module type ANALYSIS = sig
  (** Passed down from the top level call to the `analyze_define` function. This should be cheap to
      marshal, since it will be sent to multiple workers. *)
  type context

  module Model : MODEL

  module Result : RESULT

  module Logger : LOGGER

  val initial_model : Model.t

  val empty_model : Model.t

  (** Model for obscure callables (usually, stubs) *)
  val obscure_model : Model.t

  (** Analyze a function or method definition.

      `get_callee_model` can be used to get the model of a callee, as long as it is registered in
      the call graph. *)
  val analyze_define
    :  context:context ->
    qualifier:Reference.t ->
    callable:Target.t ->
    define:Define.t Node.t ->
    previous_model:Model.t ->
    get_callee_model:(Target.t -> Model.t option) ->
    Result.t * Model.t
end

module Make (Analysis : ANALYSIS) = struct
  module Model = Analysis.Model
  module Result = Analysis.Result
  module Logger = Analysis.Logger

  (** Represents a mapping from target to models, living in the ocaml heap. *)
  module Registry = struct
    type t = Model.t Target.Map.t

    let empty = Target.Map.empty

    let is_empty = Target.Map.is_empty

    let singleton ~target ~model = Target.Map.singleton target model

    let size registry = Target.Map.cardinal registry

    let set registry ~target ~model = Target.Map.add target model registry

    let add ~join registry ~target ~model =
      Target.Map.update
        target
        (function
          | None -> Some model
          | Some existing -> Some (join existing model))
        registry


    let get target registry = Target.Map.find_opt registry target

    let merge ~join left right =
      Target.Map.union (fun _ left right -> Some (join left right)) left right


    let of_alist ~join = Target.Map.of_alist ~f:join

    let to_alist registry = Target.Map.to_alist registry

    let iteri registry ~f = Target.Map.iter (fun key data -> f ~target:key ~model:data) registry

    let map registry ~f = Target.Map.map f registry

    let targets registry = Target.Map.keys registry

    let object_targets registry =
      let add target _ so_far =
        match target with
        | Target.Object _ -> Target.Set.add target so_far
        | _ -> so_far
      in
      Target.Map.fold add registry Target.Set.empty


    let fold ~init ~f map =
      Target.Map.fold (fun key data so_far -> f ~target:key ~model:data so_far) map init
  end

  module Epoch = struct
    type t = int [@@deriving show]

    let predefined = 0

    let initial = 1
  end

  type step = {
    epoch: Epoch.t;
    iteration: int;
  }

  (* The fixpoint state, stored in shared memory. *)
  module State = struct
    module SharedModels = struct
      module FirstClass =
        Hack_parallel.Std.SharedMemory.FirstClass.WithCache.Make
          (Target.SharedMemoryKey)
          (struct
            type t = Model.t

            let prefix = Hack_parallel.Std.Prefix.make ()

            let description = "InterproceduralFixpointModel"
          end)

      include FirstClass
    end

    module SharedResults =
      Memory.WithCache.Make
        (Target.SharedMemoryKey)
        (struct
          type t = Result.t

          let prefix = Hack_parallel.Std.Prefix.make ()

          let description = "InterproceduralFixpointResults"
        end)

    type meta_data = {
      is_partial: bool;
      step: step;
    }

    (* Caches the fixpoint state (is_partial) of a call model. *)
    module SharedFixpoint =
      Memory.WithCache.Make
        (Target.SharedMemoryKey)
        (struct
          type t = meta_data

          let prefix = Hack_parallel.Std.Prefix.make ()

          let description = "InterproceduralFixpointMetadata"
        end)

    module KeySet = SharedModels.KeySet

    (* Store all targets in order to clean-up the shared memory afterward. *)
    module SharedTargets =
      Memory.NoCache.Make
        (Memory.SingletonKey)
        (struct
          type t = KeySet.t

          let prefix = Hack_parallel.Std.Prefix.make ()

          let description = "InterproceduralFixpointTarget"
        end)

    let get_new_model shared_models_handle callable = SharedModels.get shared_models_handle callable

    let get_old_model shared_models_handle callable =
      SharedModels.get_old shared_models_handle callable


    let get_model shared_models_handle callable =
      match get_new_model shared_models_handle callable with
      | Some _ as model -> model
      | None -> get_old_model shared_models_handle callable


    let get_result callable = SharedResults.get callable |> Option.value ~default:Result.empty

    let set_result callable result =
      SharedResults.remove_batch (KeySet.singleton callable);
      SharedResults.add callable result


    let get_is_partial callable =
      match SharedFixpoint.get callable with
      | Some { is_partial; _ } -> is_partial
      | None -> (
          match SharedFixpoint.get_old callable with
          | None -> true
          | Some { is_partial; _ } -> is_partial)


    let get_meta_data callable =
      match SharedFixpoint.get callable with
      | Some _ as meta_data -> meta_data
      | None -> SharedFixpoint.get_old callable


    let meta_data_to_string { is_partial; step = { epoch; iteration } } =
      Format.sprintf "{ partial: %b; epoch: %d; iteration: %d }" is_partial epoch iteration


    type t = {
      (* Whether to reanalyze this and its callers. *)
      is_partial: bool;
      (* Model to use at call sites. *)
      model: Model.t;
      (* The result of the analysis. *)
      result: Result.t;
    }

    let add ~shared_models_handle step callable state =
      (* Separate diagnostics from state to speed up lookups, and cache fixpoint state
         separately. *)
      let () = SharedModels.add shared_models_handle callable state.model in
      (* Skip result writing unless necessary (e.g. overrides don't have results) *)
      let () =
        match callable with
        | Target.Function _
        | Target.Method _ ->
            SharedResults.add callable state.result
        | _ -> ()
      in
      SharedFixpoint.add callable { is_partial = state.is_partial; step }


    let add_predefined epoch callable =
      let step = { epoch; iteration = 0 } in
      SharedFixpoint.add callable { is_partial = false; step }


    let oldify shared_models_handle callable_set =
      SharedModels.oldify_batch shared_models_handle callable_set;
      SharedFixpoint.oldify_batch callable_set;

      (* Old results are never looked up, so remove them. *)
      SharedResults.remove_batch callable_set


    let remove_old shared_models_handle callable_set =
      SharedModels.remove_old_batch shared_models_handle callable_set;
      SharedFixpoint.remove_old_batch callable_set


    let set_targets targets =
      let () =
        SharedTargets.remove_batch (SharedTargets.KeySet.singleton Memory.SingletonKey.key)
      in
      SharedTargets.add Memory.SingletonKey.key targets


    let targets () = SharedTargets.get Memory.SingletonKey.key |> Option.value ~default:KeySet.empty

    let clear_results () =
      let targets = targets () in
      SharedResults.remove_batch targets


    (** Remove the fixpoint state from the shared memory. This must be called before computing
        another fixpoint. *)
    let cleanup shared_models_handle =
      let targets = targets () in
      let () = SharedModels.remove_batch shared_models_handle targets in
      let () = SharedModels.remove_old_batch shared_models_handle targets in
      let () = SharedResults.remove_batch targets in
      let () = SharedFixpoint.remove_batch targets in
      let () = SharedFixpoint.remove_old_batch targets in
      ()
  end

  type shared_models = State.SharedModels.t

  (* Save initial models in the shared memory. *)
  let record_initial_models ~scheduler ~initial_models ~initial_callables ~stubs ~override_targets =
    let timer = Timer.start () in
    let record_models models =
      let shared_models = State.SharedModels.create () in
      State.set_targets (models |> Registry.targets |> State.KeySet.of_list);
      let map models =
        let add_model (target, model) =
          State.add_predefined Epoch.initial target;
          State.SharedModels.add shared_models target model
        in
        List.iter models ~f:add_model
      in
      let policy =
        Scheduler.Policy.fixed_chunk_size
          ~minimum_chunks_per_worker:1
          ~minimum_chunk_size:1
          ~preferred_chunk_size:1000
          ()
      in
      let () =
        Scheduler.map_reduce
          scheduler
          ~policy
          ~initial:()
          ~map
          ~reduce:(fun () () -> ())
          ~inputs:(Registry.to_alist models)
          ()
      in
      shared_models
    in
    (* Augment models with initial inferred and obscure models *)
    let add_missing_initial_models models =
      initial_callables
      |> List.filter ~f:(fun target -> not (Target.Map.mem target models))
      |> List.fold ~init:models ~f:(fun models target ->
             Registry.set models ~target ~model:Analysis.initial_model)
    in
    let add_missing_obscure_models models =
      stubs
      |> List.filter ~f:(fun target -> not (Target.Map.mem target models))
      |> List.fold ~init:models ~f:(fun models target ->
             Registry.set models ~target ~model:Analysis.obscure_model)
    in
    let add_override_models models =
      List.fold
        ~init:models
        ~f:(fun models target -> Registry.set models ~target ~model:Analysis.empty_model)
        override_targets
    in
    let shared_models_handle =
      initial_models
      |> add_missing_initial_models
      |> add_missing_obscure_models
      |> add_override_models
      |> record_models
    in
    Logger.initial_models_stored ~timer;
    shared_models_handle


  let widen_if_necessary ~step ~callable ~previous_model ~new_model ~result =
    (* Check if we've reached a fixed point *)
    if Model.less_or_equal ~callable ~left:new_model ~right:previous_model then
      State.{ is_partial = false; model = previous_model; result }
    else
      let model =
        Model.widen ~iteration:step.iteration ~callable ~previous:previous_model ~next:new_model
      in
      State.{ is_partial = true; model; result }


  let analyze_define
      ~shared_models_handle
      ~context
      ~step:({ iteration; _ } as step)
      ~callable
      ~qualifier
      ~define
    =
    let previous_model =
      match State.get_old_model shared_models_handle callable with
      | Some model -> model
      | None ->
          (* We need to ensure the all models are properly initialized before doing the global
             fixpoint analysis. That is, if the global fixpoint analysis discovers any model is not
             initialized, then it is better to be warned that something is wrong with the model
             initialization. *)
          Format.asprintf "No initial model found for `%a`" Target.pp_pretty callable |> failwith
    in
    let result, new_model =
      try
        Analysis.analyze_define
          ~context
          ~qualifier
          ~callable
          ~define
          ~previous_model
          ~get_callee_model:(State.get_model shared_models_handle)
      with
      | exn ->
          let wrapped_exn = Exception.wrap exn in
          let () = Logger.on_analyze_define_exception ~iteration ~callable ~exn in
          Exception.reraise wrapped_exn
    in
    widen_if_necessary ~step ~callable ~previous_model ~new_model ~result


  let analyze_overrides
      ~max_iterations
      ~shared_models_handle
      ~override_graph
      ~step:({ iteration; _ } as step)
      ~callable
    =
    let timer = Timer.start () in
    let overrides =
      OverrideGraph.SharedMemory.ReadOnly.get_overriding_types
        override_graph
        ~member:(Target.get_corresponding_method callable)
      |> Option.value ~default:[]
      |> List.map ~f:(fun at_type -> Target.create_derived_override callable ~at_type)
    in
    let new_model =
      let lookup override =
        let () =
          Logger.on_approaching_max_iterations
            ~max_iterations
            ~current_iteration:iteration
            "Finding model of overriding callable %a (whose base is %a)"
            Target.pp_pretty
            override
            Target.pp_pretty
            callable
        in
        match State.get_model shared_models_handle override with
        | None ->
            Format.asprintf
              "During override analysis, can't find model for %a when analyzing %a"
              Target.pp_pretty
              override
              Target.pp_pretty
              callable
            |> failwith
        | Some model -> model
      in
      let direct_model =
        let direct_callable = Target.get_corresponding_method callable in
        State.get_model shared_models_handle direct_callable
        |> Option.value ~default:Analysis.empty_model
        |> Model.for_override_model ~callable:direct_callable
      in
      overrides
      |> List.map ~f:lookup
      |> Algorithms.fold_balanced ~f:(Model.join ~iteration) ~init:direct_model
    in
    let previous_model =
      match State.get_old_model shared_models_handle callable with
      | Some model -> model
      | None ->
          Format.asprintf "No initial model found for `%a`" Target.pp_pretty callable |> failwith
    in
    let state =
      widen_if_necessary ~step ~callable ~previous_model ~new_model ~result:Result.empty
    in
    let () = Logger.override_analysis_end ~callable ~timer in
    state


  let analyze_callable ~max_iterations ~pyre_api ~override_graph ~context ~step ~callable =
    let () =
      (* Verify invariants *)
      match State.get_meta_data callable with
      | None -> ()
      | Some { step = { epoch; _ }; _ } when epoch <> step.epoch ->
          Format.asprintf
            "Fixpoint inconsistency: callable %a analyzed during epoch %a, but stored metadata \
             from epoch %a"
            Target.pp_pretty
            callable
            Epoch.pp
            step.epoch
            Epoch.pp
            epoch
          |> failwith
      | _ -> ()
    in
    match callable with
    | (Target.Function _ | Target.Method _) as callable -> (
        match Target.get_module_and_definition callable ~pyre_api with
        | None ->
            Format.asprintf "Found no definition for `%a`" Target.pp_pretty callable |> failwith
        | Some (qualifier, define) -> analyze_define ~context ~step ~callable ~qualifier ~define)
    | Target.Override _ as callable ->
        analyze_overrides ~max_iterations ~override_graph ~step ~callable
    | Target.Object _ as target ->
        Format.asprintf "Found object `%a` in fixpoint analysis" Target.pp_pretty target |> failwith


  type iteration_result = {
    callables_processed: int;
    expensive_callables: expensive_callable list;
  }

  (* Called on a worker with a set of targets to analyze. *)
  let one_analysis_pass
      ~max_iterations
      ~shared_models_handle
      ~pyre_api
      ~override_graph
      ~context
      ~step:({ iteration; _ } as step)
      ~callables
    =
    let analyze_target expensive_callables callable =
      let timer = Timer.start () in
      let result =
        analyze_callable
          ~max_iterations
          ~shared_models_handle
          ~pyre_api
          ~override_graph
          ~context
          ~step
          ~callable
      in
      let () =
        Logger.on_approaching_max_iterations
          ~max_iterations
          ~current_iteration:iteration
          "New model of %a: %a"
          Target.pp_pretty
          callable
          Model.pp
          result.State.model
      in
      State.add ~shared_models_handle step callable result;
      (* Log outliers. *)
      if Logger.is_expensive_callable ~callable ~timer then
        { time_to_analyze_in_ms = Timer.stop_in_ms timer; callable } :: expensive_callables
      else
        expensive_callables
    in
    let expensive_callables = List.fold callables ~f:analyze_target ~init:[] in
    { callables_processed = List.length callables; expensive_callables }


  let compute_callables_to_reanalyze ~dependency_graph ~all_callables ~previous_callables ~step =
    let might_change_if_reanalyzed =
      List.fold previous_callables ~init:Target.Set.empty ~f:(fun accumulator callable ->
          if not (State.get_is_partial callable) then
            accumulator
          else
            (* callable must be re-analyzed next iteration because its result has changed, and
               therefore its callers must also be reanalyzed. *)
            let callers = DependencyGraph.dependencies dependency_graph callable in
            List.fold
              callers
              ~init:(Target.Set.add callable accumulator)
              ~f:(fun accumulator caller -> Target.Set.add caller accumulator))
    in
    (* Filter the original list in order to preserve topological sort order. *)
    let callables_to_reanalyze =
      List.filter all_callables ~f:(fun callable ->
          Target.Set.mem callable might_change_if_reanalyzed)
    in
    let () =
      if List.length callables_to_reanalyze <> Target.Set.cardinal might_change_if_reanalyzed then
        let missing =
          Target.Set.diff might_change_if_reanalyzed (Target.Set.of_list callables_to_reanalyze)
        in
        let check_missing callable =
          match State.get_meta_data callable with
          | None -> () (* okay, caller is in a later epoch *)
          | Some { step = { epoch; _ }; _ } when epoch = Epoch.predefined -> ()
          | Some meta ->
              let message =
                Format.asprintf
                  "Re-analysis in iteration %d determined to analyze %a but it is not part of \
                   epoch %a (meta: %s)"
                  step.iteration
                  Target.pp_pretty
                  callable
                  Epoch.pp
                  step.epoch
                  (State.meta_data_to_string meta)
              in
              Log.error "%s" message;
              failwith message
        in
        Target.Set.iter check_missing missing
    in
    callables_to_reanalyze


  type t = {
    fixpoint_reached_iterations: int;
    shared_models_handle: State.SharedModels.t;
  }

  let compute
      ~scheduler
      ~scheduler_policy
      ~pyre_api
      ~override_graph
      ~dependency_graph
      ~context
      ~callables_to_analyze:initial_callables_to_analyze
      ~max_iterations
      ~epoch
      ~shared_models:shared_models_handle
    =
    let rec iterate ~iteration callables_to_analyze =
      let number_of_callables = List.length callables_to_analyze in
      if number_of_callables = 0 then (* Fixpoint. *)
        iteration
      else if iteration >= max_iterations then
        raise (Logger.reached_maximum_iteration_exception ~iteration ~callables_to_analyze)
      else
        let () = Logger.iteration_start ~iteration ~callables_to_analyze ~number_of_callables in
        let timer = Timer.start () in
        let step = { epoch; iteration } in
        let old_batch = State.KeySet.of_list callables_to_analyze in
        let () = State.oldify shared_models_handle old_batch in
        let map callables =
          one_analysis_pass
            ~max_iterations
            ~shared_models_handle
            ~pyre_api
            ~override_graph
            ~context
            ~step
            ~callables
        in
        let reduce left right =
          let callables_processed = left.callables_processed + right.callables_processed in
          let () = Logger.iteration_progress ~iteration ~callables_processed ~number_of_callables in
          {
            callables_processed;
            expensive_callables = List.rev_append left.expensive_callables right.expensive_callables;
          }
        in
        let { expensive_callables; _ } =
          Scheduler.map_reduce
            scheduler
            ~policy:scheduler_policy
            ~initial:{ callables_processed = 0; expensive_callables = [] }
            ~map
            ~reduce
            ~inputs:callables_to_analyze
            ()
        in
        let () = State.remove_old shared_models_handle old_batch in
        let callables_to_analyze =
          compute_callables_to_reanalyze
            ~dependency_graph
            ~all_callables:initial_callables_to_analyze
            ~previous_callables:callables_to_analyze
            ~step
        in
        let () = Logger.iteration_end ~iteration ~expensive_callables ~number_of_callables ~timer in
        iterate ~iteration:(iteration + 1) callables_to_analyze
    in
    let iterations = iterate ~iteration:0 initial_callables_to_analyze in
    { fixpoint_reached_iterations = iterations; shared_models_handle }


  let get_model { shared_models_handle; _ } target = State.get_model shared_models_handle target

  let get_result _ target = State.get_result target

  let set_result _ target result = State.set_result target result

  let clear_results _ = State.clear_results ()

  let get_iterations { fixpoint_reached_iterations; _ } = fixpoint_reached_iterations

  let cleanup { shared_models_handle; _ } = State.cleanup shared_models_handle
end

module WithoutLogging = struct
  let initial_models_stored ~timer:_ = ()

  let reached_maximum_iteration_exception ~iteration ~callables_to_analyze:_ =
    Format.asprintf "Failed to reach a fixpoint after %d iterations" iteration |> failwith


  let iteration_start ~iteration:_ ~callables_to_analyze:_ ~number_of_callables:_ = ()

  let iteration_end ~iteration:_ ~expensive_callables:_ ~number_of_callables:_ ~timer:_ = ()

  let iteration_progress ~iteration:_ ~callables_processed:_ ~number_of_callables:_ = ()

  let is_expensive_callable ~callable:_ ~timer:_ = false

  let override_analysis_end ~callable:_ ~timer:_ = ()

  let on_analyze_define_exception ~iteration:_ ~callable:_ ~exn:_ = ()

  let on_approaching_max_iterations ~max_iterations:_ ~current_iteration:_ =
    Format.ifprintf Format.err_formatter
end

module WithLogging (Config : sig
  val expensive_callable_ms : int
end) =
struct
  let initial_models_stored ~timer =
    Statistics.performance
      ~name:"Recorded initial models"
      ~phase_name:"Recording initial models"
      ~timer
      ()


  let reached_maximum_iteration_exception ~iteration ~callables_to_analyze =
    let max_to_show = 15 in
    let bucket =
      callables_to_analyze |> List.map ~f:Target.show_pretty |> List.sort ~compare:String.compare
    in
    let bucket_len = List.length bucket in
    Format.sprintf
      "Failed to reach a fixpoint after %d iterations (%d callables: %s%s)"
      iteration
      (List.length callables_to_analyze)
      (String.concat ~sep:", " (List.take bucket max_to_show))
      (if bucket_len > max_to_show then "..." else "")
    |> failwith


  let iteration_start ~iteration ~callables_to_analyze ~number_of_callables =
    let witnesses =
      if number_of_callables <= 6 then
        String.concat ~sep:", " (List.map ~f:Target.show_pretty callables_to_analyze)
      else
        "..."
    in
    Log.info "Iteration #%d. %d callables [%s]" iteration number_of_callables witnesses


  let iteration_end ~iteration ~expensive_callables ~number_of_callables ~timer =
    let () =
      if not (List.is_empty expensive_callables) then
        Log.log
          ~section:`Performance
          "Expensive callables for iteration %d: %s"
          iteration
          (expensive_callables
          |> List.sort ~compare:(fun left right ->
                 Int.compare right.time_to_analyze_in_ms left.time_to_analyze_in_ms)
          |> List.map ~f:(fun { time_to_analyze_in_ms; callable } ->
                 Format.asprintf "`%a`: %d ms" Target.pp_pretty callable time_to_analyze_in_ms)
          |> String.concat ~sep:", ")
    in
    Log.info
      "Iteration #%n, %d callables, heap size %.3fGB took %.2fs"
      iteration
      number_of_callables
      (Int.to_float (Hack_parallel.Std.SharedMemory.heap_size ()) /. 1000000000.0)
      (Timer.stop_in_sec timer)


  let iteration_progress ~iteration:_ ~callables_processed ~number_of_callables =
    Log.log
      ~section:`Progress
      "Processed %d of %d callables"
      callables_processed
      number_of_callables


  let is_expensive_callable ~callable ~timer =
    let time_to_analyze_in_ms = Timer.stop_in_ms timer in
    let () =
      if time_to_analyze_in_ms >= Config.expensive_callable_ms then
        Statistics.performance
          ~name:"static analysis of expensive callable"
          ~timer
          ~section:`Interprocedural
          ~normals:["callable", Target.show_pretty callable]
          ()
    in
    time_to_analyze_in_ms >= Config.expensive_callable_ms


  let override_analysis_end ~callable ~timer =
    Statistics.performance
      ~randomly_log_every:1000
      ~always_log_time_threshold:1.0 (* Seconds *)
      ~name:"Override analysis"
      ~section:`Interprocedural
      ~normals:["callable", Target.show_pretty callable]
      ~timer
      ()


  let on_analyze_define_exception ~iteration ~callable ~exn =
    let message =
      match exn with
      | Stdlib.Sys.Break -> "Hit Ctrl+C"
      | _ -> "Analysis failed"
    in
    let message =
      Format.asprintf
        "%s in iteration %d while analyzing `%a`."
        message
        iteration
        Target.pp_pretty
        callable
    in
    Log.log_exception message exn (Hack_parallel.Std.Worker.exception_backtrace exn)


  let on_approaching_max_iterations ~max_iterations ~current_iteration format =
    if current_iteration >= max_iterations - 5 then
      Log.info format
    else
      Format.ifprintf Format.err_formatter format
end
