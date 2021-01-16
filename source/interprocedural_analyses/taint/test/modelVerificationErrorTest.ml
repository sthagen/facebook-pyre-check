(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Pyre
open Core
open OUnit2
open Taint

let test_to_json _ =
  let assert_json ~expected error =
    assert_equal
      ~printer:Yojson.Safe.pretty_to_string
      ~cmp:Yojson.Safe.equal
      (Yojson.Safe.from_string expected)
      (Model.verification_error_to_json error)
  in
  assert_json
    ~expected:
      {|
        {
          "description": "`foo` is not part of the environment!",
          "line": 1,
          "column": 2,
          "stop_line": 3,
          "stop_column": 4,
          "path": "/a/b.pysa",
          "code": 6
        }
        |}
    {
      Model.ModelVerificationError.kind = Model.ModelVerificationError.NotInEnvironment "foo";
      location =
        {
          Ast.Location.start = { Ast.Location.line = 1; column = 2 };
          stop = { Ast.Location.line = 3; column = 4 };
        };
      path = Some (Path.create_absolute ~follow_symbolic_links:false "/a/b.pysa");
    }


let () = "model_verification_error" >::: ["to_json" >:: test_to_json] |> Test.run
