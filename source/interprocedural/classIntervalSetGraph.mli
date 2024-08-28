(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Mapping from a class name to its class interval set, stored in the ocaml heap. *)
module Heap : sig
  type t = ClassIntervalSet.t ClassHierarchyGraph.ClassNameMap.t

  val from_class_hierarchy : ClassHierarchyGraph.Heap.t -> t
end

(** Mapping from a class name to its class interval set, stored in shared memory. *)
module SharedMemory : sig
  type t

  (* Create a "region" in the shared memory to store class interval graphs. *)
  val create : unit -> t

  (* Store the class interval graph (as an OCaml value) into shared memory. *)
  val from_heap : Heap.t -> t

  val add : t -> class_name:ClassHierarchyGraph.class_name -> interval:ClassIntervalSet.t -> unit

  val get : t -> class_name:ClassHierarchyGraph.class_name -> ClassIntervalSet.t option

  val of_class : t -> string -> ClassIntervalSet.t

  val of_type : t -> Type.t option -> ClassIntervalSet.t

  val of_definition : t -> Ast.Reference.t -> Ast.Statement.Define.t -> ClassIntervalSet.t

  val cleanup : t -> Heap.t -> unit
end
