(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
open Analysis

type error_reason = FileNotFound [@@deriving sexp, show, compare, to_yojson]

type types_by_location = ((Location.t * Type.t) list, error_reason) Result.t

type coverage_by_location =
  (LocationBasedLookup.ExpressionLevelCoverage.coverage_for_path, error_reason) Result.t

type module_path = (Ast.ModulePath.t, error_reason) Result.t

val find_all_resolved_types_for_path
  :  type_environment:TypeEnvironment.ReadOnly.t ->
  build_system:BuildSystem.t ->
  string ->
  types_by_location

val find_expression_level_coverage_for_path
  :  type_environment:TypeEnvironment.ReadOnly.t ->
  build_system:BuildSystem.t ->
  string ->
  coverage_by_location

val get_lookup
  :  build_system:BuildSystem.t ->
  type_environment:TypeEnvironment.ReadOnly.t ->
  string ->
  (LocationBasedLookup.ExpressionTypes.coverage_data_lookup, error_reason) result

val get_module_path
  :  type_environment:TypeEnvironment.ReadOnly.t ->
  build_system:BuildSystem.t ->
  string ->
  module_path
