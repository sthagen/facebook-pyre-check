(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* ErrorsEnvironment: layer of the environment stack
 * - upstream: TypeEnvironment
 * - downstream: nothing, this is the top layer
 *   - OverlaidEnvironment is built on top of ErrorsEnvironment, but it is
 *     not a layer but rather an abstraction to deal with a root environment
 *     and one or more overlays.
 * - key: qualifier (as a Reference.t)
 * - value: A list of errors for the module
 *
 * This layer is needed for two reasons:
 * - we need to aggregate all of the per-define errors in the TypeEnvironment
 *   so that we can report them out.
 * - we also need a place to handle specific cases that the TypeEnvironment
 *   cannot handle, for example:
 *   - if the parser failed, there are no defines but we need a syntax error.
 *   - we deal with error suppressions at this layer.
 *
 * The actual logic for construting per-module errors from TypeEnvironment
 * errors lives in the Postprocessing module.
 *)

open Ast
open Core
open Pyre
module PreviousEnvironment = TypeEnvironment
module Error = AnalysisError

module QualifierErrorsValue = struct
  type t = Error.t list [@@deriving compare]

  let prefix = Hack_parallel.Std.Prefix.make ()

  let description = "QualifierErrorsValue"

  let equal = Memory.equal_from_compare compare
end

let produce_errors type_environment qualifier ~dependency =
  Postprocessing.run_on_qualifier type_environment ~dependency qualifier


module QualifierErrorsTable = Environment.EnvironmentTable.WithCache (struct
  module PreviousEnvironment = TypeEnvironment
  module Key = SharedMemoryKeys.ReferenceKey
  module Value = QualifierErrorsValue

  type trigger = Reference.t [@@deriving sexp, compare]

  module TriggerSet = Reference.Set

  let convert_trigger = Fn.id

  let key_to_trigger = Fn.id

  let show_key = Reference.show

  let overlay_owns_key source_code_overlay =
    SourceCodeIncrementalApi.Overlay.owns_qualifier source_code_overlay


  let lazy_incremental = false

  let produce_value = produce_errors

  let filter_upstream_dependency = function
    | SharedMemoryKeys.CreateModuleErrors name -> Some name
    | _ -> None


  let trigger_to_dependency name = SharedMemoryKeys.CreateModuleErrors name

  let equal_value = QualifierErrorsValue.equal
end)

include QualifierErrorsTable

module ReadOnly = struct
  include ReadOnly

  let type_environment environment = upstream_environment environment

  let get_untracked_source_code_api environment =
    source_code_read_only environment |> SourceCodeIncrementalApi.ReadOnly.get_untracked_api


  let controls environment = type_environment environment |> TypeEnvironment.ReadOnly.controls

  let get_errors_for_qualifier environment qualifier = get environment qualifier

  let get_errors_for_qualifiers environment qualifiers =
    List.concat_map qualifiers ~f:(get_errors_for_qualifier environment)
end

module AssumeDownstreamNeverNeedsUpdates = struct
  let upstream = AssumeDownstreamNeverNeedsUpdates.upstream

  let type_environment = upstream

  let class_metadata_environment environment =
    type_environment environment
    |> TypeEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> AnnotatedGlobalEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> FunctionDefinitionEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> AttributeResolution.AssumeDownstreamNeverNeedsUpdates.upstream


  let unannotated_global_environment environment =
    class_metadata_environment environment
    |> ClassSuccessorMetadataEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> ClassHierarchyEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> TypeAliasEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
    |> EmptyStubEnvironment.AssumeDownstreamNeverNeedsUpdates.upstream
end

module AssumeGlobalModuleListing = struct
  let global_module_paths_api errors_environment =
    source_code_base errors_environment
    |> SourceCodeIncrementalApi.Base.AssumeGlobalModuleListing.global_module_paths_api
end

module ErrorsEnvironmentReadOnly = ReadOnly

let populate_for_modules ~scheduler environment qualifiers =
  (* Because of lazy evaluation, we can actually perform this operation using only a read-only
     environment. But we put it on the read-write API because the behavior is explicitly
     stateful. *)
  let environment = read_only environment in
  let timer = Timer.start () in
  let number_of_qualifiers = List.length qualifiers in
  Log.log ~section:`Progress "Postprocessing %d sources..." number_of_qualifiers;
  let map modules =
    List.length modules, List.concat_map modules ~f:(ReadOnly.get_errors_for_qualifier environment)
  in
  let reduce (left_count, left_errors) (right_count, right_errors) =
    let number_so_far = left_count + right_count in
    Log.log ~section:`Progress "Postprocessed %d of %d sources" number_so_far number_of_qualifiers;
    number_so_far, List.append left_errors right_errors
  in
  let _ =
    SharedMemoryKeys.DependencyKey.Registry.collected_map_reduce
      scheduler
      ~policy:
        (Scheduler.Policy.fixed_chunk_count
           ~minimum_chunks_per_worker:1
           ~minimum_chunk_size:1
           ~preferred_chunks_per_worker:1
           ())
      ~initial:(0, [])
      ~map
      ~reduce
      ~inputs:qualifiers
      ()
  in
  Statistics.performance ~name:"check_Postprocessing" ~phase_name:"Postprocessing" ~timer ();
  ()


