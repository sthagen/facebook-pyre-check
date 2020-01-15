(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Hack_parallel.Std
module Daemon = Daemon
open Core

type t = {
  is_parallel: bool;
  workers: Worker.t list;
  number_of_workers: int;
}

let number_of_workers { number_of_workers; _ } = number_of_workers

let entry = Worker.register_entry_point ~restore:(fun _ -> ())

let create
    ~configuration:({ Configuration.Analysis.parallel; number_of_workers; _ } as configuration)
    ()
  =
  let heap_handle = Memory.get_heap_handle configuration in
  let workers =
    Hack_parallel.Std.Worker.make
      ~saved_state:()
      ~entry
      ~nbr_procs:number_of_workers
      ~heap_handle
      ~gc_control:Memory.worker_garbage_control
  in
  { workers; number_of_workers; is_parallel = parallel }


let run_process
    ~configuration:({ Configuration.Analysis.verbose; sections; _ } as configuration)
    process
  =
  Log.initialize ~verbose ~sections;
  Configuration.Analysis.set_global configuration;
  try
    let result = process () in
    Statistics.flush ();
    result
  with
  | error -> raise error


let map_reduce
    { workers; number_of_workers; is_parallel; _ }
    ?bucket_size
    ~configuration
    ~initial
    ~map
    ~reduce
    ~inputs
    ()
  =
  if is_parallel then
    let number_of_workers =
      Core.Int.max
        number_of_workers
        ( match bucket_size with
        | Some exact_size when exact_size > 0 -> (List.length inputs / exact_size) + 1
        | _ ->
            let bucket_multiplier = Core.Int.min 10 (1 + (List.length inputs / 400)) in
            number_of_workers * bucket_multiplier )
    in
    let map accumulator inputs = (fun () -> map accumulator inputs) |> run_process ~configuration in
    MultiWorker.call
      (Some workers)
      ~job:map
      ~merge:reduce
      ~neutral:initial
      ~next:(Bucket.make ~num_workers:number_of_workers inputs)
  else
    map initial inputs |> fun mapped -> reduce mapped initial


let iter ?bucket_size scheduler ~configuration ~f ~inputs =
  map_reduce
    scheduler
    ?bucket_size
    ~configuration
    ~initial:()
    ~map:(fun _ inputs -> f inputs)
    ~reduce:(fun _ _ -> ())
    ~inputs
    ()


let single_job { workers; _ } ~f work =
  let rec wait_until_ready handle =
    let { Worker.readys; _ } = Worker.select [handle] in
    match readys with
    | [] -> wait_until_ready handle
    | ready :: _ -> ready
  in
  match workers with
  | worker :: _ -> Worker.call worker f work |> wait_until_ready |> Worker.get_result
  | [] -> failwith "This service contains no workers"


let mock () =
  let configuration = Configuration.Analysis.create () in
  Memory.get_heap_handle configuration |> ignore;
  { workers = []; number_of_workers = 1; is_parallel = false }


let is_parallel { is_parallel; _ } = is_parallel

let workers { workers; _ } = workers

let destroy _ = Worker.killall ()

let once_per_worker scheduler ~configuration ~f =
  let number_of_workers = number_of_workers scheduler in
  let f _ = f () in
  iter scheduler ~bucket_size:1 ~configuration ~f ~inputs:(List.init number_of_workers ~f:Fn.id)
