(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
open Network
open Scheduler
open Server
open State
open Socket
open Protocol
module Time = Core_kernel.Time_ns.Span
module Request = Server.Request
module Connections = Server.Connections.Unix

exception AlreadyRunning

let computation_thread
    request_queue
    ({ Configuration.Server.pid_path; configuration = analysis_configuration; _ } as configuration)
    ({ Server.State.ast_environment; open_documents; _ } as state)
  =
  let errors_to_lsp_responses errors =
    let build_file_to_error_map error_list =
      let table = String.Table.create () in
      let add_to_table error =
        let update = function
          | None -> [error]
          | Some errors -> error :: errors
        in
        let key = Analysis.AnalysisError.Instantiated.path error in
        Hashtbl.update table key ~f:update
      in
      let add_empty_error_array reference =
        let update = function
          | None -> []
          | Some errors -> errors
        in
        let open Analysis in
        reference
        |> Analysis.AstEnvironment.ReadOnly.get_real_path_relative
             (AstEnvironment.read_only ast_environment)
             ~configuration:analysis_configuration
        >>| Hashtbl.update table ~f:update
        |> ignore
      in
      Ast.Reference.Table.iter_keys open_documents ~f:add_empty_error_array;
      List.iter error_list ~f:add_to_table;
      Hashtbl.to_alist table
    in
    let { Configuration.Analysis.local_root; _ } = analysis_configuration in
    let file_diagnostic_response (handle, errors) =
      let path =
        try
          Path.create_relative ~root:local_root ~relative:handle
          |> Path.real_path
          |> function
          | Path.Absolute path -> Some path
          | Path.Relative _ -> None
        with
        | Unix.Unix_error (name, kind, parameters) ->
            Log.log_unix_error (name, kind, parameters);
            None
      in
      path
      >>| (fun path -> LanguageServer.Protocol.PublishDiagnostics.of_errors path errors)
      >>| LanguageServer.Protocol.PublishDiagnostics.to_yojson
      >>| Yojson.Safe.to_string
      >>| fun serialized_diagnostic -> LanguageServerProtocolResponse serialized_diagnostic
    in
    build_file_to_error_map errors |> List.filter_map ~f:file_diagnostic_response
  in
  (* Decides what to broadcast to persistent clients after a request is processed. *)
  let broadcast_response state response =
    let responses =
      match response with
      | TypeCheckResponse errors -> errors_to_lsp_responses errors
      | LanguageServerProtocolResponse _ -> [response]
      | ClientExitResponse Persistent -> [response]
      | ServerUuidResponse _ -> [response]
      | _ -> []
    in
    List.iter responses ~f:(fun response ->
        Connections.broadcast_response ~connections:state.connections ~response)
  in
  let rec loop state =
    let rec handle_request ?(retries = 2) state ~origin ~request =
      try
        let process_request ~state ~request =
          Log.log ~section:`Server "Processing request %a" Protocol.Request.pp request;
          Request.process ~state ~configuration ~request
        in
        match origin with
        | Protocol.Request.PersistentSocket socket ->
            let { Request.state; response } = process_request ~state ~request in
            ( match response with
            | Some (LanguageServerProtocolResponse _)
            | Some (ServerUuidResponse _)
            | Some (ClientExitResponse Persistent) ->
                response
                >>| (fun response ->
                      Connections.write_to_persistent_client
                        ~connections:state.connections
                        ~socket
                        ~response)
                |> ignore
            | Some (TypeCheckResponse error_map) ->
                StatusUpdate.information ~message:"Done recheck." ~state ~short_message:None;
                broadcast_response state (TypeCheckResponse error_map)
            | Some _ -> Log.error "Unexpected response for persistent client request"
            | None -> () );
            state
        | Protocol.Request.JSONSocket socket ->
            let write_to_json_socket response =
              try
                Connections.write_to_json_socket ~socket response;
                Connections.remove_json_socket ~connections:state.connections ~socket |> ignore
              with
              | Unix.Unix_error (name, kind, parameters) ->
                  Connections.remove_json_socket ~connections:state.connections ~socket |> ignore;
                  Log.log_unix_error (name, kind, parameters)
              | _ ->
                  Connections.remove_json_socket ~connections:state.connections ~socket |> ignore;
                  Log.error "Socket error"
            in
            ( match request with
            | Server.Protocol.Request.StopRequest ->
                write_to_json_socket (Jsonrpc.Response.Stop.to_json ());
                Operations.stop ~reason:"explicit request" ~configuration
            | _ -> () );
            let { Request.state; response } = process_request ~state ~request in
            ( match response with
            | Some (TypeCheckResponse response) ->
                write_to_json_socket (Jsonrpc.Response.TypeErrors.to_json response)
            | Some (TypeQueryResponse response) ->
                write_to_json_socket (TypeQuery.json_socket_response response)
            | _ -> () );
            state
        | Protocol.Request.FileNotifier ->
            let { Request.state; response } = process_request ~state ~request in
            ( match response with
            | Some response -> broadcast_response state response
            | None -> () );
            state
        | Protocol.Request.NewConnectionSocket socket ->
            (* Stop requests are special - they require communicating back to the socket, but never
               return, so we need to respond to the request before processing it. *)
            (* TODO: Remove this special handling when we've switched over to json sockets
               completely. *)
            ( match request with
            | Server.Protocol.Request.StopRequest -> Socket.write socket StopResponse
            | _ -> () );
            let { Request.state; response } = process_request ~state ~request in
            ( match response with
            | Some response ->
                Socket.write_ignoring_epipe socket response;
                broadcast_response state response
            | None -> () );
            state
      with
      | uncaught_exception ->
          if retries > 0 then
            handle_request ~retries:(retries - 1) state ~origin ~request
          else
            raise uncaught_exception
    in
    let state =
      match Squeue.length request_queue with
      | 0 ->
          (* Stop if the server is idle. *)
          let current_time = Unix.time () in
          let stop_after_idle_for = 24.0 *. 60.0 *. 60.0 (* 1 day *) in
          if current_time -. state.last_request_time > stop_after_idle_for then
            Mutex.critical_section state.connections.lock ~f:(fun () ->
                Operations.stop ~reason:"idle" ~configuration);

          (* Stop if there's any inconsistencies in the .pyre directory. *)
          let last_integrity_check =
            let integrity_check_every = 60.0 (* 1 minute *) in
            if current_time -. state.last_integrity_check > integrity_check_every then
              try
                let pid =
                  let pid_file = Path.absolute pid_path |> In_channel.create in
                  protect
                    ~f:(fun () -> In_channel.input_all pid_file)
                    ~finally:(fun () -> In_channel.close pid_file)
                in
                if not (String.equal (Pid.to_string (Unix.getpid ())) pid) then
                  raise (Failure "pid mismatch");
                current_time
              with
              | _ ->
                  Mutex.critical_section state.connections.lock ~f:(fun () ->
                      Operations.stop ~reason:"failed integrity check" ~configuration)
            else
              state.last_integrity_check
          in
          (* This sleep is necessary because OCaml threads aren't pre-emptively scheduled. *)
          Unix.nanosleep 0.1 |> ignore;
          { state with last_integrity_check }
      | _ ->
          let state = { state with last_request_time = Unix.time () } in
          let origin, request = Squeue.pop request_queue in
          handle_request state ~origin ~request
    in
    loop state
  in
  loop state


let request_handler_thread
    ( ( {
          Configuration.Server.configuration =
            { expected_version; local_root; _ } as analysis_configuration;
          _;
        } as server_configuration ),
      ({ Server.State.lock; connections = raw_connections } as connections),
      request_queue )
  =
  let queue_request ~origin request =
    match request, origin with
    | Protocol.Request.StopRequest, Protocol.Request.NewConnectionSocket socket ->
        Socket.write socket StopResponse;
        Operations.stop ~reason:"explicit request" ~configuration:server_configuration
    | Protocol.Request.StopRequest, Protocol.Request.JSONSocket _ ->
        Squeue.push_or_drop request_queue (origin, request) |> ignore
    | Protocol.Request.StopRequest, _ ->
        Operations.stop ~reason:"explicit request" ~configuration:server_configuration
    | Protocol.Request.ClientConnectionRequest client, Protocol.Request.NewConnectionSocket socket
      ->
        Log.log ~section:`Server "Adding %s client" (show_client client);
        ( match client with
        | Persistent -> Connections.add_persistent_client ~connections ~socket
        | _ -> () );
        Socket.write socket (ClientConnectionResponse client)
    | Protocol.Request.ClientConnectionRequest _, _ ->
        Log.error
          "Unexpected request origin %s for connection request"
          (Protocol.Request.origin_name origin)
    | _ -> Squeue.push_or_drop request_queue (origin, request) |> ignore
  in
  let handle_readable_persistent socket =
    try
      Log.log ~section:`Server "A persistent client socket is readable.";
      let request = Socket.read socket in
      queue_request ~origin:(Protocol.Request.PersistentSocket socket) request
    with
    | End_of_file
    | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
        Log.log ~section:`Server "Persistent client disconnected";
        Connections.remove_persistent_client ~connections ~socket
  in
  let handle_readable_json_request socket =
    try
      Log.log ~section:`Server "A file notifier is readable.";
      let request = socket |> Unix.in_channel_of_descr |> LanguageServer.Protocol.read_message in
      let origin = request >>| Jsonrpc.Request.origin ~socket |> Option.value ~default:None in
      request
      >>| Jsonrpc.Request.format_request ~configuration:analysis_configuration
      |> function
      | request -> (
          match request, origin with
          | Some request, Some origin -> queue_request ~origin request
          | _, _ -> Log.log ~section:`Server "Failed to parse LSP message from JSON socket." )
    with
    | End_of_file
    | Yojson.Json_error _
    | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
        Log.log ~section:`Server "File notifier disconnected";
        Connections.remove_json_socket ~connections ~socket
  in
  let rec loop () =
    let { socket = server_socket; json_socket; persistent_clients; json_sockets; _ } =
      Mutex.critical_section lock ~f:(fun () -> !raw_connections)
    in
    if not (PyrePath.is_directory local_root) then (
      Log.error "Stopping server due to missing source root.";
      Operations.stop ~reason:"missing source root" ~configuration:server_configuration );
    let readable =
      Unix.select
        ~restart:true
        ~read:((server_socket :: json_socket :: Map.keys persistent_clients) @ json_sockets)
        ~write:[]
        ~except:[]
        ~timeout:(`After (Time.of_sec 5.0))
        ()
      |> fun { Unix.Select_fds.read; _ } -> read
    in
    let handle_socket socket =
      if Unix.File_descr.equal socket server_socket then
        let new_socket, _ =
          Log.log ~section:`Server "New client connection";
          Unix.accept server_socket
        in
        try
          Socket.write
            new_socket
            (Handshake.ServerConnected (Option.value ~default:"-1" expected_version));
          Socket.read new_socket
          |> fun Handshake.ClientConnected ->
          let request = Socket.read new_socket in
          queue_request ~origin:(Protocol.Request.NewConnectionSocket new_socket) request
        with
        | Unix.Unix_error (Unix.EPIPE, _, _) -> Log.warning "EPIPE while writing to socket."
        | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
            Log.warning "ECONNRESET while reading from socket."
        | End_of_file -> Log.warning "New client socket unreadable"
      else if Unix.File_descr.equal socket json_socket then
        try
          let new_socket, _ =
            Log.log ~section:`Server "New json client connection";
            Unix.accept json_socket
          in
          Jsonrpc.handshake_message (Option.value ~default:"-1" expected_version)
          |> LanguageServer.Types.HandshakeServer.to_yojson
          |> Connections.write_to_json_socket ~socket:new_socket;
          new_socket
          |> Unix.in_channel_of_descr
          |> LanguageServer.Protocol.read_message
          >>| LanguageServer.Types.HandshakeClient.of_yojson
          |> function
          (* TODO: Once we have fully rolled out the socket fix - we can remove this special
             handling. *)
          | Some
              (Ok
                {
                  parameters =
                    Some { LanguageServer.Types.HandshakeClientParameters.send_confirmation = true };
                  _;
                }) ->
              Connections.add_json_socket ~connections ~socket:new_socket;
              Jsonrpc.socket_added_message |> Connections.write_to_json_socket ~socket:new_socket
          | Some (Ok _) -> Connections.add_json_socket ~connections ~socket:new_socket
          | Some (Error error) -> Log.warning "Failed to parse handshake: %s" error
          | None -> Log.warning "Failed to parse handshake as LSP."
        with
        | End_of_file -> Log.warning "Got end of file while waiting for handshake."
        | Sys_error error
        | Yojson.Json_error error ->
            Log.warning "Failed to complete handshake: %s" error
      else if Mutex.critical_section lock ~f:(fun () -> Map.mem persistent_clients socket) then
        handle_readable_persistent socket
      else
        handle_readable_json_request socket
    in
    List.iter ~f:handle_socket readable;

    (* We need to introduce this nanosleep to avoid burning CPU. *)
    if List.is_empty readable then
      Unix.nanosleep 0.1 |> ignore;
    loop ()
  in
  try loop () with
  | uncaught_exception ->
      Statistics.log_exception uncaught_exception ~fatal:true ~origin:"server";
      Operations.stop ~reason:"exception" ~configuration:server_configuration


