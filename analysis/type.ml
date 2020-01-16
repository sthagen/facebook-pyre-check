(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Expression
open Pyre
open PyreParser
module ExpressionParameter = Parameter

module Record = struct
  module Variable = struct
    type state =
      | Free of { escaped: bool }
      | InFunction
    [@@deriving compare, eq, sexp, show, hash]

    type 'annotation constraints =
      | Bound of 'annotation
      | Explicit of 'annotation list
      | Unconstrained
      | LiteralIntegers
    [@@deriving compare, eq, sexp, show, hash]

    type variance =
      | Covariant
      | Contravariant
      | Invariant
    [@@deriving compare, eq, sexp, show, hash]

    module RecordNamespace = struct
      type t = int [@@deriving compare, eq, sexp, show, hash]
    end

    module RecordUnary = struct
      type 'annotation record = {
        variable: Identifier.t;
        constraints: 'annotation constraints;
        variance: variance;
        state: state;
        namespace: RecordNamespace.t;
      }
      [@@deriving compare, eq, sexp, show, hash]

      let create ?(constraints = Unconstrained) ?(variance = Invariant) name =
        { variable = name; constraints; variance; state = Free { escaped = false }; namespace = 0 }


      let pp_concise format { variable; constraints; variance; _ } ~pp_type =
        let name =
          match constraints with
          | Bound _
          | Explicit _
          | Unconstrained ->
              "Variable"
          | LiteralIntegers -> "IntegerVariable"
        in
        let constraints =
          match constraints with
          | Bound bound -> Format.asprintf " (bound to %a)" pp_type bound
          | Explicit constraints ->
              Format.asprintf
                " <: [%a]"
                (Format.pp_print_list ~pp_sep:(fun format () -> Format.fprintf format ", ") pp_type)
                constraints
          | Unconstrained -> ""
          | LiteralIntegers -> ""
        in
        let variance =
          match variance with
          | Covariant -> "(covariant)"
          | Contravariant -> "(contravariant)"
          | Invariant -> ""
        in
        Format.fprintf format "%s[%s%s]%s" name (Identifier.sanitized variable) constraints variance
    end

    module RecordVariadic = struct
      (* TODO(T47346673): Handle variance on variadics. *)
      module RecordParameters = struct
        type 'annotation record = {
          name: Identifier.t;
          variance: variance;
          state: state;
          namespace: RecordNamespace.t;
        }
        [@@deriving compare, eq, sexp, show, hash]

        module RecordComponents = struct
          type component =
            | KeywordArguments
            | PositionalArguments
          [@@deriving compare, eq, sexp, show, hash]

          type t = {
            component: component;
            variance: variance;
            variable_name: Identifier.t;
            variable_namespace: RecordNamespace.t;
          }
          [@@deriving compare, eq, sexp, show, hash]

          let component_name = function
            | KeywordArguments -> "kwargs"
            | PositionalArguments -> "args"


          let pp_concise format { component; variable_name; _ } =
            Format.fprintf format "%s.%s" variable_name (component_name component)
        end

        let create ?(variance = Invariant) name =
          { name; variance; state = Free { escaped = false }; namespace = 1 }
      end

      module RecordList = struct
        type 'annotation record = {
          name: Identifier.t;
          constraints: 'annotation constraints;
          variance: variance;
          state: state;
          namespace: RecordNamespace.t;
        }
        [@@deriving compare, eq, sexp, show, hash]

        let create ?(constraints = Unconstrained) ?(variance = Invariant) name =
          { name; constraints; variance; state = Free { escaped = false }; namespace = 1 }


        let name { name; _ } = name
      end
    end

    type 'a record =
      | Unary of 'a RecordUnary.record
      | ParameterVariadic of 'a RecordVariadic.RecordParameters.record
      | ListVariadic of 'a RecordVariadic.RecordList.record
    [@@deriving compare, eq, sexp, show, hash]
  end

  module OrderedTypes = struct
    let map_public_name = "pyre_extensions.type_variable_operators.Map"

    let show_type_list types ~pp_type =
      Format.asprintf
        "%a"
        (Format.pp_print_list ~pp_sep:(fun format () -> Format.fprintf format ", ") pp_type)
        types


    module RecordConcatenate = struct
      let public_name = "pyre_extensions.type_variable_operators.Concatenate"

      module Middle = struct
        type 'annotation t = {
          variable: 'annotation Variable.RecordVariadic.RecordList.record;
          mappers: Identifier.t list;
        }
        [@@deriving compare, eq, sexp, show, hash]

        let rec show_concise = function
          | { variable = { name; _ }; mappers = [] } -> name
          | { mappers = head_mapper :: tail_mappers; _ } as mapped ->
              let inner = { mapped with mappers = tail_mappers } in
              Format.asprintf "Map[%s, %s]" head_mapper (show_concise inner)


        let unwrap_if_bare = function
          | { variable; mappers = [] } -> Some variable
          | _ -> None
      end

      type 'annotation wrapping = {
        head: 'annotation list;
        tail: 'annotation list;
      }
      [@@deriving compare, eq, sexp, show, hash]

      type ('middle, 'annotation) t = {
        middle: 'middle;
        wrapping: 'annotation wrapping;
      }
      [@@deriving compare, eq, sexp, show, hash]

      let empty_wrap (middle : 'a Middle.t) = { middle; wrapping = { head = []; tail = [] } }

      let head { wrapping = { head; _ }; _ } = head

      let middle { middle; _ } = middle

      let tail { wrapping = { tail; _ }; _ } = tail

      let unwrap_if_only_middle concatenation =
        Option.some_if
          (List.is_empty (head concatenation) && List.is_empty (tail concatenation))
          (middle concatenation)


      let pp_concatenation format { middle; wrapping } ~pp_type =
        match wrapping with
        | { head = []; tail = [] } -> Format.fprintf format "%s" (Middle.show_concise middle)
        | { head; tail = [] } ->
            Format.fprintf
              format
              "Concatenate[%s, %s]"
              (show_type_list head ~pp_type)
              (Middle.show_concise middle)
        | { head = []; tail } ->
            Format.fprintf
              format
              "Concatenate[%s, %s]"
              (Middle.show_concise middle)
              (show_type_list tail ~pp_type)
        | { head; tail } ->
            Format.fprintf
              format
              "Concatenate[%s, %s, %s]"
              (show_type_list head ~pp_type)
              (Middle.show_concise middle)
              (show_type_list tail ~pp_type)
    end

    type 'annotation record =
      | Concrete of 'annotation list
      | Any
      | Concatenation of ('annotation RecordConcatenate.Middle.t, 'annotation) RecordConcatenate.t
    [@@deriving compare, eq, sexp, show, hash]

    let pp_concise format variable ~pp_type =
      match variable with
      | Concrete types -> Format.fprintf format "%s" (show_type_list types ~pp_type)
      | Any -> Format.fprintf format "..."
      | Concatenation concatenation ->
          Format.fprintf format "%a" (RecordConcatenate.pp_concatenation ~pp_type) concatenation


    let concatenate ~left ~right =
      match left, right with
      | Concrete left, Concrete right -> Some (Concrete (left @ right))
      (* Any can masquerade as the empty list *)
      | other, Any
      | Any, other
      | other, Concrete []
      | Concrete [], other ->
          Some other
      | Concrete left, Concatenation ({ wrapping = { head; tail }; _ } as concatenation) ->
          Some (Concatenation { concatenation with wrapping = { head = left @ head; tail } })
      | Concatenation ({ wrapping = { head; tail }; _ } as concatenation), Concrete right ->
          Some (Concatenation { concatenation with wrapping = { head; tail = tail @ right } })
      | Concatenation _, Concatenation _ -> None
  end

  module Callable = struct
    module RecordParameter = struct
      type 'annotation named = {
        name: Identifier.t;
        annotation: 'annotation;
        default: bool;
      }
      [@@deriving compare, eq, sexp, show, hash]

      type 'annotation variable =
        | Concrete of 'annotation
        | Concatenation of
            ( 'annotation OrderedTypes.RecordConcatenate.Middle.t,
              'annotation )
            OrderedTypes.RecordConcatenate.t
      [@@deriving compare, eq, sexp, show, hash]

      type 'annotation t =
        | Anonymous of {
            index: int;
            annotation: 'annotation;
            default: bool;
          }
        | Named of 'annotation named
        | KeywordOnly of 'annotation named
        | Variable of 'annotation variable
        | Keywords of 'annotation
      [@@deriving compare, eq, sexp, show, hash]

      let equal equal_annotation left right =
        match left, right with
        | Named left, Named right ->
            Bool.equal left.default right.default
            && Identifier.equal (Identifier.sanitized left.name) (Identifier.sanitized right.name)
            && equal_annotation left.annotation right.annotation
        | _ -> equal equal_annotation left right


      let show_concise ~pp_type parameter =
        let print_named ~kind { name; annotation; default } =
          let name = Identifier.sanitized name in
          Format.asprintf
            "%s(%s, %a%s)"
            kind
            name
            pp_type
            annotation
            (if default then ", default" else "")
        in
        match parameter with
        | Anonymous { default; annotation; _ } ->
            Format.asprintf "%a%s" pp_type annotation (if default then ", default" else "")
        | Named named -> print_named ~kind:"Named" named
        | KeywordOnly named -> print_named ~kind:"KeywordOnly" named
        | Variable (Concrete annotation) -> Format.asprintf "Variable(%a)" pp_type annotation
        | Variable (Concatenation concatenation) ->
            Format.asprintf
              "Variable(%a)"
              (OrderedTypes.RecordConcatenate.pp_concatenation ~pp_type)
              concatenation
        | Keywords annotation -> Format.asprintf "Keywords(%a)" pp_type annotation


      let annotation = function
        | Anonymous { annotation; _ } -> Some annotation
        | Named { annotation; _ } -> Some annotation
        | KeywordOnly { annotation; _ } -> Some annotation
        | Variable (Concrete annotation) -> Some annotation
        | Keywords annotation -> Some annotation
        | _ -> None
    end

    type kind =
      | Anonymous
      | Named of Reference.t

    and 'annotation implicit_record = {
      implicit_annotation: 'annotation;
      name: Identifier.t;
    }

    and 'annotation record_parameters =
      | Defined of 'annotation RecordParameter.t list
      | Undefined
      | ParameterVariadicTypeVariable of 'annotation Variable.RecordVariadic.RecordParameters.record

    and 'annotation overload = {
      annotation: 'annotation;
      parameters: 'annotation record_parameters;
      define_location: Location.t option;
    }

    and 'annotation record = {
      kind: kind;
      implementation: 'annotation overload;
      overloads: 'annotation overload list;
      implicit: 'annotation implicit_record option;
    }
    [@@deriving compare, eq, sexp, show, hash]

    let equal_overload equal_annotation left right =
      equal_record_parameters equal_annotation left.parameters right.parameters
      && equal_annotation left.annotation right.annotation


    let _ = equal_record (* suppress warning about unused generated version *)

    let equal_record equal_annotation left right =
      (* Ignores implicit argument to simplify unit tests. *)
      equal_kind left.kind right.kind
      && equal_overload equal_annotation left.implementation right.implementation
      && List.equal (equal_overload equal_annotation) left.overloads right.overloads
  end

  module Parameter = struct
    type 'annotation record =
      | Single of 'annotation
      | Group of 'annotation OrderedTypes.record
    [@@deriving compare, eq, sexp, show, hash]

    let is_single = function
      | Single single -> Some single
      | Group _ -> None
  end
end

open Record.Callable
module CallableParameter = Record.Callable.RecordParameter

module Primitive = struct
  type t = Identifier.t [@@deriving compare, eq, sexp, show, hash]

  include Hashable.Make (struct
    type t = Identifier.t [@@deriving compare, hash, sexp]
  end)

  module Set = Set.Make (struct
    type t = Identifier.t [@@deriving compare, sexp]
  end)
end

module T = struct
  type literal =
    | Boolean of bool
    | Integer of int
    | String of string

  and tuple =
    | Bounded of t Record.OrderedTypes.record
    | Unbounded of t

  and typed_dictionary_field = {
    name: string;
    annotation: t;
  }

  and t =
    | Annotated of t
    | Bottom
    | Callable of t Record.Callable.record
    | Any
    | Literal of literal
    | Optional of t
    | Parametric of {
        name: Identifier.t;
        parameters: t Record.Parameter.record list;
      }
    | ParameterVariadicComponent of
        Record.Variable.RecordVariadic.RecordParameters.RecordComponents.t
    | Primitive of Primitive.t
    | Top
    | Tuple of tuple
    | TypedDictionary of {
        name: Identifier.t;
        fields: typed_dictionary_field list;
        total: bool;
      }
    | Union of t list
    | Variable of t Record.Variable.RecordUnary.record
  [@@deriving compare, eq, sexp, show, hash]
end

include T

let _ = show (* shadowed below *)

type class_data = {
  instantiated: t;
  class_attributes: bool;
  class_name: Primitive.t;
}

type type_t = t [@@deriving compare, eq, sexp, show, hash]

module Map = Map.Make (T)

let default_to_bottom map keys =
  let to_bottom solution key =
    Map.update solution key ~f:(function
        | None -> Bottom
        | Some value -> value)
  in
  List.fold keys ~f:to_bottom ~init:map


module Set = Set.Make (T)
include Hashable.Make (T)

module Parameter = struct
  include Record.Parameter

  type t = type_t record [@@deriving compare, eq, sexp, show, hash]

  let all_singles parameters =
    List.map parameters ~f:(function
        | Single single -> Some single
        | Group _ -> None)
    |> Option.all
end

let is_any = function
  | Any -> true
  | _ -> false


let is_async_iterator = function
  | Parametric { name = "typing.AsyncIterator"; _ } -> true
  | _ -> false


let is_callable = function
  | Callable _ -> true
  | _ -> false


let is_dictionary ?(with_key = None) = function
  | Parametric { name = "dict"; parameters } -> (
      match with_key, parameters with
      | Some key, [Single key_parameter; _] -> equal key key_parameter
      | _ -> true )
  | _ -> false


let is_ellipsis = function
  | Primitive "ellipsis" -> true
  | _ -> false


let is_final = function
  | Parametric { name = "typing.Final" | "typing_extensions.Final"; _ } -> true
  | Primitive ("typing.Final" | "typing_extensions.Final") -> true
  | _ -> false


let is_generator = function
  | Parametric { name = "typing.Generator" | "typing.AsyncGenerator"; _ } -> true
  | _ -> false


let is_generic_primitive = function
  | Primitive "typing.Generic" -> true
  | _ -> false


