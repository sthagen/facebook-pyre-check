(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Assumptions

type order = {
  handler: (module ClassHierarchy.Handler);
  constructor: Type.t -> protocol_assumptions:ProtocolAssumptions.t -> Type.t option;
  attributes: Type.t -> assumptions:Assumptions.t -> AnnotatedAttribute.instantiated list option;
  is_protocol: Type.t -> protocol_assumptions:ProtocolAssumptions.t -> bool;
  assumptions: Assumptions.t;
}

val solve_less_or_equal
  :  order ->
  constraints:TypeConstraints.t ->
  left:Type.t ->
  right:Type.t ->
  TypeConstraints.t list

val always_less_or_equal : order -> left:Type.t -> right:Type.t -> bool

val is_compatible_with : order -> left:Type.t -> right:Type.t -> bool

val join : order -> Type.t -> Type.t -> Type.t

val meet : order -> Type.t -> Type.t -> Type.t

val widen
  :  order ->
  widening_threshold:int ->
  previous:Type.t ->
  next:Type.t ->
  iteration:int ->
  Type.t

module OrderedConstraints : TypeConstraints.OrderedConstraintsType with type order = order

val instantiate_protocol_parameters
  :  order ->
  candidate:Type.t ->
  protocol:Ast.Identifier.t ->
  Type.Parameter.t list option

val solve_ordered_types_less_or_equal
  :  order ->
  left:Type.OrderedTypes.t ->
  right:Type.OrderedTypes.t ->
  constraints:TypeConstraints.t ->
  TypeConstraints.t sexp_list
