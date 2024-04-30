(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)


module List = Hack_core.Hack_core_list
module Daemon = Hack_utils.Daemon
module Fork = Hack_utils.Fork
module Exit_status = Hack_utils.Exit_status
module Measure = Hack_utils.Measure
module PrintSignal = Hack_utils.PrintSignal
module String_utils = Hack_utils.String_utils
module Utils = Hack_utils.Utils
open Hack_heap

(*****************************************************************************
 * Module building workers
 *
 * A worker is a subprocess executing an arbitrary function
 *
 * You should first create a fixed amount of workers and then use those
 * because the amount of workers is limited and to make the load-balancing
 * of tasks better (cf multiWorker.ml)
 *
 * On Unix, we "spawn" workers when initializing Hack. Then, this
 * worker, "fork" an ephemeral worker for each incoming request. The forked
 * wephemeral worker will die after processing a single request. (We use this
 * two-layer architecture because, *if* the long-lived worker was created when the
 * original process was still very small, those forks run much faster than forking
 * off the original process which will eventually have a large heap).
 *
 * A worker never handle more than one request at a time.
 *
 *****************************************************************************)

exception Worker_exited_abnormally of int * Unix.process_status
exception Worker_exception of string * Printexc.raw_backtrace
exception Worker_oomed
exception Worker_busy
exception Worker_killed

type send_job_failure =
  | Worker_already_exited of Unix.process_status
  | Other_send_job_failure of exn

exception Worker_failed_to_send_job of send_job_failure

(* The maximum amount of workers *)
let max_workers = 1000



(*****************************************************************************
 * The job executed by the worker.
 *
 * The 'serializer' is the job continuation: it is a function that must
 * be called at the end of the request in order to send back the result
 * to the master (this is "internal business", this is not visible outside
 * this module). The ephemeral worker will provide the expected function.
 * cf 'send_result' in 'ephemeral_worker_main'.
 *
 *****************************************************************************)

type request = Request of (serializer -> unit)
and serializer = { send: 'a. 'a -> unit }
and void (* an empty type *)
type call_wrapper = { wrap: 'x 'b. ('x -> 'b) -> 'x -> 'b }

(*****************************************************************************
 * Everything we need to know about a worker.
 *
 *****************************************************************************)

type t = {

  (* The call wrapper will wrap any workload sent to the worker (via "call"
   * below) before invoking the workload.
   *
   * That is, when calling the worker with workload `f x`, it will be wrapped
   * as `wrap (f x)`.
   *
   * This allows universal handling of workload at the time we create the actual
   * workers. For example, this can be useful to handle exceptions uniformly
   * across workers regardless what workload is called on them. *)
  call_wrapper: call_wrapper;

  (* Sanity check: is the worker still available ? *)
  mutable killed: bool;

  (* Sanity check: is the worker currently busy ? *)
  mutable busy: bool;

  (* A reference to the worker process. *)
  handle: (void, request) Daemon.handle;

}



(*****************************************************************************
 * The handle is what we get back when we start a job. It's a "future"
 * (sometimes called a "promise"). The scheduler uses the handle to retrieve
 * the result of the job when the task is done (cf multiWorker.ml).
 *
 *****************************************************************************)

type 'a handle = 'a delayed ref

and 'a delayed =
  | Processing of 'a ephemeral_worker
  | Cached of 'a
  | Failed of exn

and 'a ephemeral_worker = {

  worker: t;      (* The associated worker *)

  (* The file descriptor we might pass to select in order to
     wait for the ephemeral worker to finish its job. *)
  infd: Unix.file_descr;

  (* A blocking function that returns the job result. *)
  result: unit -> 'a;

}

