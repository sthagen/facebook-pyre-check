(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast

type t [@@deriving show]

type resolve_statement_result_t =
  | Unreachable
  | Reachable of {
      resolution: t;
      errors: AnalysisError.t list;
    }

val create
  :  global_resolution:GlobalResolution.t ->
  type_info_store:TypeInfo.Store.t ->
  resolve_expression:(resolution:t -> Expression.t -> t * TypeInfo.Unit.t) ->
  resolve_statement:(resolution:t -> Statement.t -> resolve_statement_result_t) ->
  ?parent:Reference.t ->
  unit ->
  t

val resolve_expression : t -> Expression.t -> t * Type.t

val resolve_expression_to_type : t -> Expression.t -> Type.t

val resolve_expression_to_type_with_locals
  :  t ->
  locals:(Reference.t * TypeInfo.Unit.t) list ->
  Expression.t ->
  Type.t

val resolve_expression_to_type_info : t -> Expression.t -> TypeInfo.Unit.t

val resolve_reference : t -> Reference.t -> Type.t

val resolve_statement : t -> Statement.t -> resolve_statement_result_t

val resolve_assignment : t -> Statement.Assign.t -> t

(* Return None when the assertion cannot be satisfied *)
val resolve_assertion : t -> asserted_expression:Expression.t -> t option

val resolve_attribute_access : t -> base_type:Type.t -> attribute:string -> Type.t

val has_nontemporary_type_info : reference:Reference.t -> t -> bool

val new_local : ?temporary:bool -> t -> reference:Reference.t -> type_info:TypeInfo.Unit.t -> t

val refine_local : ?temporary:bool -> t -> reference:Reference.t -> type_info:TypeInfo.Unit.t -> t

val new_local_with_attributes
  :  ?temporary:bool ->
  t ->
  name:Reference.t ->
  attribute_path:Reference.t ->
  base_type_info:TypeInfo.Unit.t option ->
  type_info:TypeInfo.Unit.t ->
  t

val refine_local_with_attributes
  :  ?temporary:bool ->
  t ->
  name:Reference.t ->
  attribute_path:Reference.t ->
  base_type_info:TypeInfo.Unit.t option ->
  type_info:TypeInfo.Unit.t ->
  t

val get_local : ?global_fallback:bool -> reference:Reference.t -> t -> TypeInfo.Unit.t option

val get_local_with_attributes
  :  ?global_fallback:bool ->
  name:Reference.t ->
  attribute_path:Reference.t ->
  t ->
  TypeInfo.Unit.t option

val unset_local : t -> reference:Reference.t -> t

val clear_temporary_type_info : t -> t

val is_global : t -> reference:Reference.t -> bool

val add_type_variable : t -> variable:Type.Variable.t -> t

val type_variable_exists : t -> variable:Type.Variable.t -> bool

val all_type_variables_in_scope : t -> Type.Variable.t list

val type_info_store : t -> TypeInfo.Store.t

val refinements_equal : t -> t -> bool

val meet_refinements : t -> t -> t

val outer_join_refinements : t -> t -> t

val outer_widen_refinements : iteration:int -> widening_threshold:int -> t -> t -> t

val update_existing_refinements : old_resolution:t -> new_resolution:t -> t

val update_refinements_with_filter
  :  old_resolution:t ->
  new_resolution:t ->
  filter:(Reference.t -> TypeInfo.Unit.t -> bool) ->
  t

val with_type_info_store : t -> type_info_store:TypeInfo.Store.t -> t

val parent : t -> Reference.t option

val with_parent : t -> parent:Reference.t option -> t

val resolution_for_statement
  :  local_annotations:TypeInfo.ForFunctionBody.ReadOnly.t option ->
  parent:Reference.t option ->
  statement_key:int ->
  t ->
  t

val is_consistent_with : t -> Type.t -> Type.t -> expression:Ast.Expression.t option -> bool

val global_resolution : t -> GlobalResolution.t

(* Attribute defined by `__getattr__`. *)
val fallback_attribute
  :  ?accessed_through_class:bool ->
  ?instantiated:Type.t option ->
  resolution:t ->
  name:Identifier.t ->
  Type.Primitive.t ->
  AnnotatedAttribute.instantiated option
