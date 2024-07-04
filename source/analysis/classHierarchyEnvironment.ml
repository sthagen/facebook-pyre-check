(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* ClassHierarchyEnvironment: layer of the environment stack
 * - upstream: TypeAliasEnvironment
 * - downstream: ClassSuccessorMetadataEnvironment
 * - key: the name type, as an Identifier.t
 * - value: ClassHierarchy.Target.t
 *
 * The ClassHierarchyEnvironment tracks the direct parents
 * of types.
 *
 * It is keyed on class name as an Identifier.t
 *)

open Core
open Ast
open Pyre
open Expression
module PreviousEnvironment = TypeAliasEnvironment

module IncomingDataComputation = struct
  module Queries = struct
    type t = {
      class_exists: string -> bool;
      get_class_summary: string -> ClassSummary.t Ast.Node.t option;
      is_from_empty_stub: Ast.Reference.t -> bool;
      get_type_alias:
        ?replace_unbound_parameters_with_any:bool -> Type.Primitive.t -> Type.Alias.t option;
      parse_annotation_without_validating_type_parameters:
        ?modify_aliases:(?replace_unbound_parameters_with_any:bool -> Type.Alias.t -> Type.Alias.t) ->
        ?allow_untracked:bool ->
        Ast.Expression.t ->
        Type.t;
    }
  end

  let compute_extends_placeholder_stub_class
      { Node.value = { ClassSummary.bases = { base_classes; metaclass; _ }; _ }; _ }
      ~aliases
      ~is_from_empty_stub
    =
    let metaclass_is_from_placeholder_stub =
      metaclass
      >>| AnnotatedBases.base_is_from_placeholder_stub ~aliases ~is_from_empty_stub
      |> Option.value ~default:false
    in
    List.exists
      base_classes
      ~f:(AnnotatedBases.base_is_from_placeholder_stub ~aliases ~is_from_empty_stub)
    || metaclass_is_from_placeholder_stub


  let find_propagated_type_variables parsed_bases =
    (* Note: We want to preserve order when deduplicating, so we can't use `List.dedup_and_sort`.
       This is quadratic, but it should be fine given the small number of generic variables. *)
    let deduplicate ~equal xs =
      let add_if_not_seen_so_far (seen, unique_items) x =
        if List.mem seen x ~equal then
          seen, unique_items
        else
          x :: seen, x :: unique_items
      in
      List.fold xs ~init:([], []) ~f:add_if_not_seen_so_far |> snd |> List.rev
    in
    List.concat_map ~f:Type.Variable.all_free_variables parsed_bases
    |> deduplicate ~equal:Type.Variable.equal
    |> List.map ~f:Type.Variable.to_parameter


  let compute_generic_base parsed_bases =
    let is_generic base_type =
      let primitive, _ = Type.split base_type in
      Type.is_generic_primitive primitive
    in
    let extract_protocol_parameters base_type =
      match base_type with
      | Type.Parametric { name = "typing.Protocol"; parameters } -> Some parameters
      | _ -> None
    in
    match List.find ~f:is_generic parsed_bases with
    | Some _ as generic_base -> generic_base
    | None -> (
        let create variables = Type.parametric "typing.Generic" variables in
        match List.find_map parsed_bases ~f:extract_protocol_parameters with
        | Some parameters -> Some (create parameters)
        | None ->
            (* TODO:(T60673574) Ban propagating multiple type variables *)
            let variables = find_propagated_type_variables parsed_bases in
            if List.is_empty variables then None else Some (create variables))


  let get_parents
      Queries.
        {
          class_exists;
          get_class_summary;
          is_from_empty_stub;
          get_type_alias;
          parse_annotation_without_validating_type_parameters;
          _;
        }
      name
    =
    (* Split `base_expression` into `(name, params)` where `name` is the name of the class and
       `params` is its type parameters. E.g. `Foo[T]` ==> `("Foo", [TypeVar "T"])` *)
    (* For some reason, this function parses `base_expression` into type with `allow_untracked` set
       to true, which is not the case for other invocations of parse_annotation within this file. *)
    let extract_supertype base_expression =
      let value = delocalize base_expression in
      match Node.value value with
      | Expression.Subscript _
      | Name _ -> (
          let supertype, parameters =
            parse_annotation_without_validating_type_parameters ~allow_untracked:true value
            |> Type.split
          in
          match supertype with
          | Type.Top ->
              Log.log ~section:`Environment "Unresolved superclass name: %a" Expression.pp value;
              ();
              None
          | Type.Primitive primitive when not (class_exists primitive) ->
              Log.log ~section:`Environment "Superclass annotation %a is missing" Type.pp supertype;
              None
          | Type.Primitive supertype -> Some (supertype, parameters)
          | _ -> None)
      | _ -> None
    in
    let bases { Node.value = { ClassSummary.bases = { base_classes; _ }; _ }; _ } = base_classes in
    let add_special_parents parents =
      let simples = List.map ~f:(fun parent -> parent, []) in
      match parents, name with
      | _, "int" -> simples ["float"; "numbers.Integral"]
      | _, "float" -> simples ["complex"; "numbers.Rational"; "numbers.Real"]
      | _, "complex" -> simples ["numbers.Complex"]
      | _, "numbers.Complex" -> simples ["numbers.Number"]
      | [], _ -> simples ["object"]
      | _ -> parents
    in
    (* If `typing.Generic[]` appears in the base list, that entry needs to go through special
       handling. This behavior was established in PEP 560 and gets implemented in CPython via
       `GenericAlias.__mro_entries__()`. See https://fburl.com/mro_in_pyre for more detailed
       explanation. *)
    let filter_shadowed_generic_bases name_and_parameters =
      let is_protocol =
        List.exists name_and_parameters ~f:(fun (name, _) -> String.equal name "typing.Protocol")
      in
      let process_parent ((name, _) as current) rest =
        match name with
        | "typing.Generic" ->
            (* TODO: type parameters of the `name` class is expected to be non-empty here because
               Python forbids inheriting from `typing.Generic` directly. But we currently can't
               check for that since we lack the setup to emit errors from this environment. *)
            if is_protocol then
              (* Hide `Generic` from MRO if the class also extends from `Protocol` *)
              rest
            else if List.exists rest ~f:(fun (_, parameters) -> not (List.is_empty parameters)) then
              (* Hide `Generic` from MRO if there exist other generic aliases down the base class
                 list *)
              rest
            else
              current :: rest
        | _ -> current :: rest
      in
      List.fold_right name_and_parameters ~init:[] ~f:process_parent
    in
    let is_not_primitive_cycle (parent, _) = not (String.equal name parent) in
    let convert_to_targets =
      List.map ~f:(fun (name, parameters) -> { ClassHierarchy.Target.target = name; parameters })
    in
    let deduplicate targets =
      let deduplicate (visited, sofar) ({ ClassHierarchy.Target.target; _ } as edge) =
        if Set.mem visited target then
          visited, sofar
        else
          Set.add visited target, edge :: sofar
      in
      List.fold targets ~f:deduplicate ~init:(Identifier.Set.empty, []) |> snd |> List.rev
    in
    let remove_extra_edges_to_object targets =
      let not_object_edge { ClassHierarchy.Target.target; _ } =
        not ([%compare.equal: Identifier.t] target "object")
      in
      match List.filter targets ~f:not_object_edge with
      | [] -> targets
      | filtered -> filtered
    in
    match get_class_summary name with
    | None -> None
    | Some class_summary ->
        let base_classes = bases class_summary in
        let parents =
          List.filter_map base_classes ~f:extract_supertype
          |> add_special_parents
          |> List.filter ~f:is_not_primitive_cycle
          |> filter_shadowed_generic_bases
          |> convert_to_targets
          |> deduplicate
          |> remove_extra_edges_to_object
        in
        let generic_base =
          let open Option in
          let parsed_bases =
            List.map base_classes ~f:parse_annotation_without_validating_type_parameters
          in
          compute_generic_base parsed_bases
          >>= fun base ->
          extract_supertype (Type.expression base)
          >>= fun (name, parameters) -> Some { ClassHierarchy.Target.target = name; parameters }
        in
        let has_placeholder_stub_parent =
          compute_extends_placeholder_stub_class
            class_summary
            ~aliases:get_type_alias
            ~is_from_empty_stub
        in
        Some { ClassHierarchy.Edges.parents; generic_base; has_placeholder_stub_parent }
