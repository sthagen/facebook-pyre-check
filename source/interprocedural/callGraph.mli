(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Data_structures
open Ast
open Expression
module PyrePysaApi = Analysis.PyrePysaApi

(** Represents type information about the return type of a call. *)
module ReturnType : sig
  type t = {
    is_boolean: bool;
    is_integer: bool;
    is_float: bool;
    is_enumeration: bool;
  }
  [@@deriving eq, show]

  val any : t

  val none : t

  val bool : t

  val integer : t

  val from_annotation : pyre_api:PyrePysaApi.ReadOnly.t -> Type.t -> t

  val to_json : t -> Yojson.Safe.t
end

(** A specific target of a given call, with extra information. *)
module CallTarget : sig
  type t = {
    target: Target.t;
    (* True if the call has an implicit receiver.
     * For instance, `x.foo()` should be treated as `C.foo(x)`. *)
    implicit_receiver: bool;
    (* True if this is an implicit call to the `__call__` method. *)
    implicit_dunder_call: bool;
    (* The textual order index of the call in the function. *)
    index: int;
    (* The return type of the call expression, or `None` for object targets. *)
    return_type: ReturnType.t option;
    (* The class of the receiver object at this call site, if any. *)
    receiver_class: string option; (* True if calling a class method. *)
    is_class_method: bool;
    (* True if calling a static method. *)
    is_static_method: bool;
  }
  [@@deriving eq, show, compare]

  val target : t -> Target.t

  val create
    :  ?implicit_receiver:bool ->
    ?implicit_dunder_call:bool ->
    ?index:int ->
    ?return_type:ReturnType.t option ->
    ?receiver_class:string ->
    ?is_class_method:bool ->
    ?is_static_method:bool ->
    Target.t ->
    t

  val to_json : t -> Yojson.Safe.t
end

module ImplicitArgument : sig
  type t =
    | CalleeBase
    | Callee
    | None
  [@@deriving show]

  val implicit_argument : ?is_implicit_new:bool -> CallTarget.t -> t
end

(** Information about an argument being a callable. *)
module HigherOrderParameter : sig
  type t = {
    index: int;
    call_targets: CallTarget.t list;
    (* True if at least one callee could not be resolved.
     * Usually indicates missing type information at the call site. *)
    unresolved: bool;
  }
  [@@deriving eq, show]

  val to_json : t -> Yojson.Safe.t
end

(** Mapping from a parameter index to its HigherOrderParameter, if any. *)
module HigherOrderParameterMap : sig
  type t [@@deriving eq, show]

  val empty : t

  val is_empty : t -> bool

  val from_list : HigherOrderParameter.t list -> t

  val to_list : t -> HigherOrderParameter.t list

  val first_index : t -> HigherOrderParameter.t option

  val to_json : t -> Yojson.Safe.t
end

(** An aggregate of all possible callees at a call site. *)
module CallCallees : sig
  type t = {
    (* Normal call targets. *)
    call_targets: CallTarget.t list;
    (* Call targets for calls to the `__new__` class method. *)
    new_targets: CallTarget.t list;
    (* Call targets for calls to the `__init__` instance method. *)
    init_targets: CallTarget.t list;
    (* Information about arguments that are callables, and possibly called. *)
    higher_order_parameters: HigherOrderParameterMap.t;
    (* True if at least one callee could not be resolved.
     * Usually indicates missing type information at the call site. *)
    unresolved: bool;
  }
  [@@deriving eq, show]

  val create
    :  ?call_targets:CallTarget.t list ->
    ?new_targets:CallTarget.t list ->
    ?init_targets:CallTarget.t list ->
    ?higher_order_parameters:HigherOrderParameterMap.t ->
    ?unresolved:bool ->
    unit ->
    t

  (* When `debug` is true, log the reason for creating `unresolved`. *)
  val unresolved : ?debug:bool -> ?reason:string -> unit -> t

  val is_partially_resolved : t -> bool

  val pp_option : Format.formatter -> t option -> unit

  val is_mapping_method : t -> bool

  val is_sequence_method : t -> bool

  val is_string_method : t -> bool

  val is_object_new : CallTarget.t list -> bool

  val is_object_init : CallTarget.t list -> bool

  val to_json : t -> Yojson.Safe.t
end

(** An aggregrate of all possible callees for a given attribute access. *)
module AttributeAccessCallees : sig
  type t = {
    property_targets: CallTarget.t list;
    global_targets: CallTarget.t list;
    (* True if the attribute access should also be considered a regular attribute.
     * For instance, if the object has type `Union[A, B]` where only `A` defines a property. *)
    is_attribute: bool;
  }
  [@@deriving eq, show]

  val empty : t

  val to_json : t -> Yojson.Safe.t
end

(** An aggregate of all possible callees for a given identifier expression, i.e `foo`. *)
module IdentifierCallees : sig
  type t = {
    global_targets: CallTarget.t list;
    nonlocal_targets: CallTarget.t list;
  }
  [@@deriving eq, show]

  val to_json : t -> Yojson.Safe.t
end

(** An aggregate of callees for formatting strings. *)
module StringFormatCallees : sig
  type t = {
    (* Implicit callees for any expression that is stringified. *)
    stringify_targets: CallTarget.t list;
    (* Artificial callees for distinguishing f-strings within a function. *)
    f_string_targets: CallTarget.t list;
  }
  [@@deriving eq, show]

  val from_stringify_targets : CallTarget.t list -> t

  val from_f_string_targets : CallTarget.t list -> t

  val to_json : t -> Yojson.Safe.t
end

(** An aggregate of all possible callees for an arbitrary expression. *)
module ExpressionCallees : sig
  type t = {
    call: CallCallees.t option;
    attribute_access: AttributeAccessCallees.t option;
    identifier: IdentifierCallees.t option;
    string_format: StringFormatCallees.t option;
  }
  [@@deriving eq, show]

  val from_call : CallCallees.t -> t

  val from_call_with_empty_attribute : CallCallees.t -> t

  val from_attribute_access : AttributeAccessCallees.t -> t

  val from_identifier : IdentifierCallees.t -> t

  val from_string_format : StringFormatCallees.t -> t

  val to_json : t -> Yojson.Safe.t
end

(** An aggregate of all possible callees for an arbitrary location.

    Note that multiple expressions might have the same location. *)
module LocationCallees : sig
  type t =
    | Singleton of ExpressionCallees.t
    | Compound of ExpressionCallees.t SerializableStringMap.t
  [@@deriving eq, show]

  val to_json : t -> Yojson.Safe.t
end

(* Exposed for rare use cases, such as resolving the callees of decorators. *)
val resolve_callees_from_type_external
  :  pyre_in_context:PyrePysaApi.InContext.t ->
  override_graph:OverrideGraph.SharedMemory.ReadOnly.t option ->
  return_type:Type.t lazy_t ->
  ?dunder_call:bool ->
  Expression.t ->
  CallCallees.t

(** The call graph of a function or method definition. *)
module DefineCallGraph : sig
  type t [@@deriving eq, show]

  val empty : t

  val add : t -> location:Ast.Location.t -> callees:LocationCallees.t -> t

  val resolve_call
    :  t ->
    location:Ast.Location.t ->
    call:Ast.Expression.Call.t ->
    CallCallees.t option

  val resolve_attribute_access
    :  t ->
    location:Ast.Location.t ->
    attribute:string ->
    AttributeAccessCallees.t option

  val resolve_identifier
    :  t ->
    location:Ast.Location.t ->
    identifier:string ->
    IdentifierCallees.t option

  val resolve_string_format : t -> location:Ast.Location.t -> StringFormatCallees.t option

  (* For testing purpose only. *)
  val equal_ignoring_types : t -> t -> bool

  (** Return all callees of the call graph, as a sorted list. *)
  val all_targets : t -> Target.t list

  val to_json
    :  pyre_api:PyrePysaApi.ReadOnly.t ->
    resolve_module_path:(Reference.t -> RepositoryPath.t option) option ->
    callable:Target.t ->
    t ->
    Yojson.Safe.t
end

val call_graph_of_define
  :  static_analysis_configuration:Configuration.StaticAnalysis.t ->
  pyre_api:PyrePysaApi.ReadOnly.t ->
  override_graph:OverrideGraph.SharedMemory.ReadOnly.t option ->
  attribute_targets:Target.HashSet.t ->
  qualifier:Reference.t ->
  define:Ast.Statement.Define.t ->
  DefineCallGraph.t

val redirect_expressions
  :  pyre_in_context:PyrePysaApi.InContext.t ->
  location:Location.t ->
  Expression.expression ->
  Expression.expression

val redirect_assignments : Statement.t -> Statement.t

val call_graph_of_callable
  :  static_analysis_configuration:Configuration.StaticAnalysis.t ->
  pyre_api:PyrePysaApi.ReadOnly.t ->
  override_graph:OverrideGraph.SharedMemory.ReadOnly.t option ->
  attribute_targets:Target.HashSet.t ->
  callable:Target.t ->
  DefineCallGraph.t

(** Call graphs of callables, stored in the shared memory. This is a mapping from a callable to its
    `DefineCallGraph.t`. *)
module DefineCallGraphSharedMemory : sig
  type t

  val cleanup : t -> unit

  val save_to_cache : t -> unit

  val load_from_cache : unit -> (t, SaveLoadSharedMemory.Usage.t) result

  module ReadOnly : sig
    type t

    val get : t -> callable:Target.t -> DefineCallGraph.t option
  end

  val read_only : t -> ReadOnly.t
end

(** Whole-program call graph, stored in the ocaml heap. This is a mapping from a callable to all its
    callees. *)
module WholeProgramCallGraph : sig
  type t

  val empty : t

  val is_empty : t -> bool

  val of_alist_exn : (Target.t * Target.t list) list -> t

  val add_or_exn : callable:Target.t -> callees:Target.t list -> t -> t

  val fold : t -> init:'a -> f:(target:Target.t -> callees:Target.t list -> 'a -> 'a) -> 'a

  val to_target_graph : t -> TargetGraph.t
end

type call_graphs = {
  whole_program_call_graph: WholeProgramCallGraph.t;
  define_call_graphs: DefineCallGraphSharedMemory.t;
}

(** Build the whole call graph of the program.

    The overrides must be computed first because we depend on a global shared memory graph to
    include overrides in the call graph. Without it, we'll underanalyze and have an inconsistent
    fixpoint. *)
val build_whole_program_call_graph
  :  scheduler:Scheduler.t ->
  static_analysis_configuration:Configuration.StaticAnalysis.t ->
  pyre_api:PyrePysaApi.ReadOnly.t ->
  resolve_module_path:(Reference.t -> RepositoryPath.t option) option ->
  override_graph:OverrideGraph.SharedMemory.ReadOnly.t option ->
  store_shared_memory:bool ->
  attribute_targets:Target.Set.t ->
  skip_analysis_targets:Target.Set.t ->
  definitions:Target.t list ->
  call_graphs
