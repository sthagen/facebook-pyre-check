(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

module YojsonUtils = struct
  open Yojson.Safe.Util

  let with_default ~extract ~extract_optional ?default json =
    match default with
    | None -> extract json
    | Some default -> extract_optional json |> Option.value ~default


  let to_bool_with_default = with_default ~extract:to_bool ~extract_optional:to_bool_option

  let to_int_with_default = with_default ~extract:to_int ~extract_optional:to_int_option

  let to_string_with_default = with_default ~extract:to_string ~extract_optional:to_string_option

  let to_path json = to_string json |> PyrePath.create_absolute

  (* The absent of explicit `~default` parameter means that the corresponding JSON field is
     mandantory. *)
  let bool_member ?default name json = member name json |> to_bool_with_default ?default

  let int_member ?default name json = member name json |> to_int_with_default ?default

  let string_member ?default name json = member name json |> to_string_with_default ?default

  let optional_member ~f name json =
    member name json
    |> function
    | `Null -> None
    | _ as element -> Some (f element)


  let optional_string_member = optional_member ~f:to_string

  let optional_int_member = optional_member ~f:to_int

  let optional_bool_member = optional_member ~f:to_bool

  let path_member name json = member name json |> to_path

  let optional_path_member = optional_member ~f:to_path

  let list_member ?default ~f name json =
    member name json
    |> fun element ->
    match element, default with
    | `Null, Some default -> default
    | _, _ -> convert_each f element


  let optional_list_member ~f name json =
    member name json
    |> function
    | `Null -> None
    | element -> Some (convert_each f element)


  let string_list_member = list_member ~f:to_string

  let path_list_member = list_member ~f:to_path
end

module JsonAst = struct
  open Core
  module Result = Core.Result

  module Location = struct
    type position = {
      line: int;
      column: int;
    }
    [@@deriving equal, compare]

    and t = {
      start: position;
      stop: position;
    }
    [@@deriving equal, compare]

    let pp_position formatter { line; column } = Format.fprintf formatter "%d:%d" line column

    let show_position = Format.asprintf "%a" pp_position

    let null_position = { line = -1; column = -1 }

    let null_location = { start = null_position; stop = null_position }

    let pp_start formatter { start; _ } = Format.fprintf formatter "%a" pp_position start

    let pp formatter { start; stop } =
      Format.fprintf formatter "%a-%a" pp_position start pp_position stop


    let show = Format.asprintf "%a" pp

    let from_decoded_range range =
      let (start_line, start_column), (end_line, end_column) = range in
      {
        start = { line = start_line; column = start_column };
        stop = { line = end_line; column = end_column };
      }
  end

  module LocationWithPath = struct
    type t = {
      location: Location.t;
      path: PyrePath.t;
    }
    [@@deriving equal, show, compare]

    let create ~location ~path = { location; path }
  end

  module Node = struct
    type 'a t = {
      location: Location.t;
      value: 'a;
    }
    [@@deriving equal, show, compare]
  end

  exception
    ParseException of {
      message: string;
      location: Location.t;
    }

  module ParseError = struct
    type t = {
      message: string;
      location: Location.t;
    }
  end

  module Json = struct
    type expression =
      [ `Null
      | `Bool of bool
      | `String of string
      | `Float of float
      | `Int of int
      | `List of t list
      | `Assoc of (string * t) list
      ]

    and t = expression Node.t [@@deriving equal, compare]

    (* Pretty-print each node with their location. Useful for debugging. *)
    module PrettyPrint = struct
      let rec pp_expression_t formatter { Node.value = expression; location } =
        Format.fprintf formatter "%a (loc: %a)" pp_expression expression Location.pp location


      and pp_expression formatter = function
        | `Null -> Format.fprintf formatter "Null"
        | `Bool value -> Format.fprintf formatter "%b" value
        | `String value -> Format.fprintf formatter "\"%s\"" value
        | `Float value -> Format.fprintf formatter "%f" value
        | `Int value -> Format.fprintf formatter "%d" value
        | `List values -> Format.fprintf formatter "%a" pp_value_list values
        | `Assoc values -> Format.fprintf formatter "%a" pp_assoc_value_list values


      and pp_value_list formatter = function
        | [] -> ()
        | [element] -> Format.fprintf formatter "[%a]" pp_expression_t element
        | elements ->
            let pp_element formatter element =
              Format.fprintf formatter "@,%a" pp_expression_t element
            in
            let pp_elements formatter = List.iter ~f:(pp_element formatter) in
            Format.fprintf formatter "[@[<v 2>%a@]@,]" pp_elements elements


      and pp_assoc_value_list formatter = function
        | [] -> ()
        | [(key, value)] -> Format.fprintf formatter "{\"%s\" -> %a}" key pp_expression_t value
        | pairs ->
            let pp_pair formatter (key, value) =
              Format.fprintf formatter "@,\"%s\" -> %a" key pp_expression_t value
            in
            let pp_pairs formatter = List.iter ~f:(pp_pair formatter) in
            Format.fprintf formatter "{@[<v 2>%a@]@,}" pp_pairs pairs
    end

    let pp_internal = PrettyPrint.pp_expression_t

    let show_internal = Format.asprintf "%a" pp_internal

    let rec to_yojson { Node.value; _ } =
      match value with
      | `Null -> `Null
      | `Bool value -> `Bool value
      | `String value -> `String value
      | `Float value -> `Float value
      | `Int value -> `Int value
      | `List elements -> elements |> List.map ~f:to_yojson |> fun elements -> `List elements
      | `Assoc pairs ->
          pairs
          |> List.map ~f:(fun (name, value) -> name, to_yojson value)
          |> fun pairs -> `Assoc pairs


    exception
      TypeError of {
        message: string;
        json: t;
      }

    let null_node = { Node.location = Location.null_location; value = `Null }

    let from_string_exn input =
      let decode decoder =
        match Jsonm.decode decoder with
        | `Lexeme lexeme -> lexeme
        | `Error error ->
            raise
              (ParseException
                 {
                   message = Format.asprintf "%a" Jsonm.pp_error error;
                   location = Location.from_decoded_range (Jsonm.decoded_range decoder);
                 })
        | `End
        | `Await ->
            raise
              (ParseException
                 {
                   message = "Encountered end of file or input";
                   location = Location.from_decoded_range (Jsonm.decoded_range decoder);
                 })
      in
      let rec parse_value value post_parse_function decoder =
        let location = Location.from_decoded_range (Jsonm.decoded_range decoder) in
        match value with
        | `Os -> parse_object [] post_parse_function decoder
        | `As -> parse_array [] post_parse_function decoder
        | (`Null | `Bool _ | `String _ | `Float _) as value ->
            post_parse_function { Node.location; value } decoder
        | _ ->
            raise (ParseException { message = "Encountered unexpected token or element"; location })
      and parse_array current_values post_parse_function decoder =
        let location = Location.from_decoded_range (Jsonm.decoded_range decoder) in
        match decode decoder with
        | `Ae ->
            post_parse_function { Node.value = `List (List.rev current_values); location } decoder
        | element ->
            parse_value
              element
              (fun value -> parse_array (value :: current_values) post_parse_function)
              decoder
      and parse_object current_children post_parse_function decoder =
        let location = Location.from_decoded_range (Jsonm.decoded_range decoder) in
        match decode decoder with
        | `Oe ->
            post_parse_function
              { Node.value = `Assoc (List.rev current_children); location }
              decoder
        | `Name name ->
            parse_value
              (decode decoder)
              (fun value -> parse_object ((name, value) :: current_children) post_parse_function)
              decoder
        | _ ->
            raise (ParseException { message = "Encountered unexpected token or element"; location })
      in
      let decoder = Jsonm.decoder (`String input) in
      parse_value (decode decoder) (fun v _ -> v) decoder


    let from_string input =
      try Result.Ok (from_string_exn input) with
      | ParseException { message; location } -> Result.Error { ParseError.message; location }


    module Util = struct
      let type_error expected json =
        let message current = Format.sprintf "Expected %s, got %s" expected current in
        let obj =
          match json.Node.value with
          | `Assoc _ -> "object"
          | `Int _ -> "integer"
          | `Float _ -> "float"
          | `Null -> "null"
          | `String _ -> "string"
          | `Bool _ -> "boolean"
          | `List _ -> "list"
        in
        TypeError { message = message obj; json }


      let keys node =
        match node.Node.value with
        | `Assoc children -> List.map ~f:fst children
        | _ -> []


      (* Extract a child element with a particular key from a a json object. Raises TypeError for
         other types. *)
      let member_exn key node =
        match node.Node.value with
        | `Assoc children -> (
            match List.Assoc.find children key ~equal:String.equal with
            | Some child -> child
            | None -> null_node)
        | _ -> raise (type_error "object" node)


      let member key node =
        try member_exn key node with
        | _ -> null_node


      let to_bool node =
        match node.Node.value with
        | `Bool b -> Some b
        | _ -> None


      let to_string_exn node =
        match node.Node.value with
        | `String s -> s
        | _ -> raise (type_error "string" node)


      let to_int_exn node =
        match node.Node.value with
        | `Int i -> i
        | `Float f -> int_of_float f
        | _ -> raise (type_error "integer" node)


      let to_int node =
        try Some (to_int_exn node) with
        | _ -> None


      let to_list_exn node =
        match node.Node.value with
        | `List l -> l
        | _ -> raise (type_error "list" node)


      let to_location_exn node =
        match node.Node.value with
        | `Null -> raise (type_error "non-null" node)
        | _ -> node.Node.location


      let is_string node =
        match node.Node.value with
        | `String _ -> true
        | _ -> false
    end
  end
end