end

module OutgoingDataComputation = struct
  module Queries = struct
    type t = {
      class_exists: string -> bool;
      get_edges: Ast.Identifier.t -> ClassHierarchy.Edges.t option;
    }
  end

  let class_hierarchy Queries.{ class_exists; get_edges; _ } =
    (module struct
      let edges = get_edges

      let contains key = class_exists key
    end : ClassHierarchy.Handler)


  let type_parameters_as_variables queries ?(default = None) class_name =
    ClassHierarchy.type_parameters_as_variables ~default (class_hierarchy queries) class_name
end

module EdgesValue = struct
  type t = ClassHierarchy.Edges.t option

  let prefix = Hack_parallel.Std.Prefix.make ()

  let description = "Edges"

  let equal = Memory.equal_from_compare [%compare: ClassHierarchy.Edges.t option]
end

module Edges = Environment.EnvironmentTable.WithCache (struct
  module PreviousEnvironment = PreviousEnvironment
  module Key = SharedMemoryKeys.StringKey
  module Value = EdgesValue

  type trigger = string [@@deriving sexp, compare]

  let convert_trigger = Fn.id

  let key_to_trigger = Fn.id

  module TriggerSet = Type.Primitive.Set

  let lazy_incremental = false

  let produce_value alias_environment key ~dependency =
    let queries =
      let empty_stub_environment =
        TypeAliasEnvironment.ReadOnly.empty_stub_environment alias_environment
      in
      let unannotated_global_environment =
        EmptyStubEnvironment.ReadOnly.unannotated_global_environment empty_stub_environment
      in
      IncomingDataComputation.Queries.
        {
          class_exists =
            UnannotatedGlobalEnvironment.ReadOnly.class_exists
              unannotated_global_environment
              ?dependency;
          get_class_summary =
            UnannotatedGlobalEnvironment.ReadOnly.get_class_summary
              unannotated_global_environment
              ?dependency;
          is_from_empty_stub =
            EmptyStubEnvironment.ReadOnly.is_from_empty_stub empty_stub_environment ?dependency;
          get_type_alias =
            TypeAliasEnvironment.ReadOnly.get_type_alias alias_environment ?dependency;
          parse_annotation_without_validating_type_parameters =
            TypeAliasEnvironment.ReadOnly.parse_annotation_without_validating_type_parameters
              alias_environment
              ?dependency;
        }
    in
    IncomingDataComputation.get_parents queries key


  let filter_upstream_dependency = function
    | SharedMemoryKeys.ClassConnect name -> Some name
    | _ -> None


  let trigger_to_dependency name = SharedMemoryKeys.ClassConnect name

  let show_key = Fn.id

  let overlay_owns_key source_code_overlay index =
    key_to_trigger index |> SourceCodeIncrementalApi.Overlay.owns_identifier source_code_overlay


  let equal_value = [%compare.equal: ClassHierarchy.Edges.t option]
end)

