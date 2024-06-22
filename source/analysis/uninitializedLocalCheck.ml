(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* This module defines Pyre's check for uninitialized local variables. This check, which is
   independent of type checking but makes use of the same control flow graph, catches situations
   where code uses a local variable that may not have been defined yet. For example an uninitialized
   local error can occur if a variable is bound inside an `if` statement and then used
   unconditionally later on. *)

open Core
open Ast
open Pyre
open Statement
open Expression
module Error = AnalysisError
module NameAccessSet = Set.Make (Define.NameAccess)

(** Collect accesses to names within expressions. Within lambdas and comprehensions, collect
    accesses to names not bound by the lambda or comprehension. *)
module AccessCollector = struct
  let rec from_expression collected { Node.value; location = expression_location } =
    let open Expression in
    let from_entry collected entry =
      let open Dictionary.Entry in
      match entry with
      | KeyValue { key; value } ->
          let collected = from_expression collected key in
          from_expression collected value
      | Splat s -> from_expression collected s
    in
    match value with
    (* Lambdas are special -- they bind their own names, which we want to exclude *)
    | Lambda { Lambda.parameters; body } ->
        let collected =
          let from_parameter collected { Node.value = { Parameter.value; _ }; _ } =
            Option.value_map value ~f:(from_expression collected) ~default:collected
          in
          List.fold parameters ~init:collected ~f:from_parameter
        in
        let bound_names =
          List.map parameters ~f:(fun { Node.value = { Parameter.name; _ }; _ } ->
              Identifier.split_star name |> snd)
          |> Identifier.Set.of_list
        in
        let names_in_body = from_expression NameAccessSet.empty body in
        let unbound_names_in_body =
          Set.filter names_in_body ~f:(fun { Define.NameAccess.name; _ } ->
              not (Set.mem bound_names name))
        in
        Set.union unbound_names_in_body collected
    | Name (Name.Identifier identifier) ->
        (* For simple names, add them to the result *)
        Set.add collected { Define.NameAccess.name = identifier; location = expression_location }
    | Name (Name.Attribute { Name.Attribute.base; _ }) -> (
        (* We want to recursively collect attribute access in base expressions of attribute lookups,
           but we have to short-circuit identifiers because, due to qualification, we aren't able to
           reliably distinguish attribute access on locals from globals. (see T94414920) *)
        match base.value with
        | Name (Name.Identifier _) -> collected
        | _ -> from_expression collected base)
    (* The rest is boilerplates to make sure that expressions are visited recursively *)
    | Await await -> from_expression collected await
    | BinaryOperator { BinaryOperator.left; right; _ }
    | BooleanOperator { BooleanOperator.left; right; _ }
    | ComparisonOperator { ComparisonOperator.left; right; _ } ->
        let collected = from_expression collected left in
        from_expression collected right
    | Slice { start; stop; step } ->
        let collected = Option.value_map start ~default:collected ~f:(from_expression collected) in
        let collected = Option.value_map stop ~default:collected ~f:(from_expression collected) in
        Option.value_map step ~default:collected ~f:(from_expression collected)
    | Subscript { Subscript.base; index } ->
        let collected = from_expression collected base in
        from_expression collected index
    | Call { Call.callee; arguments } ->
        let collected = from_expression collected callee in
        List.fold arguments ~init:collected ~f:(fun collected { Call.Argument.value; _ } ->
            from_expression collected value)
    | Dictionary entries -> List.fold entries ~init:collected ~f:from_entry
    | DictionaryComprehension comprehension ->
        from_comprehension
          ~collected
          (fun collected Dictionary.Entry.KeyValue.{ key; value } ->
            let collected = from_expression collected key in
            from_expression collected value)
          comprehension
    | Generator comprehension
    | ListComprehension comprehension
    | SetComprehension comprehension ->
        from_comprehension ~collected from_expression comprehension
    | List expressions
    | Set expressions
    | Tuple expressions ->
        List.fold expressions ~init:collected ~f:from_expression
    | FormatString substrings ->
        let from_substring sofar = function
          | Substring.Literal _ -> sofar
          | Substring.Format { value; format_spec } ->
              let sofar = from_expression sofar value in
              Option.value_map format_spec ~default:sofar ~f:(from_expression sofar)
        in
        List.fold substrings ~init:collected ~f:from_substring
    | Starred (Starred.Once expression)
    | Starred (Starred.Twice expression) ->
        from_expression collected expression
    | Ternary { Ternary.target; test; alternative } ->
        let collected = from_expression collected target in
        let collected = from_expression collected test in
        from_expression collected alternative
    | UnaryOperator { UnaryOperator.operand; _ } -> from_expression collected operand
    | WalrusOperator { WalrusOperator.value; _ } -> from_expression collected value
    | Yield yield -> Option.value_map yield ~default:collected ~f:(from_expression collected)
    | YieldFrom yield -> from_expression collected yield
    | Constant _ -> collected


  (* Generators are as special as lambdas -- they bind their own names, which we want to exclude *)
  and from_comprehension :
        'a.
        collected:NameAccessSet.t ->
        (NameAccessSet.t -> 'a -> NameAccessSet.t) ->
        'a Comprehension.t ->
        NameAccessSet.t
    =
   fun ~collected from_element { Comprehension.element; generators } ->
    let remove_bound_names ~bound_names =
      Set.filter ~f:(fun { Define.NameAccess.name; _ } -> not (Set.mem bound_names name))
    in
    let bound_names, collected =
      let from_generator
          (bound_names, accesses_sofar)
          { Comprehension.Generator.target; iterator; conditions; _ }
        =
        let iterator_accesses =
          from_expression NameAccessSet.empty iterator |> remove_bound_names ~bound_names
        in
        let bound_names =
          let add_bound_name bound_names { Define.NameAccess.name; _ } = Set.add bound_names name in
          from_expression NameAccessSet.empty target |> Set.fold ~init:bound_names ~f:add_bound_name
        in
        let condition_accesses =
          List.fold conditions ~init:NameAccessSet.empty ~f:from_expression
          |> remove_bound_names ~bound_names
        in
        ( bound_names,
          NameAccessSet.union_list [accesses_sofar; iterator_accesses; condition_accesses] )
      in
      List.fold generators ~init:(Identifier.Set.empty, collected) ~f:from_generator
    in
    let element_accesses =
      from_element NameAccessSet.empty element |> remove_bound_names ~bound_names
    in
    Set.union collected element_accesses
end

let extract_reads_in_expression expression =
  let name_access_to_identifier_node { Define.NameAccess.name; location } =
    { Node.value = name; location }
  in
  AccessCollector.from_expression NameAccessSet.empty expression
  |> Set.to_list
  |> List.map ~f:name_access_to_identifier_node


let extract_value_expressions_from_assignment_target expression =
  (* Assignments can sometimes involve no reads (if they just bind a name in scope), but they can
     also resolve to either attribute setting or `__setitem__` calls for subscript targets. We
     cannot yet handle attribute access because we don't model scope well, but we should detect both
     the base and the key in subscript targets. *)
  let rec extract_one_element so_far { Node.value; _ } =
    match value with
    | Expression.Subscript { base; index } -> base :: index :: so_far
    | List elements
    | Tuple elements ->
        List.fold ~f:extract_one_element ~init:so_far elements
    | _ -> so_far
  in
  extract_one_element [] expression


let extract_reads_in_statement { Node.value; _ } =
  let expressions =
    match value with
    | Statement.Assign { Assign.value = Some expression; target; _ } ->
        expression :: extract_value_expressions_from_assignment_target target
    | Assign { Assign.value = None; target; _ } ->
        extract_value_expressions_from_assignment_target target
    | AugmentedAssign { AugmentedAssign.value; target; _ } ->
        value :: extract_value_expressions_from_assignment_target target
    | Expression expression
    | If { If.test = expression; _ }
    | While { While.test = expression; _ } ->
        [expression]
    | Delete expressions -> expressions
    | Assert { Assert.test; message; _ } -> [test] @ Option.to_list message
    | For { For.target; iterator; _ } -> [target; iterator]
    | Raise { Raise.expression; from } -> Option.to_list expression @ Option.to_list from
    | Return { Return.expression; _ } -> Option.to_list expression
    | With { With.items; _ } -> items |> List.map ~f:(fun (value, _) -> value)
    | Break
    | Class _
    | Continue
    | Define _
    | Global _
    | Import _
    (* TODO(T107105911): Handle access for match statement. *)
    | Match _
    | Nonlocal _
    | Pass
    | Try _ ->
        []
  in
  expressions |> List.concat_map ~f:extract_reads_in_expression


type defined_locals = Scope.Binding.t Identifier.Map.t

module StatementKey = Int

let local_bindings { Scope.Scope.bindings; globals; nonlocals; _ } =
  (* Santitization is needed to remove (some) scope information that is (sometimes, but not
     consistently) added into the identifiers themselves (e.g. $local_test?f$y). *)
  let locals = Map.keys bindings |> List.map ~f:Identifier.sanitized |> Identifier.Set.of_list in
  (* This operation needs to be repeated as Scope doesn't know about qualification, and hence
     doesn't remove all globals and nonlocals from bindings *)
  let globals = Identifier.Set.map ~f:Identifier.sanitized globals in
  let nonlocals = Identifier.Set.map ~f:Identifier.sanitized nonlocals in
  let filtered_locals = Set.diff (Set.diff locals globals) nonlocals in
  let sanitized_local_bindings =
    Map.fold bindings ~init:Identifier.Map.empty ~f:(fun ~key ~data sanitized ->
        Map.set sanitized ~key:(Identifier.sanitized key) ~data)
  in
  Map.filteri ~f:(fun ~key ~data:_ -> Set.mem filtered_locals key) sanitized_local_bindings


let create_map =
  List.fold ~init:Identifier.Map.empty ~f:(fun sofar ({ Scope.Binding.name; _ } as binding) ->
      (* First binding (i.e. last item in the list) wins. *)
      Map.set sofar ~key:(Identifier.sanitized name) ~data:binding)


module type Context = sig
  val fixpoint_post_statement : (Statement.t * defined_locals) StatementKey.Table.t
end

module State (Context : Context) = struct
  type t =
    | Bottom
    | Value of defined_locals

  let show = function
    | Bottom -> "Bottom"
    | Value state ->
        let show_binding { Scope.Binding.name; location; _ } =
          [%show: Identifier.t * Location.t] (name, location)
        in
        state
        |> Map.data
        |> List.map ~f:show_binding
        |> String.concat ~sep:", "
        |> Format.sprintf "[%s]"


  let bottom = Bottom

  let pp format state = Format.fprintf format "%s" (show state)

  let initial ~define:{ Node.value = { Define.signature; _ }; _ } =
    signature.parameters |> Scope.Binding.of_parameters [] |> create_map |> fun value -> Value value


  let less_or_equal ~left ~right =
    match left, right with
    | Value left, Value right ->
        let to_set map = Map.keys map |> Identifier.Set.of_list in
        to_set right |> Set.is_subset ~of_:(to_set left)
    | Value _, Bottom -> false
    | Bottom, Value _ -> true
    | Bottom, Bottom -> true


  let join left right =
    match left, right with
    | Value left, Value right ->
        let intersect ~key:_ = function
          | `Both (left, _) -> Some left
          | `Right _
          | `Left _ ->
              None
        in
        Value (Map.merge ~f:intersect left right)
    | Value left, Bottom -> Value left
    | Bottom, Value right -> Value right
    | Bottom, Bottom -> Bottom


  let widen ~previous ~next ~iteration:_ = join previous next

  let forward ~statement_key state ~statement =
    match state, statement with
    (* try statements are only included in the CFG to check the annotations of their exception
       handlers *)
    | _, { Node.value = Statement.Try _; _ } -> state
    | Bottom, _ -> Bottom
    | Value state, _ ->
        let union ~key:_ = function
          | `Both
              ( ({ Scope.Binding.location = left_location; _ } as left),
                ({ Scope.Binding.location = right_location; _ } as right) ) ->
              (* Pick the later-assigned variable. *)
              if [%compare: Location.t] left_location right_location >= 0 then
                Some left
              else
                Some right
          | `Right only
          | `Left only ->
              Some only
        in
        let new_state =
          Scope.Binding.of_statement [] statement |> create_map |> Map.merge ~f:union state
        in
        Hashtbl.set Context.fixpoint_post_statement ~key:statement_key ~data:(statement, new_state);
        Value new_state


  let backward ~statement_key:_ _ ~statement:_ = failwith "Not implemented"
end

let defined_locals_at_each_statement define =
  let module Context = struct
    let fixpoint_post_statement = StatementKey.Table.create ()
  end
  in
  let module State = State (Context) in
  let module Fixpoint = Fixpoint.Make (State) in
  let cfg = Cfg.create (Node.value define) in
  let fixpoint = Fixpoint.forward ~cfg ~initial:(State.initial ~define) in
  let defined_locals =
    match Context.fixpoint_post_statement |> Hashtbl.to_alist |> StatementKey.Map.of_alist with
    | `Ok map -> map
    | `Duplicate_key _ -> StatementKey.Map.empty
  in
  Fixpoint.exit fixpoint
  >>| (fun _ -> defined_locals)
  |> Option.value ~default:StatementKey.Map.empty


let errors ~qualifier ~define defined_locals_at_each_statement =
  let emit_error { Node.value; location } =
    Error.create
      ~location:(Location.with_module ~module_reference:qualifier location)
      ~kind:(Error.UninitializedLocal value)
      ~define
  in
  let bindings = Scope.Scope.of_define_exn define.value in
  let in_local_scope { Node.value = identifier; _ } =
    let all_local_identifiers = local_bindings bindings |> Map.keys |> Identifier.Set.of_list in
    identifier |> Identifier.sanitized |> Set.mem all_local_identifiers
  in
  let is_binding { Node.location; _ } =
    let { Scope.Scope.bindings; _ } = bindings in
    let all_binding_locations =
      bindings
      |> Map.data
      |> List.map ~f:(fun { Scope.Binding.location; _ } -> location)
      |> Location.Set.of_list
    in
    Set.mem all_binding_locations location
  in
  let uninitialized_usage (statement, initialized) =
    let is_uninitialized { Node.value = identifier; _ } =
      not (Map.mem initialized (Identifier.sanitized identifier))
    in
    extract_reads_in_statement statement |> List.filter ~f:is_uninitialized
  in
  defined_locals_at_each_statement
  |> Map.data
  |> List.concat_map ~f:uninitialized_usage
  |> List.filter ~f:in_local_scope
  |> List.filter ~f:(fun usage -> not (is_binding usage))
  |> List.map ~f:emit_error


let check_define ~qualifier define =
  defined_locals_at_each_statement define |> errors ~qualifier ~define


let check_module_for_testing
    ~source:({ Source.module_path = { ModulePath.qualifier; _ }; _ } as source)
  =
  source
  |> Preprocessing.defines ~include_toplevels:false
  |> List.map ~f:(check_define ~qualifier)
  |> List.concat