let is_iterable = function
  | Parametric { name = "typing.Iterable"; _ } -> true
  | _ -> false


let is_iterator = function
  | Parametric { name = "typing.Iterator"; _ } -> true
  | _ -> false


let is_list = function
  | Parametric { name = "list"; _ } -> true
  | _ -> false


let is_meta = function
  | Parametric { name = "type"; _ } -> true
  | _ -> false


let is_none = function
  | Optional Bottom -> true
  | _ -> false


let is_noreturn = function
  | Primitive "typing.NoReturn" -> true
  | _ -> false


let is_object = function
  | Primitive "object" -> true
  | _ -> false


let is_optional = function
  | Optional _ -> true
  | Parametric { name = "typing.Optional" | "Optional"; _ } -> true
  | _ -> false


let is_optional_primitive = function
  | Primitive "typing.Optional" -> true
  | _ -> false


let is_primitive = function
  | Primitive _ -> true
  | _ -> false


let is_top = function
  | Top -> true
  | _ -> false


let is_tuple = function
  | Tuple _ -> true
  | _ -> false


let is_type_alias = function
  | Primitive "typing.TypeAlias" -> true
  | _ -> false


let is_typed_dictionary = function
  | TypedDictionary _ -> true
  | _ -> false


let is_unbound = function
  | Bottom -> true
  | _ -> false


let is_union = function
  | Union _ -> true
  | _ -> false


let reverse_substitute name =
  match name with
  | "collections.defaultdict" -> "typing.DefaultDict"
  | "dict" -> "typing.Dict"
  | "list" -> "typing.List"
  | "set" -> "typing.Set"
  | "type" -> "typing.Type"
  | _ -> name


let pp_parameters ~pp_type format = function
  | [Record.Parameter.Group ordered] ->
      Format.fprintf format "%a" (Record.OrderedTypes.pp_concise ~pp_type) ordered
  | parameters
    when List.for_all parameters ~f:(function
             | Single parameter -> is_unbound parameter || is_top parameter
             | _ -> false) ->
      Format.fprintf format ""
  | parameters ->
      let s format = function
        | Record.Parameter.Single parameter -> Format.fprintf format "%a" pp_type parameter
        | Group ordered_types ->
            Format.fprintf format "[%a]" (Record.OrderedTypes.pp_concise ~pp_type:pp) ordered_types
      in
      Format.pp_print_list ~pp_sep:(fun format () -> Format.fprintf format ", ") s format parameters


let rec pp format annotation =
  match annotation with
  | Annotated annotation -> Format.fprintf format "typing.Annotated[%a]" pp annotation
  | Bottom -> Format.fprintf format "undefined"
  | Callable { kind; implementation; overloads; _ } ->
      let kind =
        match kind with
        | Anonymous -> ""
        | Named name -> Format.asprintf "(%a)" Reference.pp name
      in
      let signature_to_string { annotation; parameters; _ } =
        let parameters =
          match parameters with
          | Undefined -> "..."
          | ParameterVariadicTypeVariable { name; _ } -> name
          | Defined parameters ->
              List.map parameters ~f:(CallableParameter.show_concise ~pp_type:pp)
              |> String.concat ~sep:", "
              |> fun parameters -> Format.asprintf "[%s]" parameters
        in
        Format.asprintf "%s, %a" parameters pp annotation
      in
      let implementation = signature_to_string implementation in
      let overloads =
        let overloads = List.map overloads ~f:signature_to_string in
        if List.is_empty overloads then
          ""
        else
          String.concat ~sep:"][" overloads |> Format.sprintf "[[%s]]"
      in
      Format.fprintf format "typing.Callable%s[%s]%s" kind implementation overloads
  | Any -> Format.fprintf format "typing.Any"
  | Literal (Boolean literal) ->
      Format.fprintf format "typing_extensions.Literal[%s]" (if literal then "True" else "False")
  | Literal (Integer literal) -> Format.fprintf format "typing_extensions.Literal[%d]" literal
  | Literal (String literal) -> Format.fprintf format "typing_extensions.Literal['%s']" literal
  | Optional Bottom -> Format.fprintf format "None"
  | Optional parameter -> Format.fprintf format "typing.Optional[%a]" pp parameter
  | Parametric { name; parameters } ->
      let name = reverse_substitute name in
      Format.fprintf format "%s[%a]" name (pp_parameters ~pp_type:pp) parameters
  | ParameterVariadicComponent component ->
      Record.Variable.RecordVariadic.RecordParameters.RecordComponents.pp_concise format component
  | Primitive name -> Format.fprintf format "%a" String.pp name
  | Top -> Format.fprintf format "unknown"
  | Tuple tuple ->
      let parameters =
        match tuple with
        | Bounded parameters ->
            Format.asprintf "%a" (Record.OrderedTypes.pp_concise ~pp_type:pp) parameters
        | Unbounded parameter -> Format.asprintf "%a, ..." pp parameter
      in
      Format.fprintf format "typing.Tuple[%s]" parameters
  | TypedDictionary { name; fields; total } ->
      let fields =
        fields
        |> List.map ~f:(fun { name; annotation } -> Format.asprintf "%s: %a" name pp annotation)
        |> String.concat ~sep:", "
      in
      let totality = if total then "" else " (non-total)" in
      let name =
        if String.equal name "$anonymous" then
          ""
        else
          Format.sprintf " `%s`" name
      in
      let fields =
        let fields_message = Format.sprintf " with fields (%s)" fields in
        if String.equal name "" then
          fields_message
        else if String.length fields_message < 80 then
          fields_message
        else
          ""
      in
      Format.fprintf format "TypedDict%s%s%s" totality name fields
  | Union parameters ->
      Format.fprintf
        format
        "typing.Union[%s]"
        (List.map parameters ~f:show |> String.concat ~sep:", ")
  | Variable unary -> Record.Variable.RecordUnary.pp_concise format unary ~pp_type:pp


and show annotation = Format.asprintf "%a" pp annotation

let rec pp_concise format annotation =
  let pp_comma_separated =
    Format.pp_print_list ~pp_sep:(fun format () -> Format.fprintf format ", ") pp_concise
  in
  let strip_qualification identifier =
    String.split ~on:'.' identifier |> List.last |> Option.value ~default:identifier
  in
  match annotation with
  | Annotated annotation -> Format.fprintf format "typing.Annotated[%a]" pp_concise annotation
  | Bottom -> Format.fprintf format "?"
  | Callable { implementation; _ } ->
      let signature_to_string { annotation; parameters; _ } =
        let parameters =
          match parameters with
          | Undefined -> "..."
          | ParameterVariadicTypeVariable { name; _ } -> name
          | Defined parameters ->
              let parameter = function
                | CallableParameter.Anonymous { annotation; default; _ } ->
                    if default then
                      Format.asprintf "%a=..." pp_concise annotation
                    else
                      Format.asprintf "%a" pp_concise annotation
                | KeywordOnly { name; annotation; default }
                | Named { name; annotation; default } ->
                    let name = Identifier.sanitized name in
                    if default then
                      Format.asprintf "%s: %a = ..." name pp_concise annotation
                    else
                      Format.asprintf "%s: %a" name pp_concise annotation
                | Variable (Concrete annotation) -> Format.asprintf "*(%a)" pp_concise annotation
                | Variable (Concatenation concatenation) ->
                    Format.asprintf
                      "*(%a)"
                      (Record.OrderedTypes.RecordConcatenate.pp_concatenation ~pp_type:pp_concise)
                      concatenation
                | Keywords annotation -> Format.asprintf "**(%a)" pp_concise annotation
              in
              List.map parameters ~f:parameter |> String.concat ~sep:", "
        in
        Format.asprintf "(%s) -> %a" parameters pp_concise annotation
      in
      Format.fprintf format "%s" (signature_to_string implementation)
  | Any -> Format.fprintf format "Any"
  | Literal (Boolean literal) ->
      Format.fprintf format "typing_extensions.Literal[%s]" (if literal then "True" else "False")
  | Literal (Integer literal) -> Format.fprintf format "typing_extensions.Literal[%d]" literal
  | Literal (String literal) -> Format.fprintf format "typing_extensions.Literal['%s']" literal
  | Optional Bottom -> Format.fprintf format "None"
  | Optional parameter -> Format.fprintf format "Optional[%a]" pp_concise parameter
  | Parametric { name; parameters } ->
      let name = strip_qualification (reverse_substitute name) in
      Format.fprintf format "%s[%a]" name (pp_parameters ~pp_type:pp) parameters
  | ParameterVariadicComponent component ->
      Record.Variable.RecordVariadic.RecordParameters.RecordComponents.pp_concise format component
  | Primitive name -> Format.fprintf format "%s" (strip_qualification name)
  | Top -> Format.fprintf format "unknown"
  | Tuple (Bounded parameters) ->
      Format.fprintf
        format
        "Tuple[%a]"
        (Record.OrderedTypes.pp_concise ~pp_type:pp_concise)
        parameters
  | Tuple (Unbounded parameter) -> Format.fprintf format "Tuple[%a, ...]" pp_concise parameter
  | TypedDictionary { name = "$anonymous"; fields; _ } ->
      let fields =
        fields
        |> List.map ~f:(fun { name; annotation } ->
               Format.asprintf "%s: %a" name pp_concise annotation)
        |> String.concat ~sep:", "
      in
      Format.fprintf format "TypedDict(%s)" fields
  | TypedDictionary { name; _ } -> Format.fprintf format "%s" (strip_qualification name)
  | Union parameters -> Format.fprintf format "Union[%a]" pp_comma_separated parameters
  | Variable { variable; _ } -> Format.fprintf format "%s" (strip_qualification variable)


and show_concise annotation = Format.asprintf "%a" pp_concise annotation

let show_for_hover annotation =
  match annotation with
  | Callable { kind = Named reference; _ } ->
      (* add def [function name] : ... to provide better syntax highlighting for hover *)
      Format.asprintf "def %s%s: ..." (Reference.last reference) (show_concise annotation)
  | _ -> show_concise annotation


let serialize = function
  | Bottom -> "$bottom"
  | annotation -> Format.asprintf "%a" pp annotation


let parametric name parameters = Parametric { name; parameters }

let rec annotated annotation =
  match annotation with
  | Annotated annotation -> annotated annotation
  | _ -> Annotated annotation


let awaitable parameter = Parametric { name = "typing.Awaitable"; parameters = [Single parameter] }

let coroutine parameters = Parametric { name = "typing.Coroutine"; parameters }

let bool = Primitive "bool"

let bytes = Primitive "bytes"

let complex = Primitive "complex"

let dictionary ~key ~value = Parametric { name = "dict"; parameters = [Single key; Single value] }

let enumeration = Primitive "enum.Enum"

let float = Primitive "float"

let number = Primitive "numbers.Number"

let generator ?(async = false) parameter =
  let none = Optional Bottom in
  if async then
    Parametric { name = "typing.AsyncGenerator"; parameters = [Single parameter; Single none] }
  else
    Parametric
      { name = "typing.Generator"; parameters = [Single parameter; Single none; Single none] }


let generic_primitive = Primitive "typing.Generic"

let integer = Primitive "int"

let literal_integer literal = Literal (Integer literal)

let iterable parameter = Parametric { name = "typing.Iterable"; parameters = [Single parameter] }

let iterator parameter = Parametric { name = "typing.Iterator"; parameters = [Single parameter] }

let async_iterator parameter =
  Parametric { name = "typing.AsyncIterator"; parameters = [Single parameter] }


let list parameter = Parametric { name = "list"; parameters = [Single parameter] }

let meta annotation = Parametric { name = "type"; parameters = [Single annotation] }

let named_tuple = Primitive "typing.NamedTuple"

let none = Optional Bottom

let object_primitive = Primitive "object"

let optional parameter =
  match parameter with
  | Top -> Top
  | Optional _ -> parameter
  | _ -> Optional parameter


let sequence parameter = Parametric { name = "typing.Sequence"; parameters = [Single parameter] }

let set parameter = Parametric { name = "set"; parameters = [Single parameter] }

let string = Primitive "str"

let literal_string literal = Literal (String literal)

let tuple parameters = Tuple (Bounded (Concrete parameters))

let undeclared = Primitive "typing.Undeclared"

let union parameters =
  let parameters =
    let rec flattened parameters =
      let flatten sofar = function
        | Union parameters -> flattened parameters @ sofar
        | parameter -> parameter :: sofar
      in
      List.fold ~init:[] ~f:flatten parameters
    in
    let parameters = Set.of_list (flattened parameters) in
    let filter_redundant_annotations sofar annotation =
      match annotation with
      | Optional _ -> annotation :: sofar
      | _ when Set.mem parameters (Optional annotation) -> sofar
      | _ -> annotation :: sofar
    in
    Set.fold ~init:[] ~f:filter_redundant_annotations parameters |> List.sort ~compare
  in
  if List.mem ~equal parameters undeclared then
    Union parameters
  else if List.exists ~f:is_top parameters then
    Top
  else
    let normalize parameters =
      let parameters =
        List.filter parameters ~f:(function parameter -> not (is_unbound parameter))
      in
      match parameters with
      | [] -> Bottom
      | [parameter] -> parameter
      | parameters -> Union parameters
    in
    let extract_optional_parameter = function
      | Optional parameter -> parameter
      | parameter -> parameter
    in
    if List.exists parameters ~f:is_optional then
      parameters
      |> List.filter ~f:(fun parameter -> not (is_none parameter))
      |> List.map ~f:extract_optional_parameter
      |> normalize
      |> fun union -> Optional union
    else
      normalize parameters


let variable ?constraints ?variance name =
  Variable (Record.Variable.RecordUnary.create ?constraints ?variance name)


let yield parameter = Parametric { name = "Yield"; parameters = [Single parameter] }

let parametric_substitution_map =
  [
    "typing.ChainMap", "collections.ChainMap";
    "typing.Counter", "collections.Counter";
    "typing.DefaultDict", "collections.defaultdict";
    "typing.Deque", "collections.deque";
    "typing.Dict", "dict";
    "typing.FrozenSet", "frozenset";
    "typing.List", "list";
    "typing.Set", "set";
    "typing.Type", "type";
    "typing_extensions.Protocol", "typing.Protocol";
    "pyre_extensions.Generic", "typing.Generic";
  ]
  |> Identifier.Table.of_alist_exn


