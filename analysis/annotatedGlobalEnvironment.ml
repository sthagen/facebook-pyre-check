(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Pyre
open Statement
module PreviousEnvironment = AttributeResolution

type global = Annotation.t [@@deriving eq, show, compare, sexp]

let class_hierarchy_environment class_metadata_environment =
  ClassMetadataEnvironment.ReadOnly.class_hierarchy_environment class_metadata_environment


let alias_environment environment =
  class_hierarchy_environment environment |> ClassHierarchyEnvironment.ReadOnly.alias_environment


let unannotated_global_environment environment =
  alias_environment environment |> AliasEnvironment.ReadOnly.unannotated_global_environment


module GlobalValueValue = struct
  type t = global option

  let prefix = Prefix.make ()

  let description = "Global"

  let unmarshall value = Marshal.from_string value 0

  let compare = Option.compare compare_global
end

module GlobalLocationValue = struct
  type t = Location.t option

  let prefix = Prefix.make ()

  let description = "Global Locations"

  let unmarshall value = Marshal.from_string value 0

  let compare = Option.compare Location.compare
end

let produce_global_annotation attribute_resolution name ~track_dependencies =
  let class_metadata_environment =
    AttributeResolution.ReadOnly.class_metadata_environment attribute_resolution
  in
  let dependency = Option.some_if track_dependencies (SharedMemoryKeys.AnnotateGlobal name) in
  let process_unannotated_global global =
    let produce_assignment_global ~is_explicit annotation =
      let original =
        if is_explicit then
          None
        else if
          (* Treat literal globals as having been explicitly annotated. *)
          Type.is_partially_typed annotation
        then
          Some Type.Top
        else
          None
      in
      Annotation.create_immutable ~original annotation
    in
    match global with
    | UnannotatedGlobalEnvironment.Define defines ->
        let create_overload
            { Node.value = { Define.Signature.name = { Node.value = name; _ }; _ } as signature; _ }
          =
          let overload =
            AttributeResolution.ReadOnly.create_overload attribute_resolution ?dependency signature
          in
          if Define.Signature.is_overloaded_function signature then
            {
              Type.Callable.kind = Named name;
              implementation = { annotation = Type.Top; parameters = Undefined };
              overloads = [overload];
              implicit = None;
            }
          else
            {
              Type.Callable.kind = Named name;
              implementation = overload;
              overloads = [];
              implicit = None;
            }
        in

        List.map defines ~f:create_overload
        |> Type.Callable.from_overloads
        >>| (fun callable -> Type.Callable callable)
        >>| Annotation.create_immutable
    | SimpleAssign
        {
          explicit_annotation = None;
          value =
            {
              Node.value =
                Call
                  {
                    callee =
                      {
                        value =
                          Name
                            (Attribute
                              {
                                base = { Node.value = Name (Identifier "typing"); _ };
                                attribute = "TypeAlias";
                                _;
                              });
                        _;
                      };
                    _;
                  };
              _;
            };
          target_location = location;
        } ->
        Ast.Expression.Expression.Name (Expression.create_name_from_reference ~location name)
        |> Node.create ~location
        |> AttributeResolution.ReadOnly.parse_annotation
             ~validation:ValidatePrimitives
             ?dependency
             attribute_resolution
        |> Type.meta
        |> Annotation.create_immutable
        |> Option.some
    | SimpleAssign { explicit_annotation; value; _ } ->
        let explicit_annotation =
          explicit_annotation
          >>| AttributeResolution.ReadOnly.parse_annotation ?dependency attribute_resolution
          >>= fun annotation -> Option.some_if (not (Type.is_type_alias annotation)) annotation
        in
        let annotation =
          match explicit_annotation with
          | Some explicit -> explicit
          | None ->
              AttributeResolution.ReadOnly.resolve_literal ?dependency attribute_resolution value
        in
        produce_assignment_global ~is_explicit:(Option.is_some explicit_annotation) annotation
        |> Option.some
    | TupleAssign { value; index; total_length; _ } ->
        let extracted =
          match
            AttributeResolution.ReadOnly.resolve_literal ?dependency attribute_resolution value
          with
          | Type.Tuple (Type.Bounded (Concrete parameters))
            when List.length parameters = total_length ->
              List.nth parameters index
              (* This should always be Some, but I don't think its worth being fragile here *)
              |> Option.value ~default:Type.Top
          | Type.Tuple (Type.Unbounded parameter) -> parameter
          | _ -> Type.Top
        in
        produce_assignment_global ~is_explicit:false extracted |> Option.some
    | _ -> None
  in
  let class_lookup =
    Reference.show name
    |> UnannotatedGlobalEnvironment.ReadOnly.class_exists
         (unannotated_global_environment class_metadata_environment)
         ?dependency
  in
  if class_lookup then
    let primitive = Type.Primitive (Reference.show name) in
    Annotation.create_immutable (Type.meta primitive) |> Option.some
  else
    UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global
      (unannotated_global_environment class_metadata_environment)
      ?dependency
      name
    >>= fun global ->
    let timer = Timer.start () in
    let result = process_unannotated_global global in
    Statistics.performance
      ~flush:false
      ~randomly_log_every:500
      ~section:`Check
      ~name:"SingleGlobalTypeCheck"
      ~timer
      ~normals:["name", Reference.show name; "request kind", "SingleGlobalTypeCheck"]
      ();
    result


module Common = struct
  let legacy_invalidated_keys upstream =
    let previous_classes =
      UnannotatedGlobalEnvironment.UpdateResult.previous_classes upstream
      |> Type.Primitive.Set.to_list
      |> List.map ~f:Reference.create
    in
    let previous_unannotated_globals =
      UnannotatedGlobalEnvironment.UpdateResult.previous_unannotated_globals upstream
    in
    List.fold ~init:previous_unannotated_globals ~f:Set.add previous_classes


  let all_keys = UnannotatedGlobalEnvironment.ReadOnly.all_unannotated_globals

  let show_key = Reference.show
end

module GlobalValueTable = Environment.EnvironmentTable.WithCache (struct
  include Common
  module PreviousEnvironment = PreviousEnvironment
  module Key = SharedMemoryKeys.ReferenceKey
  module Value = GlobalValueValue

  type trigger = Reference.t

  let convert_trigger = Fn.id

  let key_to_trigger = Fn.id

  module TriggerSet = Reference.Set

  let lazy_incremental = false

  let produce_value = produce_global_annotation

  let filter_upstream_dependency = function
    | SharedMemoryKeys.AnnotateGlobal name -> Some name
    | _ -> None


  let serialize_value = function
    | Some annotation -> Annotation.sexp_of_t annotation |> Sexp.to_string
    | None -> "None"


  let equal_value = Option.equal Annotation.equal
end)

let produce_global_location global_value_table name ~track_dependencies =
  let class_metadata_environment =
    GlobalValueTable.ReadOnly.upstream_environment global_value_table
    |> AttributeResolution.ReadOnly.class_metadata_environment
  in
  let dependency =
    Option.some_if track_dependencies (SharedMemoryKeys.AnnotateGlobalLocation name)
  in
  let class_location =
    Reference.show name
    |> UnannotatedGlobalEnvironment.ReadOnly.get_class_definition
         (unannotated_global_environment class_metadata_environment)
         ?dependency
    >>| Node.location
  in
  match class_location with
  | Some location -> Some location
  | None ->
      let extract_location = function
        | UnannotatedGlobalEnvironment.Define (head :: _) -> Some (Node.location head)
        | SimpleAssign { target_location; _ } -> Some target_location
        | TupleAssign { target_location; _ } -> Some target_location
        | _ -> None
      in
      UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global
        (unannotated_global_environment class_metadata_environment)
        ?dependency
        name
      >>= extract_location


module GlobalLocationTable = Environment.EnvironmentTable.WithCache (struct
  include Common
  module PreviousEnvironment = GlobalValueTable
  module Key = SharedMemoryKeys.ReferenceKey
  module Value = GlobalLocationValue

  type trigger = Reference.t

  let convert_trigger = Fn.id

  let key_to_trigger = Fn.id

  module TriggerSet = Reference.Set

  let lazy_incremental = false

  let produce_value = produce_global_location

  let filter_upstream_dependency = function
    | SharedMemoryKeys.AnnotateGlobalLocation name -> Some name
    | _ -> None


  let serialize_value = function
    | Some location -> Location.sexp_of_t location |> Sexp.to_string
    | None -> "None"


  let equal_value = Option.equal Location.equal
end)

include GlobalLocationTable

module ReadOnly = struct
  include GlobalLocationTable.ReadOnly

  let get_global read_only ?dependency name =
    GlobalValueTable.ReadOnly.get (upstream_environment read_only) ?dependency name


  let get_global_location = get

  let attribute_resolution read_only =
    upstream_environment read_only |> GlobalValueTable.ReadOnly.upstream_environment


  let class_metadata_environment read_only =
    attribute_resolution read_only |> AttributeResolution.ReadOnly.class_metadata_environment


  let ast_environment environment =
    class_metadata_environment environment
    |> ClassMetadataEnvironment.ReadOnly.class_hierarchy_environment
    |> ClassHierarchyEnvironment.ReadOnly.alias_environment
    |> AliasEnvironment.ReadOnly.unannotated_global_environment
    |> UnannotatedGlobalEnvironment.ReadOnly.ast_environment
end

module UpdateResult = GlobalLocationTable.UpdateResult
module AnnotatedReadOnly = ReadOnly
