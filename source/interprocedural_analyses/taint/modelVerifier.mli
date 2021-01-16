(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis

(* Exposed for testing. *)
val demangle_class_attribute : string -> string

val verify_signature
  :  path:Pyre.Path.t option ->
  location:Location.t ->
  normalized_model_parameters:(AccessPath.Root.t * string * Ast.Expression.Parameter.t) list ->
  name:Reference.t ->
  Type.Callable.t option ->
  (unit, ModelVerificationError.t) result

val verify_global
  :  path:Pyre.Path.t option ->
  location:Location.t ->
  resolution:Resolution.t ->
  name:Reference.t ->
  (unit, ModelVerificationError.t) result