(** Main server either as a daemon or in terminal *)
let serve
    ~socket
    ~json_socket
    ~server_configuration:({ Configuration.Server.configuration; _ } as server_configuration)
  =
  Version.log_version_banner ();
  (fun () ->
    Log.log ~section:`Server "Starting daemon server loop...";
    Configuration.Server.set_global server_configuration;
    let request_queue = Squeue.create 25 in
    let connections =
      {
        lock = Mutex.create ();
        connections =
          ref { socket; json_socket; persistent_clients = Socket.Map.empty; json_sockets = [] };
      }
    in
    (* Register signal handlers. *)
    Signal.Expert.handle Signal.int (fun _ ->
        Operations.stop ~reason:"interrupt" ~configuration:server_configuration);
    Signal.Expert.handle Signal.pipe (fun _ -> ());
    Thread.create request_handler_thread (server_configuration, connections, request_queue)
    |> ignore;
    let state = Operations.start ~connections ~configuration:server_configuration () in
    try computation_thread request_queue server_configuration state with
    | uncaught_exception ->
        Statistics.log_exception uncaught_exception ~fatal:true ~origin:"server";
        Operations.stop ~reason:"exception" ~configuration:server_configuration)
  |> Scheduler.run_process ~configuration


(* Create lock file and pid file. Used for both daemon mode and in-terminal *)
let acquire_lock ~server_configuration:{ Configuration.Server.lock_path; pid_path; _ } =
  let pid = Unix.getpid () |> Pid.to_int in
  if not (Lock.grab (Path.absolute lock_path)) then
    raise AlreadyRunning;
  Out_channel.with_file (Path.absolute pid_path) ~f:(fun out_channel ->
      Format.fprintf (Format.formatter_of_out_channel out_channel) "%d%!" pid)


type run_server_daemon_entry =
  ( Socket.t * Socket.t * Configuration.Server.t,
    unit Daemon.in_channel,
    unit Daemon.out_channel )
  Daemon.entry
(** Daemon forking code *)

(** When spawned, a child is passed input/output channels that can communicate with the parent
    process. We don't currently use these, so close them after spawning. *)
let run_server_daemon_entry : run_server_daemon_entry =
  Daemon.register_entry_point
    "server_daemon"
    (fun (socket, json_socket, server_configuration) (parent_in_channel, parent_out_channel) ->
      Daemon.close_in parent_in_channel;
      Daemon.close_out parent_out_channel;

      (* Detach the from a controlling terminal *)
      Unix.Terminal_io.setsid () |> ignore;
      acquire_lock ~server_configuration;
      let _ =
        match Sys.getenv "PYRE_DISABLE_TELEMETRY" with
        | Some _ -> ()
        | None -> Telemetry.reset_budget ()
      in
      serve ~socket ~json_socket ~server_configuration)


let run
    ( {
        Configuration.Server.lock_path;
        socket = { path = socket_path; _ };
        json_socket = { path = json_socket_path; _ };
        log_path;
        daemonize;
        configuration = { incremental_style; _ } as configuration;
        _;
      } as server_configuration )
  =
  (fun () ->
    try
      let () =
        match incremental_style with
        | Configuration.Analysis.FineGrained -> Log.info "Starting up server ..."
        | Configuration.Analysis.Shallow ->
            Log.warning
              "Starting server in legacy incremental mode. Incremental Pyre check will only get \
               triggered on changed files but not on any of their dependencies."
      in
      if daemonize then
        Version.log_version_banner ();
      if not (Lock.check (Path.absolute lock_path)) then
        raise AlreadyRunning;
      Log.log ~section:`Server "Creating server socket at `%a`" Path.pp socket_path;
      let socket = Socket.initialize_unix_socket socket_path in
      let json_socket = Socket.initialize_unix_socket json_socket_path in
      if daemonize then (
        let stdin = Daemon.null_fd () in
        let log_path = Log.rotate (Path.absolute log_path) in
        let stdout = Daemon.fd_of_path log_path in
        Log.log ~section:`Server "Spawning the daemon now.";
        let ({ Daemon.pid; _ } as handle) =
          Daemon.spawn
            (stdin, stdout, stdout)
            run_server_daemon_entry
            (socket, json_socket, server_configuration)
        in
        Daemon.close handle;
        Log.log ~section:`Server "Forked off daemon with pid %d" pid;
        Log.info "Server starting in background";
        pid )
      else (
        acquire_lock ~server_configuration;
        serve ~socket ~json_socket ~server_configuration )
    with
    | AlreadyRunning ->
        Log.info "Server is already running";
        0)
  |> Scheduler.run_process ~configuration


