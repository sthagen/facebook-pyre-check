(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Ast
open Expression
open Statement
open Test

module ModifyingTransformer : sig
  type t = int

  include Transform.Transformer with type t := t

  val final : t -> int
end = struct
  include Transform.Identity

  type t = int

  let final count = count

  let expression _ = function
    | { Node.location; value = Expression.Integer number } ->
        { Node.location; value = Expression.Integer (number + 1) }
    | expression -> expression
end

module ShallowModifyingTransformer : sig
  type t = int

  include Transform.Transformer with type t := t
end = struct
  include Transform.Identity
  include ModifyingTransformer

  let transform_children _ _ = false
end

module ModifyingTransform = Transform.Make (ModifyingTransformer)
module ShallowModifyingTransform = Transform.Make (ShallowModifyingTransformer)

let assert_modifying_source ?(shallow = false) statements expected_statements expected_sum =
  let state, modified =
    if shallow then
      let { ShallowModifyingTransform.state; source } =
        ShallowModifyingTransform.transform 0 (Source.create statements)
      in
      state, source
    else
      let { ModifyingTransform.state; source } =
        ModifyingTransform.transform 0 (Source.create statements)
      in
      state, source
  in
  assert_source_equal (Source.create expected_statements) modified;
  assert_equal expected_sum (ModifyingTransformer.final state) ~printer:string_of_int


let test_transform _ =
  assert_modifying_source
    [+Statement.Expression (+Expression.Integer 1); +Statement.Expression (+Expression.Integer 2)]
    [+Statement.Expression (+Expression.Integer 2); +Statement.Expression (+Expression.Integer 3)]
    0;
  assert_modifying_source
    [
      +Statement.Expression
         (+Expression.WalrusOperator { target = !"a"; value = +Expression.Integer 1 });
    ]
    [
      +Statement.Expression
         (+Expression.WalrusOperator { target = !"a"; value = +Expression.Integer 2 });
    ]
    0;
  assert_modifying_source
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body =
             [
               +Statement.If
                  {
                    If.test = +Expression.Integer 2;
                    body = [+Statement.Expression (+Expression.Integer 3)];
                    orelse = [+Statement.Expression (+Expression.Integer 4)];
                  };
             ];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]
    [
      +Statement.If
         {
           If.test = +Expression.Integer 2;
           body =
             [
               +Statement.If
                  {
                    If.test = +Expression.Integer 3;
                    body = [+Statement.Expression (+Expression.Integer 4)];
                    orelse = [+Statement.Expression (+Expression.Integer 5)];
                  };
             ];
           orelse = [+Statement.Expression (+Expression.Integer 6)];
         };
    ]
    0;
  assert_modifying_source
    ~shallow:true
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body =
             [
               +Statement.If
                  {
                    If.test = +Expression.Integer 2;
                    body = [+Statement.Expression (+Expression.Integer 3)];
                    orelse = [+Statement.Expression (+Expression.Integer 4)];
                  };
             ];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body =
             [
               +Statement.If
                  {
                    If.test = +Expression.Integer 2;
                    body = [+Statement.Expression (+Expression.Integer 3)];
                    orelse = [+Statement.Expression (+Expression.Integer 4)];
                  };
             ];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]
    0


module ExpandingTransformer : sig
  type t = unit

  include Transform.Transformer with type t := t
end = struct
  include Transform.Identity

  type t = unit

  let statement state statement = state, [statement; statement]
end

module ShallowExpandingTransformer : sig
  type t = unit

  include Transform.Transformer with type t := t
end = struct
  include Transform.Identity
  include ExpandingTransformer

  let transform_children _ _ = false
end

module ExpandingTransform = Transform.Make (ExpandingTransformer)
module ShallowExpandingTransform = Transform.Make (ShallowExpandingTransformer)

let assert_expanded_source ?(shallow = false) statements expected_statements =
  let modified =
    if shallow then
      ShallowExpandingTransform.transform () (Source.create statements)
      |> ShallowExpandingTransform.source
    else
      ExpandingTransform.transform () (Source.create statements) |> ExpandingTransform.source
  in
  assert_source_equal (Source.create expected_statements) modified


let test_expansion _ =
  assert_expanded_source
    [+Statement.Expression (+Expression.Float 1.0); +Statement.Expression (+Expression.Float 2.0)]
    [
      +Statement.Expression (+Expression.Float 1.0);
      +Statement.Expression (+Expression.Float 1.0);
      +Statement.Expression (+Expression.Float 2.0);
      +Statement.Expression (+Expression.Float 2.0);
    ];
  assert_expanded_source
    ~shallow:true
    [+Statement.Expression (+Expression.Float 1.0); +Statement.Expression (+Expression.Float 2.0)]
    [
      +Statement.Expression (+Expression.Float 1.0);
      +Statement.Expression (+Expression.Float 1.0);
      +Statement.Expression (+Expression.Float 2.0);
      +Statement.Expression (+Expression.Float 2.0);
    ];
  assert_expanded_source
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body = [+Statement.Expression (+Expression.Integer 3)];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body =
             [
               +Statement.Expression (+Expression.Integer 3);
               +Statement.Expression (+Expression.Integer 3);
             ];
           orelse =
             [
               +Statement.Expression (+Expression.Integer 5);
               +Statement.Expression (+Expression.Integer 5);
             ];
         };
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body =
             [
               +Statement.Expression (+Expression.Integer 3);
               +Statement.Expression (+Expression.Integer 3);
             ];
           orelse =
             [
               +Statement.Expression (+Expression.Integer 5);
               +Statement.Expression (+Expression.Integer 5);
             ];
         };
    ];
  assert_expanded_source
    ~shallow:true
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body = [+Statement.Expression (+Expression.Integer 3)];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]
    [
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body = [+Statement.Expression (+Expression.Integer 3)];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
      +Statement.If
         {
           If.test = +Expression.Integer 1;
           body = [+Statement.Expression (+Expression.Integer 3)];
           orelse = [+Statement.Expression (+Expression.Integer 5)];
         };
    ]


