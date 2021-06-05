(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
module Path = PyrePath

module CheckConfiguration = struct
  type t = {
    (* Source file discovery *)
    source_paths: Configuration.SourcePaths.t;
    search_paths: SearchPath.t list;
    excludes: string list;
    checked_directory_allowlist: Path.t list;
    checked_directory_blocklist: Path.t list;
    extensions: Configuration.Extension.t list;
    (* Auxiliary paths *)
    log_path: Path.t;
    global_root: Path.t;
    local_root: Path.t option;
    (* Type checking controls *)
    debug: bool;
    strict: bool;
    python_version: Configuration.PythonVersion.t;
    show_error_traces: bool;
    (* Parallelism controls *)
    parallel: bool;
    number_of_workers: int;
    (* Memory controls *)
    shared_memory: Configuration.SharedMemory.t;
    (* Logging controls *)
    additional_logging_sections: string list;
    remote_logging: Configuration.RemoteLogging.t option;
    profiling_output: string option;
    memory_profiling_output: string option;
  }
  [@@deriving sexp, compare, hash]

  let of_yojson json =
    let open Yojson.Safe.Util in
    let open JsonParsing in
    (* Parsing logic *)
    try
      let source_paths =
        json
        |> member "source_paths"
        |> Configuration.SourcePaths.of_yojson
        |> Result.ok_or_failwith
      in
      let search_paths =
        json
        |> list_member
             "search_paths"
             ~f:(fun element -> to_string element |> SearchPath.create)
             ~default:[]
      in
      let excludes = json |> string_list_member "excludes" ~default:[] in
      let checked_directory_allowlist =
        json |> path_list_member "checked_directory_allowlist" ~default:[]
      in
      let checked_directory_blocklist =
        json |> path_list_member "checked_directory_blocklist" ~default:[]
      in
      let extensions =
        json
        |> string_list_member "extensions" ~default:[]
        |> List.map ~f:Configuration.Extension.create_extension
      in
      let log_path = json |> path_member "log_path" in
      let global_root = json |> path_member "global_root" in
      let local_root = json |> optional_path_member "local_root" in
      let debug = json |> bool_member "debug" ~default:false in
      let strict = json |> bool_member "strict" ~default:false in
      let python_version =
        json
        |> member "python_version"
        |> function
        | `Null -> Configuration.PythonVersion.default
        | _ as json -> Configuration.PythonVersion.of_yojson json |> Result.ok_or_failwith
      in
      let show_error_traces = json |> bool_member "show_error_traces" ~default:false in
      let parallel = json |> bool_member "parallel" ~default:false in
      let number_of_workers = json |> int_member "number_of_workers" ~default:1 in
      let shared_memory =
        json
        |> member "shared_memory"
        |> function
        | `Null -> Configuration.SharedMemory.default
        | _ as json -> Configuration.SharedMemory.of_yojson json |> Result.ok_or_failwith
      in
      let additional_logging_sections =
        json |> string_list_member "additional_logging_sections" ~default:[]
      in
      let remote_logging =
        json
        |> member "remote_logging"
        |> function
        | `Null -> None
        | _ as json ->
            Configuration.RemoteLogging.of_yojson json |> Result.ok_or_failwith |> Option.some
      in
      let profiling_output = json |> optional_string_member "profiling_output" in
      let memory_profiling_output = json |> optional_string_member "memory_profiling_output" in
      Result.Ok
        {
          source_paths;
          search_paths;
          excludes;
          checked_directory_allowlist;
          checked_directory_blocklist;
          extensions;
          log_path;
          global_root;
          local_root;
          debug;
          strict;
          python_version;
          show_error_traces;
          parallel;
          number_of_workers;
          shared_memory;
          additional_logging_sections;
          remote_logging;
          profiling_output;
          memory_profiling_output;
        }
    with
    | Type_error (message, _)
    | Undefined (message, _) ->
        Result.Error message
    | other_exception -> Result.Error (Exn.to_string other_exception)
end

let run_check _configuration_file = Log.warning "Coming soon..."

let command =
  let filename_argument = Command.Param.(anon ("filename" %: Filename.arg_type)) in
  Command.basic
    ~summary:"Runs a full check without a server"
    (Command.Param.map filename_argument ~f:(fun filename () -> run_check filename))