(** Default configuration when run from command line *)
let run_start_command
    log_path
    terminal
    load_state_from
    save_state_to
    changed_files_path
    saved_state_project
    saved_state_metadata
    configuration_file_hash
    store_type_check_resolution
    _transitive
    new_incremental_check
    perform_autocompletion
    features
    verbose
    expected_version
    sections
    debug
    strict
    show_error_traces
    _infer
    sequential
    filter_directories
    ignore_all_errors
    number_of_workers
    log_identifier
    logger
    profiling_output
    memory_profiling_output
    project_root
    search_path
    taint_model_paths
    excludes
    extensions
    log_directory
    local_root
    ()
  =
  let filter_directories =
    filter_directories
    >>| String.split_on_chars ~on:[';']
    >>| List.map ~f:String.strip
    >>| List.map ~f:Path.create_absolute
  in
  let ignore_all_errors =
    ignore_all_errors
    >>| String.split_on_chars ~on:[';']
    >>| List.map ~f:String.strip
    >>| List.map ~f:Path.create_absolute
  in
  let configuration =
    let incremental_style =
      if new_incremental_check then
        Configuration.Analysis.FineGrained
      else
        Shallow
    in
    Configuration.Analysis.create
      ~verbose
      ?expected_version
      ~sections
      ~debug
      ~infer:false
      ?configuration_file_hash
      ~strict
      ~show_error_traces
      ~log_identifier
      ?logger
      ?profiling_output
      ?memory_profiling_output
      ~parallel:(not sequential)
      ?filter_directories
      ?ignore_all_errors
      ~number_of_workers
      ~project_root:(Path.create_absolute project_root)
      ~search_path:(List.map search_path ~f:SearchPath.create)
      ~taint_model_paths:(List.map taint_model_paths ~f:Path.create_absolute)
      ~excludes
      ~extensions
      ~local_root:(Path.create_absolute local_root)
      ~store_type_check_resolution
      ~incremental_style
      ~perform_autocompletion
      ~features:(Configuration.Features.create features)
      ?log_directory
      ()
  in
  let log_path = log_path >>| Path.create_absolute in
  let saved_state_action =
    match save_state_to, saved_state_project with
    | Some path, _ -> Some (Configuration.Server.Save path)
    | None, Some project_name ->
        Some
          (Configuration.Server.Load
             (Configuration.Server.LoadFromProject { project_name; metadata = saved_state_metadata }))
    | None, None -> (
        match load_state_from, changed_files_path with
        | Some shared_memory_path, _ ->
            Some
              (Load
                 (Configuration.Server.LoadFromFiles
                    {
                      Configuration.Server.shared_memory_path =
                        Path.create_absolute shared_memory_path;
                      changed_files_path = changed_files_path >>| Path.create_absolute;
                    }))
        | None, Some _ ->
            Log.error "-load-state-from must be set when -changed-files-path is passed in.";
            exit 1
        | _ -> None )
  in
  run
    (Operations.create_configuration
       ~daemonize:(not terminal)
       ?log_path
       ?saved_state_action
       configuration)
  |> ignore


