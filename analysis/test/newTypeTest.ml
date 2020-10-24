(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Test

let test_transform_ast _ =
  let assert_expand ?(handle = "qualifier.py") source expected =
    let parse = parse ~handle in
    assert_source_equal
      ~location_insensitive:true
      (parse expected)
      (Preprocessing.expand_new_types (parse source))
  in
  assert_expand
    {|
      T = typing.NewType('T', int)
    |}
    {|
      class qualifier.T(int):
        def qualifier.T.__init__(self, input: int) -> None:
          pass
    |};
  assert_expand
    {|
      T = typing.NewType('T', typing.List[int])
    |}
    {|
      class qualifier.T(typing.List[int]):
        def qualifier.T.__init__(self, input: typing.List[int]) -> None:
          pass
    |};
  assert_expand
    {|
      T = typing.NewType('T', typing.Dict[str, typing.List[int]])
    |}
    {|
      class qualifier.T(typing.Dict[str, typing.List[int]]):
        def qualifier.T.__init__(self, input: typing.Dict[str, typing.List[int]]) -> None:
          pass
    |};

  (* Don't transform non-toplevel statements. *)
  assert_expand
    {|
      def foo():
        T = typing.NewType('T', int)
    |}
    {|
      def foo():
        T = typing.NewType('T', int)
    |}


let () = "plugin_new_type" >::: ["transform_ast" >:: test_transform_ast] |> Test.run
