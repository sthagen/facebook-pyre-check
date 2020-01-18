(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core

exception Cyclic

exception Incomplete

exception Untracked of Type.t

module Target : sig
  type t = {
    target: IndexTracker.t;
    parameters: Type.Parameter.t list;
  }
  [@@deriving compare, eq, sexp, show]

  module type ListOrSet = sig
    type record

    val filter : record -> f:(t -> bool) -> record

    val is_empty : record -> bool

    val exists : record -> f:(t -> bool) -> bool

    val iter : record -> f:(t -> unit) -> unit

    val equal : record -> record -> bool

    val mem : record -> t -> bool

    val to_string : f:(t -> string) -> record -> string

    val fold : record -> init:'accum -> f:('accum -> t -> 'accum) -> 'accum

    val empty : record

    val add : record -> t -> record
  end

  module Set : sig
    include Set.S with type Elt.t = t

    include ListOrSet with type record = t
  end

  module List : ListOrSet with type record = t list
end

(** The handler module for interfacing with ClassHierarchy lookups. See [Environment_handler] for
    more. *)
module type Handler = sig
  val edges : IndexTracker.t -> Target.t list option

  val contains : Type.Primitive.t -> bool
end

(* Returns true if the class hierarchy contains the given class. *)
val contains : (module Handler) -> Type.Primitive.t -> bool

(* Returns true if the annotation can be deconstructed into primitive types that exist in the class
   hierarchy. If typing.List and int are in the class hierarchy, both `contains hierarchy
   typing.List` and `is_instantiated class hierarchy typing.List[int]` will evaluate to true, but
   `is_instantiated hierarchy typing.List[str]` will evaluate to false. *)
val is_instantiated : (module Handler) -> Type.t -> bool

(* Exposed for tests only *)
val method_resolution_order_linearize
  :  get_successors:(IndexTracker.t -> Target.t list option) ->
  Type.Primitive.t ->
  Type.Primitive.t list

val successors : (module Handler) -> Type.Primitive.t -> Type.Primitive.t list

module Variable : sig
  type t =
    | Unary of Type.Variable.Unary.t
    | ListVariadic of Type.Variable.Variadic.List.t
  [@@deriving compare, eq, sexp, show]

  val zip_on_parameters
    :  parameters:Type.Parameter.t sexp_list ->
    t sexp_list ->
    (Type.Parameter.t * t) sexp_list sexp_option

  val zip_on_two_parameter_lists
    :  left_parameters:Type.Parameter.t sexp_list ->
    right_parameters:Type.Parameter.t sexp_list ->
    t sexp_list ->
    (Type.Parameter.t * Type.Parameter.t * t) sexp_list sexp_option

  val all_unary : t list -> Type.Variable.Unary.t list option

  val to_parameter : t -> Type.Parameter.t
end

val variables
  :  ?default:Variable.t list option ->
  (module Handler) ->
  Type.Primitive.t ->
  Variable.t list option

val least_upper_bound
  :  (module Handler) ->
  Type.Primitive.t ->
  Type.Primitive.t ->
  Type.Primitive.t list

val check_integrity : (module Handler) -> indices:IndexTracker.t list -> unit

val to_json : (module Handler) -> indices:IndexTracker.t list -> Yojson.Safe.t

val to_dot : (module Handler) -> indices:IndexTracker.t list -> string

val is_transitive_successor
  :  (module Handler) ->
  source:Type.Primitive.t ->
  target:Type.Primitive.t ->
  bool

val instantiate_successors_parameters
  :  (module Handler) ->
  source:Type.t ->
  target:Type.Primitive.t ->
  Type.Parameter.t list option
