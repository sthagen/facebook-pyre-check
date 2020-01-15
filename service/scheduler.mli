(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Hack_parallel.Std
module Daemon = Daemon

type t

val create : configuration:Configuration.Analysis.t -> unit -> t

val run_process : configuration:Configuration.Analysis.t -> (unit -> 'result) -> 'result

val map_reduce
  :  t ->
  ?bucket_size:int ->
  configuration:Configuration.Analysis.t ->
  initial:'state ->
  map:('state -> 'input list -> 'intermediate) ->
  reduce:('intermediate -> 'state -> 'state) ->
  inputs:'input list ->
  unit ->
  'state

val iter
  :  ?bucket_size:int ->
  t ->
  configuration:Configuration.Analysis.t ->
  f:('input list -> unit) ->
  inputs:'input list ->
  unit

val single_job : t -> f:('a -> 'b) -> 'a -> 'b

val is_parallel : t -> bool

val workers : t -> Worker.t list

val mock : unit -> t

val destroy : t -> unit

val once_per_worker : t -> configuration:Configuration.Analysis.t -> f:(unit -> unit) -> unit