let rec expression annotation =
  let location = Location.any in
  let create_name name = Expression.Name (create_name ~location name) in
  let get_item_call = get_item_call ~location in
  let convert_annotation annotation =
    match annotation with
    | Annotated annotation -> get_item_call "typing.Annotated" [expression annotation]
    | Bottom -> create_name "$bottom"
    | Callable { implementation; overloads; _ } -> (
        let convert_signature { annotation; parameters; _ } =
          let parameters =
            match parameters with
            | Defined parameters ->
                let convert_parameter parameter =
                  let call ?(default = false) ?name kind annotation =
                    let arguments =
                      let annotation = [{ Call.Argument.name = None; value = annotation }] in
                      let default =
                        if default then
                          [
                            {
                              Call.Argument.name = None;
                              value = Node.create ~location (create_name "default");
                            };
                          ]
                        else
                          []
                      in
                      let name =
                        name
                        >>| (fun name ->
                              [
                                {
                                  Call.Argument.name = None;
                                  value = Node.create ~location (create_name name);
                                };
                              ])
                        |> Option.value ~default:[]
                      in
                      name @ annotation @ default
                    in
                    Expression.Call
                      {
                        callee = Node.create ~location (Expression.Name (Name.Identifier kind));
                        arguments;
                      }
                    |> Node.create ~location
                  in
                  match parameter with
                  | CallableParameter.Anonymous { annotation; default; _ } ->
                      call ~default "Anonymous" (expression annotation)
                  | Keywords annotation -> call "Keywords" (expression annotation)
                  | Named { name; annotation; default } ->
                      call ~default ~name "Named" (expression annotation)
                  | KeywordOnly { name; annotation; default } ->
                      call ~default ~name "KeywordOnly" (expression annotation)
                  | Variable (Concrete annotation) -> call "Variable" (expression annotation)
                  | Variable (Concatenation concatenation) ->
                      call "Variable" (concatenation_expression concatenation)
                in
                Expression.List (List.map ~f:convert_parameter parameters) |> Node.create ~location
            | Undefined -> Node.create ~location Expression.Ellipsis
            | ParameterVariadicTypeVariable { name; _ } -> Node.create ~location (create_name name)
          in
          {
            Call.Argument.name = None;
            value = Node.create ~location (Expression.Tuple [parameters; expression annotation]);
          }
        in
        let base_callable =
          Expression.Call
            {
              callee =
                {
                  Node.location;
                  value =
                    Name
                      (Name.Attribute
                         {
                           base = { Node.location; value = create_name "typing.Callable" };
                           attribute = "__getitem__";
                           special = true;
                         });
                };
              arguments = [convert_signature implementation];
            }
        in
        let overloads =
          let convert_overload sofar overload =
            match sofar with
            | None ->
                Expression.Call
                  {
                    callee = { Node.location; value = Name (Name.Identifier "__getitem__") };
                    arguments = [convert_signature overload];
                  }
                |> Node.create ~location
                |> Option.some
            | Some expression ->
                Expression.Call
                  {
                    callee =
                      {
                        Node.location;
                        value =
                          Name
                            (Name.Attribute
                               { base = expression; attribute = "__getitem__"; special = true });
                      };
                    arguments = [convert_signature overload];
                  }
                |> Node.create ~location
                |> Option.some
          in
          List.fold ~init:None ~f:convert_overload overloads
        in
        match overloads with
        | Some overloads ->
            Expression.Call
              {
                callee =
                  {
                    Node.location;
                    value =
                      Name
                        (Name.Attribute
                           {
                             base = { Node.location; value = base_callable };
                             attribute = "__getitem__";
                             special = true;
                           });
                  };
                arguments = [{ Call.Argument.name = None; value = overloads }];
              }
        | None -> base_callable )
    | Any -> create_name "typing.Any"
    | Literal literal ->
        let literal =
          match literal with
          | Boolean true -> Expression.True
          | Boolean false -> Expression.False
          | Integer literal -> Expression.Integer literal
          | String literal -> Expression.String { value = literal; kind = StringLiteral.String }
        in
        get_item_call "typing_extensions.Literal" [Node.create ~location literal]
    | Optional Bottom -> create_name "None"
    | Optional parameter -> get_item_call "typing.Optional" [expression parameter]
    | Parametric { name = "typing.Optional"; parameters = [Single Bottom] } -> create_name "None"
    | Parametric { name; parameters } ->
        let parameters =
          let expression_of_ordered = function
            | Record.OrderedTypes.Any -> [expression (Primitive "...")]
            | Concrete parameters -> List.map ~f:expression parameters
            | Concatenation concatenation -> [concatenation_expression concatenation]
          in
          let expression_of_parameter = function
            | Record.Parameter.Group ordered ->
                Node.create ~location (Expression.List (expression_of_ordered ordered))
            | Single single -> expression single
          in
          match parameters with
          | [Group ordered] -> expression_of_ordered ordered
          | parameters -> List.map parameters ~f:expression_of_parameter
        in
        get_item_call (reverse_substitute name) parameters
    | ParameterVariadicComponent { component; variable_name; _ } ->
        let attribute =
          Record.Variable.RecordVariadic.RecordParameters.RecordComponents.component_name component
        in
        Expression.Name
          (Attribute { base = expression (Primitive variable_name); attribute; special = false })
    | Primitive name -> create_name name
    | Top -> create_name "$unknown"
    | Tuple (Bounded (Concrete [])) ->
        get_item_call "typing.Tuple" [Node.create ~location (Expression.Tuple [])]
    | Tuple elements ->
        let parameters =
          match elements with
          | Bounded Any -> [expression (Primitive "...")]
          | Bounded (Concrete parameters) -> List.map ~f:expression parameters
          | Bounded (Concatenation concatenation) -> [concatenation_expression concatenation]
          | Unbounded parameter -> List.map ~f:expression [parameter; Primitive "..."]
        in
        get_item_call "typing.Tuple" parameters
    | TypedDictionary { name; fields; total } ->
        let argument =
          let tail =
            let field_to_tuple { name; annotation } =
              Node.create_with_default_location
                (Expression.Tuple
                   [
                     Node.create_with_default_location
                       (Expression.String { value = name; kind = StringLiteral.String });
                     expression annotation;
                   ])
            in
            List.map fields ~f:field_to_tuple
          in
          let totality =
            (if total then Expression.True else Expression.False)
            |> Node.create_with_default_location
          in
          Expression.String { value = name; kind = StringLiteral.String }
          |> Node.create_with_default_location
          |> (fun name -> Expression.Tuple (name :: totality :: tail))
          |> Node.create_with_default_location
        in
        get_item_call "mypy_extensions.TypedDict" [argument]
    | Union parameters -> get_item_call "typing.Union" (List.map ~f:expression parameters)
    | Variable { variable; _ } -> create_name variable
  in
  let value =
    match annotation with
    | Primitive "..." -> Expression.Ellipsis
    | _ -> convert_annotation annotation
  in
  Node.create_with_default_location value


and middle_annotation middle =
  let single_wrap ~mapper ~inner =
    Parametric
      {
        name = Record.OrderedTypes.map_public_name;
        parameters = [Single (Primitive mapper); Single inner];
      }
  in
  match middle with
  | { Record.OrderedTypes.RecordConcatenate.Middle.variable = { name; _ }; mappers = [] } ->
      Primitive name
  | { mappers = head_mapper :: tail_mappers; _ } ->
      let inner = { middle with mappers = tail_mappers } in
      single_wrap ~mapper:head_mapper ~inner:(middle_annotation inner)


and concatenation_expression { middle; wrapping } =
  let concatenation_annotation =
    let middle_annotation = middle_annotation middle in
    match wrapping with
    | { head = []; tail = [] } -> middle_annotation
    | { head; tail } ->
        let concretes = head @ (middle_annotation :: tail) in
        Parametric
          {
            name = Record.OrderedTypes.RecordConcatenate.public_name;
            parameters = List.map concretes ~f:(fun concrete -> Record.Parameter.Single concrete);
          }
  in
  concatenation_annotation |> expression


module Transform = struct
  type 'state visit_result = {
    transformed_annotation: t;
    new_state: 'state;
  }

  module type Transformer = sig
    type state

    val visit : state -> t -> state visit_result

    val visit_children_before : state -> t -> bool

    val visit_children_after : bool
  end

  module Make (Transformer : Transformer) = struct
    let rec visit_annotation ~state annotation =
      let visit_children annotation =
        let visit_all = List.map ~f:(visit_annotation ~state) in
        let visit_concatenation
            { Record.OrderedTypes.RecordConcatenate.middle; wrapping = { head; tail } }
          =
          let wrapping =
            {
              Record.OrderedTypes.RecordConcatenate.head =
                List.map head ~f:(visit_annotation ~state);
              tail = List.map tail ~f:(visit_annotation ~state);
            }
          in
          { Record.OrderedTypes.RecordConcatenate.middle; wrapping }
        in
        let visit_ordered_types ordered_types =
          match ordered_types with
          | Record.OrderedTypes.Any -> ordered_types
          | Concrete concretes -> Concrete (visit_all concretes)
          | Concatenation concatenation -> Concatenation (visit_concatenation concatenation)
        in
        match annotation with
        | Annotated annotation -> Annotated (visit_annotation annotation ~state)
        | Callable ({ implementation; overloads; _ } as callable) ->
            let open Record.Callable in
            let visit_overload ({ annotation; parameters; _ } as overload) =
              let visit_parameters parameter =
                let visit_defined = function
                  | RecordParameter.Named ({ annotation; _ } as named) ->
                      RecordParameter.Named
                        { named with annotation = visit_annotation annotation ~state }
                  | RecordParameter.KeywordOnly ({ annotation; _ } as named) ->
                      RecordParameter.KeywordOnly
                        { named with annotation = visit_annotation annotation ~state }
                  | RecordParameter.Variable (Concrete annotation) ->
                      RecordParameter.Variable (Concrete (visit_annotation annotation ~state))
                  | RecordParameter.Variable (Concatenation concatenation) ->
                      Variable (Concatenation (visit_concatenation concatenation))
                  | RecordParameter.Keywords annotation ->
                      RecordParameter.Keywords (visit_annotation annotation ~state)
                  | RecordParameter.Anonymous ({ annotation; _ } as anonymous) ->
                      RecordParameter.Anonymous
                        { anonymous with annotation = visit_annotation annotation ~state }
                in
                match parameter with
                | Defined defined -> Defined (List.map defined ~f:visit_defined)
                | parameter -> parameter
              in
              {
                overload with
                annotation = visit_annotation annotation ~state;
                parameters = visit_parameters parameters;
              }
            in
            Callable
              {
                callable with
                implementation = visit_overload implementation;
                overloads = List.map overloads ~f:visit_overload;
              }
        | Optional annotation -> optional (visit_annotation annotation ~state)
        | Parametric { name; parameters } ->
            let visit = function
              | Record.Parameter.Group ordered ->
                  Record.Parameter.Group (visit_ordered_types ordered)
              | Single single -> Single (visit_annotation single ~state)
            in
            Parametric { name; parameters = List.map parameters ~f:visit }
        | Tuple (Bounded ordered) -> Tuple (Bounded (visit_ordered_types ordered))
        | Tuple (Unbounded annotation) -> Tuple (Unbounded (visit_annotation annotation ~state))
        | TypedDictionary ({ fields; _ } as typed_dictionary) ->
            let visit_field ({ annotation; _ } as field) =
              { field with annotation = visit_annotation annotation ~state }
            in
            TypedDictionary { typed_dictionary with fields = List.map fields ~f:visit_field }
        | Union annotations -> union (List.map annotations ~f:(visit_annotation ~state))
        | Variable ({ constraints; _ } as variable) ->
            let constraints =
              match constraints with
              | Record.Variable.Bound bound -> Record.Variable.Bound (visit_annotation bound ~state)
              | Explicit constraints -> Explicit (List.map constraints ~f:(visit_annotation ~state))
              | Unconstrained -> Unconstrained
              | LiteralIntegers -> LiteralIntegers
            in
            Variable { variable with constraints }
        | ParameterVariadicComponent _
        | Literal _
        | Bottom
        | Top
        | Any
        | Primitive _ ->
            annotation
      in
      let annotation =
        if Transformer.visit_children_before !state annotation then
          visit_children annotation
        else
          annotation
      in
      let { transformed_annotation; new_state } = Transformer.visit !state annotation in
      state := new_state;
      if Transformer.visit_children_after then
        visit_children transformed_annotation
      else
        transformed_annotation


    let visit state annotation =
      let state = ref state in
      let transformed_annotation = visit_annotation ~state annotation in
      !state, transformed_annotation
  end
end

let exists annotation ~predicate =
  let module ExistsTransform = Transform.Make (struct
    type state = bool

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit sofar annotation =
      let new_state = sofar || predicate annotation in
      { Transform.transformed_annotation = annotation; new_state }
  end)
  in
  fst (ExistsTransform.visit false annotation)


let is_unknown annotation = exists annotation ~predicate:is_top

let is_undeclared annotation = exists annotation ~predicate:(equal undeclared)

let pp_type = pp

