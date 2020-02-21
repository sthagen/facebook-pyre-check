(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)
open Ast
open SharedMemoryKeys

module AliasReadOnly : sig
  include Environment.ReadOnly

  val get_alias : t -> ?dependency:dependency -> Type.Primitive.t -> Type.alias option

  val unannotated_global_environment : t -> UnannotatedGlobalEnvironment.ReadOnly.t

  val empty_stub_environment : t -> EmptyStubEnvironment.ReadOnly.t

  val parse_annotation_without_validating_type_parameters
    :  t ->
    ?modify_aliases:(Type.alias -> Type.alias) ->
    ?dependency:dependency ->
    ?allow_untracked:bool ->
    Expression.t ->
    Type.t

  val parse_as_concatenation
    :  t ->
    ?dependency:dependency ->
    Expression.t ->
    (Type.t Type.OrderedTypes.Concatenation.Middle.t, Type.t) Type.OrderedTypes.Concatenation.t
    option

  val parse_as_parameter_specification_instance_annotation
    :  t ->
    ?dependency:dependency ->
    variable_parameter_annotation:Expression.t ->
    keywords_parameter_annotation:Expression.t ->
    Type.Variable.Variadic.Parameters.t option
end

include
  Environment.S
    with module ReadOnly = AliasReadOnly
     and module PreviousEnvironment = EmptyStubEnvironment
