(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
open Expression

(** Roots representing parameters, locals, and special return value in models. *)
module Root : sig
  type t =
    | LocalResult (* Special root representing the return value location. *)
    | PositionalParameter of {
        position: int;
        name: Identifier.t;
        positional_only: bool;
      }
    | NamedParameter of { name: Identifier.t }
    | StarParameter of { position: int }
    | StarStarParameter of { excluded: Identifier.t list }
    | Variable of Identifier.t
    | CapturedVariable of Identifier.t
  [@@deriving compare, eq, hash, sexp]

  val parameter_name : t -> string option

  val pp_external : Format.formatter -> t -> unit

  val show_external : t -> string

  val pp_internal : Format.formatter -> t -> unit

  val show_internal : t -> string

  val variable_to_captured_variable : t -> t

  val captured_variable_to_variable : t -> t

  val is_captured_variable : t -> bool

  (* Equivalent to pp_internal. Required by @@deriving. *)
  val pp : Format.formatter -> t -> unit

  module Set : Caml.Set.S with type elt = t
end

module NormalizedParameter : sig
  type t = {
    root: Root.t;
    (* Qualified name (prefixed with `$parameter$`), ignoring stars. *)
    qualified_name: Identifier.t;
    original: Parameter.t;
  }
end

val normalize_parameters : Parameter.t list -> NormalizedParameter.t list

module Path : sig
  type t = Abstract.TreeDomain.Label.t list [@@deriving compare, eq, show]

  val empty : t

  val is_prefix : prefix:t -> t -> bool
end

type t = {
  root: Root.t;
  path: Path.t;
}
[@@deriving show, compare]

val create : Root.t -> Path.t -> t

val extend : t -> path:Path.t -> t

val of_expression : Expression.t -> t option

val get_index : Expression.t -> Abstract.TreeDomain.Label.t

val to_json : t -> Yojson.Safe.t

type argument_match = {
  root: Root.t;
  actual_path: Path.t;
  formal_path: Path.t;
}
[@@deriving compare, show]

(* Will preserve the order in which the arguments were matched to formals. *)
val match_actuals_to_formals
  :  Call.Argument.t list ->
  Root.t list ->
  (Call.Argument.t * argument_match list) list

val dictionary_keys : Abstract.TreeDomain.Label.t
