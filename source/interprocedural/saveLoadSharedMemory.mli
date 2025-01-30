(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

val exception_to_error
  :  error:'a ->
  message:string ->
  f:(unit -> ('b, 'a) result) ->
  ('b, 'a) result

module Usage : sig
  type error =
    | LoadError
    | Stale
  [@@deriving compare, show]

  type t =
    | Used
    | Unused of error
  [@@deriving compare, show]
end

module type SingleValueValueType = sig
  type t

  val prefix : Hack_parallel.Std.Prefix.t

  val name : string
end

(* Support storing / loading a single OCaml value into / from the shared memory, for caching
   purposes. *)
module MakeSingleValue (Value : SingleValueValueType) : sig
  val load_from_cache : unit -> (Value.t, Usage.t) result

  val save_to_cache : Value.t -> unit
end

module type KeyValueValueType = sig
  type t

  val prefix : Hack_parallel.Std.Prefix.t

  val handle_prefix : Hack_parallel.Std.Prefix.t

  val description : string
end

(* Support storing / loading key-value pairs into / from the shared memory. *)
module MakeKeyValue (Key : Hack_parallel.Std.SharedMemory.KeyType) (Value : KeyValueValueType) : sig
  include
    Hack_parallel.Std.SharedMemory.FirstClassWithKeys.S
      with type key = Key.t
       and type value = Value.t

  val cleanup : t -> unit

  val save_to_cache : t -> unit

  val load_from_cache : unit -> (t, Usage.t) result
end