module Callable = struct
  module Parameter = struct
    include Record.Callable.RecordParameter

    type parameter = type_t t [@@deriving compare, eq, sexp, show, hash]

    module Map = Core.Map.Make (struct
      type t = parameter [@@deriving compare, sexp]
    end)

    let create parameters =
      let parameter index (keyword_only, sofar) { name; annotation; default } =
        if String.equal (Identifier.sanitized name) "*" then
          true, sofar
        else
          let star, name = Identifier.split_star name in
          let keyword_only = keyword_only || Identifier.equal star "*" in
          let new_parameter =
            match star with
            | "**" -> Keywords annotation
            | "*" -> Variable (Concrete annotation)
            | _ ->
                let sanitized = Identifier.sanitized name in
                if
                  String.is_prefix sanitized ~prefix:"__"
                  && not (String.is_suffix sanitized ~suffix:"__")
                then
                  CallableParameter.Anonymous { index; annotation; default }
                else
                  let named = { name; annotation; default } in
                  if keyword_only then
                    KeywordOnly named
                  else
                    Named named
          in
          keyword_only, new_parameter :: sofar
      in
      List.foldi parameters ~f:parameter ~init:(false, []) |> snd |> List.rev


    let show_concise = show_concise ~pp_type

    let default = function
      | Anonymous { default; _ }
      | KeywordOnly { default; _ }
      | Named { default; _ } ->
          default
      | Keywords _
      | Variable _ ->
          false


    let names_compatible left right =
      match left, right with
      | Variable _, Variable _
      | Keywords _, Keywords _
      | _, Anonymous _
      | Anonymous _, _ ->
          true
      | Named { name = left; _ }, Named { name = right; _ } ->
          let left = Identifier.sanitized left in
          let right = Identifier.sanitized right in
          let left = Identifier.remove_leading_underscores left in
          let right = Identifier.remove_leading_underscores right in
          Identifier.equal left right
      | _ -> false
  end

  include Record.Callable

  type implicit = type_t Record.Callable.implicit_record [@@deriving compare, eq, sexp, show, hash]

  type t = type_t Record.Callable.record [@@deriving compare, eq, sexp, show, hash]

  type parameters = type_t Record.Callable.record_parameters
  [@@deriving compare, eq, sexp, show, hash]

  module Overload = struct
    let parameters { parameters; _ } =
      match parameters with
      | Defined parameters -> Some parameters
      | ParameterVariadicTypeVariable _
      | Undefined ->
          None


    let return_annotation { annotation; _ } = annotation

    let is_undefined { parameters; annotation; _ } =
      match parameters with
      | Undefined -> is_unknown annotation
      | _ -> false
  end

  let from_overloads overloads =
    match overloads with
    | ({ kind = Named _; _ } as initial) :: overloads ->
        let fold sofar signature =
          match sofar, signature with
          | Some sofar, { kind; implementation; overloads; implicit } ->
              if equal_kind kind sofar.kind then
                Some { kind; implementation; overloads = sofar.overloads @ overloads; implicit }
              else
                None
          | _ -> None
        in
        List.fold ~init:(Some initial) ~f:fold overloads
    | _ -> None


  let map callable ~f =
    Callable callable
    |> f
    |> function
    | Callable callable -> Some callable
    | _ -> None


  let map_implementation implementation ~f =
    map { kind = Anonymous; implementation; overloads = []; implicit = None } ~f
    |> function
    | Some { implementation; _ } -> implementation
    | _ -> failwith "f did not return a callable"


  let map_parameters ({ implementation; overloads; _ } as callable) ~f =
    let for_implementation ({ parameters; _ } as implementation) =
      { implementation with parameters = f parameters }
    in
    {
      callable with
      implementation = for_implementation implementation;
      overloads = List.map overloads ~f:for_implementation;
    }


  let with_return_annotation ({ implementation; overloads; _ } as initial) ~annotation =
    let re_annotate implementation = { implementation with annotation } in
    {
      initial with
      implementation = re_annotate implementation;
      overloads = List.map ~f:re_annotate overloads;
    }


  let create ?name ?(overloads = []) ?(parameters = Undefined) ?implicit ~annotation () =
    let kind = name >>| (fun name -> Named name) |> Option.value ~default:Anonymous in
    Callable
      {
        kind;
        implementation = { annotation; parameters; define_location = None };
        overloads;
        implicit;
      }


  let create_from_implementation implementation =
    create ~parameters:implementation.parameters ~annotation:implementation.annotation ()
end

let lambda ~parameters ~return_annotation =
  let parameters =
    List.map parameters ~f:(fun (name, annotation) ->
        { CallableParameter.name; annotation; default = false })
    |> Callable.Parameter.create
  in
  Callable
    {
      kind = Anonymous;
      implementation =
        { annotation = return_annotation; parameters = Defined parameters; define_location = None };
      overloads = [];
      implicit = None;
    }