module UpdateStatistics = struct
  type t = {
    module_updates_count: int;
    invalidated_modules_count: int;
    (* This includes only re-checks of previously existing functions, not checks of newly added
       functions *)
    rechecked_modules_count: int;
    rechecked_functions_count: int;
  }

  let count_updates update_result =
    let rechecked_functions_count, rechecked_modules_count =
      let rechecked_functions, rechecked_modules =
        let filter_union sofar keyset =
          let collect_unique registered (sofar_functions, sofar_modules) =
            match SharedMemoryKeys.DependencyKey.get_key registered with
            | SharedMemoryKeys.TypeCheckDefine name -> Set.add sofar_functions name, sofar_modules
            | SharedMemoryKeys.CreateModuleErrors name ->
                sofar_functions, Set.add sofar_modules name
            | _ -> sofar_functions, sofar_modules
          in
          SharedMemoryKeys.DependencyKey.RegisteredSet.fold collect_unique keyset sofar
        in
        UpdateResult.all_triggered_dependencies update_result
        |> List.fold ~init:(Reference.Set.empty, Reference.Set.empty) ~f:filter_union
      in
      Set.length rechecked_functions, Set.length rechecked_modules
    in
    let module_updates_count, invalidated_modules_count =
      let source_code_update_result = UpdateResult.source_code_update_result update_result in
      ( SourceCodeIncrementalApi.UpdateResult.module_updates source_code_update_result |> List.length,
        SourceCodeIncrementalApi.UpdateResult.invalidated_modules source_code_update_result
        |> List.length )
    in
    {
      module_updates_count;
      invalidated_modules_count;
      rechecked_modules_count;
      rechecked_functions_count;
    }
end

module Testing = struct
  module ReadOnly = struct
    include QualifierErrorsTable.Testing.ReadOnly

    let errors_environment = Fn.id

    let type_environment = ReadOnly.type_environment

    let annotated_global_environment environment =
      type_environment environment |> TypeEnvironment.Testing.ReadOnly.upstream


    let function_definition_environment environment =
      annotated_global_environment environment
      |> AnnotatedGlobalEnvironment.Testing.ReadOnly.upstream


    let attribute_resolution environment =
      function_definition_environment environment
      |> FunctionDefinitionEnvironment.Testing.ReadOnly.upstream


    let class_metadata_environment environment =
      attribute_resolution environment |> AttributeResolution.Testing.ReadOnly.upstream


    let class_hierarchy_environment environment =
      class_metadata_environment environment
      |> ClassSuccessorMetadataEnvironment.Testing.ReadOnly.upstream


    let alias_environment environment =
      class_hierarchy_environment environment |> ClassHierarchyEnvironment.Testing.ReadOnly.upstream


    let empty_stub_environment environment =
      alias_environment environment |> TypeAliasEnvironment.Testing.ReadOnly.upstream


    let unannotated_global_environment environment =
      empty_stub_environment environment |> EmptyStubEnvironment.Testing.ReadOnly.upstream
  end

  module UpdateResult = struct
    include QualifierErrorsTable.Testing.UpdateResult

    let errors_environment = Fn.id

    let type_environment update_result = upstream update_result

    let annotated_global_environment update_result =
      type_environment update_result |> TypeEnvironment.Testing.UpdateResult.upstream


    let function_definition_environment update_result =
      annotated_global_environment update_result
      |> AnnotatedGlobalEnvironment.Testing.UpdateResult.upstream


    let attribute_resolution update_result =
      function_definition_environment update_result
      |> FunctionDefinitionEnvironment.Testing.UpdateResult.upstream


    let class_metadata_environment update_result =
      attribute_resolution update_result |> AttributeResolution.Testing.UpdateResult.upstream


    let class_hierarchy_environment update_result =
      class_metadata_environment update_result
      |> ClassSuccessorMetadataEnvironment.Testing.UpdateResult.upstream


    let alias_environment update_result =
      class_hierarchy_environment update_result
      |> ClassHierarchyEnvironment.Testing.UpdateResult.upstream


    let empty_stub_environment update_result =
      alias_environment update_result |> TypeAliasEnvironment.Testing.UpdateResult.upstream


    let unannotated_global_environment update_result =
      empty_stub_environment update_result |> EmptyStubEnvironment.Testing.UpdateResult.upstream
  end
end

let create_with_ast_environment controls =
  let timer = Timer.start () in
  (* Validate paths at creation, but only if the sources are not in memory *)
  let () =
    match EnvironmentControls.in_memory_sources controls with
    | Some _ -> ()
    | None -> EnvironmentControls.configuration controls |> Configuration.Analysis.validate_paths
  in
  let environment =
    AstEnvironment.create controls |> SourceCodeEnvironment.of_ast_environment |> create
  in
  Statistics.performance ~name:"Full environment built" ~timer ();
  environment


let check_and_postprocess ~scheduler ~scheduler_policies environment qualifiers =
  (AssumeDownstreamNeverNeedsUpdates.type_environment environment
  |> TypeEnvironment.populate_for_modules ~scheduler ~scheduler_policies)
    qualifiers;
  populate_for_modules ~scheduler environment qualifiers;
  PyreProfiling.track_shared_memory_usage ~name:"After checking and postprocess" ();
  ()
