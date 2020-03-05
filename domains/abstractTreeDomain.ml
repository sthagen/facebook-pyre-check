(** Copyright (c) 2016-present, Facebook, Inc. This source code is licensed under the MIT license
    found in the LICENSE file in the root directory of this source tree. *)

[@@@ocamlformat "wrap-comments=false"]

module Option = Core_kernel.Option
module MapPoly = Core_kernel.Map.Poly

(* optional transform: 'a option -> ('a -> 'b option) -> 'b option *)
let ( >>= ) = Option.( >>= )

module type CONFIG = sig
  val max_tree_depth_after_widening : int

  val check_invariants : bool
end

module type CHECK = sig
  type witness

  val create_witness : bool -> false_witness:string -> witness

  val option_construct : message:(unit -> string) -> witness -> witness

  val false_witness : message:(unit -> string) -> witness

  (* Captures true, as a witness, i.e. without extra info. *)
  val true_witness : witness

  val is_true : witness -> bool

  val get_witness : witness -> string option

  val and_witness : witness -> witness -> witness

  (* Calls the argument function if checking is on, otherwise ignores it. *)
  val check : (unit -> unit) -> unit
end

module WithChecks : CHECK = struct
  type witness = string option

  let create_witness condition ~false_witness =
    if not condition then
      Some false_witness
    else
      None


  let option_construct ~message = function
    | None -> None
    | Some value -> Some (message () ^ "->" ^ value)


  let false_witness ~message = Some (message ())

  let true_witness = None

  let is_true = Option.is_none

  let get_witness witness = witness

  let and_witness left_witness right_witness =
    match left_witness, right_witness with
    | None, None -> None
    | Some _, None -> left_witness
    | None, Some _ -> right_witness
    | Some left_witness, Some right_witness -> Some (left_witness ^ "\n&& " ^ right_witness)


  let check f = f ()
end

module WithoutChecks : CHECK = struct
  type witness = bool

  let create_witness condition ~false_witness:_ = condition

  let option_construct ~message:_ witness = witness

  let false_witness ~message:_ = false

  let true_witness = true

  let is_true witness = witness

  let get_witness = function
    | true -> None
    | false -> Some "<no witness>"


  let and_witness = ( && )

  let check _ = ()
end

module Label = struct
  type t =
    | Field of string
    | DictionaryKeys
    | Any
  [@@deriving show]

  let compare = Pervasives.compare

  let _ = show (* shadowed below *)

  let show = function
    | Field name -> Format.sprintf "[%s]" name
    | DictionaryKeys -> "[**keys]"
    | Any -> "[*]"


  type path = t list [@@deriving show]

  let _ = show_path (* shadowed below *)

  let show_path path = ListLabels.map ~f:show path |> String.concat ""

  let create_name_field name = Field name

  let create_int_field i = Field (string_of_int i)

  let common_prefix left right =
    let rec common_prefix_reversed left right so_far =
      match left, right with
      | left_element :: left_rest, right_element :: right_rest when left_element = right_element ->
          common_prefix_reversed left_rest right_rest (left_element :: so_far)
      | _ -> so_far
    in
    common_prefix_reversed left right [] |> List.rev


  let rec is_prefix ~prefix path =
    match prefix, path with
    | prefix_head :: prefix_rest, path_head :: path_rest when prefix_head = path_head ->
        is_prefix ~prefix:prefix_rest path_rest
    | [], _ -> true
    | _ -> false


  let rec compare_path left right =
    match left, right with
    | left :: left_rest, right :: right_rest -> (
        match compare left right with
        | 0 -> compare_path left_rest right_rest
        | n -> n )
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> 1


  let equal_path = ( = )
end