include Edges

module ReadOnly = struct
  include Edges.ReadOnly

  let alias_environment = upstream_environment

  let get_edges = get

  let unannotated_global_environment read_only =
    alias_environment read_only |> TypeAliasEnvironment.ReadOnly.unannotated_global_environment


  let outgoing_queries ?dependency read_only =
    OutgoingDataComputation.Queries.
      {
        class_exists =
          UnannotatedGlobalEnvironment.ReadOnly.class_exists
            (unannotated_global_environment read_only)
            ?dependency;
        get_edges = get_edges read_only ?dependency;
      }


  let type_parameters_as_variables read_only ?dependency =
    outgoing_queries ?dependency read_only |> OutgoingDataComputation.type_parameters_as_variables


  let class_hierarchy ?dependency read_only =
    outgoing_queries ?dependency read_only |> OutgoingDataComputation.class_hierarchy


  (* This function is not used in production, but in the past it has been useful to run it after
     incremental updates when debugging bugs in incremental logic *)
  let check_integrity read_only ~global_module_paths_api =
    let class_names =
      alias_environment read_only
      |> TypeAliasEnvironment.ReadOnly.unannotated_global_environment
      |> UnannotatedGlobalEnvironment.ReadOnly.GlobalApis.all_classes ~global_module_paths_api
    in
    ClassHierarchy.check_integrity (class_hierarchy read_only) ~class_names
end

module HierarchyReadOnly = ReadOnly

(* Exposed for unit testing only *)
let compute_generic_base = IncomingDataComputation.compute_generic_base
