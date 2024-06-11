(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
open Statement
module PyrePysaApi = Analysis.PyrePysaApi

type kind =
  | Normal
  | PropertySetter
[@@deriving show, sexp, compare, hash, eq]

type function_name = {
  name: string;
  kind: kind;
}
[@@deriving show, sexp, compare, hash, eq]

type method_name = {
  class_name: string;
  method_name: string;
  kind: kind;
}
[@@deriving show, sexp, compare, hash, eq]

type t =
  | Function of function_name
  | Method of method_name
  | Override of method_name
  (* Represents a global variable or field of a class that we want to model, * e.g os.environ or
     HttpRequest.GET *)
  | Object of string
[@@deriving sexp, compare, hash, eq]

module T : sig
  type nonrec t = t [@@deriving sexp, compare, hash, eq]
end

module Map : sig
  include Data_structures.SerializableMap.S with type key = t

  module Tree : module type of struct
    include Core.Map.Make_tree (struct
      include T
      include Core.Comparator.Make (T)
    end)
  end
end

(* Pretty printers. *)

val pp_internal : Format.formatter -> t -> unit

val show_internal : t -> string

val pp_pretty : Format.formatter -> t -> unit

val show_pretty : t -> string

val pp_pretty_with_kind : Format.formatter -> t -> unit

val show_pretty_with_kind : t -> string

val pp_external : Format.formatter -> t -> unit

val external_name : t -> string

(* Equivalent to pp_internal. Required by @@deriving. *)
val pp : Format.formatter -> t -> unit

(* Constructors. *)

val create_function : ?kind:kind -> Reference.t -> t

val create_method : ?kind:kind -> Reference.t -> t

val create_property_setter : Reference.t -> t

val create_override : ?kind:kind -> Reference.t -> t

val create_property_setter_override : Reference.t -> t

val create_object : Reference.t -> t

val create : Define.t -> t

val create_derived_override : t -> at_type:Reference.t -> t

(* Accessors. *)

val get_corresponding_method : t -> t

val get_corresponding_override : t -> t

val class_name : t -> string option

val method_name : t -> string option

val is_function_or_method : t -> bool

val is_method : t -> bool

val is_method_or_override : t -> bool

val override_to_method : t -> t

(** Return the define name of a Function or Method target. Note that multiple targets can match to
    the same define name (e.g, property getters and setters). Hence, use this at your own risk. *)
val define_name : t -> Reference.t

val object_name : t -> Reference.t

module Set : Stdlib.Set.S with type elt = t

module HashMap : Core.Hashtbl.S with type key := t

module HashSet : Core.Hash_set.S with type elt := t

type definitions_result = {
  qualifier: Reference.t;
  (* Mapping from a target to its selected definition. *)
  callables: Define.t Node.t Map.t;
  (* True if there was multiple non-stub definitions. *)
  has_multiple_definitions: bool;
}

(** This is the source of truth for the mapping of callables to definitions. All parts of the
    analysis should use this (or `get_module_and_definition`) rather than walking over source files. *)
val get_definitions : pyre_api:PyrePysaApi.ReadOnly.t -> Reference.t -> definitions_result option

val get_module_and_definition
  :  pyre_api:PyrePysaApi.ReadOnly.t ->
  t ->
  (Reference.t * Define.t Node.t) option

val get_callable_location : pyre_api:PyrePysaApi.ReadOnly.t -> t -> Ast.Location.WithModule.t option

val resolve_method
  :  pyre_api:PyrePysaApi.ReadOnly.t ->
  class_type:Type.t ->
  method_name:string ->
  t option

module ArtificialTargets : sig
  val format_string : t

  val str_add : t

  val str_mod : t

  val str_format : t

  val str_literal : t

  val condition : t
end

module SharedMemoryKey : sig
  type nonrec t = t

  val compare : t -> t -> int

  val to_string : t -> string

  val from_string : string -> t
end

(* Represent a hashset of targets inside the shared memory *)
module HashsetSharedMemory : sig
  type target = t

  type t

  val cleanup : t -> unit

  val from_heap : target list -> t

  module ReadOnly : sig
    type t

    val mem : t -> target -> bool
  end

  val read_only : t -> ReadOnly.t
end
