(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

(* `edges` mapping from type index to a set of targets. `indices` mapping from annotation to its
   vertex index. `annotations` inverse of `indices`. *)
open Core
open Ast
open Pyre

exception Cyclic

exception Incomplete

exception InconsistentMethodResolutionOrder of Type.Primitive.t

exception Untracked of Type.t

module Target = struct
  type t = {
    target: IndexTracker.t;
    parameters: Type.OrderedTypes.t;
  }
  [@@deriving compare, eq, sexp, show]

  module type ListOrSet = sig
    type record

    val filter : record -> f:(t -> bool) -> record

    val is_empty : record -> bool

    val exists : record -> f:(t -> bool) -> bool

    val iter : record -> f:(t -> unit) -> unit

    val equal : record -> record -> bool

    val mem : record -> t -> bool

    val to_string : f:(t -> string) -> record -> string

    val fold : record -> init:'accum -> f:('accum -> t -> 'accum) -> 'accum

    val empty : record

    val add : record -> t -> record
  end

  module Set = struct
    include Set.Make (struct
      type nonrec t = t

      let compare = compare

      let sexp_of_t = sexp_of_t

      let t_of_sexp = t_of_sexp
    end)

    type record = t

    let to_string ~f set = to_list set |> List.to_string ~f
  end

  let target { target; _ } = target

  let target_equal = equal

  module List = struct
    type record = t list

    include List

    let mem = List.mem ~equal:target_equal

    let equal = List.equal target_equal

    let add list element = element :: list

    let empty = []
  end
end

let generic_primitive = "typing.Generic"

module type Handler = sig
  val edges : IndexTracker.t -> Target.t list option

  val contains : Type.Primitive.t -> bool
end

let index_of annotation = IndexTracker.index annotation

let contains (module Handler : Handler) = Handler.contains

let is_instantiated (module Handler : Handler) annotation =
  let is_invalid = function
    | Type.Variable { constraints = Type.Variable.Unconstrained; _ } -> true
    | Type.Primitive name
    | Type.Parametric { name; _ } ->
        not (contains (module Handler) name)
    | _ -> false
  in
  not (Type.exists ~predicate:is_invalid annotation)


let raise_if_untracked order annotation =
  if not (contains order annotation) then
    raise (Untracked (Type.Primitive annotation))


let method_resolution_order_linearize ~get_successors class_name =
  let rec merge = function
    | [] -> []
    | [single_linearized_parent] -> single_linearized_parent
    | linearized_successors ->
        let find_valid_head linearizations =
          let is_valid_head head =
            let not_in_tail target = function
              | [] -> true
              | _ :: tail -> not (List.exists ~f:(Identifier.equal target) tail)
            in
            List.for_all ~f:(not_in_tail head) linearizations
          in
          linearizations
          |> List.filter_map ~f:List.hd
          |> List.find ~f:is_valid_head
          |> function
          | Some head -> head
          | None -> raise (InconsistentMethodResolutionOrder class_name)
        in
        let strip_head head = function
          | [] -> None
          | [successor_head] when Identifier.equal successor_head head -> None
          | successor_head :: tail when Identifier.equal successor_head head -> Some tail
          | successor -> Some successor
        in
        let head = find_valid_head linearized_successors in
        let linearized_successors = List.filter_map ~f:(strip_head head) linearized_successors in
        head :: merge linearized_successors
  in
  let rec linearize class_name =
    let linearized_successors =
      let create_annotation { Target.target = index; _ } = IndexTracker.annotation index in
      index_of class_name
      |> get_successors
      |> Option.value ~default:[]
      |> List.map ~f:create_annotation
      |> List.map ~f:linearize
    in
    class_name :: merge linearized_successors
  in
  linearize class_name


let successors (module Handler : Handler) annotation =
  let linearization = method_resolution_order_linearize ~get_successors:Handler.edges annotation in
  match linearization with
  | _ :: successors -> successors
  | [] -> []


type variables =
  | Unaries of Type.Variable.Unary.t list
  | Concatenation of
      (Type.Variable.Variadic.List.t, Type.Variable.Unary.t) Type.OrderedTypes.Concatenation.t
[@@deriving compare, eq, sexp, show]

let clean not_clean =
  let clarify_into_variables parameters =
    List.map parameters ~f:(function
        | Type.Variable variable -> Some variable
        | _ -> None)
    |> Option.all
  in
  match not_clean with
  | Type.OrderedTypes.Concrete parameters ->
      clarify_into_variables parameters >>| fun unaries -> Unaries unaries
  | Concatenation concatenation -> (
      let open Type.OrderedTypes.Concatenation in
      match
        ( clarify_into_variables (head concatenation),
          Type.OrderedTypes.Concatenation.Middle.unwrap_if_bare (middle concatenation),
          clarify_into_variables (tail concatenation) )
      with
      | Some head, Some middle, Some tail -> Some (Concatenation (create ~head ~tail middle))
      | _ -> None )
  | Any -> None


let variables ?(default = None) (module Handler : Handler) = function
  | "type" ->
      (* Despite what typeshed says, typing.Type is covariant:
         https://www.python.org/dev/peps/pep-0484/#the-type-of-class-objects *)
      Some (Unaries [Type.Variable.Unary.create ~variance:Covariant "_T_meta"])
  | "typing.Callable" ->
      (* This is not the "real" typing.Callable. We are just proxying to the Callable instance in
         the type order here. *)
      Some (Unaries [Type.Variable.Unary.create ~variance:Covariant "_T_meta"])
  | node -> (
      let edges =
        index_of generic_primitive
        |> fun generic_index ->
        index_of node
        |> fun primitive_index ->
        Handler.edges primitive_index
        >>= List.find ~f:(fun { Target.target; _ } -> IndexTracker.equal target generic_index)
        >>| fun { Target.parameters; _ } -> parameters
      in
      match edges with
      | None -> default
      | Some edges -> clean edges )


let get_generic_parameters ~generic_index edges =
  let generic_parameters { Target.target; parameters } =
    Option.some_if (IndexTracker.equal generic_index target) parameters
  in
  List.find_map ~f:generic_parameters edges


let least_common_successor ((module Handler : Handler) as order) ~successors left right =
  raise_if_untracked order left;
  raise_if_untracked order right;
  if Type.Primitive.compare left right = 0 then
    [left]
  else
    (let rec iterate left right =
       let successors sources =
         Set.fold
           ~init:IndexTracker.Set.empty
           ~f:(fun sofar index -> Set.union sofar (successors index))
           sources
       in
       let left_successors = successors (List.hd_exn left) in
       let right_successors = successors (List.hd_exn right) in
       if Set.is_empty left_successors && Set.is_empty right_successors then
         []
       else
         let intersect left right =
           let collect = List.fold ~init:IndexTracker.Set.empty ~f:Set.union in
           Set.inter (collect left) (collect right)
         in
         let left = left_successors :: left in
         let right = right_successors :: right in
         let left_tail_right = intersect (List.tl_exn left) right in
         let left_right_tail = intersect left (List.tl_exn right) in
         if (not (Set.is_empty left_tail_right)) || not (Set.is_empty left_right_tail) then
           Set.union left_tail_right left_right_tail |> Set.to_list
         else
           let left_right = intersect left right in
           if not (Set.is_empty left_right) then
             Set.to_list left_right
           else
             iterate left right
     in
     iterate [IndexTracker.Set.of_list [index_of left]] [IndexTracker.Set.of_list [index_of right]])
    |> List.map ~f:IndexTracker.annotation


let least_upper_bound ((module Handler : Handler) as order) =
  let successors index =
    match Handler.edges index with
    | Some targets -> targets |> List.map ~f:Target.target |> IndexTracker.Set.of_list
    | None -> IndexTracker.Set.empty
  in
  least_common_successor order ~successors


let is_transitive_successor ((module Handler : Handler) as handler) ~source ~target =
  raise_if_untracked handler source;
  raise_if_untracked handler target;
  let worklist = Queue.create () in
  let visited = IndexTracker.Hash_set.create () in
  Queue.enqueue worklist { Target.target = index_of source; parameters = Concrete [] };
  let rec iterate worklist =
    match Queue.dequeue worklist with
    | None -> false
    | Some { Target.target = current; _ } -> (
        match Hash_set.strict_add visited current with
        | Error _ -> iterate worklist
        | Ok () ->
            if IndexTracker.equal current (index_of target) then
              true
            else (
              Option.iter (Handler.edges current) ~f:(Queue.enqueue_all worklist);
              iterate worklist ) )
  in
  iterate worklist


let instantiate_successors_parameters ((module Handler : Handler) as handler) ~source ~target =
  raise_if_untracked handler target;
  let generic_index = IndexTracker.index generic_primitive in
  match source with
  | Type.Bottom ->
      let set_to_anys = function
        | Type.OrderedTypes.Concrete concrete ->
            List.map concrete ~f:(fun _ -> Type.Any) |> fun anys -> Type.OrderedTypes.Concrete anys
        | Concatenation _
        | Any ->
            Type.OrderedTypes.Any
      in
      index_of target |> Handler.edges >>= get_generic_parameters ~generic_index >>| set_to_anys
  | _ ->
      let split =
        match Type.split source with
        | Primitive primitive, _ when not (contains handler primitive) -> None
        | Primitive "tuple", parameters ->
            let union = Type.OrderedTypes.union_upper_bound parameters |> Type.weaken_literals in
            Some ("tuple", Type.OrderedTypes.Concrete [union])
        | Primitive primitive, parameters -> Some (primitive, parameters)
        | _ ->
            (* We can only propagate from those that actually split off a primitive *)
            None
      in
      let handle_split (primitive, parameters) =
        let worklist = Queue.create () in
        Queue.enqueue worklist { Target.target = index_of primitive; parameters };
        let rec iterate worklist =
          match Queue.dequeue worklist with
          | Some { Target.target = target_index; parameters } ->
              let instantiated_successors =
                (* If a node on the graph has Generic[_T1, _T2, ...] as a supertype and has concrete
                   parameters, all occurrences of _T1, _T2, etc. in other supertypes need to be
                   replaced with the concrete parameter corresponding to the type variable. This
                   function takes a target with concrete parameters and its supertypes, and
                   instantiates the supertypes accordingly. *)
                let get_instantiated_successors ~generic_index ~parameters successors =
                  let variables =
                    get_generic_parameters successors ~generic_index
                    >>= clean
                    |> Option.value ~default:(Unaries [])
                  in
                  let replacement =
                    match variables with
                    | Unaries variables -> (
                        let zipped =
                          match parameters with
                          | Type.OrderedTypes.Concrete parameters -> (
                              match List.zip variables parameters with
                              | Ok zipped -> Some zipped
                              | _ -> None )
                          | Concatenation _
                          | Any ->
                              None
                        in
                        match zipped with
                        | Some pairs ->
                            List.map pairs ~f:(fun (variable, parameter) ->
                                Type.Variable.UnaryPair (variable, parameter))
                        | None ->
                            (* This is the specified behavior for empty parameters, and other
                               mismatched lengths should have an error at the declaration site, and
                               this behavior seems reasonable *)
                            List.map variables ~f:(fun variable ->
                                Type.Variable.UnaryPair (variable, Type.Any)) )
                    | Concatenation concatenation -> (
                        let zipped =
                          let handle_paired paired =
                            let unary_pairs =
                              List.map ~f:(fun (variable, bound) ->
                                  Type.Variable.UnaryPair (variable, bound))
                            in
                            let middle, middle_bound =
                              Type.OrderedTypes.Concatenation.middle paired
                            in
                            unary_pairs (Type.OrderedTypes.Concatenation.head paired)
                            @ [Type.Variable.ListVariadicPair (middle, Concrete middle_bound)]
                            @ unary_pairs (Type.OrderedTypes.Concatenation.tail paired)
                          in
                          match parameters with
                          | Type.OrderedTypes.Concrete parameters ->
                              Type.OrderedTypes.Concatenation.zip concatenation ~against:parameters
                              >>| handle_paired
                          | non_concrete ->
                              Type.OrderedTypes.Concatenation.unwrap_if_only_middle concatenation
                              >>| fun variable ->
                              [Type.Variable.ListVariadicPair (variable, non_concrete)]
                        in
                        match zipped with
                        | Some pairs -> pairs
                        | None ->
                            let pair_all_with_any =
                              List.map ~f:(fun variable -> Type.Variable.UnaryPair (variable, Any))
                            in
                            pair_all_with_any (Type.OrderedTypes.Concatenation.head concatenation)
                            @ [
                                Type.Variable.ListVariadicPair
                                  (Type.OrderedTypes.Concatenation.middle concatenation, Any);
                              ]
                            @ pair_all_with_any (Type.OrderedTypes.Concatenation.tail concatenation)
                        )
                  in
                  let replacement = TypeConstraints.Solution.create replacement in
                  let instantiate_parameters { Target.target; parameters } =
                    {
                      Target.target;
                      parameters =
                        TypeConstraints.Solution.instantiate_ordered_types replacement parameters;
                    }
                  in
                  List.map successors ~f:instantiate_parameters
                in
                Handler.edges target_index
                >>| get_instantiated_successors ~generic_index ~parameters
              in
              if IndexTracker.equal target_index (index_of target) then
                match target with
                | "typing.Callable" -> Some parameters
                | _ -> instantiated_successors >>= get_generic_parameters ~generic_index
              else (
                instantiated_successors >>| List.iter ~f:(Queue.enqueue worklist) |> ignore;
                iterate worklist )
          | None -> None
        in
        iterate worklist
      in
      split >>= handle_split


let check_integrity (module Handler : Handler) ~(indices : IndexTracker.t list) =
  (* Ensure keys are consistent. *)
  let key_consistent key =
    let raise_if_none value =
      if Option.is_none value then (
        Log.error "Inconsistency in type order: No value for key %s" (IndexTracker.show key);
        raise Incomplete )
    in
    raise_if_none (Handler.edges key)
  in
  List.iter ~f:key_consistent indices;

  (* Check for cycles. *)
  let started_from = ref IndexTracker.Set.empty in
  let find_cycle start =
    if not (Set.mem !started_from start) then
      let rec visit reverse_visited index =
        if List.mem ~equal:IndexTracker.equal reverse_visited index then (
          let trace =
            List.rev_map ~f:IndexTracker.annotation (index :: reverse_visited)
            |> String.concat ~sep:" -> "
          in
          Log.error "Order is cyclic:\nTrace: %s" (* (Handler.show ()) *) trace;
          raise Cyclic )
        else if not (Set.mem !started_from index) then (
          started_from := Set.add !started_from index;
          match Handler.edges index with
          | Some successors ->
              successors
              |> List.map ~f:Target.target
              |> List.iter ~f:(visit (index :: reverse_visited))
          | None -> () )
      in
      visit [] start
  in
  indices |> List.iter ~f:find_cycle


let to_json (module Handler : Handler) ~indices =
  let add_node (index, annotation) =
    match Handler.edges index with
    | Some successors ->
        List.map successors ~f:(fun { Target.target; _ } ->
            `String (IndexTracker.annotation target))
        |> (fun successors -> `Assoc [annotation, `List successors])
        |> Option.some
    | None -> None
  in
  indices
  |> List.map ~f:(fun index -> index, IndexTracker.annotation index)
  |> List.sort ~compare:(fun (_, left_annotation) (_, right_annotation) ->
         String.compare left_annotation right_annotation)
  |> List.filter_map ~f:add_node
  |> fun hierarchy -> `List hierarchy


let to_dot (module Handler : Handler) ~indices =
  let indices = List.sort ~compare indices in
  let nodes = List.map indices ~f:(fun index -> index, IndexTracker.annotation index) in
  let buffer = Buffer.create 10000 in
  Buffer.add_string buffer "digraph {\n";
  List.iter
    ~f:(fun (index, annotation) ->
      Format.asprintf "  %s[label=\"%s\"]\n" (IndexTracker.show index) annotation
      |> Buffer.add_string buffer)
    nodes;
  let add_edges index =
    Handler.edges index
    >>| List.sort ~compare
    >>| List.iter ~f:(fun { Target.target = successor; parameters } ->
            Format.asprintf "  %s -> %s" (IndexTracker.show index) (IndexTracker.show successor)
            |> Buffer.add_string buffer;
            if not (Type.OrderedTypes.equal parameters (Concrete [])) then
              Format.asprintf "[label=\"(%a)\"]" Type.OrderedTypes.pp_concise parameters
              |> Buffer.add_string buffer;
            Buffer.add_string buffer "\n")
    |> ignore
  in
  List.iter ~f:add_edges indices;
  Buffer.add_string buffer "}";
  Buffer.contents buffer