let command =
  Command.basic_spec
    ~summary:"Starts a server in the foreground by default. See help for daemon options."
    Command.Spec.(
      empty
      +> flag
           "-log-file"
           (optional string)
           ~doc:(Format.sprintf "filename Log file (Default is ./pyre/server/server.stdout)")
      +> flag
           "-terminal"
           no_arg
           ~doc:"Run the server from the terminal instead of running as a daemon."
      +> flag
           "-load-state-from"
           (optional string)
           ~doc:"The Pyre server will start from the specified path if one is passed in."
      +> flag
           "-save-initial-state-to"
           (optional string)
           ~doc:
             "The Pyre server will save its initial state to the path passed in by this argument."
      +> flag
           "-changed-files-path"
           (optional string)
           ~doc:"Pyre will reanalyze the paths listed in path if started from a saved state."
      +> flag
           "-saved-state-project"
           (optional string)
           ~doc:"Pyre will attempt to fetch the project's saved state from the project name."
      +> flag
           "-saved-state-metadata"
           (optional string)
           ~doc:"The metadata to search for the project with, if any."
      +> flag
           "-configuration-file-hash"
           (optional string)
           ~doc:"SHA1 of the .pyre_configuration used to initialize this server."
      +> flag
           "-store-type-check-resolution"
           no_arg
           ~doc:"Store extra information, needed for `types_at_position` and `types` queries."
      +> flag "-transitive" no_arg ~doc:"Calculate dependencies of changed files transitively."
      +> flag "-new-incremental-check" no_arg ~doc:"Use the new fine grain dependency incremental"
      +> flag "-autocomplete" no_arg ~doc:"Process autocomplete requests."
      +> flag
           "-features"
           (optional string)
           ~doc:"Features gated by permissions sent from the client."
      ++ Specification.base_command_line_arguments)
    run_start_command