let test_expansion_with_stop _ =
  let module StoppingExpandingTransformer : sig
    type t = unit

    include Transform.Transformer with type t := t
  end = struct
    include ExpandingTransformer

    let transform_children _ _ = false
  end
  in
  let module StoppingExpandingTransform = Transform.Make (StoppingExpandingTransformer) in
  let assert_expanded_source_with_stop source expected_source =
    let modified =
      StoppingExpandingTransform.transform () (parse source) |> StoppingExpandingTransform.source
    in
    assert_source_equal ~location_insensitive:true (parse expected_source) modified
  in
  assert_expanded_source_with_stop
    {|
       if (1):
         if (2):
           3
         else:
           4
       else:
         if (5):
           6
         else:
           7
    |}
    {|
       if (1):
         if (2):
           3
         else:
           4
       else:
         if (5):
           6
         else:
           7
       if (1):
         if (2):
           3
         else:
           4
       else:
         if (5):
           6
         else:
           7
    |}


let test_double_count _ =
  let module DoubleCounterTransformer : sig
    type t = int

    include Transform.Transformer with type t := t
  end = struct
    include Transform.Identity

    type t = int

    let statement count statement = count + 1, [statement]
  end
  in
  let module ShallowDoubleCounterTransformer : sig
    type t = int

    include Transform.Transformer with type t := t
  end = struct
    include Transform.Identity
    include DoubleCounterTransformer

    let transform_children _ _ = false
  end
  in
  let module DoubleCounterTransform = Transform.Make (DoubleCounterTransformer) in
  let module ShallowDoubleCounterTransform = Transform.Make (ShallowDoubleCounterTransformer) in
  let assert_double_count ?(shallow = false) source expected_sum =
    let state, modified =
      if shallow then
        let { ShallowDoubleCounterTransform.state; source } =
          ShallowDoubleCounterTransform.transform 0 (parse source)
        in
        state, source
      else
        let { DoubleCounterTransform.state; source } =
          DoubleCounterTransform.transform 0 (parse source)
        in
        state, source
    in
    (* expect no change in the source *)
    assert_source_equal (parse source) modified;
    assert_equal expected_sum (ModifyingTransformer.final state) ~printer:string_of_int
  in
  assert_double_count {|
      1.0
      2.0
    |} 2;
  assert_double_count ~shallow:true {|
      1.0
      2.0
    |} 2;
  assert_double_count {|
      if (1):
        3
      else:
        5
    |} 3;
  assert_double_count ~shallow:true {|
      if (1):
        3
      else:
        5
    |} 1;
  assert_double_count
    {|
      if (1):
        if (2):
          3
        else:
          4
      else:
        if (5):
          6
        else:
          7
    |}
    7;
  assert_double_count
    ~shallow:true
    {|
      if (1):
        if (2):
          3
        else:
          4
      else:
        if (5):
          6
        else:
          7
    |}
    1


let test_statement_transformer _ =
  let module ModifyingStatementTransformer : sig
    type t = int

    include Transform.StatementTransformer with type t := t

    val final : t -> int
  end = struct
    type t = int

    let final count = count

    let statement count { Node.location; value } =
      let count, value =
        match value with
        | Statement.Assign
            ({ Assign.value = { Node.value = Integer number; _ } as value; _ } as assign) ->
            ( count + number,
              Statement.Assign
                { assign with Assign.value = { value with Node.value = Integer (number + 1) } } )
        | _ -> count, value
      in
      count, [{ Node.location; value }]
  end
  in
  let module Transform = Transform.MakeStatementTransformer (ModifyingStatementTransformer) in
  let assert_transform source expected expected_sum =
    let { Transform.state; source = modified } = Transform.transform 0 (parse source) in
    assert_source_equal (parse expected) modified;
    assert_equal expected_sum (ModifyingStatementTransformer.final state) ~printer:string_of_int
  in
  assert_transform
    {|
      def foo():
        x = 1
        y = 2
      2
      3 + 4
      x = 3
      y = 4
      if 1 == 3:
        x = 5
      else:
        if a > b:
          y = 6
      class C:
        z = 7
    |}
    {|
      def foo():
        x = 2
        y = 3
      2
      3 + 4
      x = 4
      y = 5
      if 1 == 3:
        x = 6
      else:
        if a > b:
          y = 7
      class C:
        z = 8
    |}
    28


let () =
  "transform"
  >::: [
         "transform" >:: test_transform;
         "expansion" >:: test_expansion;
         "expansion_with_stop" >:: test_expansion_with_stop;
         "statement_double_counter" >:: test_double_count;
         "statement_transformer" >:: test_statement_transformer;
       ]
  |> Test.run
