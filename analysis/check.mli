(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
module Error = AnalysisError

module type Signature = sig
  val name : string

  val run
    :  configuration:Configuration.Analysis.t ->
    environment:TypeEnvironment.ReadOnly.t ->
    source:Source.t ->
    Error.t list
end

val get_check_to_run : check_name:string -> (module Signature) option
