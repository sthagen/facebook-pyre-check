(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Pyre
open Statement
open Expression
module Error = AnalysisError

let name = "UninitializedLocal"

let identifiers { Node.value; location } =
  match value with
  | Expression.Name (Name.Identifier identifier) -> [{ Node.value = identifier; location }]
  | _ -> []


let extract_reads statement =
  match statement with
  | Statement.Assign { value = expression; _ } -> identifiers expression
  | Return { expression = Some expression; _ } -> identifiers expression
  | _ -> []


let extract_writes statement =
  ( match statement with
  | Statement.Assign { target = expression; _ } -> identifiers expression
  | _ -> [] )
  |> List.map ~f:Node.value


module InitializedVariables = Identifier.Set

module type Context = sig
  val uninitialized_usage : Identifier.t Node.t list Int.Table.t
end

module State (Context : Context) = struct
  type t = InitializedVariables.t

  let show state =
    InitializedVariables.elements state |> String.concat ~sep:", " |> Format.sprintf "[%s]"


  let pp format state = Format.fprintf format "%s" (show state)

  let initial ~define:{ Node.value = { Define.signature; _ }; _ } =
    signature.parameters |> List.map ~f:Parameter.name |> InitializedVariables.of_list


  let errors ~qualifier ~define _ =
    let emit_error { Node.value; location } =
      Error.create
        ~location:(Location.with_module ~qualifier location)
        ~kind:(Error.UnboundName value)
        ~define
    in
    Int.Table.data Context.uninitialized_usage |> List.concat |> List.map ~f:emit_error


  let less_or_equal ~left ~right = InitializedVariables.is_subset right ~of_:left

  let join left right = InitializedVariables.inter left right

  let widen ~previous ~next ~iteration:_ = join previous next

  let forward ~key state ~statement:{ Node.value; _ } =
    let is_uninitialized { Node.value = identifier; _ } =
      not (InitializedVariables.mem state identifier)
    in
    let uninitialized_usage = extract_reads value |> List.filter ~f:is_uninitialized in
    Hashtbl.set Context.uninitialized_usage ~key ~data:uninitialized_usage;
    extract_writes value |> InitializedVariables.of_list |> InitializedVariables.union state


  let backward ~key:_ _ ~statement:_ = failwith "Not implemented"
end

let run
    ~configuration:_
    ~environment:_
    ~source:({ Source.source_path = { SourcePath.qualifier; _ }; _ } as source)
  =
  let check define =
    let module Context = struct
      let uninitialized_usage = Int.Table.create ()
    end
    in
    let module State = State (Context) in
    let module Fixpoint = Fixpoint.Make (State) in
    let cfg = Cfg.create (Node.value define) in
    let fixpoint = Fixpoint.forward ~cfg ~initial:(State.initial ~define) in
    Fixpoint.exit fixpoint >>| State.errors ~qualifier ~define |> Option.value ~default:[]
  in
  source |> Preprocessing.defines ~include_toplevels:true |> List.map ~f:check |> List.concat