module Make (Config : CONFIG) (Element : AbstractDomainCore.S) () = struct
  module Checks = ( val if Config.check_invariants then
                          (module WithChecks)
                        else
                          (module WithoutChecks) : CHECK )

  module LabelMap = struct
    module Map = Map.Make (Label)
    include Map

    let filter_mapi ~f map =
      Map.mapi (fun key data -> f ~key ~data) map
      |> Map.filter (fun _key ->
           function
           | None -> false
           | Some _ -> true)
      |> Map.map (fun selected -> Option.value_exn selected)


    let filter_map ~f = filter_mapi ~f:(fun ~key:_ ~data -> f data)

    let fold ~f map ~init = Map.fold (fun key data acc -> f ~key ~data acc) map init

    let add ~key ~data map = Map.add key data map

    let fold2 ~f ~init left right =
      let combine _key left right =
        match left, right with
        | Some left, None -> Some (`Left left)
        | None, Some right -> Some (`Right right)
        | Some left, Some right -> Some (`Both (left, right))
        | None, None -> None
      in
      merge combine left right |> fold ~f ~init
  end

  type t = {
    (* Abstract contribution at this node. (Not the join from the root!) *)
    element: Element.t;
    (* Edges to child nodes.
        NOTE: Indices are special. If the AnyIndex [*] is present then it
        covers all indices [i], that are not explicitly present.
    *)
    children: t LabelMap.t;
  }
  (** Access Path tree nodes have an abstract domain element and a set of children indexed by
      AccessPath.PathElement.t *)

  let create_leaf element = { element; children = LabelMap.empty }

  let empty_tree = create_leaf Element.bottom

  let is_empty_info children element = LabelMap.is_empty children && Element.is_bottom element

  let is_empty_tree { children; element } = is_empty_info children element

  let bottom = empty_tree

  let is_bottom = is_empty_tree

  let create_tree_option path tree =
    let rec create_tree_internal path tree =
      match path with
      | [] -> tree
      | label_element :: rest ->
          {
            element = Element.bottom;
            children = LabelMap.singleton label_element (create_tree_internal rest tree);
          }
    in
    if is_empty_tree tree then
      None
    else
      Some (create_tree_internal path tree)


  type widen_depth = int option
  (** Captures whether we need to widen and at what tree level.
      None -> no widening
      Some i -> widen start i levels down.
  *)

  let must_widen_depth = function
    | None -> false
    | Some i -> i = 0


  let must_widen_element = Option.is_some

  let decrement_widen = function
    | None -> None
    | Some i when i > 0 -> Some (i - 1)
    | Some _ -> failwith "Decrementing widen depth below 0"


  let element_join ~widen_depth w1 w2 =
    if must_widen_element widen_depth then
      Element.widen ~iteration:2 ~prev:w1 ~next:w2
    else
      Element.join w1 w2


  let rec to_string_tree ~show_element indent { element; children } =
    Format.sprintf
      "%s\n%s"
      ( if show_element then
          Element.show element
      else
        "" )
      (to_string_children ~show_element (indent ^ "  ") children)


  and to_string_children ~show_element indent children =
    let to_string_element ~key ~data:subtree accumulator =
      Format.sprintf
        "%s -> %s"
        (indent ^ Label.show key)
        (to_string_tree ~show_element indent subtree)
      :: accumulator
    in
    String.concat "\n" (LabelMap.fold ~f:to_string_element children ~init:[])


  let show = to_string_tree ~show_element:true ""

  let pp formatter map = Format.fprintf formatter "%s" (show map)

  let rec max_depth { children; _ } =
    LabelMap.fold
      ~f:(fun ~key:_ ~data:tree accumulator -> max (1 + max_depth tree) accumulator)
      children
      ~init:0


  let rec min_depth { children; element } =
    if not (Element.is_bottom element) then
      0
    else
      LabelMap.fold
        ~f:(fun ~key:_ ~data:tree accumulator -> min (1 + min_depth tree) accumulator)
        children
        ~init:0


  let rec is_minimal ancestors ({ element; children } as tree) =
    if is_empty_tree tree then
      Checks.false_witness ~message:(fun () -> "empty leaf.")
    else if
      (not (Element.is_bottom element)) && Element.less_or_equal ~left:element ~right:ancestors
    then
      Checks.false_witness ~message:(fun () -> "tree.element redundant.")
    else
      let ancestors = Element.join ancestors element in
      let all_minimal ~key ~data:subtree witness =
        if not (Checks.is_true witness) then
          witness
        else
          is_minimal ancestors subtree
          |> Checks.option_construct ~message:(fun () -> Label.show key)
      in
      LabelMap.fold ~f:all_minimal children ~init:Checks.true_witness


  let check_minimal_non_empty ~message tree =
    is_minimal Element.bottom tree
    |> Checks.get_witness
    |> function
    | None -> ()
    | Some witness ->
        let message =
          Format.sprintf "%s not minimal: %s: result %s" (message ()) witness (show tree)
        in
        failwith message


  let check_minimal ~message tree =
    if is_empty_tree tree then
      ()
    else
      check_minimal_non_empty ~message tree


  let lookup_tree_with_default { children; _ } element =
    match LabelMap.find_opt element children with
    | None -> empty_tree
    | Some subtree -> subtree


  (** Compute join of all element components in tree t. *)
  let rec collapse_tree ~widen_depth element_accumulator { element; children } =
    let element_accumulator = element_join ~widen_depth element_accumulator element in
    let collapse_child ~key:_ ~data:subtree =
      Core_kernel.Fn.flip (collapse_tree ~widen_depth) subtree
    in
    LabelMap.fold ~f:collapse_child children ~init:element_accumulator


  let collapse tree = collapse_tree Element.bottom tree

  let create_leaf_option ~ancestors ~element =
    let difference = Element.subtract ancestors ~from:element in
    if Element.less_or_equal ~left:difference ~right:ancestors then
      None
    else
      Some (create_leaf difference)


  let create_node_option element children =
    if is_empty_info children element then
      None
    else
      Some { element; children }


  let option_node_tree ~message = function
    | None -> empty_tree
    | Some tree ->
        Checks.check (fun () -> check_minimal_non_empty ~message tree);
        tree


  type filtered_element_t = {
    new_element: Element.t;
    ancestors: Element.t;
  }

  let filter_by_ancestors ~ancestors ~element =
    let difference = Element.subtract ancestors ~from:element in
    if Element.less_or_equal ~left:difference ~right:ancestors then
      { new_element = Element.bottom; ancestors }
    else
      { new_element = difference; ancestors = Element.join ancestors element }


  let rec prune_tree ancestors { element; children } =
    let { new_element; ancestors } = filter_by_ancestors ~ancestors ~element in
    let children = LabelMap.filter_map ~f:(prune_tree ancestors) children in
    create_node_option new_element children


  let set_or_remove key value map =
    match value with
    | None -> LabelMap.remove key map
    | Some data -> LabelMap.add ~key ~data map


  (** Widen differs from join in that right side does not extend trees, and Element
      uses widen.

      widen_depth is less or equal to the max depth allowed in this subtree or
      None if we don't widen.  *)
  let rec join_trees
      ancestors
      ~(widen_depth : widen_depth)
      ({ element = left_element; children = left_children } as left_tree)
      ({ element = right_element; children = right_children } as right_tree)
    =
    if must_widen_depth widen_depth then
      (* Collapse left_tree and right_tree to achieve depth limit. Note that left_tree is a leaf,
         only if the widen depth was exactly the depth of left_tree.  *)
      let collapsed_left_element = collapse_tree ~widen_depth Element.bottom left_tree in
      create_leaf_option
        ~ancestors
        ~element:(collapse_tree ~widen_depth collapsed_left_element right_tree)
    else
      let joined_element = element_join ~widen_depth left_element right_element in
      let { new_element; ancestors } = filter_by_ancestors ~ancestors ~element:joined_element in
      let children =
        join_children
          ancestors
          ~widen_depth:(decrement_widen widen_depth)
          left_children
          right_children
      in
      create_node_option new_element children


  and join_option_trees ancestors ~widen_depth left right =
    match left, right with
    | None, None -> None
    | Some left, None -> prune_tree ancestors left
    | None, Some right when widen_depth = None -> prune_tree ancestors right
    | None, Some right -> join_trees ancestors ~widen_depth empty_tree right
    | Some left, Some right -> join_trees ancestors ~widen_depth left right


  and join_children ancestors ~widen_depth left_tree right_tree =
    (* Merging is tricky because of the special meaning of [*] and [f]. We
       have to identify the three sets of indices:

       L : indices [f] only in left_tree
       R : indices [f] only in right_tree
       C : indices [f] common in left_tree and right_tree.

       Let left_star be the tree associated with left_tree[*] and right_star = right_tree[*].

       The merge result joined is then:
         joined.element = pointwise merge of left_tree.element and right_tree.element
           (if element is not an index)
         joined.[*] = left_star merge right_star
         joined.[c] = left_tree[c] merge right_tree[c] if c in C
         joined.[l] = left_tree[l] merge right_star if l in L
         joined.[r] = right_tree[r] merge left_star if r in R
         joined.[<keys>] = left_tree[<keys>] merge right_tree[<keys>]

    *)
    let left_star = LabelMap.find_opt Label.Any left_tree in
    let right_star = LabelMap.find_opt Label.Any right_tree in
    (* merge_left takes care of C and L, as well as the dictionary keys *)
    let merge_left ~key:element ~data:left_subtree accumulator =
      match element with
      | Label.Any ->
          set_or_remove
            element
            (join_option_trees ancestors ~widen_depth (Some left_subtree) right_star)
            accumulator
      | Label.Field _ -> (
          match LabelMap.find_opt element right_tree with
          | Some right_subtree ->
              (* f in C *)
              set_or_remove
                element
                (join_trees ancestors ~widen_depth left_subtree right_subtree)
                accumulator
          | None ->
              (* f in L *)
              set_or_remove
                element
                (join_option_trees ancestors ~widen_depth (Some left_subtree) right_star)
                accumulator )
      | Label.DictionaryKeys -> (
          match LabelMap.find_opt element right_tree with
          | Some right_subtree ->
              set_or_remove
                element
                (join_trees ancestors ~widen_depth left_subtree right_subtree)
                accumulator
          | None ->
              let join_tree = join_option_trees ancestors ~widen_depth (Some left_subtree) None in
              set_or_remove element join_tree accumulator )
    in
    (* merge_right takes care of R *)
    let merge_right ~key:element ~data:right_subtree accumulator =
      match LabelMap.find_opt element left_tree with
      | Some _ ->
          (* pointwise, already done in merge_left. *)
          accumulator
      | None -> (
          match element with
          | Label.Field _ ->
              let join_tree =
                join_option_trees ancestors ~widen_depth left_star (Some right_subtree)
              in
              set_or_remove element join_tree accumulator
          | Label.Any
          | Label.DictionaryKeys ->
              let join_tree = join_option_trees ancestors ~widen_depth None (Some right_subtree) in
              set_or_remove element join_tree accumulator )
    in
    let left_done = LabelMap.fold ~init:LabelMap.empty left_tree ~f:merge_left in
    LabelMap.fold ~init:left_done right_tree ~f:merge_right


  (** Assign or join subtree into existing tree at path. *)
  let rec assign_or_join_path
      ~do_join
      ~ancestors
      ~tree:({ element; children } as tree)
      path
      ~subtree
    =
    if is_empty_tree tree then (* Shortcut *)
      prune_tree ancestors subtree >>= create_tree_option path
    else
      match path with
      | [] ->
          if do_join then
            join_trees ancestors ~widen_depth:None tree subtree (* Join point. *)
          else (* Note: we are overwriting t.element, so no need to add it to the path. *)
            prune_tree ancestors subtree (* Assignment/join point. *)
      | label_element :: rest -> (
          let ancestors = Element.join ancestors element in
          let existing = lookup_tree_with_default tree label_element in
          match label_element with
          | Label.Any ->
              (* Special case. Must merge with AnyIndex and also every specific index. *)
              let augmented = LabelMap.add ~key:Label.Any ~data:existing children in
              let children =
                LabelMap.filter_mapi ~f:(join_each_index ~ancestors rest ~subtree) augmented
              in
              create_node_option element children
          | Label.Field _
          | Label.DictionaryKeys ->
              let children =
                set_or_remove
                  label_element
                  (assign_or_join_path ~do_join ~ancestors ~tree:existing rest ~subtree)
                  children
              in
              create_node_option element children )


  and join_each_index ~ancestors rest ~subtree ~key:element ~data:tree =
    match element with
    | Label.Any -> assign_or_join_path ~do_join:true ~ancestors ~tree rest ~subtree
    | Label.Field _
    | Label.DictionaryKeys ->
        Some tree


  (** Assign subtree subtree into existing tree at path. *)
  let assign_path = assign_or_join_path ~do_join:false

  (** Like assign_path, but at assignment point, joins the tree with existing
      tree, effectively a weak assign. *)
  let join_path = assign_or_join_path ~do_join:true

  (** Read the subtree at path within tree and return the ancestors separately.
      ~use_precise_fields overrides the default handling of [*] matching all fields.
      This is used solely in determining port connections when emitting json.

      ancestors is accumulated down the recursion and returned when we reach the
      end of that path. That way the recursion is tail-recursive.
  *)
  let rec read_raw ~ancestors path { children; element } ~use_precise_fields ~transform_non_leaves =
    match path with
    | [] -> ancestors, create_node_option element children
    | label_element :: rest -> (
        let ancestors = transform_non_leaves path element |> Element.join ancestors in
        match label_element with
        | Label.Any when not use_precise_fields ->
            (* lookup all index fields and join result *)
            let find_index_and_join ~key ~data:subtree (ancestors_accumulator, tree_accumulator) =
              (* Dictionary keys are special - they should be excluded from [*]
                 accesses unconditionally. *)
              if key = Label.DictionaryKeys then
                Element.bottom, None
              else
                let ancestors_result, subtree =
                  read_raw ~ancestors ~use_precise_fields ~transform_non_leaves rest subtree
                in
                let subtree =
                  join_option_trees Element.bottom ~widen_depth:None tree_accumulator subtree
                in
                Element.join ancestors_result ancestors_accumulator, subtree
            in
            LabelMap.fold ~init:(ancestors, None) ~f:find_index_and_join children
        | Label.Field _ when not use_precise_fields -> (
            (* read [f] or [*] *)
            match LabelMap.find_opt label_element children with
            | None -> (
                match LabelMap.find_opt Label.Any children with
                | Some subtree ->
                    read_raw ~ancestors ~use_precise_fields ~transform_non_leaves rest subtree
                | None -> ancestors, None )
            | Some subtree ->
                read_raw ~ancestors ~use_precise_fields ~transform_non_leaves rest subtree )
        | _ -> (
            match LabelMap.find_opt label_element children with
            | None -> ancestors, None
            | Some subtree ->
                read_raw ~ancestors ~use_precise_fields ~transform_non_leaves rest subtree ) )


  (** Read the subtree at path p within t. Returns the pair ancestors, tree_at_tip. *)
  let read_tree_raw path tree ~use_precise_fields ~transform_non_leaves =
    let message () =
      Format.sprintf "read tree_raw: %s :from: %s" (Label.show_path path) (show tree)
    in
    let ancestors, tree_option =
      read_raw ~ancestors:Element.bottom ~use_precise_fields ~transform_non_leaves path tree
    in
    ancestors, option_node_tree ~message tree_option


  let assign_tree_path ~tree path ~subtree =
    let message () =
      Format.sprintf
        "assign tree: %s :to: %s :in: %s"
        (show subtree)
        (Label.show_path path)
        (show tree)
    in
    assign_path ~ancestors:Element.bottom ~tree path ~subtree |> option_node_tree ~message


  let join_tree_path ~tree path ~subtree =
    let message () =
      Format.sprintf
        "join tree: %s :to: %s :in: %s"
        (show subtree)
        (Label.show_path path)
        (show tree)
    in
    join_path ~ancestors:Element.bottom ~tree path ~subtree |> option_node_tree ~message


  let assign ?(weak = false) ~tree path ~subtree =
    if weak then
      join_tree_path ~tree path ~subtree
    else
      assign_tree_path ~tree path ~subtree


  (** right_ancestors is the path element of right_tree, i.e. the join of element's along the
      spine of the right tree to this point. *)
  let rec less_or_equal_tree
      { element = left_element; children = left_children }
      right_ancestors
      { element = right_element; children = right_children }
    =
    let right_ancestors = Element.join right_ancestors right_element in
    if not (Element.less_or_equal ~left:left_element ~right:right_ancestors) then
      let message () =
        Format.sprintf
          "Element not less_or_equal: %s\nvs\n%s\n"
          (Element.show left_element)
          (Element.show right_ancestors)
      in
      Checks.false_witness ~message
    else
      less_or_equal_children left_children right_ancestors right_children


  and less_or_equal_option_tree left_option_tree right_ancestors right_option_tree =
    match left_option_tree, right_option_tree with
    | None, _ -> Checks.true_witness
    | Some left_tree, None ->
        (* Check that all on left <= right_ancestors *)
        less_or_equal_tree left_tree right_ancestors empty_tree
    | Some left_tree, Some right_tree -> less_or_equal_tree left_tree right_ancestors right_tree


  and less_or_equal_all left_label_map right_ancestors =
    let check_less_or_equal ~key:_ ~data:left_subtree accumulator =
      if Checks.is_true accumulator then
        less_or_equal_tree left_subtree right_ancestors empty_tree
      else
        accumulator
    in
    LabelMap.fold left_label_map ~f:check_less_or_equal ~init:Checks.true_witness


  and less_or_equal_children left_label_map right_ancestors right_label_map =
    if LabelMap.is_empty left_label_map then
      Checks.true_witness
    else if LabelMap.is_empty right_label_map then
      (* Check that all on the left <= right_ancestors *)
      less_or_equal_all left_label_map right_ancestors
    else
      (* Pointwise on non-index elements, common index elements, and on dictionary keys.
         Let L, R be the index elements present only in left_label_map and right_label_map
         respectively, and let left_star, right_star be the [*] subtrees of left_label_map and
         right_label_map respectively. Then,

         left_star <= right_star /\
         left_star <= right_label_map[r] for all r in R /\
         left_label_map[l] <= right_star for all l in L.

         And with the understanding of left_label_map[<keys>] bottom and
         right_label_map[<keys>] = top if the index is missing (we choose this behavior to ensure
         that key taint doesn't interfere with value taint),

         left_label_map[<keys>] <= right_label_map[<keys>] *)
      let left_star = LabelMap.find_opt Label.Any left_label_map in
      let right_star = LabelMap.find_opt Label.Any right_label_map in
      let check_less_or_equal ~key:label_element ~data:left_subtree accumulator =
        if not (Checks.is_true accumulator) then
          accumulator
        else
          match label_element with
          | Label.Any ->
              less_or_equal_option_tree left_star right_ancestors right_star
              |> Checks.option_construct ~message:(fun () -> "[left *]")
          | Label.Field _ -> (
              match LabelMap.find_opt label_element right_label_map with
              | None ->
                  (* in L *)
                  less_or_equal_option_tree (Some left_subtree) right_ancestors right_star
                  |> Checks.option_construct ~message:(fun () -> "[right *]")
              | Some right_subtree ->
                  (* in common *)
                  less_or_equal_tree left_subtree right_ancestors right_subtree
                  |> Checks.option_construct ~message:(fun () -> Label.show label_element) )
          | Label.DictionaryKeys -> (
              match LabelMap.find_opt label_element right_label_map with
              | Some right_subtree -> less_or_equal_tree left_subtree right_ancestors right_subtree
              | None ->
                  less_or_equal_option_tree (Some left_subtree) right_ancestors None
                  |> Checks.option_construct ~message:(fun () -> "[right <keys>]") )
      in
      (* Check that all non-star index fields on right are larger than star1,
         unless they were matched directly. *)
      let check_star_left ~key:label_element ~data:right_subtree accumulator =
        if not (Checks.is_true accumulator) then
          accumulator
        else
          match label_element with
          | Label.Field _ when not (LabelMap.mem label_element left_label_map) ->
              less_or_equal_option_tree left_star right_ancestors (Some right_subtree)
              |> Checks.option_construct ~message:(fun () -> "[left *]")
          | _ -> Checks.true_witness
      in
      let result = LabelMap.fold ~f:check_less_or_equal left_label_map ~init:Checks.true_witness in
      LabelMap.fold ~f:check_star_left right_label_map ~init:result


  let read ?(transform_non_leaves = fun _p element -> element) path tree =
    let ancestors, tree = read_tree_raw path tree ~use_precise_fields:false ~transform_non_leaves in
    let message () = Format.sprintf "read [%s] from %s" (Label.show_path path) (show tree) in
    (* Important to properly join the trees and not just join ancestors and
       tree.element, as otherwise this could result in non-minimal trees. *)
    join_trees Element.bottom ~widen_depth:None (create_leaf ancestors) tree
    |> option_node_tree ~message


  (** Collapses all subtrees at depth. Used to limit amount of detail propagated
      across function boundaries, in particular for scaling. *)
  let collapse_to ~depth tree =
    let message () = Format.sprintf "collapse to %d\n%s\n" depth (show tree) in
    join_trees Element.bottom ~widen_depth:(Some depth) tree tree |> option_node_tree ~message


  let less_or_equal ~left ~right = less_or_equal_tree left Element.bottom right |> Checks.is_true

  let subtract _to_remove ~from =
    (* Correct, but one can probably do better when needed. *)
    from


  let verify_less_or_equal left_tree right_tree message =
    match less_or_equal_tree left_tree Element.bottom right_tree |> Checks.get_witness with
    | None -> ()
    | Some witness ->
        Format.sprintf
          "bad join %s - %s: %s\nvs %s"
          message
          witness
          (show left_tree)
          (show right_tree)
        |> failwith


  let check_join_property left_tree right_tree result =
    if Config.check_invariants then begin
      verify_less_or_equal left_tree result "left_tree<=result";
      verify_less_or_equal right_tree result "right_tree<=result"
    end;
    result


  let join left right =
    if left == right then
      left
    else
      let message () =
        Format.sprintf "join trees: left_tree\n%s\nright_tree:\n%s\n" (show left) (show right)
      in
      join_trees Element.bottom ~widen_depth:None left right
      |> option_node_tree ~message
      |> check_join_property left right


  let widen ~iteration:_ ~prev ~next =
    let message () =
      Format.sprintf "wident trees: previous\n%s\nnext:\n%s\n" (show prev) (show next)
    in
    join_trees Element.bottom ~widen_depth:(Some Config.max_tree_depth_after_widening) prev next
    |> option_node_tree ~message
    |> check_join_property prev next


  (* Shape tree ~mold transforms the left tree so it only contains branches present in mold. *)
  let rec shape_tree
      ~ancestors
      { element = left_element; children = left_children }
      ~mold:{ element = _; children = mold_children }
    =
    let widen_depth = None in
    let joined_element, left_children =
      let lift_dead_branches ~key ~data (lifted, result) =
        match data with
        | `Both (left, _mold) -> lifted, LabelMap.add ~key ~data:left result
        | `Left left -> Element.join lifted (collapse ~widen_depth left), result
        | `Right _ -> lifted, result
      in
      LabelMap.fold2
        left_children
        mold_children
        ~init:(left_element, LabelMap.empty)
        ~f:lift_dead_branches
    in
    let { new_element; ancestors } = filter_by_ancestors ~ancestors ~element:joined_element in
    let children = shape_children ancestors left_children ~mold:mold_children in
    create_node_option new_element children


  (* left_tree already contains only branches that are also in mold. *)
  and shape_children ancestors left_children ~mold =
    let mold_branch ~key ~data result =
      match data with
      | `Both (left_tree, mold) -> (
          match shape_tree ~ancestors left_tree ~mold with
          | Some merged -> LabelMap.add result ~key ~data:merged
          | None -> result )
      | `Right _mold -> failwith "Invariant broken. Mold should not have more branches"
      | `Left _ -> failwith "Invariant broken. Left branch should have been lifted"
    in
    LabelMap.fold2 left_children mold ~init:LabelMap.empty ~f:mold_branch


  let shape tree ~mold =
    let message () = Format.sprintf "shape tree\n%s\nmold:\n%s\n" (show tree) (show mold) in
    shape_tree ~ancestors:Element.bottom tree ~mold |> option_node_tree ~message


  let get_root_taint { element; _ } = element

  (** Fold over tree, where each non-bottom element node is visited. The
      function ~f is passed the path to the node, the joined ancestor elements,
      and the non-bottom element at the node. *)
  let fold_tree_paths ~init ~f tree =
    let rec walk_children path ancestors { element; children } first_accumulator =
      let new_ancestors = Element.join element ancestors in
      let second_accumulator =
        if Element.is_bottom element then
          first_accumulator
        else
          f ~path ~ancestors ~element first_accumulator
      in
      if LabelMap.is_empty children then
        second_accumulator
      else
        let walk ~key:label_element ~data:subtree =
          walk_children (path @ [label_element]) new_ancestors subtree
        in
        LabelMap.fold children ~init:second_accumulator ~f:walk
    in
    walk_children [] Element.bottom tree init


  (** Filter map over tree, where each non-bottom element node is visited. The
      function ~f is passed the path to the node, the joined ancestor elements,
      and the non-bottom element at the node and returns a new Element to
      substitute (possibly bottom). *)
  let filter_map_tree_paths ~f tree =
    let build ~path ~ancestors ~element access_path_tree =
      let new_path, element = f ~path ~ancestors ~element in
      if Element.is_bottom element then
        access_path_tree
      else
        assign_tree_path ~tree:access_path_tree new_path ~subtree:(create_leaf element)
    in
    let result = fold_tree_paths ~init:empty_tree ~f:build tree in
    let message () = "filter_map_tree_paths" in
    Checks.check (fun () -> check_minimal ~message result);
    result


  (** Removes all subtrees at depth. Used to limit amount of propagation across
      function boundaries, in particular for scaling. *)
  let cut_tree_after ~depth tree =
    let filter ~path ~ancestors:_ ~element =
      if List.length path > depth then
        path, Element.bottom
      else
        path, element
    in
    filter_map_tree_paths ~f:filter tree


  let create_tree path element =
    let message () = Format.sprintf "create_tree %s" (Label.show_path path) in
    create_tree_option path element |> option_node_tree ~message


  type raw_path_info = {
    path: Label.path;
    ancestors: Element.t;
    tip: Element.t;
  }

  module CommonArg = struct
    type nonrec t = t

    let bottom = bottom

    let join = join
  end

  module C = AbstractDomainCore.Common (CommonArg)

  type _ AbstractDomainCore.part +=
    | Self = C.Self
    | Path : (Label.path * Element.t) AbstractDomainCore.part
    | RawPath : raw_path_info AbstractDomainCore.part

  let fold (type a b) (part : a AbstractDomainCore.part) ~(f : a -> b -> b) ~init (tree : t) =
    match part with
    | Path ->
        let fold_tree_node ~path ~ancestors ~element accumulator =
          f (path, Element.join ancestors element) accumulator
        in
        fold_tree_paths ~init ~f:fold_tree_node tree
    | RawPath ->
        let fold_tree_node ~path ~ancestors ~element accumulator =
          f { path; ancestors; tip = element } accumulator
        in
        fold_tree_paths ~init ~f:fold_tree_node tree
    | C.Self -> C.fold part ~f ~init tree
    | _ ->
        let fold_tree_node ~path:_ ~ancestors:_ ~element accumulator =
          Element.fold part ~init:accumulator ~f element
        in
        fold_tree_paths ~init ~f:fold_tree_node tree


  let rec transform : type a. a AbstractDomainCore.part -> a AbstractDomainCore.transform -> t -> t =
   fun part t tree ->
    let open AbstractDomainCore in
    match part, t with
    | Path, Map f ->
        let transform_node ~path ~ancestors ~element = f (path, Element.join ancestors element) in
        filter_map_tree_paths ~f:transform_node tree
    | Path, Add (path, element) -> join tree (create_tree path (create_leaf element))
    | Path, Filter f ->
        filter_map_tree_paths
          ~f:(fun ~path ~ancestors ~element ->
            if f (path, Element.join ancestors element) then
              path, element
            else
              path, Element.bottom)
          tree
    | RawPath, Map f ->
        let transform_node ~path ~ancestors ~element =
          let { path; ancestors; tip } = f { path; ancestors; tip = element } in
          path, Element.join ancestors tip
        in
        filter_map_tree_paths ~f:transform_node tree
    | RawPath, Add { path; ancestors = _; tip } -> join tree (create_tree path (create_leaf tip))
    | RawPath, Filter f ->
        filter_map_tree_paths
          ~f:(fun ~path ~ancestors ~element ->
            if f { path; ancestors; tip = element } then
              path, element
            else
              path, Element.bottom)
          tree
    | Path, _ -> C.transform transformer part t tree
    | RawPath, _ -> C.transform transformer part t tree
    | C.Self, _ -> C.transform transformer part t tree
    | _ ->
        let transform_node ~path ~ancestors:_ ~element = path, Element.transform part t element in
        filter_map_tree_paths ~f:transform_node tree


  and transformer (AbstractDomainCore.T (part, t)) (d : t) : t = transform part t d

  let partition (type a b) (part : a AbstractDomainCore.part) ~(f : a -> b option) (tree : t)
      : (b, t) MapPoly.t
    =
    let update path element existing =
      let leaf = create_leaf element in
      match existing with
      | None -> create_tree path leaf
      | Some tree -> assign_tree_path ~tree path ~subtree:leaf
    in
    match part with
    | Path ->
        let partition ~path ~ancestors ~element result =
          match f (path, Element.join ancestors element) with
          | None -> result
          | Some partition_key -> MapPoly.update result partition_key ~f:(update path element)
        in
        fold_tree_paths ~init:MapPoly.empty ~f:partition tree
    | RawPath ->
        let partition ~path ~ancestors ~element result =
          match f { path; ancestors; tip = element } with
          | None -> result
          | Some partition_key -> MapPoly.update result partition_key ~f:(update path element)
        in
        fold_tree_paths ~init:MapPoly.empty ~f:partition tree
    | C.Self -> C.partition part ~f tree
    | _ ->
        let partition ~path ~ancestors:_ ~element result =
          let element_partition = Element.partition part ~f element in
          let distribute ~key ~data result = MapPoly.update result key ~f:(update path data) in
          MapPoly.fold ~init:result ~f:distribute element_partition
        in
        fold_tree_paths ~init:MapPoly.empty ~f:partition tree


  let create parts =
    let create_path result part =
      match part with
      | AbstractDomainCore.Part (Path, (path, element)) ->
          create_leaf element |> create_tree path |> join result
      | AbstractDomainCore.Part (RawPath, info) ->
          create_leaf (Element.join info.ancestors info.tip) |> create_tree info.path |> join result
      | AbstractDomainCore.Part (C.Self, info) -> join result (info : t)
      | _ ->
          (* Assume [] path *)
          Element.create [part] |> create_leaf |> join result
    in
    ListLabels.fold_left parts ~init:bottom ~f:create_path


  let collapse = collapse ~widen_depth:None

  let prepend = create_tree

  let introspect (type a) (op : a AbstractDomainCore.introspect) : a =
    let open AbstractDomainCore in
    match op with
    | GetParts f ->
        f#report C.Self;
        f#report Path;
        f#report RawPath;
        Element.introspect op
    | Structure ->
        let range = Element.introspect op in
        "Tree ->" :: ListLabels.map ~f:(fun s -> "  " ^ s) range
    | Name part -> (
        match part with
        | Path -> Format.sprintf "Tree.Path"
        | RawPath -> Format.sprintf "Tree.PathRaw"
        | Self -> Format.sprintf "Tree.Self"
        | _ -> C.introspect op )
end
