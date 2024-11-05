(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
module Callable = Type.Callable

module DecoratorsBeingResolved : sig
  type t [@@deriving show]

  val add : t -> assume_is_not_a_decorator:Reference.t -> t

  val not_a_decorator : t -> candidate:Reference.t -> bool

  val empty : t
end

module AssumedCallableTypes : sig
  (* This should be removed when classes can be generic over TParams, and Callable can be treated
     like any other generic protocol. *)
  type t [@@deriving show]

  val find_assumed_callable_type : candidate:Type.t -> t -> Type.t option

  val add : candidate:Type.t -> callable:Type.t -> t -> t

  val empty : t
end

module AssumedRecursiveInstantiations : sig
  type t [@@deriving show]

  val find_assumed_recursive_type_parameters
    :  candidate:Type.t ->
    target:Identifier.t ->
    t ->
    Type.Argument.t list option

  val add
    :  candidate:Type.t ->
    target:Identifier.t ->
    target_parameters:Type.Argument.t list ->
    t ->
    t

  val empty : t
end

type t = {
  decorators_being_resolved: DecoratorsBeingResolved.t;
  assumed_callable_types: AssumedCallableTypes.t;
  assumed_recursive_instantiations: AssumedRecursiveInstantiations.t;
}
[@@deriving compare, equal, sexp, hash, show]
