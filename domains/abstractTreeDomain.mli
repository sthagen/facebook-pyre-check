(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the LICENSE file in the root
    directory of this source tree. *)

module type CONFIG = sig
  val max_tree_depth_after_widening : int

  val check_invariants : bool
end

module Label : sig
  type t =
    | Field of string
    | DictionaryKeys
    | Any
  [@@deriving show]

  type path = t list [@@deriving show]

  val compare_path : path -> path -> int

  val equal_path : path -> path -> bool

  val create_name_field : string -> t

  val create_int_field : int -> t

  val common_prefix : path -> path -> path

  val is_prefix : prefix:path -> path -> bool
end

module Make (Config : CONFIG) (Element : AbstractDomainCore.S) () : sig
  include AbstractDomainCore.S

  type raw_path_info = {
    path: Label.path;
    ancestors: Element.t;
    tip: Element.t;
  }

  type _ AbstractDomainCore.part +=
    | (* The abstract value at each path including ancestors (only non-bottom points are visitied *)
        Path :
        (Label.path * Element.t) AbstractDomainCore.part
    | (* The abstract value at each path with separate ancestor values (only non-bottom points are
         visitied *)
        RawPath :
        raw_path_info AbstractDomainCore.part

  val create_leaf : Element.t -> t

  (* Creates a new tree that has the given tree as a subtree at the given path. *)
  val prepend : Label.path -> t -> t

  (* Assign the given subtree at the path in the tree. If weak is true, join the subtree with the
     existing tree at that point. *)
  val assign : ?weak:bool -> tree:t -> Label.path -> subtree:t -> t

  val read : ?transform_non_leaves:(Label.path -> Element.t -> Element.t) -> Label.path -> t -> t

  (* Compute minimum/maximum path length to non-bottom element. *)
  val min_depth : t -> int

  val max_depth : t -> int

  val collapse : t -> Element.t

  (* Collapse subtrees at depth *)
  val collapse_to : depth:int -> t -> t

  (* shape tree ~mold performs a join of tree and mold such that the resulting tree only has
     branches that are already in mold. *)
  val shape : t -> mold:t -> t

  val cut_tree_after : depth:int -> t -> t

  val get_root_taint : t -> Element.t
end