module Response = struct
  type 'a t =
    | Success of { result: 'a; stats: Measure.record_data }
    | Failure of { exn: string; backtrace: Printexc.raw_backtrace }
end


(*****************************************************************************
 * Entry point for spawned worker.
 *
 *****************************************************************************)

let ephemeral_worker_main ic oc =
  let start_user_time = ref 0.0 in
  let start_system_time = ref 0.0 in
  let send_response response =
    let s = Marshal.to_string response [Marshal.Closures] in
    Daemon.output_string oc s;
    Daemon.flush oc
  in
  let send_result result =
    let tm = Unix.times () in
    let end_user_time = tm.Unix.tms_utime +. tm.Unix.tms_cutime in
    let end_system_time = tm.Unix.tms_stime +. tm.Unix.tms_cstime in
    Measure.sample "worker_user_time" (end_user_time -. !start_user_time);
    Measure.sample "worker_system_time" (end_system_time -. !start_system_time);

    let stats = Measure.serialize (Measure.pop_global ()) in
    send_response (Response.Success { result; stats })
  in
  try
    Measure.push_global ();
    let Request do_process = Daemon.from_channel ic in
    let tm = Unix.times () in
    start_user_time := tm.Unix.tms_utime +. tm.Unix.tms_cutime;
    start_system_time := tm.Unix.tms_stime +. tm.Unix.tms_cstime;
    do_process { send = send_result };
    exit 0
  with
  | End_of_file ->
      exit 1
  | SharedMemory.Out_of_shared_memory ->
      Exit_status.(exit Out_of_shared_memory)
  | SharedMemory.Hash_table_full ->
      Exit_status.(exit Hash_table_full)
  | SharedMemory.Heap_full ->
      Exit_status.(exit Heap_full)
  | SharedMemory.Sql_assertion_failure err_num ->
      let exit_code = match err_num with
        | 11 -> Exit_status.Sql_corrupt
        | 14 -> Exit_status.Sql_cantopen
        | 21 -> Exit_status.Sql_misuse
        | _ -> Exit_status.Sql_assertion_failure
      in
      Exit_status.exit exit_code
  | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      send_response (Response.Failure { exn = Base.Exn.to_string exn; backtrace });
      exit 0

let worker_main restore state (ic, oc) =
  restore state;
  let in_fd = Daemon.descr_of_in_channel ic in
  if !Utils.profile then Utils.log := prerr_endline;
  try
    while true do
      (* Wait for an incoming job : is there something to read?
         But we don't read it yet. It will be read by the forked ephemeral worker. *)
      let readyl, _, _ = Unix.select [in_fd] [] [] (-1.0) in
      if readyl = [] then exit 0;
      (* We fork an ephemeral worker for every incoming request.
         And let it die after one request. This is the quickest GC. *)
      match Fork.fork() with
      | 0 -> ephemeral_worker_main ic oc
      | pid ->
          (* Wait for the ephemeral worker termination... *)
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED 1 ->
              raise End_of_file
          | Unix.WEXITED code ->
              Printf.printf "Worker exited (code: %d)\n" code;
              flush stdout;
              Stdlib.exit code
          | Unix.WSIGNALED x ->
              let sig_str = PrintSignal.string_of_signal x in
              Printf.printf "Worker interrupted with signal: %s\n" sig_str;
              exit 2
          | Unix.WSTOPPED x ->
              Printf.printf "Worker stopped with signal: %d\n" x;
              exit 3
    done;
    assert false
  with End_of_file -> exit 0

type 'a entry_state = 'a * Gc.control * SharedMemory.handle
type 'a entry = ('a entry_state, request, void) Daemon.entry

let entry_counter = ref 0
let register_entry_point ~restore =
  incr entry_counter;
  let restore (st, gc_control, heap_handle) =
    restore st;
    SharedMemory.connect heap_handle;
    Gc.set gc_control in
  let name = Printf.sprintf "ephemeral_worker_%d" !entry_counter in
  Daemon.register_entry_point name (worker_main restore)

(**************************************************************************
 * Creates a pool of workers.
 *
 **************************************************************************)


let current_worker_id = ref 0

(* Build one worker. *)
let make_one spawn id =
  if id >= max_workers then failwith "Too many workers";
  let handle = spawn () in
  let wrap f input =
    current_worker_id := id;
    f input
  in
  let worker = { call_wrapper = { wrap }; busy = false; killed = false; handle } in
  worker

(** Make a few workers. When workload is given to a worker (via "call" below),
 * the workload is wrapped in the call_wrapper. *)
let make ~saved_state ~entry ~nbr_procs ~gc_control ~heap_handle =
  let spawn _log_fd =
    Unix.clear_close_on_exec heap_handle.SharedMemory.h_fd;
    let handle =
      Daemon.spawn
        (Daemon.null_fd (), Unix.stdout, Unix.stderr)
        entry
        (saved_state, gc_control, heap_handle) in
    Unix.set_close_on_exec heap_handle.SharedMemory.h_fd;
    handle
  in
  let made_workers = ref [] in
  for n = 1 to nbr_procs do
    made_workers := make_one spawn n :: !made_workers
  done;
  !made_workers

let current_worker_id () = !current_worker_id

(**************************************************************************
 * Send a job to a worker
 *
 **************************************************************************)

let call w (type a) (type b) (f : a -> b) (x : a) : b handle =
  if w.killed then raise Worker_killed;
  if w.busy then raise Worker_busy;
  let { Daemon.pid = worker_pid; channels = (inc, outc) } = w.handle in
  (* Prepare ourself to read answer from the ephemeral_worker. *)
  let result () : b =
    match Daemon.input_value inc with
    | Response.Success { result; stats } ->
      Measure.merge ~from:(Measure.deserialize stats) ();
      result
    | Response.Failure { exn; backtrace } ->
      raise (Worker_exception (exn, backtrace))
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      match Unix.waitpid [Unix.WNOHANG] worker_pid with
      | 0, _ -> Printexc.raise_with_backtrace exn backtrace
      | _, Unix.WEXITED i when i = Exit_status.(exit_code Out_of_shared_memory) ->
          raise SharedMemory.Out_of_shared_memory
      | _, exit_status ->
          raise (Worker_exited_abnormally (worker_pid, exit_status))
  in
  (* Mark the worker as busy. *)
  let infd = Daemon.descr_of_in_channel inc in
  let ephemeral_worker = { result; infd; worker = w; } in
  w.busy <- true;
  let request =
    let { wrap } = w.call_wrapper in
    Request (fun { send } -> send (wrap f x))
  in
  (* Send the job to the ephemeral worker. *)
  let () = try Daemon.to_channel outc
                 ~flush:true ~flags:[Marshal.Closures]
                 request with
  | e ->
      match Unix.waitpid [Unix.WNOHANG] worker_pid with
      | 0, _ ->
          raise (Worker_failed_to_send_job (Other_send_job_failure e))
      | _, status ->
          raise (Worker_failed_to_send_job (Worker_already_exited status))
  in
  (* And returned the 'handle'. *)
  ref (Processing ephemeral_worker)


(**************************************************************************
 * Read results from a handle.
 * This might block if the worker hasn't finished yet.
 *
 **************************************************************************)

let is_oom_failure msg =
  (String_utils.string_starts_with msg "Subprocess") &&
  (String_utils.is_substring "signaled -7" msg)

let get_result d =
  match !d with
  | Cached x -> x
  | Failed exn -> raise exn
  | Processing s ->
      try
        let res = s.result () in
        s.worker.busy <- false;
        d := Cached res;
        res
      with
      | Failure (msg) when is_oom_failure msg ->
          raise Worker_oomed
      | exn ->
          s.worker.busy <- false;
          d := Failed exn;
          raise exn


(*****************************************************************************
 * Our polling primitive on workers
 * Given a list of handle, returns the ones that are ready.
 *
 *****************************************************************************)

type 'a selected = {
  readys: 'a handle list;
  waiters: 'a handle list;
}

