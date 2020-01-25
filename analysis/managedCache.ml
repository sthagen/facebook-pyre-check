(* Copyright (c) 2019-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core

module type In = sig
  module PreviousEnvironment : Environment.PreviousEnvironment

  module Key : Memory.KeyType

  module Value : Memory.ComparableValueType

  module KeySet : Set.S with type Elt.t = Key.t

  module HashableKey : Hashable with type t := Key.t

  val lazy_incremental : bool

  val produce_value : PreviousEnvironment.ReadOnly.t -> Key.t -> track_dependencies:bool -> Value.t

  val filter_upstream_dependency : SharedMemoryKeys.dependency -> Key.t option
end

module Make (In : In) = struct
  module UnmanagedCache = struct
    let cache = In.HashableKey.Table.create ()

    let clear () = In.HashableKey.Table.clear cache
  end

  (* For some reason this no longer matches our mli when I directly include this :/ *)
  module EnvironmentTable = Environment.EnvironmentTable.WithCache (struct
    include In

    (* I'd like to remove the distinction between triggers and values in general, but for now we can
       just make sure that any new managed caches don't rely on it *)
    type trigger = In.Key.t

    let convert_trigger = Fn.id

    let key_to_trigger = Fn.id

    module TriggerSet = KeySet

    let lazy_incremental = In.lazy_incremental

    (* In legacy mode we're actually using process-local caches, so we never need to do a
       legacy-style invalidate in the way this interface is designed to do *)
    let legacy_invalidated_keys _ = KeySet.empty

    (* All of these functions are used for the shared memory debugging functionality. They all rely
       on the ability to exhaustively list your keys, which is doable for traditional environments,
       but the idea of a managed cache is using this for situations where the keys are not known
       ahead of time. For now we'll just ignore this debugging stuff, and maybe return to it later. *)
    let all_keys _ = []

    let serialize_value _ = "Not used"

    let show_key _ = "Not used"

    let equal_value _ _ = false
  end)

  include EnvironmentTable

  let update_this_and_all_preceding_environments ast_environment ~scheduler ~configuration =
    let () =
      (* We really need the configuration to be consistent between the update call and the get call.
         In theory we could use the configuration we're passed, but using the global one
         consistently makes this more un-screw-up-able *)
      match Configuration.Analysis.get_global () with
      | None
      | Some { incremental_style = FineGrained; _ } ->
          ()
      | _ ->
          Scheduler.once_per_worker scheduler ~configuration ~f:UnmanagedCache.clear;
          UnmanagedCache.clear ()
    in
    (* In both cases we need to produce a UpdateResult, but in the legacy case this will be a
       basically a no-op because of all_keys = []. *)
    update_this_and_all_preceding_environments ast_environment ~scheduler ~configuration


  module ReadOnly = struct
    include ReadOnly

    let get read_only ?dependency key =
      match Configuration.Analysis.get_global () with
      | None
      | Some { incremental_style = FineGrained; _ } ->
          get read_only ?dependency key
      | _ ->
          let default () =
            In.produce_value (upstream_environment read_only) key ~track_dependencies:false
          in
          Hashtbl.find_or_add UnmanagedCache.cache key ~default
  end
end