let primitive_substitution_map =
  [
    "$bottom", Bottom;
    "$unknown", Top;
    "None", none;
    "function", Callable.create ~annotation:Any ();
    "tuple", Tuple (Unbounded Any);
    "typing.Any", Any;
    "typing.Callable", Callable.create ~annotation:Any ();
    "typing.ChainMap", Primitive "collections.ChainMap";
    "typing.Counter", Primitive "collections.Counter";
    "typing.DefaultDict", Primitive "collections.defaultdict";
    "typing.Deque", Primitive "collections.deque";
    "typing.Dict", Primitive "dict";
    "typing.List", Primitive "list";
    "typing.Tuple", Tuple (Unbounded Any);
    "typing.Type", Primitive "type";
    "typing_extensions.Protocol", Primitive "typing.Protocol";
    (* This is broken in typeshed:
       https://github.com/python/typeshed/pull/991#issuecomment-288160993 *)
    "PathLike", Primitive "_PathLike";
    "TSelf", variable "_PathLike";
  ]
  |> Identifier.Table.of_alist_exn


let primitive_name = function
  | Primitive name -> Some name
  | _ -> None


let create_concatenation_operator_from_annotation annotation ~variable_aliases =
  let create_map_operator_from_annotation annotation =
    match annotation with
    | Parametric
        {
          name;
          parameters = [Single (Primitive left_parameter); Group (Concatenation right_parameter)];
        }
      when Identifier.equal name Record.OrderedTypes.map_public_name ->
        let open Record.OrderedTypes.RecordConcatenate in
        unwrap_if_only_middle right_parameter
        >>= Middle.unwrap_if_bare
        >>| fun variable ->
        { Record.OrderedTypes.RecordConcatenate.Middle.variable; mappers = [left_parameter] }
    | _ -> None
  in
  match annotation with
  | Parametric { name; parameters } -> (
      match Identifier.equal name Record.OrderedTypes.RecordConcatenate.public_name with
      | true -> (
          let parse_as_middle = function
            | Record.Parameter.Group (Concatenation potential_middle) ->
                let open Record.OrderedTypes.RecordConcatenate in
                unwrap_if_only_middle potential_middle
            | Group (Concrete _)
            | Group Any ->
                None
            | Record.Parameter.Single potentially_a_map ->
                create_map_operator_from_annotation potentially_a_map
          in
          let parameter_to_parsed =
            List.map parameters ~f:(fun parameter ->
                Record.Parameter.is_single parameter, parse_as_middle parameter)
          in
          let head, middle_and_tail =
            List.split_while parameter_to_parsed ~f:(fun (_, parsed) -> Option.is_none parsed)
          in
          let middle, tail =
            List.split_while middle_and_tail ~f:(fun (_, parsed) -> Option.is_some parsed)
          in
          let fsts = List.map ~f:fst in
          let head = fsts head in
          let tail = fsts tail in
          match Option.all head, middle, Option.all tail with
          | Some head, [(_, Some middle)], Some tail ->
              Some { Record.OrderedTypes.RecordConcatenate.middle; wrapping = { head; tail } }
          | _ -> None )
      | _ ->
          create_map_operator_from_annotation annotation
          >>| fun map -> Record.OrderedTypes.RecordConcatenate.empty_wrap map )
  | Primitive name -> (
      match variable_aliases name with
      | Some (Record.Variable.ListVariadic variable) ->
          Some
            (Record.OrderedTypes.RecordConcatenate.empty_wrap
               { Record.OrderedTypes.RecordConcatenate.Middle.variable; mappers = [] })
      | _ -> None )
  | _ -> None


type alias =
  | TypeAlias of t
  | VariableAlias of t Record.Variable.record
[@@deriving compare, eq, sexp, show, hash]

let rec create_logic ~aliases ~variable_aliases { Node.value = expression; _ } =
  let substitute_ordered_types = function
    | Primitive "..." -> Some Record.OrderedTypes.Any
    | parameter ->
        create_concatenation_operator_from_annotation parameter ~variable_aliases
        >>| fun concatenation -> Record.OrderedTypes.Concatenation concatenation
  in
  let result =
    let create_logic = create_logic ~aliases ~variable_aliases in
    let resolve_aliases annotation =
      let visited = Hash_set.create () in
      let module ResolveTransform = Transform.Make (struct
        type state = unit

        let visit_children_before _ _ = false

        let visit_children_after = true

        let visit _ annotation =
          let rec resolve annotation =
            if Core.Hash_set.mem visited annotation then
              annotation
            else (
              Core.Hash_set.add visited annotation;
              match aliases annotation, annotation with
              | Some aliased, _ ->
                  (* We need to fully resolve aliases to aliases before we go on to resolve the
                     aliases those may contain *)
                  resolve aliased
              | None, Parametric { name; parameters } -> (
                  let annotation = resolve (Primitive name) in
                  match annotation with
                  | Primitive name -> parametric name parameters
                  | Parametric { name; _ } ->
                      (* TODO(T44787675): Implement actual generic aliases *)
                      parametric name parameters
                  | Union elements ->
                      (* TODO(T44787675): Implement actual generic aliases *)
                      let replace_parameters = function
                        | Parametric { name; _ } -> parametric name parameters
                        | annotation -> annotation
                      in
                      Union (List.map elements ~f:replace_parameters)
                  | _ ->
                      (* This should probably error or something *)
                      parametric name parameters )
              | _ -> annotation )
          in
          let transformed_annotation = resolve annotation in
          { Transform.transformed_annotation; new_state = () }
      end)
      in
      snd (ResolveTransform.visit () annotation)
    in
    let rec is_typing_callable = function
      | Expression.Name
          (Name.Attribute
            {
              base = { Node.value = Name (Name.Identifier "typing"); _ };
              attribute = "Callable";
              _;
            }) ->
          true
      | Name (Name.Attribute { base; _ }) -> is_typing_callable (Node.value base)
      | Call { callee; _ } -> is_typing_callable (Node.value callee)
      | _ -> false
    in
    let parse_callable expression =
      let modifiers, implementation_signature, overload_signatures =
        let get_from_base base implementation_argument overloads_argument =
          match Node.value base with
          | Expression.Call { callee; arguments } when name_is ~name:"typing.Callable" callee ->
              Some arguments, implementation_argument, overloads_argument
          | Name
              (Name.Attribute
                {
                  base = { Node.value = Name (Name.Identifier "typing"); _ };
                  attribute = "Callable";
                  _;
                }) ->
              None, implementation_argument, overloads_argument
          | _ ->
              (* Invalid base. *)
              None, None, None
        in
        match expression with
        | Expression.Call
            {
              callee =
                {
                  Node.value =
                    Name
                      (Name.Attribute
                        {
                          base =
                            {
                              Node.value =
                                Call
                                  {
                                    callee =
                                      {
                                        Node.value =
                                          Name
                                            (Name.Attribute { base; attribute = "__getitem__"; _ });
                                        _;
                                      };
                                    arguments = [{ Call.Argument.value = argument; _ }];
                                  };
                              _;
                            };
                          attribute = "__getitem__";
                          _;
                        });
                  _;
                };
              arguments = [{ Call.Argument.value = overloads_argument; _ }];
            } ->
            (* Overloads are provided *)
            get_from_base base (Some argument) (Some overloads_argument)
        | Call
            {
              callee =
                { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
              arguments = [{ Call.Argument.value = argument; _ }];
            } ->
            (* No overloads provided *)
            get_from_base base (Some argument) None
        | _ -> None, None, None
      in
      let kind =
        match modifiers with
        | Some
            ({
               Call.Argument.value =
                 { Node.value = Expression.String { StringLiteral.value; _ }; _ };
               _;
             }
            :: _) ->
            Named (Reference.create value)
        | _ -> Anonymous
      in
      let undefined = { annotation = Top; parameters = Undefined; define_location = None } in
      let get_signature = function
        | Expression.Tuple [parameters; annotation] ->
            let parameters =
              let parse_as_variadic parsed_parameter =
                create_concatenation_operator_from_annotation parsed_parameter ~variable_aliases
                >>| fun concatenation -> CallableParameter.Concatenation concatenation
              in
              let extract_parameter index parameter =
                match Node.value parameter with
                | Expression.Call
                    { callee = { Node.value = Name (Name.Identifier name); _ }; arguments } -> (
                    let arguments =
                      List.map arguments ~f:(fun { Call.Argument.value; _ } -> Node.value value)
                    in
                    match name, arguments with
                    | "Anonymous", annotation :: tail ->
                        let default =
                          match tail with
                          | [Name (Name.Identifier "default")] -> true
                          | _ -> false
                        in
                        CallableParameter.Anonymous
                          {
                            index;
                            annotation = create_logic (Node.create_with_default_location annotation);
                            default;
                          }
                    | "Named", Name (Name.Identifier name) :: annotation :: tail ->
                        let default =
                          match tail with
                          | [Name (Name.Identifier "default")] -> true
                          | _ -> false
                        in
                        Named
                          {
                            name;
                            annotation = create_logic (Node.create_with_default_location annotation);
                            default;
                          }
                    | "KeywordOnly", Name (Name.Identifier name) :: annotation :: tail ->
                        let default =
                          match tail with
                          | [Name (Name.Identifier "default")] -> true
                          | _ -> false
                        in
                        KeywordOnly
                          {
                            name;
                            annotation = create_logic (Node.create_with_default_location annotation);
                            default;
                          }
                    | "Variable", tail ->
                        let annotation =
                          match tail with
                          | annotation :: _ ->
                              create_logic (Node.create_with_default_location annotation)
                          | _ -> Top
                        in
                        parse_as_variadic annotation
                        |> Option.value ~default:(CallableParameter.Concrete annotation)
                        |> fun variable -> CallableParameter.Variable variable
                    | "Keywords", tail ->
                        let annotation =
                          match tail with
                          | annotation :: _ ->
                              create_logic (Node.create_with_default_location annotation)
                          | _ -> Top
                        in
                        Keywords annotation
                    | _ -> Anonymous { index; annotation = Top; default = false } )
                | _ -> Anonymous { index; annotation = create_logic parameter; default = false }
              in
              match Node.value parameters with
              | List parameters -> Defined (List.mapi ~f:extract_parameter parameters)
              | _ -> (
                  match variable_aliases (Expression.show parameters) with
                  | Some (Record.Variable.ParameterVariadic variable) ->
                      ParameterVariadicTypeVariable variable
                  | _ -> (
                      match parse_as_variadic (create_logic parameters) with
                      | Some variadic -> Defined [CallableParameter.Variable variadic]
                      | None -> Undefined ) )
            in
            { annotation = create_logic annotation; parameters; define_location = None }
        | _ -> undefined
      in
      let implementation =
        match implementation_signature with
        | Some signature -> get_signature (Node.value signature)
        | None -> undefined
      in
      let overloads =
        let rec parse_overloads = function
          | Expression.List arguments -> [get_signature (Tuple arguments)]
          | Call
              {
                callee = { Node.value = Name (Name.Identifier "__getitem__"); _ };
                arguments = [{ Call.Argument.value = argument; _ }];
              } ->
              [get_signature (Node.value argument)]
          | Call
              {
                callee =
                  { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
                arguments = [{ Call.Argument.value = argument; _ }];
              } ->
              get_signature (Node.value argument) :: parse_overloads (Node.value base)
          | _ -> [undefined]
        in
        match overload_signatures with
        | Some signatures -> List.rev (parse_overloads (Node.value signatures))
        | None -> []
      in
      Callable { kind; implementation; overloads; implicit = None }
    in
    match expression with
    | Call
        {
          callee;
          arguments =
            { Call.Argument.value = { Node.value = String { StringLiteral.value; _ }; _ }; _ }
            :: arguments;
        }
      when name_is ~name:"typing.TypeVar" callee ->
        let constraints =
          let explicits =
            let explicit = function
              | { Call.Argument.name = None; value } -> Some (create_logic value)
              | _ -> None
            in
            List.filter_map ~f:explicit arguments
          in
          let bound =
            let bound = function
              | { Call.Argument.value; name = Some { Node.value = bound; _ } }
                when String.equal (Identifier.sanitized bound) "bound" ->
                  Some (create_logic value)
              | _ -> None
            in
            List.find_map ~f:bound arguments
          in
          if not (List.is_empty explicits) then
            Record.Variable.Explicit explicits
          else if Option.is_some bound then
            Bound (Option.value_exn bound)
          else
            Unconstrained
        in
        let variance =
          let variance_definition = function
            | {
                Call.Argument.name = Some { Node.value = name; _ };
                value = { Node.value = True; _ };
              }
              when String.equal (Identifier.sanitized name) "covariant" ->
                Some Record.Variable.Covariant
            | {
                Call.Argument.name = Some { Node.value = name; _ };
                value = { Node.value = True; _ };
              }
              when String.equal (Identifier.sanitized name) "contravariant" ->
                Some Contravariant
            | _ -> None
          in
          List.find_map arguments ~f:variance_definition
          |> Option.value ~default:Record.Variable.Invariant
        in
        variable value ~constraints ~variance
    | Call
        {
          callee;
          arguments =
            [{ Call.Argument.value = { Node.value = String { StringLiteral.value; _ }; _ }; _ }];
        }
      when name_is ~name:"typing_extensions.IntVar" callee ->
        variable value ~constraints:LiteralIntegers
    | Call
        {
          callee;
          arguments =
            [
              {
                Call.Argument.name = None;
                value =
                  {
                    Node.value =
                      Expression.Tuple
                        ({ Node.value = Expression.String { value = typed_dictionary_name; _ }; _ }
                        :: { Node.value = true_or_false; _ } :: fields);
                    _;
                  };
              };
            ];
        }
      when name_is ~name:"mypy_extensions.TypedDict.__getitem__" callee ->
        let total =
          match true_or_false with
          | Expression.True -> Some true
          | Expression.False -> Some false
          | _ -> None
        in
        let parse_typed_dictionary total =
          let fields =
            let tuple_to_field = function
              | {
                  Node.value =
                    Expression.Tuple
                      [
                        { Node.value = Expression.String { value = field_name; _ }; _ };
                        field_annotation;
                      ];
                  _;
                } ->
                  Some { name = field_name; annotation = create_logic field_annotation }
              | _ -> None
            in
            fields |> List.filter_map ~f:tuple_to_field
          in
          TypedDictionary { name = typed_dictionary_name; fields; total }
        in
        let undefined_primitive =
          Primitive (Expression.show (Node.create_with_default_location expression))
        in
        total >>| parse_typed_dictionary |> Option.value ~default:undefined_primitive
    | Call { callee; arguments } when name_is ~name:"typing_extensions.Literal.__getitem__" callee
      ->
        let arguments =
          match arguments with
          | [{ Call.Argument.name = None; value = { Node.value = Expression.Tuple arguments; _ } }]
            ->
              Some (List.map arguments ~f:Node.value)
          | [{ Call.Argument.name = None; value = { Node.value = argument; _ } }] -> Some [argument]
          | _ -> None
        in
        let parse = function
          | Expression.True -> Some (Literal (Boolean true))
          | Expression.False -> Some (Literal (Boolean false))
          | Expression.Integer literal -> Some (literal_integer literal)
          | Expression.String { StringLiteral.kind = StringLiteral.String; value } ->
              Some (literal_string value)
          | _ -> None
        in
        arguments >>| List.map ~f:parse >>= Option.all >>| union |> Option.value ~default:Top
    | Call { callee = { Node.value = callee; _ }; _ } when is_typing_callable callee ->
        parse_callable expression
    | Call
        {
          callee = { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
          arguments = [{ Call.Argument.value = argument; _ }];
        } -> (
        let parametric name =
          let parameters =
            let parse_parameter = function
              | { Node.value = Expression.List elements; _ } ->
                  let concrete = List.map elements ~f:create_logic in
                  Record.Parameter.Group (Concrete concrete)
              | element ->
                  let parsed = create_logic element in
                  substitute_ordered_types parsed
                  >>| (fun ordered -> Record.Parameter.Group ordered)
                  |> Option.value ~default:(Record.Parameter.Single parsed)
            in
            match argument with
            | { Node.value = Expression.Tuple elements; _ } -> List.map elements ~f:parse_parameter
            | element -> [parse_parameter element]
          in
          Parametric { name; parameters } |> resolve_aliases
        in
        match create_logic base, Node.value base with
        | Primitive name, _ -> parametric name
        | _, Name _ -> parametric (Expression.show base)
        | _ -> Top )
    | Name (Name.Identifier identifier) ->
        let sanitized = Identifier.sanitized identifier in
        if String.equal sanitized "None" then
          none
        else
          Primitive sanitized |> resolve_aliases
    | Name (Name.Attribute { base; attribute; _ }) -> (
        let attribute = Identifier.sanitized attribute in
        match create_logic base with
        | Primitive primitive -> Primitive (primitive ^ "." ^ attribute) |> resolve_aliases
        | _ -> Primitive (Expression.show base ^ "." ^ attribute) )
    | Ellipsis -> Primitive "..."
    | String { StringLiteral.value; _ } ->
        let expression =
          try
            let parsed =
              Parser.parse [value] |> Source.create |> Preprocessing.preprocess |> Source.statements
            in
            match parsed with
            | [{ Node.value = Expression { Node.value; _ }; _ }] -> Some value
            | _ -> None
          with
          | _ -> None
        in
        expression
        >>| Node.create_with_default_location
        >>| create_logic
        |> Option.value ~default:(Primitive value)
    | _ -> Top
  in
  (* Substitutions. *)
  match result with
  | Primitive name -> (
      match Identifier.Table.find primitive_substitution_map name with
      | Some substitute -> substitute
      | None -> result )
  | Parametric { name = "typing.Tuple"; parameters }
  | Parametric { name = "tuple"; parameters } -> (
      match parameters with
      | [Single parameter; Group Any] -> Tuple (Unbounded parameter)
      | [Group group] -> Tuple (Bounded group)
      | parameters ->
          Parameter.all_singles parameters
          >>| (fun singles -> Tuple (Bounded (Concrete singles)))
          |> Option.value ~default:Top )
  | Parametric { name; parameters } -> (
      match
        Identifier.Table.find parametric_substitution_map name, Parameter.all_singles parameters
      with
      | Some name, _ -> Parametric { name; parameters }
      | None, Some parameters -> (
          match name with
          | "typing_extensions.Annotated"
          | "typing.Annotated"
            when List.length parameters > 0 ->
              annotated (List.hd_exn parameters)
          | "typing.Optional" when List.length parameters = 1 -> optional (List.hd_exn parameters)
          | "typing.Union" -> union parameters
          | _ -> result )
      | _, None -> result )
  | Union elements -> union elements
  | _ -> result


let create ~aliases =
  let variable_aliases name =
    match aliases name with
    | Some (VariableAlias variable) -> Some variable
    | _ -> None
  in
  let aliases = function
    | Primitive name -> (
        match aliases name with
        | Some (TypeAlias alias) -> Some alias
        | _ -> None )
    | _ -> None
  in
  create_logic ~aliases ~variable_aliases


let contains_callable annotation = exists annotation ~predicate:is_callable

let contains_any annotation = exists annotation ~predicate:is_any

let contains_unknown annotation = exists annotation ~predicate:is_unknown

module LiteralAnyVisitor = struct
  module Visitor = struct
    type t = bool

    let node state = function
      | Visit.Expression { Node.value = Name name; _ } ->
          let is_any =
            name_to_reference name
            >>| Reference.show
            >>| String.equal "typing.Any"
            |> Option.value ~default:false
          in
          state || is_any
      | _ -> state
  end

  include Visit.MakeNodeVisitor (Visitor)

  let expression_contains_any expression =
    let state =
      (* We also want to take into account annotations like `list`, `dict`, etc. *)
      match Node.value expression with
      | Expression.Name name when is_simple_name name ->
          name_to_reference_exn name
          |> Reference.show
          |> Hashtbl.find primitive_substitution_map
          |> Option.value_map ~default:false ~f:contains_any
          |> fun state -> ref state
      | _ -> ref false
    in
    visit_expression ~state expression;
    !state
end

(* Check if there is a literal Any provided, not including type aliases to Any. *)
let expression_contains_any = LiteralAnyVisitor.expression_contains_any

let is_not_instantiated annotation =
  let predicate = function
    | Bottom -> true
    | Variable { constraints = Unconstrained; _ } -> true
    | _ -> false
  in
  exists annotation ~predicate


let contains_literal annotation =
  let predicate = function
    | Literal _ -> true
    | _ -> false
  in
  exists annotation ~predicate


let contains_final annotation = exists annotation ~predicate:is_final

let collect annotation ~predicate =
  let module CollectorTransform = Transform.Make (struct
    type state = t list

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit sofar annotation =
      let new_state = if predicate annotation then sofar @ [annotation] else sofar in
      { Transform.transformed_annotation = annotation; new_state }
  end)
  in
  fst (CollectorTransform.visit [] annotation)


let primitives annotation =
  let predicate = function
    | Primitive _ -> true
    | _ -> false
  in
  collect annotation ~predicate


let elements annotation =
  let module CollectorTransform = Transform.Make (struct
    type state = Primitive.t list

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit sofar annotation =
      let new_state =
        match annotation with
        | Annotated _ -> "typing.Annotated" :: sofar
        | Callable _ -> "typing.Callable" :: sofar
        | Literal _ -> "typing_extensions.Literal" :: sofar
        | Optional _ -> "typing.Optional" :: sofar
        | Parametric { name; _ } -> name :: sofar
        | Primitive annotation -> annotation :: sofar
        | Tuple _ -> "tuple" :: sofar
        | TypedDictionary _ -> "TypedDictionary" :: sofar
        | Union _ -> "typing.Union" :: sofar
        | ParameterVariadicComponent _
        | Bottom
        | Any
        | Top
        | Variable _ ->
            sofar
      in
      { Transform.transformed_annotation = annotation; new_state }
  end)
  in
  fst (CollectorTransform.visit [] annotation) |> List.rev


let is_untyped = function
  | Any
  | Bottom
  | Top ->
      true
  | _ -> false


let is_partially_typed annotation = exists annotation ~predicate:is_untyped

let is_variable = function
  | Variable _ -> true
  | _ -> false


let contains_variable = exists ~predicate:is_variable

let optional_value = function
  | Optional annotation -> Some annotation
  | _ -> None


let async_generator_value = function
  | Parametric { name = "typing.AsyncGenerator"; parameters = [Single parameter; _] } ->
      Some (generator parameter)
  | _ -> None


let awaitable_value = function
  | Parametric { name = "typing.Awaitable"; parameters = [Single parameter] } -> Some parameter
  | _ -> None


let coroutine_value = function
  | Parametric { name = "typing.Coroutine"; parameters = [_; _; Single parameter] } ->
      Some parameter
  | _ -> None


let parameters = function
  | Parametric { parameters; _ } -> Some parameters
  | _ -> None


let single_parameter = function
  | Parametric { parameters = [Single parameter]; _ } -> parameter
  | _ -> failwith "Type does not have single parameter"


let instantiate ?(widen = false) ?(visit_children_before = false) annotation ~constraints =
  let module InstantiateTransform = Transform.Make (struct
    type state = unit

    let visit_children_before _ annotation =
      visit_children_before || constraints annotation |> Option.is_none


    let visit_children_after = false

    let visit _ annotation =
      let transformed_annotation =
        match constraints annotation with
        | Some Bottom when widen -> Top
        | Some replacement -> replacement
        | None -> annotation
      in
      { Transform.transformed_annotation; new_state = () }
  end)
  in
  snd (InstantiateTransform.visit () annotation)


let weaken_literals annotation =
  let constraints = function
    | Literal (Integer _) -> Some integer
    | Literal (String _) -> Some string
    | Literal (Boolean _) -> Some bool
    | _ -> None
  in
  instantiate ~constraints annotation


module OrderedTypes = struct
  include Record.OrderedTypes

  type t = type_t record [@@deriving compare, eq, sexp, show, hash]

  type ordered_types_t = t

  let pp_concise = pp_concise ~pp_type

  module Concatenation = struct
    include Record.OrderedTypes.RecordConcatenate

    let apply_mapping { middle; wrapping = { head; tail } } ~mapper =
      let apply concrete = Parametric { name = mapper; parameters = [Single concrete] } in
      let wrapping = { head = List.map head ~f:apply; tail = List.map tail ~f:apply } in
      let middle = { middle with Middle.mappers = mapper :: middle.Middle.mappers } in
      { middle; wrapping }


    module Middle = struct
      include Record.OrderedTypes.RecordConcatenate.Middle

      let create_bare variable = { variable; mappers = [] }

      let create ~variable ~mappers = { variable; mappers }

      let rec replace_variable middle ~replacement =
        match middle with
        | { Middle.mappers = []; variable } -> replacement variable
        | { Middle.mappers = head_mapper :: tail_mapper; _ } ->
            let inner = { middle with mappers = tail_mapper } in
            let apply concrete =
              Parametric { name = head_mapper; parameters = [Single concrete] }
            in
            let handle_replaced = function
              | Any -> Any
              | Concrete concretes -> Concrete (List.map concretes ~f:apply)
              | Concatenation concatenation ->
                  Concatenation (apply_mapping ~mapper:head_mapper concatenation)
            in
            replace_variable inner ~replacement >>| handle_replaced


      let singleton_replace_variable middle ~replacement =
        let extract = function
          | Some (Concrete [extracted]) -> extracted
          | _ -> failwith "this was a singleton replace"
        in
        replace_variable middle ~replacement:(fun _ -> Some (Concrete [replacement])) |> extract
    end

    let parse expression ~aliases =
      let variable_aliases name =
        match aliases name with
        | Some (VariableAlias variable) -> Some variable
        | _ -> None
      in
      create expression ~aliases |> create_concatenation_operator_from_annotation ~variable_aliases


    let map_head_and_tail { middle; wrapping = { head; tail } } ~f =
      let wrapping = { head = List.map head ~f; tail = List.map tail ~f } in
      { middle; wrapping }


    let map_middle { middle; wrapping } ~f = { middle = f middle; wrapping }

    let replace_variable { middle; wrapping } ~replacement =
      let merge ~inner:{ head; tail } ~outer:{ head = outer_head; tail = outer_tail } =
        { head = outer_head @ head; tail = tail @ outer_tail }
      in
      let actualize ~inner { head; tail } = head @ inner @ tail in
      match Middle.replace_variable middle ~replacement with
      | None -> None
      | Some Any -> Some Any
      | Some (Concrete inner) -> Some (Concrete (actualize ~inner wrapping))
      | Some (Concatenation { middle = inner_middle; wrapping = inner }) ->
          Some (Concatenation { middle = inner_middle; wrapping = merge ~inner ~outer:wrapping })


    let variable { middle = { Middle.variable; _ }; _ } = variable

    let expression = concatenation_expression

    let create ?(head = []) ?(tail = []) middle = { wrapping = { head; tail }; middle }

    let zip concatenation ~against =
      let head = head concatenation in
      let tail = tail concatenation in
      let head_length = List.length head in
      let tail_length = List.length tail in
      let middle_length = List.length against - head_length - tail_length in
      if middle_length >= 0 then
        let middle = middle concatenation in
        let concretes_head = List.sub against ~pos:0 ~len:head_length in
        let concretes_middle = List.sub against ~pos:head_length ~len:middle_length in
        let concretes_tail = List.sub against ~pos:(head_length + middle_length) ~len:tail_length in
        let head = List.zip_exn head concretes_head in
        let tail = List.zip_exn tail concretes_tail in
        Some (create ~head ~tail (middle, concretes_middle))
      else
        None
  end

  let union_upper_bound ordered =
    match ordered with
    | Concrete concretes -> union concretes
    | Any -> Any
    | Concatenation _ -> object_primitive


  let variable ordered_types =
    match ordered_types with
    | Concrete _ -> None
    | Any -> None
    | Concatenation concatenation -> Some (Concatenation.variable concatenation)


  let local_replace_variable ordered_types ~replacement =
    match ordered_types with
    | Concrete _ -> None
    | Any -> None
    | Concatenation concatenation -> Concatenation.replace_variable concatenation ~replacement
end

let typed_dictionary_class_name ~total =
  if total then
    "TypedDictionary"
  else
    "NonTotalTypedDictionary"


let split annotation =
  let open Record.Parameter in
  match annotation with
  | Optional parameter -> Primitive "typing.Optional", [Single parameter]
  | Parametric { name; parameters } -> Primitive name, parameters
  | Tuple tuple ->
      let parameters =
        match tuple with
        | Bounded parameters -> [Group parameters]
        | Unbounded parameter -> [Single parameter]
      in
      Primitive "tuple", parameters
  | TypedDictionary { total; _ } -> Primitive (typed_dictionary_class_name ~total), []
  | Literal _ as literal -> weaken_literals literal, []
  | annotation -> annotation, []


let class_name annotation =
  let strip_calls =
    let rec collect_identifiers identifiers = function
      | {
          Node.value =
            Expression.Call { callee = { Node.value = Name (Name.Attribute { base; _ }); _ }; _ };
          _;
        } ->
          collect_identifiers identifiers base
      | { Node.value = Name (Name.Identifier identifier); _ } -> identifier :: identifiers
      | { Node.value = Name (Name.Attribute { base; attribute; _ }); _ } ->
          collect_identifiers (attribute :: identifiers) base
      | _ -> identifiers
    in
    collect_identifiers []
  in
  split annotation
  |> fst
  |> expression
  |> strip_calls
  |> fun identifiers ->
  if List.is_empty identifiers then
    Reference.create "typing.Any"
  else
    Reference.create_from_list identifiers


let class_variable annotation = parametric "typing.ClassVar" [Single annotation]

let class_variable_value = function
  | Parametric { name = "typing.ClassVar"; parameters = [Single parameter] } -> Some parameter
  | _ -> None


let final_value = function
  | Parametric
      { name = "typing.Final" | "typing_extensions.Final"; parameters = [Single parameter] } ->
      Some parameter
  | Primitive ("typing.Final" | "typing_extensions.Final") -> Some Top
  | _ -> None


(* Angelic assumption: Any occurrences of top indicate that we're dealing with Any instead of None.
   See T22792667. *)
let assume_any = function
  | Top -> Any
  | annotation -> annotation


let dequalify_reference map reference =
  let rec fold accumulator reference =
    if Reference.Map.mem map reference then
      Reference.combine
        (Reference.Map.find_exn map reference)
        (Reference.create_from_list accumulator)
    else
      match Reference.prefix reference with
      | Some prefix -> fold (Reference.last reference :: accumulator) prefix
      | None -> Reference.create_from_list accumulator
  in
  fold [] reference


let dequalify_identifier map identifier =
  Reference.create identifier |> dequalify_reference map |> Reference.show


let create_type = create

module Variable : sig
  module Namespace : sig
    include module type of struct
      include Record.Variable.RecordNamespace
    end

    val reset : unit -> unit

    val create_fresh : unit -> t
  end

  type unary_t = type_t Record.Variable.RecordUnary.record
  [@@deriving compare, eq, sexp, show, hash]

  type unary_domain = type_t

  type parameter_variadic_t = type_t Record.Variable.RecordVariadic.RecordParameters.record
  [@@deriving compare, eq, sexp, show, hash]

  type parameter_variadic_domain = Callable.parameters

  type list_variadic_t = type_t Record.Variable.RecordVariadic.RecordList.record
  [@@deriving compare, eq, sexp, show, hash]

  type list_variadic_domain = OrderedTypes.t

  type pair =
    | UnaryPair of unary_t * unary_domain
    | ParameterVariadicPair of parameter_variadic_t * parameter_variadic_domain
    | ListVariadicPair of list_variadic_t * list_variadic_domain

  type t = type_t Record.Variable.record [@@deriving compare, eq, sexp, show, hash]

  type variable_t = t

  module type VariableKind = sig
    type t [@@deriving compare, eq, sexp, show, hash]

    module Map : Core.Map.S with type Key.t = t

    val is_free : t -> bool

    val is_escaped_and_free : t -> bool

    val mark_as_bound : t -> t

    val mark_as_escaped : t -> t

    val namespace : t -> namespace:Namespace.t -> t

    val dequalify : t -> dequalify_map:Reference.t Reference.Map.t -> t

    type domain [@@deriving compare, eq, sexp, show, hash]

    val any : domain

    (* The value in the domain directly corresponding to the variable, i.e. the replacement that
       would leave a type unchanged *)
    val self_reference : t -> domain

    val pair : t -> domain -> pair
  end

  module Unary : sig
    include module type of struct
      include Record.Variable.RecordUnary
    end

    include VariableKind with type t = unary_t and type domain = type_t

    val create
      :  ?constraints:type_t Record.Variable.constraints ->
      ?variance:Record.Variable.variance ->
      string ->
      t

    val is_contravariant : t -> bool

    val is_covariant : t -> bool

    val upper_bound : t -> type_t

    val is_escaped_and_free : t -> bool

    val contains_subvariable : t -> bool
  end

  module Variadic : sig
    module Parameters : sig
      include VariableKind with type t = parameter_variadic_t and type domain = Callable.parameters

      val name : t -> Identifier.t

      val create : ?variance:Record.Variable.variance -> string -> t

      val parse_instance_annotation
        :  variable_parameter_annotation:Expression.t ->
        keywords_parameter_annotation:Expression.t ->
        aliases:(Primitive.t -> alias option) ->
        t option

      module Components : sig
        include module type of struct
          include Record.Variable.RecordVariadic.RecordParameters.RecordComponents
        end

        type decomposition = {
          positional_component: type_t;
          keyword_component: type_t;
        }

        val combine : decomposition -> parameter_variadic_t option
      end

      val decompose : t -> Components.decomposition
    end

    module List : sig
      include VariableKind with type t = list_variadic_t and type domain = list_variadic_domain

      val name : t -> Identifier.t

      val create
        :  ?constraints:type_t Record.Variable.constraints ->
        ?variance:Record.Variable.variance ->
        string ->
        t
    end
  end

  module GlobalTransforms : sig
    module type S = sig
      type t

      type domain

      val replace_all : (t -> domain option) -> type_t -> type_t

      val collect_all : type_t -> t list
    end

    module Unary : S with type t = unary_t and type domain = type_t

    module ParameterVariadic :
      S with type t = parameter_variadic_t and type domain = Callable.parameters

    module ListVariadic : S with type t = list_variadic_t and type domain = list_variadic_domain
  end

  include module type of struct
    include Record.Variable
  end

  module Set : Core.Set.S with type Elt.t = t

  val pp_concise : Format.formatter -> t -> unit

  val parse_declaration : Expression.t -> target:Reference.t -> t option

  val dequalify : Reference.t Reference.Map.t -> t -> t

  val namespace : t -> namespace:Namespace.t -> t

  val mark_all_variables_as_bound : ?specific:t list -> type_t -> type_t

  val namespace_all_free_variables : type_t -> namespace:Namespace.t -> type_t

  val all_free_variables : type_t -> t list

  val all_variables_are_resolved : type_t -> bool

  val mark_all_free_variables_as_escaped : ?specific:t list -> type_t -> type_t

  val collapse_all_escaped_variable_unions : type_t -> type_t

  val contains_escaped_free_variable : type_t -> bool

  val convert_all_escaped_free_variables_to_anys : type_t -> type_t

  val converge_all_variable_namespaces : type_t -> type_t
end = struct
  module Namespace = struct
    include Record.Variable.RecordNamespace

    let fresh = ref 1

    let reset () = fresh := 1

    let create_fresh () =
      let namespace = !fresh in
      fresh := namespace + 1;
      namespace
  end

  type unary_t = type_t Record.Variable.RecordUnary.record
  [@@deriving compare, eq, sexp, show, hash]

  type unary_domain = type_t

  type parameter_variadic_t = type_t Record.Variable.RecordVariadic.RecordParameters.record
  [@@deriving compare, eq, sexp, show, hash]

  type parameter_variadic_domain = Callable.parameters

  type list_variadic_t = type_t Record.Variable.RecordVariadic.RecordList.record
  [@@deriving compare, eq, sexp, show, hash]

  type list_variadic_domain = OrderedTypes.t

  type pair =
    | UnaryPair of unary_t * unary_domain
    | ParameterVariadicPair of parameter_variadic_t * parameter_variadic_domain
    | ListVariadicPair of list_variadic_t * list_variadic_domain

  module type VariableKind = sig
    type t [@@deriving compare, eq, sexp, show, hash]

    module Map : Core.Map.S with type Key.t = t

    val is_free : t -> bool

    val is_escaped_and_free : t -> bool

    val mark_as_bound : t -> t

    val mark_as_escaped : t -> t

    val namespace : t -> namespace:Namespace.t -> t

    val dequalify : t -> dequalify_map:Reference.t Reference.Map.t -> t

    type domain [@@deriving compare, eq, sexp, show, hash]

    val any : domain

    val self_reference : t -> domain

    val pair : t -> domain -> pair
  end

  module Unary = struct
    include Record.Variable.RecordUnary

    type t = type_t record [@@deriving compare, eq, sexp, show, hash]

    type domain = type_t [@@deriving compare, eq, sexp, show, hash]

    module Map = Core.Map.Make (struct
      type t = type_t record [@@deriving compare, sexp]
    end)

    let any = Any

    let self_reference variable = Variable variable

    let pair variable value = UnaryPair (variable, value)

    let is_contravariant = function
      | { variance = Contravariant; _ } -> true
      | _ -> false


    let is_covariant = function
      | { variance = Covariant; _ } -> true
      | _ -> false


    let is_free = function
      | { state = Free _; _ } -> true
      | _ -> false


    let namespace variable ~namespace = { variable with namespace }

    let mark_as_bound variable = { variable with state = InFunction }

    let local_replace replacement = function
      | Variable variable -> replacement variable
      | _ -> None


    let upper_bound { constraints; _ } =
      match constraints with
      | Unconstrained -> object_primitive
      | Bound bound -> bound
      | Explicit explicits -> union explicits
      | LiteralIntegers -> integer


    let is_escaped_and_free = function
      | { state = Free { escaped }; _ } -> escaped
      | _ -> false


    let contains_subvariable { constraints; _ } =
      match constraints with
      | Unconstrained -> false
      | Bound bound -> contains_variable bound
      | Explicit explicits -> List.exists explicits ~f:contains_variable
      | LiteralIntegers -> false


    let mark_as_escaped variable = { variable with state = Free { escaped = true } }

    let local_collect = function
      | Variable variable -> [variable]
      | _ -> []


    let dequalify ({ variable = name; _ } as variable) ~dequalify_map =
      { variable with variable = dequalify_identifier dequalify_map name }
  end

  module Variadic = struct
    module Parameters = struct
      include Record.Variable.RecordVariadic.RecordParameters

      type t = type_t record [@@deriving compare, eq, sexp, show, hash]

      type domain = Callable.parameters [@@deriving compare, eq, sexp, show, hash]

      module Map = Core.Map.Make (struct
        type t = type_t record [@@deriving compare, sexp]
      end)

      let name { name; _ } = name

      let any = Callable.Undefined

      let self_reference variable = Callable.ParameterVariadicTypeVariable variable

      let pair variable value = ParameterVariadicPair (variable, value)

      let is_free = function
        | { state = Free _; _ } -> true
        | _ -> false


      let is_escaped_and_free = function
        | { state = Free { escaped }; _ } -> escaped
        | _ -> false


      let mark_as_bound variable = { variable with state = InFunction }

      let namespace variable ~namespace = { variable with namespace }

      let local_replace replacement = function
        | Callable callable ->
            let map = function
              | ParameterVariadicTypeVariable variable ->
                  replacement variable
                  |> Option.value ~default:(ParameterVariadicTypeVariable variable)
              | parameters -> parameters
            in
            Callable.map_parameters callable ~f:map
            |> (fun callable -> Callable callable)
            |> Option.some
        | _ -> None


      let mark_as_escaped variable = { variable with state = Free { escaped = true } }

      let local_collect = function
        | Callable { implementation; overloads; _ } ->
            let extract = function
              | { parameters = ParameterVariadicTypeVariable variable; _ } -> Some variable
              | _ -> None
            in
            List.filter_map (implementation :: overloads) ~f:extract
        | _ -> []


      let dequalify ({ name; _ } as variable) ~dequalify_map =
        { variable with name = dequalify_identifier dequalify_map name }


      let parse_declaration value ~target =
        match value with
        | {
         Node.value =
           Expression.Call
             {
               callee =
                 {
                   Node.value =
                     Name
                       (Name.Attribute
                         {
                           base = { Node.value = Name (Name.Identifier "pyre_extensions"); _ };
                           attribute = "ParameterSpecification";
                           special = false;
                         });
                   _;
                 };
               arguments = [{ Call.Argument.value = { Node.value = String _; _ }; _ }];
             };
         _;
        } ->
            Some (create (Reference.show target))
        | _ -> None


      let parse_instance_annotation
          ~variable_parameter_annotation
          ~keywords_parameter_annotation
          ~aliases
        =
        let get_variable name =
          match aliases name with
          | Some (VariableAlias (ParameterVariadic variable)) -> Some variable
          | _ -> None
        in
        let open Record.Variable.RecordVariadic.RecordParameters.RecordComponents in
        match variable_parameter_annotation, keywords_parameter_annotation with
        | ( {
              Node.value =
                Expression.Name
                  (Attribute
                    { base = variable_parameter_base; attribute = variable_parameter_attribute; _ });
              _;
            },
            {
              Node.value =
                Expression.Name
                  (Attribute
                    { base = keywords_parameter_base; attribute = keywords_parameter_attribute; _ });
              _;
            } )
          when Identifier.equal variable_parameter_attribute (component_name PositionalArguments)
               && Identifier.equal keywords_parameter_attribute (component_name KeywordArguments)
          -> (
            match
              ( create_type variable_parameter_base ~aliases,
                create_type keywords_parameter_base ~aliases )
            with
            | Primitive positionals_base, Primitive keywords_base
              when Identifier.equal positionals_base keywords_base ->
                get_variable positionals_base
            | _ -> None )
        | _ -> None


      module Components = struct
        include Record.Variable.RecordVariadic.RecordParameters.RecordComponents

        type decomposition = {
          positional_component: type_t;
          keyword_component: type_t;
        }

        let combine { positional_component; keyword_component } =
          let component_agnostic_equal left right =
            equal
              { left with component = KeywordArguments }
              { right with component = KeywordArguments }
          in
          match positional_component, keyword_component with
          | ( ParameterVariadicComponent
                ({ component = PositionalArguments; _ } as positional_component),
              ParameterVariadicComponent ({ component = KeywordArguments; _ } as keyword_component)
            )
            when component_agnostic_equal positional_component keyword_component ->
              let { variance; variable_name = name; variable_namespace = namespace; _ } =
                positional_component
              in
              Some { name; namespace; variance; state = InFunction }
          | _ -> None
      end

      let decompose { name = variable_name; variance; namespace = variable_namespace; _ } =
        {
          Components.positional_component =
            ParameterVariadicComponent
              { component = PositionalArguments; variable_name; variance; variable_namespace };
          keyword_component =
            ParameterVariadicComponent
              { component = KeywordArguments; variable_name; variance; variable_namespace };
        }
    end

    module List = struct
      include Record.Variable.RecordVariadic.RecordList

      type t = type_t record [@@deriving compare, eq, sexp, show, hash]

      type domain = OrderedTypes.t [@@deriving compare, eq, sexp, show, hash]

      module Map = Core.Map.Make (struct
        type t = type_t record [@@deriving compare, sexp]
      end)

      let any = OrderedTypes.Any

      let self_reference variable =
        OrderedTypes.Concatenation
          (OrderedTypes.Concatenation.empty_wrap
             { OrderedTypes.Concatenation.Middle.variable; mappers = [] })


      let pair variable value = ListVariadicPair (variable, value)

      let is_free = function
        | { state = Free _; _ } -> true
        | _ -> false


      let is_escaped_and_free = function
        | { state = Free { escaped }; _ } -> escaped
        | _ -> false


      let mark_as_bound variable = { variable with state = InFunction }

      let namespace variable ~namespace = { variable with namespace }

      (* TODO(T45087986): Add more entries here as we add hosts for these variables *)
      let local_replace replacement = function
        | Tuple (Bounded bounded) ->
            OrderedTypes.local_replace_variable bounded ~replacement
            >>| fun ordered_types -> Tuple (Bounded ordered_types)
        | Parametric { name; parameters } ->
            let replace = function
              | Record.Parameter.Group ordered ->
                  OrderedTypes.local_replace_variable ordered ~replacement
                  >>| fun group -> Record.Parameter.Group group
              | Single _ -> None
            in
            let replaced = List.map parameters ~f:(fun parameter -> replace parameter, parameter) in
            if List.exists replaced ~f:(fun (replaced, _) -> Option.is_some replaced) then
              Some
                ( List.map replaced ~f:(fun (replaced, default) -> Option.value replaced ~default)
                |> parametric name )
            else
              None
        | Callable callable ->
            let map = function
              | Defined parameters ->
                  let replace_variadic = function
                    | Callable.Parameter.Variable (Concatenation concatenation) ->
                        let encode_ordered_types_into_parameters = function
                          | OrderedTypes.Any -> [Callable.Parameter.Variable (Concrete Any)]
                          | Concrete concretes ->
                              let make_anonymous annotation =
                                Callable.Parameter.Anonymous
                                  { index = 0; annotation; default = false }
                              in
                              List.map concretes ~f:make_anonymous
                          | Concatenation concatenation -> [Variable (Concatenation concatenation)]
                        in
                        OrderedTypes.Concatenation.replace_variable concatenation ~replacement
                        >>| encode_ordered_types_into_parameters
                        |> Option.value
                             ~default:[Callable.Parameter.Variable (Concatenation concatenation)]
                    | parameter -> [parameter]
                  in
                  let correct_indices index = function
                    | Callable.Parameter.Anonymous anonymous ->
                        Callable.Parameter.Anonymous { anonymous with index }
                    | parameter -> parameter
                  in
                  List.concat_map parameters ~f:replace_variadic
                  |> List.mapi ~f:correct_indices
                  |> fun defined -> Defined defined
              | parameters -> parameters
            in
            Callable.map_parameters callable ~f:map
            |> (fun callable -> Callable callable)
            |> Option.some
        | _ -> None


      let mark_as_escaped variable = { variable with state = Free { escaped = true } }

      (* TODO(T45087986): Add more entries here as we add hosts for these variables *)
      let local_collect = function
        | Tuple (Bounded bounded) -> OrderedTypes.variable bounded |> Option.to_list
        | Callable { implementation; overloads; _ } ->
            let map = function
              | { parameters = Defined parameters; _ } ->
                  let collect_variadic = function
                    | Callable.Parameter.Variable (Concatenation concatenation) ->
                        Some (OrderedTypes.Concatenation.variable concatenation)
                    | _ -> None
                  in
                  List.filter_map parameters ~f:collect_variadic
              | _ -> []
            in
            implementation :: overloads |> List.concat_map ~f:map
        | Parametric { parameters; _ } ->
            let collect = function
              | Record.Parameter.Group ordered -> OrderedTypes.variable ordered |> Option.to_list
              | Single _ -> []
            in
            List.concat_map parameters ~f:collect
        | _ -> []


      let dequalify ({ name; _ } as variable) ~dequalify_map =
        { variable with name = dequalify_identifier dequalify_map name }


      let parse_declaration value ~target =
        match value with
        | {
         Node.value =
           Expression.Call
             {
               callee =
                 {
                   Node.value =
                     Name
                       (Name.Attribute
                         {
                           base = { Node.value = Name (Name.Identifier "pyre_extensions"); _ };
                           attribute = "ListVariadic";
                           special = false;
                         });
                   _;
                 };
               arguments = [{ Call.Argument.value = { Node.value = String _; _ }; _ }];
             };
         _;
        } ->
            Some (create (Reference.show target))
        | _ -> None
    end
  end

  module GlobalTransforms = struct
    module type VariableKind = sig
      include VariableKind

      (* We don't want these to be part of the public interface for Unary or Variadic.Parameters *)
      val local_replace : (t -> domain option) -> type_t -> type_t option

      val local_collect : type_t -> t list
    end

    module Make (Variable : VariableKind) = struct
      include Variable

      let replace_all operation =
        instantiate
          ~visit_children_before:true
          ~constraints:(Variable.local_replace operation)
          ~widen:false


      let map operation =
        replace_all (fun variable -> operation variable |> Variable.self_reference |> Option.some)


      let mark_all_as_bound ?specific =
        let in_list =
          match specific with
          | Some variables -> List.mem variables ~equal:Variable.equal
          | None -> fun _ -> true
        in
        let mark_as_bound_if_in_list variable =
          if in_list variable then
            Variable.mark_as_bound variable
          else
            variable
        in
        map mark_as_bound_if_in_list


      let namespace_all_free_variables annotation ~namespace =
        let namespace_if_free variable =
          if Variable.is_free variable then
            Variable.namespace variable ~namespace
          else
            variable
        in
        map namespace_if_free annotation


      let mark_as_escaped annotation ~variables ~namespace =
        let mark_as_escaped_if_in_list variable =
          if List.mem variables variable ~equal:Variable.equal then
            Variable.mark_as_escaped variable |> Variable.namespace ~namespace
          else
            variable
        in
        map mark_as_escaped_if_in_list annotation


      (* Sets all of the variables of type Variable.t to the same namespace (-1). This should only
         be used to implement namespace_insensitive_compare *)
      let converge_all_variable_namespaces = map (Variable.namespace ~namespace:(-1))

      let convert_all_escaped_free_variables_to_anys =
        let convert_if_escaped variable =
          if Variable.is_escaped_and_free variable then
            Some Variable.any
          else
            Some (Variable.self_reference variable)
        in
        replace_all convert_if_escaped


      let collect_all annotation =
        let module CollectorTransform = Transform.Make (struct
          type state = Variable.t list

          let visit_children_before _ _ = true

          let visit_children_after = false

          let visit sofar annotation =
            let new_state = Variable.local_collect annotation @ sofar in
            { Transform.transformed_annotation = annotation; new_state }
        end)
        in
        fst (CollectorTransform.visit [] annotation) |> List.rev


      let all_free_variables annotation = collect_all annotation |> List.filter ~f:Variable.is_free

      let contains_escaped_free_variable annotation =
        collect_all annotation |> List.exists ~f:Variable.is_escaped_and_free
    end

    module type S = sig
      type t

      type domain

      val replace_all : (t -> domain option) -> type_t -> type_t

      val collect_all : type_t -> t list
    end

    module Unary = Make (Unary)
    module ParameterVariadic = Make (Variadic.Parameters)
    module ListVariadic = Make (Variadic.List)
  end

  let pp_type = pp

  type t = type_t Record.Variable.record [@@deriving compare, eq, sexp, show, hash]

  type variable_t = t

  include Record.Variable

  module Set = Core.Set.Make (struct
    type t = type_t Record.Variable.record [@@deriving compare, sexp]
  end)

  let pp_concise format = function
    | Unary variable -> Unary.pp_concise format variable ~pp_type
    | ParameterVariadic { name; _ } ->
        Format.fprintf format "CallableParameterTypeVariable[%s]" name
    | ListVariadic { name; _ } -> Format.fprintf format "ListVariadic[%s]" name


  let parse_declaration expression ~target =
    match Variadic.Parameters.parse_declaration expression ~target with
    | Some variable -> Some (ParameterVariadic variable)
    | None -> (
        match Variadic.List.parse_declaration expression ~target with
        | Some variable -> Some (ListVariadic variable)
        | None -> None )


  let dequalify dequalify_map = function
    | Unary variable -> Unary (Unary.dequalify variable ~dequalify_map)
    | ParameterVariadic variable ->
        ParameterVariadic (Variadic.Parameters.dequalify variable ~dequalify_map)
    | ListVariadic variable -> ListVariadic (Variadic.List.dequalify variable ~dequalify_map)


  let namespace variable ~namespace =
    match variable with
    | Unary variable -> Unary (Unary.namespace variable ~namespace)
    | ParameterVariadic variable ->
        ParameterVariadic (Variadic.Parameters.namespace variable ~namespace)
    | ListVariadic variable -> ListVariadic (Variadic.List.namespace variable ~namespace)


  let partition =
    let partitioner = function
      | Unary variable -> `Fst variable
      | ParameterVariadic variable -> `Snd variable
      | ListVariadic variable -> `Trd variable
    in
    List.partition3_map ~f:partitioner


  let mark_all_variables_as_bound ?specific annotation =
    let specific_unaries, specific_parameters_variadics, specific_list_variadics =
      match specific >>| partition with
      | None -> None, None, None
      | Some (unaries, parameters, lists) -> Some unaries, Some parameters, Some lists
    in
    GlobalTransforms.Unary.mark_all_as_bound ?specific:specific_unaries annotation
    |> GlobalTransforms.ParameterVariadic.mark_all_as_bound ?specific:specific_parameters_variadics
    |> GlobalTransforms.ListVariadic.mark_all_as_bound ?specific:specific_list_variadics


  let namespace_all_free_variables annotation ~namespace =
    GlobalTransforms.Unary.namespace_all_free_variables annotation ~namespace
    |> GlobalTransforms.ParameterVariadic.namespace_all_free_variables ~namespace
    |> GlobalTransforms.ListVariadic.namespace_all_free_variables ~namespace


  let all_free_variables annotation =
    let unaries =
      GlobalTransforms.Unary.all_free_variables annotation
      |> List.map ~f:(fun variable -> Unary variable)
    in
    let callable_variadics =
      GlobalTransforms.ParameterVariadic.all_free_variables annotation
      |> List.map ~f:(fun variable -> ParameterVariadic variable)
    in
    let list_variadics =
      GlobalTransforms.ListVariadic.all_free_variables annotation
      |> List.map ~f:(fun variable -> ListVariadic variable)
    in
    unaries @ callable_variadics @ list_variadics


  let all_variables_are_resolved annotation = all_free_variables annotation |> List.is_empty

  let mark_all_free_variables_as_escaped ?specific annotation =
    let fresh_namespace = Namespace.create_fresh () in
    let variables =
      match specific with
      | Some variables -> variables
      | None -> all_free_variables annotation
    in
    let specific_unaries, specific_parameters_variadics, specific_list_variadics =
      partition variables
    in
    GlobalTransforms.Unary.mark_as_escaped
      annotation
      ~variables:specific_unaries
      ~namespace:fresh_namespace
    |> GlobalTransforms.ParameterVariadic.mark_as_escaped
         ~variables:specific_parameters_variadics
         ~namespace:fresh_namespace
    |> GlobalTransforms.ListVariadic.mark_as_escaped
         ~variables:specific_list_variadics
         ~namespace:fresh_namespace


  let collapse_all_escaped_variable_unions annotation =
    let module ConcreteTransform = Transform.Make (struct
      type state = unit

      let visit_children_before _ _ = true

      let visit_children_after = false

      let visit new_state annotation =
        let transformed_annotation =
          match annotation with
          | Union parameters ->
              let not_escaped_free_variable = function
                | Variable variable -> not (Unary.is_escaped_and_free variable)
                | _ -> true
              in
              List.filter parameters ~f:not_escaped_free_variable |> union
          | _ -> annotation
        in
        { Transform.transformed_annotation; new_state }
    end)
    in
    snd (ConcreteTransform.visit () annotation)


  let contains_escaped_free_variable annotation =
    GlobalTransforms.Unary.contains_escaped_free_variable annotation
    || GlobalTransforms.ParameterVariadic.contains_escaped_free_variable annotation
    || GlobalTransforms.ListVariadic.contains_escaped_free_variable annotation


  let convert_all_escaped_free_variables_to_anys annotation =
    GlobalTransforms.Unary.convert_all_escaped_free_variables_to_anys annotation
    |> GlobalTransforms.ParameterVariadic.convert_all_escaped_free_variables_to_anys
    |> GlobalTransforms.ListVariadic.convert_all_escaped_free_variables_to_anys


  let converge_all_variable_namespaces annotation =
    GlobalTransforms.Unary.converge_all_variable_namespaces annotation
    |> GlobalTransforms.ParameterVariadic.converge_all_variable_namespaces
    |> GlobalTransforms.ListVariadic.converge_all_variable_namespaces
end

let namespace_insensitive_compare left right =
  compare
    (Variable.converge_all_variable_namespaces left)
    (Variable.converge_all_variable_namespaces right)


let is_concrete annotation =
  let module ConcreteTransform = Transform.Make (struct
    type state = bool

    let visit_children_before _ = function
      | Optional Bottom -> false
      | Parametric { name = "typing.Optional" | "Optional"; parameters = [Single Bottom] } -> false
      | _ -> true


    let visit_children_after = false

    let visit sofar annotation =
      let new_state =
        match annotation with
        | Bottom
        | Top
        | Any ->
            false
        | _ -> sofar
      in
      { Transform.transformed_annotation = annotation; new_state }
  end)
  in
  fst (ConcreteTransform.visit true annotation)
  && not (Variable.contains_escaped_free_variable annotation)


let dequalify map annotation =
  let dequalify_string string = string |> dequalify_identifier map in
  let module DequalifyTransform = Transform.Make (struct
    type state = unit

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit _ annotation =
      let transformed_annotation =
        match annotation with
        | Optional Bottom -> Optional Bottom
        | Optional parameter ->
            Parametric
              { name = dequalify_string "typing.Optional"; parameters = [Single parameter] }
        | Parametric { name; parameters } ->
            Parametric { name = dequalify_identifier map (reverse_substitute name); parameters }
        | Union parameters ->
            Parametric
              {
                name = dequalify_string "typing.Union";
                parameters =
                  List.map parameters ~f:(fun parameter -> Record.Parameter.Single parameter);
              }
        | Primitive name -> Primitive (dequalify_identifier map name)
        | Variable ({ variable = name; _ } as annotation) ->
            Variable { annotation with variable = dequalify_identifier map name }
        | Callable ({ kind; _ } as callable) ->
            let kind =
              match kind with
              | Anonymous -> kind
              | Named reference -> Named (dequalify_reference map reference)
            in
            Callable { callable with kind }
        | _ -> annotation
      in
      { Transform.transformed_annotation; new_state = () }
  end)
  in
  snd (DequalifyTransform.visit () annotation)


module TypedDictionary = struct
  let anonymous ~total fields = TypedDictionary { name = "$anonymous"; fields; total }

  let fields_have_colliding_keys left_fields right_fields =
    let found_collision { name = needle_name; annotation = needle_annotation } =
      let same_name_different_annotation { name; annotation } =
        String.equal name needle_name && not (equal annotation needle_annotation)
      in
      List.exists left_fields ~f:same_name_different_annotation
    in
    List.exists right_fields ~f:found_collision


  let field_named_parameters ~default fields =
    let field_to_argument { name; annotation } =
      Record.Callable.RecordParameter.KeywordOnly
        { name = Format.asprintf "$parameter$%s" name; annotation; default }
    in
    List.map ~f:field_to_argument fields |> fun parameters -> Defined parameters


  let constructor ~name ~fields ~total =
    let annotation = TypedDictionary { name; fields; total } in
    {
      Callable.kind = Named (Reference.create "__init__");
      implementation = { annotation = Top; parameters = Undefined; define_location = None };
      overloads =
        [
          {
            annotation;
            parameters = field_named_parameters ~default:(not total) fields;
            define_location = None;
          };
          {
            annotation;
            parameters =
              Defined
                [
                  Record.Callable.RecordParameter.Anonymous
                    { index = 0; annotation; default = false };
                ];
            define_location = None;
          };
        ];
      implicit = None;
    }


  type special_method = {
    name: string;
    special_index: int option;
    overloads: typed_dictionary_field list -> t Callable.overload list;
  }

  let key_parameter name =
    CallableParameter.Named { name = "k"; annotation = literal_string name; default = false }


  let common_special_methods =
    let getitem_overloads =
      let overload { name; annotation } =
        { annotation; parameters = Defined [key_parameter name]; define_location = None }
      in
      List.map ~f:overload
    in
    let setitem_overloads =
      let overload { name; annotation } =
        {
          annotation = none;
          parameters =
            Defined [key_parameter name; Named { name = "v"; annotation; default = false }];
          define_location = None;
        }
      in
      List.map ~f:overload
    in
    let get_overloads =
      let overloads { name; annotation } =
        [
          {
            annotation = Optional annotation;
            parameters = Defined [key_parameter name];
            define_location = None;
          };
          {
            annotation = Union [annotation; Variable (Variable.Unary.create "_T")];
            parameters =
              Defined
                [
                  key_parameter name;
                  Named
                    {
                      name = "default";
                      annotation = Variable (Variable.Unary.create "_T");
                      default = false;
                    };
                ];
            define_location = None;
          };
        ]
      in
      List.concat_map ~f:overloads
    in
    let setdefault_overloads =
      let overload { name; annotation } =
        {
          annotation;
          parameters =
            Defined [key_parameter name; Named { name = "default"; annotation; default = false }];
          define_location = None;
        }
      in
      List.map ~f:overload
    in
    let update_overloads fields =
      [
        {
          annotation = none;
          parameters = field_named_parameters fields ~default:true;
          define_location = None;
        };
      ]
    in
    [
      { name = "__getitem__"; special_index = Some 1; overloads = getitem_overloads };
      { name = "__setitem__"; special_index = Some 1; overloads = setitem_overloads };
      { name = "get"; special_index = Some 1; overloads = get_overloads };
      { name = "setdefault"; special_index = Some 1; overloads = setdefault_overloads };
      { name = "update"; special_index = None; overloads = update_overloads };
    ]


  let non_total_special_methods =
    let pop_overloads =
      let overloads { name; annotation } =
        [
          { annotation; parameters = Defined [key_parameter name]; define_location = None };
          {
            annotation = Union [annotation; Variable (Variable.Unary.create "_T")];
            parameters =
              Defined
                [
                  key_parameter name;
                  Named
                    {
                      name = "default";
                      annotation = Variable (Variable.Unary.create "_T");
                      default = false;
                    };
                ];
            define_location = None;
          };
        ]
      in
      List.concat_map ~f:overloads
    in
    let delitem_overloads fields =
      let overload { name; annotation = _ } =
        { annotation = none; parameters = Defined [key_parameter name]; define_location = None }
      in
      List.map ~f:overload fields
    in
    [
      { name = "pop"; special_index = Some 1; overloads = pop_overloads };
      { name = "__delitem__"; special_index = Some 1; overloads = delitem_overloads };
    ]


  let special_overloads ~fields ~method_name ~total =
    let special_methods =
      if total then common_special_methods else non_total_special_methods @ common_special_methods
    in
    List.find special_methods ~f:(fun { name; _ } -> String.equal name method_name)
    >>| fun { overloads; _ } -> overloads fields


  let is_special_mismatch ~method_name ~position ~total =
    let special_methods =
      if total then common_special_methods else non_total_special_methods @ common_special_methods
    in
    List.find special_methods ~f:(fun { name; _ } -> String.equal name method_name)
    >>= (fun { special_index; _ } -> special_index)
    >>| ( = ) position
    |> Option.value ~default:false


  let class_name = typed_dictionary_class_name

  let defines ~t_self_expression ~total =
    let open Statement in
    let class_name = class_name ~total in
    let define ?self_parameter ?return_annotation name =
      Statement.Define
        {
          signature =
            {
              name =
                Reference.create_from_list [class_name; name] |> Node.create_with_default_location;
              parameters =
                [
                  { ExpressionParameter.name = "self"; value = None; annotation = self_parameter }
                  |> Node.create_with_default_location;
                ];
              decorators = [];
              return_annotation;
              async = false;
              generator = false;
              parent = Some (Reference.create class_name);
              nesting_define = None;
            };
          captures = [];
          body = [];
        }
      |> Node.create_with_default_location
    in
    let common_methods =
      [
        define ~self_parameter:t_self_expression ~return_annotation:t_self_expression "copy";
        define ~self_parameter:t_self_expression ~return_annotation:(expression integer) "__len__";
        define
          ~self_parameter:t_self_expression
          ~return_annotation:(expression (iterator string))
          "__iter__";
      ]
      @ List.map common_special_methods ~f:(fun { name; _ } -> define name)
    in
    if total then
      common_methods
    else
      common_methods @ List.map non_total_special_methods ~f:(fun { name; _ } -> define name)
end

let remove_undeclared annotation =
  let module RemoveUndeclared = Transform.Make (struct
    type state = unit

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit _ annotation =
      let transformed_annotation =
        match annotation with
        | Parametric { name; parameters } ->
            let declare annotation =
              match annotation with
              | Record.Parameter.Single (Primitive "typing.Undeclared") ->
                  Record.Parameter.Single Any
              | _ -> annotation
            in
            let parameters = List.map parameters ~f:declare in
            Parametric { name; parameters }
        | Union annotations -> (
            let annotations =
              let declared = function
                | Primitive "typing.Undeclared" -> false
                | _ -> true
              in
              List.filter ~f:declared annotations
            in
            match annotations with
            | [] -> Any
            | [annotation] -> annotation
            | _ -> union annotations )
        | _ -> annotation
      in
      { Transform.transformed_annotation; new_state = () }
  end)
  in
  match annotation with
  | Primitive "typing.Undeclared" -> Any
  | _ -> snd (RemoveUndeclared.visit () annotation)


(* Transform tuples and callables so they are printed correctly when running infer and click to fix. *)
let infer_transform annotation =
  let module InferTransform = Transform.Make (struct
    type state = unit

    let visit_children_before _ _ = true

    let visit_children_after = false

    let visit _ annotation =
      let transformed_annotation =
        match annotation with
        | Tuple (Bounded (Concrete types)) when List.length types > 2 ->
            let parameter = List.hd types |> Option.value ~default:Bottom in
            let should_be_unbound =
              List.fold types ~init:true ~f:(fun all_match next_parameter ->
                  if equal parameter next_parameter then
                    all_match
                  else
                    false)
            in
            if should_be_unbound then
              Tuple (Unbounded parameter)
            else
              annotation
        | Callable
            ( { implementation = { parameters = Defined parameters; _ } as implementation; _ } as
            callable ) ->
            let parameters =
              let transform_parameter index parameter =
                match parameter with
                | CallableParameter.Anonymous { annotation; _ }
                | KeywordOnly { annotation; _ }
                | Named { annotation; _ }
                | Variable (Concrete annotation) ->
                    CallableParameter.Anonymous { annotation; default = false; index }
                | _ -> parameter
              in
              List.mapi parameters ~f:transform_parameter
            in
            let implementation = { implementation with parameters = Defined parameters } in
            Callable { callable with implementation }
        | Parametric { name = "typing.Dict"; parameters = [Single Bottom; Single Bottom] } ->
            dictionary ~key:Any ~value:Any
        | Parametric { name = "List" | "typing.List"; parameters = [Single Bottom] } -> list Any
        (* This is broken in typeshed:
           https://github.com/python/typeshed/pull/991#issuecomment-288160993 *)
        | Primitive "_PathLike" -> Primitive "PathLike"
        | Parametric { name = "_PathLike"; parameters } ->
            Parametric { name = "PathLike"; parameters }
        | Parametric { name = "Union" | "typing.Union"; parameters } ->
            Parameter.all_singles parameters >>| union |> Option.value ~default:annotation
        | _ -> annotation
      in
      { Transform.transformed_annotation; new_state = () }
  end)
  in
  snd (InferTransform.visit () annotation)


let contains_prohibited_any annotation =
  let is_string_to_any_mapping
    = (* TODO(T40377122): Remove special-casing of Dict[str, Any] in strict. *)
    function
    | Parametric { name = "typing.Mapping"; parameters = [Single (Primitive "str"); Single Any] }
    | Parametric { name = "dict"; parameters = [Single (Primitive "str"); Single Any] } ->
        true
    | _ -> false
  in
  let module Exists = Transform.Make (struct
    type state = bool

    let visit_children_before _ annotation = not (is_string_to_any_mapping annotation)

    let visit_children_after = false

    let visit sofar annotation =
      { Transform.transformed_annotation = annotation; new_state = sofar || is_any annotation }
  end)
  in
  fst (Exists.visit false annotation)


let to_yojson annotation = `String (show annotation)

let resolve_class annotation =
  let rec extract ~meta original_annotation =
    let annotation =
      match original_annotation with
      | Variable variable -> Variable.Unary.upper_bound variable
      | _ -> original_annotation
    in
    match annotation with
    | Top
    | Bottom
    | Any ->
        Some []
    | Union annotations ->
        let flatten_optional sofar optional =
          match sofar, optional with
          | Some sofar, Some optional -> Some (optional :: sofar)
          | _ -> None
        in
        List.map ~f:(extract ~meta) annotations
        |> List.fold ~init:(Some []) ~f:flatten_optional
        >>| List.concat
        >>| List.rev
    | annotation when is_meta annotation -> single_parameter annotation |> extract ~meta:true
    | _ -> (
        match split annotation |> fst |> primitive_name with
        | Some class_name ->
            Some [{ instantiated = original_annotation; class_attributes = meta; class_name }]
        | None -> None )
  in
  extract ~meta:false annotation
