(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core

module ExitStatus : sig
  type t =
    | Ok
    | Error
  [@@deriving sexp, compare, hash]

  val exit_code : t -> int
end

val watchman_options_of : PyrePath.t option -> Server.StartOptions.Watchman.t option Lwt.t

module ServerConfiguration : sig
  type t = {
    base: CommandStartup.BaseConfiguration.t;
    socket_path: PyrePath.t;
    strict: bool;
    show_error_traces: bool;
    additional_logging_sections: string list;
    watchman_root: PyrePath.t option;
    taint_model_paths: PyrePath.t list;
    store_type_check_resolution: bool;
    critical_files: CriticalFile.t list;
    saved_state_action: Saved_state.Action.t option;
    skip_initial_type_check: bool;
    use_lazy_module_tracking: bool;
    analyze_external_sources: bool;
  }
  [@@deriving sexp, compare, hash, of_yojson]
end

val command : Command.t