let get_processing ds =
  List.rev_filter_map
    ds
    ~f:(fun d -> match !d with Processing p -> Some p | _ -> None)

let select ds =
  let processing = get_processing ds in
  let fds = List.map ~f:(fun {infd; _} -> infd) processing in
  let ready_fds, _, _ =
    if fds = [] || List.length processing <> List.length ds then
      [], [], []
    else
      Unix.select fds [] [] ~-.1. in
  List.fold_right
    ~f:(fun d { readys ; waiters } ->
        match !d with
        | Cached _ | Failed _ ->
            { readys = d :: readys ; waiters }
        | Processing s when List.mem ready_fds s.infd ->
            { readys = d :: readys ; waiters }
        | Processing _ ->
            { readys ; waiters = d :: waiters})
    ~init:{ readys = [] ; waiters = [] }
    ds

let get_worker h =
  match !h with
  | Processing {worker; _} -> worker
  | Cached _
  | Failed _ -> invalid_arg "Worker.get_worker"

(**************************************************************************
 * Worker termination
 **************************************************************************)

let kill w =
  if not w.killed then begin
    w.killed <- true;
    Daemon.kill_and_wait w.handle
  end

let exception_backtrace = function
  | Worker_exception (_, backtrace) -> backtrace
  | _ -> Printexc.get_raw_backtrace ()
