(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
(* TODO(T170743593) new warning with ppx_conv_sexp.v0.16.X *)
[@@@warning "-name-out-of-scope"]

(* TODO(T132410158) Add a module-level doc comment. *)

type t = ArtifactPath of PyrePath.t [@@deriving sexp, compare, hash, show]

let create raw = ArtifactPath raw

let raw (ArtifactPath raw) = raw

module Event = struct
  module Kind = struct
    type t =
      | CreatedOrChanged
      | Deleted
    [@@deriving sexp, compare]
  end

  type source_path = t [@@deriving sexp, compare]

  type t = {
    kind: Kind.t;
    path: source_path;
  }
  [@@deriving sexp, compare]

  let create ~kind path = { kind; path }
end
