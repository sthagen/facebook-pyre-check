(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Core
open Ppx_sexp_conv_lib
module Hash = Core.Hash
module Formatter = Core.Formatter

module type S = sig
  include Stdlib.Map.S

  val set : 'a t -> key:key -> data:'a -> 'a t

  val to_alist : 'a t -> (key * 'a) list

  val of_alist_exn : (key * 'a) list -> 'a t

  val of_alist : f:('a -> 'a -> 'a) -> (key * 'a) list -> 'a t

  val keys : 'a t -> key list

  val data : 'a t -> 'a list

  val add_multi : 'a list t -> key:key -> data:'a -> 'a list t

  val t_of_sexp : (Sexp.t -> 'a) -> Sexp.t -> 'a t

  val sexp_of_t : ('a -> Sexp.t) -> 'a t -> Sexp.t

  val hash_fold_t : (Hash.state -> 'a -> Hash.state) -> Hash.state -> 'a t -> Hash.state

  val pp : (Formatter.t -> 'a -> unit) -> Formatter.t -> 'a t -> unit
end

module type OrderedType = sig
  include Stdlib.Map.OrderedType

  val t_of_sexp : Sexp.t -> t

  val sexp_of_t : t -> Sexp.t

  val hash_fold_t : Hash.state -> t -> Hash.state

  val pp : Formatter.t -> t -> unit
end

module Make (Ordered : OrderedType) : S with type key = Ordered.t = struct
  include Stdlib.Map.Make (Ordered)

  module Key = struct
    include Ordered

    type 'a assoc = t * 'a [@@deriving compare, sexp, hash]
  end

  let set map ~key ~data = add key data map

  let to_alist = bindings

  let of_alist ~f list =
    let add_new_key map (key, value) =
      update
        key
        (function
          | None -> Some value
          | Some old_value -> Some (f value old_value))
        map
    in
    List.fold ~init:empty ~f:add_new_key list


  let of_alist_exn list =
    of_alist ~f:(fun _ _ -> failwith "key specified twice in of_alist_exn") list


  let keys map = fold (fun key _ sofar -> key :: sofar) map []

  let data map = fold (fun _ value sofar -> value :: sofar) map []

  let add_multi map ~key ~data =
    update
      key
      (function
        | None -> Some [data]
        | Some existing -> Some (data :: existing))
      map


  let t_of_sexp a_of_sexp sexp =
    Core.List.t_of_sexp (Key.assoc_of_sexp a_of_sexp) sexp |> Stdlib.List.to_seq |> of_seq


  let sexp_of_t sexp_of_a map = bindings map |> Core.List.sexp_of_t (Key.sexp_of_assoc sexp_of_a)

  let hash_fold_t hash_fold_a hash_state map =
    bindings map |> Core.List.hash_fold_t (Key.hash_fold_assoc hash_fold_a) hash_state


  let pp pp_a formatter map =
    match bindings map with
    | [] -> Format.fprintf formatter "{}"
    | [(key, value)] -> Format.fprintf formatter "{%a -> %a}" Ordered.pp key pp_a value
    | pairs ->
        let pp_pair formatter (key, value) =
          Format.fprintf formatter "@,%a -> %a" Ordered.pp key pp_a value
        in
        let pp_pairs formatter = List.iter ~f:(pp_pair formatter) in
        Format.fprintf formatter "{@[<v 2>%a@]@,}" pp_pairs pairs
end
