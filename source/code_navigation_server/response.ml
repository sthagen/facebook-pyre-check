(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Base

module ErrorKind = struct
  type t =
    | InvalidRequest of string
    | ModuleNotTracked of { module_: Request.Module.t [@key "module"] }
    | OverlayNotFound of { overlay_id: string }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module HoverContent = struct
  module Kind = struct
    type t = PlainText [@@deriving sexp, compare, yojson { strict = false }]
  end

  type t = {
    kind: Kind.t;
    value: string;
  }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module DefinitionLocation = struct
  type t = {
    path: string;
    range: Ast.Location.t;
  }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module Status = struct
  type t =
    | Idle
    | BusyChecking of { overlay_id: string option }
    | Stop of { message: string }
  [@@deriving sexp, compare, yojson { strict = false }]
end

type t =
  | Ok
  | Error of ErrorKind.t
  | TypeErrors of Analysis.AnalysisError.Instantiated.t list
  | Hover of { contents: HoverContent.t list }
  | LocationOfDefinition of DefinitionLocation.t list
  | ServerStatus of Status.t
[@@deriving sexp, compare, yojson { strict = false }]

let to_string response = to_yojson response |> Yojson.Safe.to_string