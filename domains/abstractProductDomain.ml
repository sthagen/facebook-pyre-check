(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the LICENSE file in the root
    directory of this source tree. *)

open AbstractDomainCore

module type PRODUCT_CONFIG = sig
  type 'a slot

  (* Cardinality of type 'a slot, i.e., distinct constants *)
  val slots : int

  (* Name of the product slot, e.g., "Left", "Right". Must be distinct for each slot. *)
  val slot_name : 'a slot -> string

  (* The abstract domain of values in a given product slot. E.g., let slot_domain (type a) (a slot)
     = | Left -> (module LeftDomain : AbstractDomainCore.S with type t = a) ... *)
  val slot_domain : 'a slot -> 'a abstract_domain

  (* If a slot is strict, then the entire product is bottom when that slot is bottom. *)
  val strict : 'a slot -> bool
end

module Make (Config : PRODUCT_CONFIG) = struct
  type element = Element : 'a -> element [@@unbox]

  type t = element array

  module IntMap = Map.Make (struct
    type t = int

    let compare = compare
  end)

  type abstract_slot = Slot : 'a Config.slot -> abstract_slot [@@unbox]

  let slots =
    let rec get_slots i sofar =
      if i < Config.slots then
        let slot = Slot (Obj.magic i : 'a Config.slot) in
        get_slots (i + 1) (slot :: sofar)
      else
        List.rev sofar
    in
    get_slots 0 [] |> Array.of_list


  let strict_slots =
    let filter_strict (Slot slot) = Config.strict slot in
    Array.to_list slots |> ListLabels.filter ~f:filter_strict |> Array.of_list


  (* The route map indicates for each part under a product element which slot the element is in *)
  let route_map : int IntMap.t =
    let map = ref IntMap.empty in
    let gather (route : int) (type a) (part : a part) =
      map := IntMap.add (part_id part) route !map
    in
    Array.iteri
      (fun route (Slot slot) ->
        let module D = (val Config.slot_domain slot) in
        D.introspect
          (GetParts
             (object
                method report : 'a. 'a part -> unit = gather route
             end)))
      slots;
    !map


  let get_route (type a) (part : a part) =
    try IntMap.find (part_id part) route_map with
    | Not_found -> Format.sprintf "No route to part %s" (part_name part) |> failwith


  let bottom =
    let get_bottom (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      Element D.bottom
    in
    Array.map get_bottom slots


  let slot_number (type a) (slot : a Config.slot) : int =
    if Obj.repr slot |> Obj.is_int then (
      let i = Obj.magic slot in
      assert (i >= 0 && i < Array.length slots);
      i )
    else
      failwith "slots must be a datatype with 0-ary constructors"


  let get (type a) (slot : a Config.slot) (product : t) : a =
    let i = slot_number slot in
    match product.(i) with
    | Element value -> Obj.magic value


  let is_bottom product =
    let is_bottom_slot (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      let v = get slot product in
      if not (D.is_bottom v) then raise Exit
    in
    if product == bottom then
      true
    else
      try
        Array.iter is_bottom_slot slots;
        true
      with
      | Exit -> false


  let join left right =
    let merge (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      let left = get slot left in
      let right = get slot right in
      Element (D.join left right)
    in
    if left == right then
      left
    else
      Array.map merge slots


  let widen ~iteration ~prev ~next =
    let merge (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      let prev = get slot prev in
      let next = get slot next in
      Element (D.widen ~iteration ~prev ~next)
    in
    if prev == next then
      prev
    else
      Array.map merge slots


  let less_or_equal ~left ~right =
    let less_or_equal_slot (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      let left = get slot left in
      let right = get slot right in
      if not (D.less_or_equal ~left ~right) then raise Exit
    in
    try
      Array.iter less_or_equal_slot slots;
      true
    with
    | Exit -> false


  exception Strict

  let subtract to_remove ~from =
    if to_remove == from then
      bottom
    else if is_bottom to_remove || is_bottom from then
      from
    else
      try
        let sub (Slot slot) =
          let module D = (val Config.slot_domain slot) in
          let to_remove = get slot to_remove in
          let from = get slot from in
          let result = D.subtract to_remove ~from in
          if Config.strict slot && D.is_bottom result then
            raise Strict
          else
            Element result
        in
        Array.map sub slots
      with
      | Strict -> bottom


  let show product =
    let show_element (Slot slot) =
      let slot_name = Config.slot_name slot in
      let module D = (val Config.slot_domain slot) in
      let value = get slot product in
      Format.sprintf "%s: %s" slot_name (D.show value)
    in
    Array.map show_element slots |> Array.to_list |> String.concat ", "


  let pp formatter map = Format.fprintf formatter "%s" (show map)

  module CommonArg = struct
    type nonrec t = t

    let bottom = bottom

    let join = join
  end

  module C = Common (CommonArg)

  type _ part += Self = C.Self

  let make_strict result =
    let check_strict (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      let value = get slot result in
      if D.is_bottom value then raise Strict
    in
    try
      Array.iter check_strict strict_slots;
      result
    with
    | Strict -> bottom


  let update (type a) (slot : a Config.slot) (value : a) (product : t) =
    let i = slot_number slot in
    match product.(i) with
    | Element old_value ->
        if old_value == Obj.magic value then
          product
        else
          let module D = (val Config.slot_domain slot) in
          if Config.strict slot && D.is_bottom value then
            bottom
          else
            let result = Array.copy product in
            result.(i) <- Element value;
            (* Check existing strict slots are not bottom *)
            make_strict result


  let rec transform : type a. a part -> a transform -> t -> t =
   fun part t product ->
    match part with
    | C.Self -> C.transform transformer part t product
    | _ ->
        let transform (Slot slot) =
          let value = get slot product in
          let module D = (val Config.slot_domain slot) in
          let new_value = D.transform part t value in
          update slot new_value product
        in
        let route = get_route part in
        transform slots.(route)


  and transformer (T (part, t)) (d : t) : t = transform part t d

  let fold (type a b) (part : a part) ~(f : a -> b -> b) ~(init : b) (product : t) : b =
    match part with
    | C.Self -> C.fold part ~f ~init product
    | _ ->
        let fold (Slot slot) =
          let value = get slot product in
          let module D = (val Config.slot_domain slot) in
          D.fold part ~f ~init value
        in
        let route = get_route part in
        fold slots.(route)


  let partition (type a b) (part : a part) ~(f : a -> b option) (product : t)
      : (b, t) Core_kernel.Map.Poly.t
    =
    match part with
    | C.Self -> C.partition part ~f product
    | _ ->
        let partition (Slot slot) : (b, t) Core_kernel.Map.Poly.t =
          let value = get slot product in
          let module D = (val Config.slot_domain slot) in
          D.partition part ~f value
          |> Core_kernel.Map.Poly.map ~f:(fun value -> update slot value product)
        in
        let route = get_route part in
        partition slots.(route)


  let create parts =
    let update part = function
      | Some parts -> part :: parts
      | None -> [part]
    in
    let partition_by_slot partition (Part (part, _) as pv) =
      let key = get_route part in
      Core_kernel.Map.Poly.update partition key ~f:(update pv)
    in
    let partition =
      ListLabels.fold_left parts ~f:partition_by_slot ~init:Core_kernel.Map.Poly.empty
    in
    let create_slot i (Slot slot) =
      let module D = (val Config.slot_domain slot) in
      match Core_kernel.Map.Poly.find partition i with
      | Some parts -> Element (List.rev parts |> D.create)
      | _ -> Element D.bottom
    in
    Array.mapi create_slot slots |> make_strict


  let indent prefix range = ListLabels.map ~f:(fun s -> prefix ^ s) range

  let islot_name (i : int) =
    let slot = (Obj.magic i : 'a Config.slot) in
    let strict = Config.strict slot in
    let name = Config.slot_name slot in
    if strict then
      Format.sprintf "%s (strict)" name
    else
      name


  let introspect (type a) (op : a introspect) : a =
    let introspect_slot (op : a introspect) (Slot slot) : a =
      let module D = (val Config.slot_domain slot) in
      D.introspect op
    in
    match op with
    | GetParts f ->
        f#report C.Self;
        Array.iter (introspect_slot op) slots
    | Structure ->
        let tuples =
          Array.map (introspect_slot op) slots
          |> Array.to_list
          |> ListLabels.mapi ~f:(fun i sl -> islot_name i :: indent "  " sl)
          |> List.concat
        in
        ("Product [" :: indent "  " tuples) @ ["]"]
    | Name part -> (
        match part with
        | Self ->
            let slot_name (Slot slot) = Config.slot_name slot in
            let slot_names = Array.to_list slots |> ListLabels.map ~f:slot_name in
            Format.sprintf "Product(%s).Self" (String.concat "," slot_names)
        | _ ->
            let introspect (Slot slot) =
              let module D = (val Config.slot_domain slot) in
              D.introspect op
            in
            let route = get_route part in
            introspect slots.(route) )
end
