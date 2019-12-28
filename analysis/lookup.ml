(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
open Ast
open Expression
open Statement

type annotation_lookup = Type.t Location.Table.t

type definition_lookup = Location.t Location.Table.t

type t = {
  annotations_lookup: annotation_lookup;
  definitions_lookup: definition_lookup;
}

(** The result state of this visitor is ignored. We need two read-only pieces of information to
    build the location table: the types resolved for this statement, and a reference to the
    (mutable) location table to update. *)
module NodeVisitor = struct
  type t = {
    pre_resolution: Resolution.t;
    post_resolution: Resolution.t;
    resolution_lookup: LocalAnnotationMap.t;
    global_resolution: GlobalResolution.t;
    annotations_lookup: annotation_lookup;
    definitions_lookup: definition_lookup;
  }

  let node_base
      ~postcondition
      ( {
          pre_resolution;
          post_resolution;
          resolution_lookup;
          global_resolution;
          annotations_lookup;
          definitions_lookup;
        } as state )
      node
    =
    let rec annotate_expression ({ Node.location; value } as expression) =
      let resolution = if postcondition then post_resolution else pre_resolution in
      let resolve ~resolution ~expression =
        try
          let annotation = Resolution.resolve_to_annotation resolution expression in
          let original = Annotation.original annotation in
          if Type.is_top original || Type.is_unbound original then
            let annotation = Annotation.annotation annotation in
            if Type.is_top annotation || Type.is_unbound annotation then
              None
            else
              Some annotation
          else
            Some original
        with
        | ClassHierarchy.Untracked _ -> None
      in
      let resolve_definition ~expression =
        let find_definition reference =
          let fallback = function
            | Some location -> Some location
            | None -> (
                match Resolution.resolve_reference resolution reference with
                | Type.Callable { implementation = { define_location; _ }; _ } -> define_location
                | _ -> None )
          in
          GlobalResolution.global (Resolution.global_resolution resolution) reference
          >>| Node.location
          |> fallback
          >>= fun location -> if Location.equal location Location.any then None else Some location
        in
        match Node.value expression with
        | Expression.Name (Name.Identifier identifier) ->
            find_definition (Reference.create identifier)
        | Name (Name.Attribute { base; attribute; _ } as name) -> (
            let definition = name_to_reference name >>= find_definition in
            match definition with
            | Some definition -> Some definition
            | None ->
                (* Resolve prefix to check if this is a method. *)
                resolve ~resolution ~expression:base
                >>| Type.class_name
                >>| (fun prefix -> Reference.create ~prefix attribute)
                >>= find_definition )
        | _ -> None
      in
      let store_lookup ~table ~location ~data =
        if
          (not (Location.equal location Location.any))
          && not (Location.equal location Location.synthetic)
        then
          Hashtbl.set table ~key:location ~data |> ignore
      in
      let store_annotation location annotation =
        store_lookup ~table:annotations_lookup ~location ~data:annotation
      in
      let store_definition location data = store_lookup ~table:definitions_lookup ~location ~data in
      resolve ~resolution ~expression >>| store_annotation location |> ignore;
      resolve_definition ~expression >>| store_definition location |> ignore;
      let annotate_nested_scope_expression ~annotations ({ Node.location; _ } as expression) =
        let resolution = TypeCheck.resolution global_resolution ~annotations () in
        resolve ~resolution ~expression >>| store_annotation location |> ignore
      in
      match value with
      | Call { arguments; _ } ->
          let annotate_argument_name { Call.Argument.name; value = { Node.location; _ } as value } =
            match name, resolve ~resolution ~expression:value with
            | Some { Node.location = { Location.start; _ }; _ }, Some annotation ->
                let location = { location with Location.start } in
                store_annotation location annotation
            | _ -> ()
          in
          List.iter ~f:annotate_argument_name arguments
      | DictionaryComprehension { element = { key; value }; generators; _ } ->
          let store_generator_annotation { Comprehension.Generator.target; iterator; conditions; _ }
            =
            let annotations =
              LocalAnnotationMap.get_expression_postcondition resolution_lookup target.Node.location
              |> Option.value ~default:Reference.Map.empty
            in
            let annotate_expression expression =
              annotate_nested_scope_expression ~annotations expression |> ignore
            in
            annotate_expression key;
            annotate_expression value;
            annotate_expression target;
            annotate_expression iterator;
            List.iter ~f:annotate_expression conditions
          in
          List.iter ~f:store_generator_annotation generators
      | ListComprehension { element; generators; _ }
      | SetComprehension { element; generators; _ } ->
          let store_generator_annotation { Comprehension.Generator.target; iterator; conditions; _ }
            =
            let annotations =
              LocalAnnotationMap.get_expression_postcondition resolution_lookup target.Node.location
              |> Option.value ~default:Reference.Map.empty
            in
            let annotate_expression expression =
              annotate_nested_scope_expression ~annotations expression |> ignore
            in
            annotate_expression element;
            annotate_expression target;
            annotate_expression iterator;
            List.iter ~f:annotate_expression conditions
          in
          List.iter ~f:store_generator_annotation generators
      | _ -> ()
    in
    match node with
    | Visit.Expression expression ->
        annotate_expression expression;
        state
    | Visit.Reference { Node.value = reference; location } ->
        annotate_expression (Ast.Expression.from_reference ~location reference);
        state
    | _ -> state


  let node = node_base ~postcondition:false

  let node_postcondition = node_base ~postcondition:true
end

module Visit = struct
  include Visit.MakeNodeVisitor (NodeVisitor)

  let visit state source =
    let state = ref state in
    let visit_statement_override ~state statement =
      (* Special-casing for statements that require lookup using the postcondition. *)
      let precondition_visit = visit_expression ~state ~visitor_override:NodeVisitor.node in
      let postcondition_visit =
        visit_expression ~state ~visitor_override:NodeVisitor.node_postcondition
      in
      (* Special-casing for annotations that should be parsed rather than resolved as expressions. *)
      let store_annotation annotation =
        let { NodeVisitor.pre_resolution; annotations_lookup; _ } = !state in
        let resolved =
          GlobalResolution.parse_annotation (Resolution.global_resolution pre_resolution) annotation
          |> Type.meta
        in
        let location = Node.location annotation in
        if
          (not (Location.equal location Location.any))
          && not (Location.equal location Location.synthetic)
        then
          Hashtbl.add annotations_lookup ~key:location ~data:resolved |> ignore
      in
      match Node.value statement with
      | Statement.Assign { Assign.target; annotation; value; _ } ->
          postcondition_visit target;
          annotation >>| store_annotation |> ignore;
          precondition_visit value
      | Define
          {
            Define.signature =
              {
                name = { Node.value = name; location = name_location };
                parameters;
                decorators;
                return_annotation;
                _;
              };
            _;
          } ->
          let visit_parameter { Node.value = { Parameter.annotation; value; name }; location } =
            Expression.Name (Name.Identifier name) |> Node.create ~location |> postcondition_visit;
            Option.iter ~f:postcondition_visit value;
            annotation >>| store_annotation |> ignore
          in
          precondition_visit (Ast.Expression.from_reference ~location:name_location name);
          List.iter parameters ~f:visit_parameter;
          List.iter decorators ~f:postcondition_visit;
          Option.iter ~f:postcondition_visit return_annotation
      | Import { Import.from; imports } ->
          let visit_import { Import.name = { Node.value = name; location = name_location }; alias } =
            let qualifier =
              match from with
              | Some { Node.value = from; _ } -> from
              | None -> Reference.empty
            in
            let create_qualified_expression ~location =
              Reference.combine qualifier name |> Ast.Expression.from_reference ~location
            in
            precondition_visit (create_qualified_expression ~location:name_location);
            Option.iter
              ~f:(fun { Node.location; _ } ->
                precondition_visit (create_qualified_expression ~location))
              alias
          in
          Option.iter
            ~f:(fun { Node.value = from; location } ->
              Ast.Expression.from_reference ~location from |> precondition_visit)
            from;
          List.iter imports ~f:visit_import
      | _ -> visit_statement ~state statement
    in
    List.iter ~f:(visit_statement_override ~state) source.Source.statements;
    !state
end

let create_of_source type_environment source =
  let annotations_lookup = Location.Table.create () in
  let definitions_lookup = Location.Table.create () in
  let global_resolution = TypeEnvironment.ReadOnly.global_resolution type_environment in
  let walk_define
      ( {
          Node.value = { Define.signature = { name = { Node.value = name; _ }; _ }; _ } as define;
          _;
        } as define_node )
    =
    let annotation_lookup =
      TypeCheck.get_or_recompute_local_annotations ~environment:type_environment name
      |> Option.value ~default:LocalAnnotationMap.empty
    in
    let cfg = Cfg.create define in
    let walk_statement node_id statement_index statement =
      let pre_annotations, post_annotations =
        let key = [%hash: int * int] (node_id, statement_index) in
        ( LocalAnnotationMap.get_statement_precondition annotation_lookup key
          |> Option.value ~default:Reference.Map.empty,
          LocalAnnotationMap.get_statement_postcondition annotation_lookup key
          |> Option.value ~default:Reference.Map.empty )
      in
      let pre_resolution = TypeCheck.resolution global_resolution ~annotations:pre_annotations () in
      let post_resolution =
        TypeCheck.resolution global_resolution ~annotations:post_annotations ()
      in
      let statement =
        match Node.value statement with
        | Statement.Class class_statement ->
            { statement with Node.value = Statement.Class { class_statement with Class.body = [] } }
        | Define define_statement ->
            { statement with Node.value = Define { define_statement with Define.body = [] } }
        | _ -> statement
      in
      Visit.visit
        {
          NodeVisitor.pre_resolution;
          post_resolution;
          resolution_lookup = annotation_lookup;
          global_resolution;
          annotations_lookup;
          definitions_lookup;
        }
        (Source.create [statement])
      |> ignore
    in
    let walk_cfg_node ~key:node_id ~data:cfg_node =
      let statements = Cfg.Node.statements cfg_node in
      List.iteri statements ~f:(walk_statement node_id)
    in
    Hashtbl.iteri cfg ~f:walk_cfg_node;

    (* Special-case define signature processing, since this is not included in the define's cfg. *)
    let define_signature =
      { define_node with value = Statement.Define { define with Define.body = [] } }
    in
    walk_statement Cfg.entry_index 0 define_signature
  in
  Preprocessing.defines ~include_nested:true ~include_toplevels:true source
  |> List.iter ~f:walk_define;
  { annotations_lookup; definitions_lookup }


let get_best_location lookup_table ~position =
  let location_contains_position
      {
        Location.start = { Location.column = start_column; line = start_line };
        stop = { Location.column = stop_column; line = stop_line };
        _;
      }
      { Location.column; line }
    =
    let start_ok = start_line < line || (start_line = line && start_column <= column) in
    let stop_ok = stop_line > line || (stop_line = line && stop_column > column) in
    start_ok && stop_ok
  in
  let weight
      {
        Location.start = { Location.column = start_column; line = start_line };
        stop = { Location.column = stop_column; line = stop_line };
        _;
      }
    =
    ((stop_line - start_line) * 1000) + stop_column - start_column
  in
  Hashtbl.filter_keys lookup_table ~f:(fun key -> location_contains_position key position)
  |> Hashtbl.to_alist
  |> List.min_elt ~compare:(fun (location_left, _) (location_right, _) ->
         weight location_left - weight location_right)


let get_annotation { annotations_lookup; _ } ~position =
  get_best_location annotations_lookup ~position


let get_definition { definitions_lookup; _ } ~position =
  get_best_location definitions_lookup ~position >>| snd


let get_all_annotations { annotations_lookup; _ } = Hashtbl.to_alist annotations_lookup

let get_all_definitions { definitions_lookup; _ } = Hashtbl.to_alist definitions_lookup
