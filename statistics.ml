(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre

let enabled = ref true

let cache = String.Table.create ()

let size = 500

let flush_timeout = 6.0 *. 3600.0 (* Seconds. *)

let username = Option.value (Sys.getenv "USER") ~default:(Unix.getlogin ())

let hostname = Option.value (Sys.getenv "HOSTNAME") ~default:(Unix.gethostname ())

let disable () = enabled := false

let sample ?(integers = []) ?(normals = []) ?(metadata = true) () =
  let open Configuration.Analysis in
  let local_root, start_time, log_identifier =
    match get_global () with
    | Some { local_root; start_time; log_identifier; _ } ->
        Path.last local_root, start_time, log_identifier
    | _ ->
        Log.warning "Trying to log without a global configuration";
        "LOGGED WITHOUT CONFIGURATION", 0.0, "no configuration"
  in
  let server_configuration_metadata =
    match Configuration.Server.get_global () with
    | Some { Configuration.Server.socket = { path = socket_path; _ }; saved_state_action; _ } ->
        let saved_state_metadata =
          match saved_state_action with
          | Some
              (Configuration.Server.Load
                (Configuration.Server.LoadFromFiles
                  { Configuration.Server.shared_memory_path; changed_files_path })) ->
              let changed =
                match changed_files_path with
                | Some changed -> ["changed_files_path", Path.absolute changed]
                | None -> []
              in
              ("shared_memory_path", Path.absolute shared_memory_path) :: changed
          | Some
              (Configuration.Server.Load (Configuration.Server.LoadFromProject { project_name; _ }))
            ->
              ["saved_state_project", project_name]
          | Some (Configuration.Server.Save project) -> ["save_state_to", project]
          | None -> []
        in
        ("socket_path", Path.absolute socket_path) :: saved_state_metadata
    | None -> []
  in
  let normals =
    if metadata then
      [
        "binary", Sys.argv.(0);
        "root", local_root;
        "username", username;
        "hostname", hostname;
        "identifier", log_identifier;
      ]
      @ server_configuration_metadata
      @ normals
    else
      normals
  in
  let integers =
    if metadata then
      ["time", Unix.time () |> Int.of_float; "start_time", start_time |> Int.of_float] @ integers
    else
      integers
  in
  Yojson.Safe.to_string
    (`Assoc
      [
        "int", `Assoc (List.map ~f:(fun (label, data) -> label, `Int data) integers);
        "normal", `Assoc (List.map ~f:(fun (label, data) -> label, `String data) normals);
      ])


let last_flush_timestamp = ref (Unix.time ())

let flush () =
  let flush_category ~key ~data =
    Configuration.Analysis.get_global ()
    >>= (fun { Configuration.Analysis.logger; _ } -> logger)
    >>| (fun logger -> Format.sprintf "%s %s" logger key)
    >>| (fun command ->
          let out_channel = Unix.open_process_out command in
          List.iter ~f:(Printf.fprintf out_channel "%s\n") data;
          Out_channel.flush out_channel;
          Unix.close_process_out out_channel |> ignore)
    |> ignore
  in
  if !enabled then
    Hashtbl.iteri ~f:flush_category cache;
  Hashtbl.clear cache;
  last_flush_timestamp := Unix.time ()


let flush_cache = flush

let log ?(flush = false) ?(randomly_log_every = 1) category sample =
  ( if Random.int randomly_log_every = 0 then
      match Hashtbl.find cache category with
      | Some samples -> Hashtbl.set ~key:category ~data:(sample :: samples) cache
      | _ -> Hashtbl.set ~key:category ~data:[sample] cache );
  let samples_count () =
    Hashtbl.fold cache ~init:0 ~f:(fun ~key:_ ~data count -> count + List.length data)
  in
  let exceeds_timeout () =
    let current_time = Unix.time () in
    current_time -. !last_flush_timestamp >= flush_timeout
  in
  if flush || samples_count () >= size || exceeds_timeout () then
    flush_cache ()


let performance
    ?(flush = false)
    ?randomly_log_every
    ?always_log_time_threshold
    ?(section = `Performance)
    ?(category = "perfpipe_pyre_performance")
    ~name
    ~timer
    ?phase_name
    ?(integers = [])
    ?(normals = [])
    ()
  =
  let microseconds = Timer.stop_in_us timer in
  let randomly_log_every =
    match always_log_time_threshold with
    | Some threshold ->
        let threshold_microseconds = Int.of_float (threshold *. 1000000.0) in
        if microseconds > threshold_microseconds then None else randomly_log_every
    | None -> randomly_log_every
  in
  Log.log ~section "%s: %fs" (String.capitalize name) (Int.to_float microseconds /. 1000000.0);
  Profiling.log_performance_event (fun () ->
      let tags =
        match phase_name with
        | None -> normals
        | Some name -> ("phase_name", name) :: normals
      in
      Profiling.Event.create name ~event_type:(Duration microseconds) ~tags);
  sample
    ~integers:(("elapsed_time", microseconds) :: integers)
    ~normals:(("name", name) :: normals)
    ()
  |> log ~flush ?randomly_log_every category


let event
    ?(flush = false)
    ?randomly_log_every
    ?(section = `Event)
    ~name
    ?(integers = [])
    ?(normals = [])
    ()
  =
  let integer (name, value) = Format.asprintf "%s: %d" name value in
  let normal (name, value) = Format.asprintf "%s: %s" name value in
  Log.log
    ~section
    "%s (%s)"
    (String.capitalize name)
    (List.map ~f:integer integers @ List.map ~f:normal normals |> String.concat ~sep:", ");
  sample ~integers ~normals:(("name", name) :: normals) ()
  |> log ?randomly_log_every ~flush "perfpipe_pyre_events"


let log_exception caught_exception ~fatal ~origin =
  event
    ~section:`Error
    ~flush:true
    ~name:"uncaught exception"
    ~integers:[]
    ~normals:
      [
        "exception", Exn.to_string caught_exception;
        "exception backtrace", Printexc.get_backtrace ();
        "exception origin", origin;
        ("fatal", if fatal then "true" else "false");
      ]
    ()


let log_worker_exception ~pid ~origin status =
  let message =
    match status with
    | Caml.Unix.WEXITED exit_code ->
        Printf.sprintf "Worker process %d exited with code %d" pid exit_code
    | Caml.Unix.WSTOPPED signal_number ->
        Printf.sprintf "Worker process %d was stopped by signal %d" pid signal_number
    | Caml.Unix.WSIGNALED signal_number ->
        Printf.sprintf "Worker process %d was kill by signal %d" pid signal_number
  in
  event
    ~section:`Error
    ~flush:true
    ~name:"Worker exited abnormally"
    ~integers:[]
    ~normals:
      [
        "exception", message;
        "exception backtrace", Printexc.get_backtrace ();
        "exception origin", origin;
        "fatal", "true";
      ]
    ()


let server_telemetry normals =
  sample ~integers:["time", Unix.time () |> Int.of_float] ~normals ~metadata:false ()
  |> log ~flush:true "perfpipe_pyre_server_telemetry"
