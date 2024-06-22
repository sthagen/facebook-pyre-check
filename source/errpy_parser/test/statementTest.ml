(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Test
open Ast
open Ast.Expression
open Ast.Statement

let statements_location_insensitive_equal left right =
  List.compare Statement.location_insensitive_compare left right |> Int.equal 0


let statements_print_to_sexp statements =
  Base.Sexp.to_string_hum ((Base.List.sexp_of_t Statement.sexp_of_t) statements)


let assert_parsed ~expected text _context =
  let check_ast (actual_ast : Ast.Statement.t list) =
    assert_equal
      ~cmp:statements_location_insensitive_equal
      ~printer:statements_print_to_sexp
      expected
      actual_ast
  in
  match PyreErrpyParser.parse_module text with
  | Result.Error error -> (
      match error with
      | PyreErrpyParser.ParserError.Recoverable recoverable -> check_ast recoverable.recovered_ast
      | PyreErrpyParser.ParserError.Unrecoverable message ->
          let message = Stdlib.Format.sprintf "Unexpected parsing failure: %s" message in
          assert_failure message)
  | Result.Ok actual_ast -> check_ast actual_ast


let assert_not_parsed text _context =
  match PyreErrpyParser.parse_module text with
  | Result.Ok _ ->
      let message = Stdlib.Format.asprintf "Unexpected parsing success of input: %s" text in
      assert_failure message
  | Result.Error error -> (
      match error with
      | PyreErrpyParser.ParserError.Recoverable _ -> ()
      | PyreErrpyParser.ParserError.Unrecoverable message ->
          let message = Stdlib.Format.sprintf "Unexpected errpy stacktrace thrown: %s" message in
          assert_failure message)


let test_pass_break_continue =
  let assert_parsed = assert_parsed in
  (*TODO (T148669698): let assert_not_parsed = assert_not_parsed in*)
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "pass" ~expected:[+Statement.Pass];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "break" ~expected:[+Statement.Break];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "continue" ~expected:[+Statement.Continue];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "pass\npass" ~expected:[+Statement.Pass; +Statement.Pass];
      (*TODO (T148669698): assert_not_parsed "pass\n pass";*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "break\ncontinue\npass\n"
           ~expected:[+Statement.Break; +Statement.Continue; +Statement.Pass];
    ]


let test_global_nonlocal =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "global a" ~expected:[+Statement.Global ["a"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "global a, b" ~expected:[+Statement.Global ["a"; "b"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "nonlocal a" ~expected:[+Statement.Nonlocal ["a"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "nonlocal a, b" ~expected:[+Statement.Nonlocal ["a"; "b"]];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "global";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "nonlocal";
    ]


let test_expression_return_raise =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "a" ~expected:[+Statement.Expression !"a"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a is b"
           ~expected:
             [
               +Statement.Expression
                  (+Expression.ComparisonOperator
                      {
                        ComparisonOperator.left = !"a";
                        operator = ComparisonOperator.Is;
                        right = !"b";
                      });
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x)"
           ~expected:
             [
               +Statement.Expression
                  (+Expression.Call
                      {
                        Call.callee = !"foo";
                        arguments = [{ Call.Argument.name = None; value = !"x" }];
                      });
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "return"
           ~expected:[+Statement.Return { Return.expression = None; is_implicit = false }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "return a"
           ~expected:[+Statement.Return { Return.expression = Some !"a"; is_implicit = false }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "raise" ~expected:[+Statement.Raise { Raise.expression = None; from = None }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "raise a"
           ~expected:[+Statement.Raise { Raise.expression = Some !"a"; from = None }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "raise a from b"
           ~expected:[+Statement.Raise { Raise.expression = Some !"a"; from = Some !"b" }];
    ]


let test_assert_delete =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "assert a"
           ~expected:
             [
               +Statement.Assert
                  { Assert.test = !"a"; message = None; origin = Assert.Origin.Assertion };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "assert a, b"
           ~expected:
             [
               +Statement.Assert
                  { Assert.test = !"a"; message = Some !"b"; origin = Assert.Origin.Assertion };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "assert (a, b)"
           ~expected:
             [
               +Statement.Assert
                  {
                    Assert.test = +Expression.Tuple [!"a"; !"b"];
                    message = None;
                    origin = Assert.Origin.Assertion;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "assert a is not None, 'b or c'"
           ~expected:
             [
               +Statement.Assert
                  {
                    Assert.test =
                      +Expression.ComparisonOperator
                         {
                           ComparisonOperator.left = !"a";
                           operator = ComparisonOperator.IsNot;
                           right = +Expression.Constant Constant.NoneLiteral;
                         };
                    message =
                      Some (+Expression.Constant (Constant.String (StringLiteral.create "b or c")));
                    origin = Assert.Origin.Assertion;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "del ()" ~expected:[+Statement.Delete [+Expression.Tuple []]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "del a" ~expected:[+Statement.Delete [!"a"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "del (a)" ~expected:[+Statement.Delete [!"a"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "del a, b" ~expected:[+Statement.Delete [!"a"; !"b"]];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "del (a, b)" ~expected:[+Statement.Delete [+Expression.Tuple [!"a"; !"b"]]];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "assert";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "del";
    ]


let test_import =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "import a"
           ~expected:
             [
               +Statement.Import
                  { Import.from = None; imports = [+{ Import.name = !&"a"; alias = None }] };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "import a.b"
           ~expected:
             [
               +Statement.Import
                  { Import.from = None; imports = [+{ Import.name = !&"a.b"; alias = None }] };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "import a as b"
           ~expected:
             [
               +Statement.Import
                  { Import.from = None; imports = [+{ Import.name = !&"a"; alias = Some "b" }] };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "import a as b, c, d as e"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = None;
                    imports =
                      [
                        +{ Import.name = !&"a"; alias = Some "b" };
                        +{ Import.name = !&"c"; alias = None };
                        +{ Import.name = !&"d"; alias = Some "e" };
                      ];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from a import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"a");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from a import *"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"a");
                    imports = [+{ Import.name = !&"*"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from . import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&".");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from ...foo import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"...foo");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from .....foo import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&".....foo");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from .a import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&".a");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from ..a import b"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"..a");
                    imports = [+{ Import.name = !&"b"; alias = None }];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from a import (b, c)"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"a");
                    imports =
                      [
                        +{ Import.name = !&"b"; alias = None };
                        +{ Import.name = !&"c"; alias = None };
                      ];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from a.b import c"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"a.b");
                    imports = [+{ Import.name = !&"c"; alias = None }];
                  };
             ];
      (*FIXME (T148694587): For tests of the form: `from ... import ...` test for actual locations,
        don't just use create_with_default_location *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "from f import a as b, c, d as e"
           ~expected:
             [
               +Statement.Import
                  {
                    Import.from = Some (Node.create_with_default_location !&"f");
                    imports =
                      [
                        +{ Import.name = !&"a"; alias = Some "b" };
                        +{ Import.name = !&"c"; alias = None };
                        +{ Import.name = !&"d"; alias = Some "e" };
                      ];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "import";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "import .";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "import a.async";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "from import foo";
    ]


let test_for_while_if =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a in b: c\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = !"a";
                    iterator = !"b";
                    body = [+Statement.Expression !"c"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a in b:\n  c\n  d"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = !"a";
                    iterator = !"b";
                    body = [+Statement.Expression !"c"; +Statement.Expression !"d"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a, b in c: d\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = +Expression.Tuple [!"a"; !"b"];
                    iterator = !"c";
                    body = [+Statement.Expression !"d"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for (a, b) in c: d\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = +Expression.Tuple [!"a"; !"b"];
                    iterator = !"c";
                    body = [+Statement.Expression !"d"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for [a, b] in c: d\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = +Expression.List [!"a"; !"b"];
                    iterator = !"c";
                    body = [+Statement.Expression !"d"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a.b in c: d\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target =
                      +Expression.Name
                         (Name.Attribute
                            { Name.Attribute.base = !"a"; attribute = "b"; special = false });
                    iterator = !"c";
                    body = [+Statement.Expression !"d"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "async for a in b: c\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = !"a";
                    iterator = !"b";
                    body = [+Statement.Expression !"c"];
                    orelse = [];
                    async = true;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a in b:\n\tc\n"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = !"a";
                    iterator = !"b";
                    body = [+Statement.Expression !"c"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a in b:\n\tc\nelse:\n\td\n\te"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = !"a";
                    iterator = !"b";
                    body = [+Statement.Expression !"c"];
                    orelse = [+Statement.Expression !"d"; +Statement.Expression !"e"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "for a, *b in c: \n\ta"
           ~expected:
             [
               +Statement.For
                  {
                    For.target = +Expression.Tuple [!"a"; +Expression.Starred (Starred.Once !"b")];
                    iterator = !"c";
                    body = [+Statement.Expression !"a"];
                    orelse = [];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "while a: b\n"
           ~expected:
             [
               +Statement.While
                  { While.test = !"a"; body = [+Statement.Expression !"b"]; orelse = [] };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "while a:\n  b\n  c\n"
           ~expected:
             [
               +Statement.While
                  {
                    While.test = !"a";
                    body = [+Statement.Expression !"b"; +Statement.Expression !"c"];
                    orelse = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "while a:\n\tb\nelse:\n\tc\n\td\n"
           ~expected:
             [
               +Statement.While
                  {
                    While.test = !"a";
                    body = [+Statement.Expression !"b"];
                    orelse = [+Statement.Expression !"c"; +Statement.Expression !"d"];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a: b\n"
           ~expected:
             [+Statement.If { If.test = !"a"; body = [+Statement.Expression !"b"]; orelse = [] }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a:\n  b\n  c\n"
           ~expected:
             [
               +Statement.If
                  {
                    If.test = !"a";
                    body = [+Statement.Expression !"b"; +Statement.Expression !"c"];
                    orelse = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a: b\nelif c: d"
           ~expected:
             [
               +Statement.If
                  {
                    If.test = !"a";
                    body = [+Statement.Expression !"b"];
                    orelse =
                      [
                        +Statement.If
                           { If.test = !"c"; body = [+Statement.Expression !"d"]; orelse = [] };
                      ];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a:\n\n\tb\n"
           ~expected:
             [+Statement.If { If.test = !"a"; body = [+Statement.Expression !"b"]; orelse = [] }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a:\n\tb\n\n\tc"
           ~expected:
             [
               +Statement.If
                  {
                    If.test = !"a";
                    body = [+Statement.Expression !"b"; +Statement.Expression !"c"];
                    orelse = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "if a:\n\tb\nelse:\n\tc\n\td\n"
           ~expected:
             [
               +Statement.If
                  {
                    If.test = !"a";
                    body = [+Statement.Expression !"b"];
                    orelse = [+Statement.Expression !"c"; +Statement.Expression !"d"];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "for";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "for a in b";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "while a";
      (*TODO (T148669698): assert_not_parsed "while a:";*)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "if a";
      (*TODO (T148669698): assert_not_parsed "if a:";*)
    ]


let test_try =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nfinally:\n\tb"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers = [];
                    orelse = [];
                    finally = [+Statement.Expression !"b"];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept:\n\tb"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        { Try.Handler.kind = None; name = None; body = [+Statement.Expression !"b"] };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept a:\n\tb"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind = Some !"a";
                          name = None;
                          body = [+Statement.Expression !"b"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept a as b:\n\tb"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind = Some !"a";
                          name = Some (+"b");
                          body = [+Statement.Expression !"b"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept a or b:\n\tc"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind =
                            Some
                              (+Expression.BooleanOperator
                                  {
                                    BooleanOperator.left = !"a";
                                    operator = BooleanOperator.Or;
                                    right = !"b";
                                  });
                          name = None;
                          body = [+Statement.Expression !"c"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept a or b as e:\n\tc"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind =
                            Some
                              (+Expression.BooleanOperator
                                  {
                                    BooleanOperator.left = !"a";
                                    operator = BooleanOperator.Or;
                                    right = !"b";
                                  });
                          name = Some (+"e");
                          body = [+Statement.Expression !"c"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept (a, b) as c:\n\tb"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind = Some (+Expression.Tuple [!"a"; !"b"]);
                          name = Some (+"c");
                          body = [+Statement.Expression !"b"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept a as b:\n\tb\nexcept d:\n\te"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        {
                          Try.Handler.kind = Some !"a";
                          name = Some (+"b");
                          body = [+Statement.Expression !"b"];
                        };
                        {
                          Try.Handler.kind = Some !"d";
                          name = None;
                          body = [+Statement.Expression !"e"];
                        };
                      ];
                    orelse = [];
                    finally = [];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\nexcept:\n\tb\nelse:\n\tc\nfinally:\n\td"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"];
                    handlers =
                      [
                        { Try.Handler.kind = None; name = None; body = [+Statement.Expression !"b"] };
                      ];
                    orelse = [+Statement.Expression !"c"];
                    finally = [+Statement.Expression !"d"];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "try:\n\ta\n\tb\nexcept:\n\tc\n\td\nelse:\n\te\n\tf\nfinally:\n\tg\n\th"
           ~expected:
             [
               +Statement.Try
                  {
                    Try.body = [+Statement.Expression !"a"; +Statement.Expression !"b"];
                    handlers =
                      [
                        {
                          Try.Handler.kind = None;
                          name = None;
                          body = [+Statement.Expression !"c"; +Statement.Expression !"d"];
                        };
                      ];
                    orelse = [+Statement.Expression !"e"; +Statement.Expression !"f"];
                    finally = [+Statement.Expression !"g"; +Statement.Expression !"h"];
                    handles_exception_group = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "try: a";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "try:\n\ta\nelse:\n\tb";
      (*TODO (T148669698): assert_not_parsed "try:\n\ta\nexcept a, b:\n\tb";*)
    ]


let test_with =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with a: b\n"
           ~expected:
             [
               +Statement.With
                  { With.items = [!"a", None]; body = [+Statement.Expression !"b"]; async = false };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with a:\n  b\n  c"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", None];
                    body = [+Statement.Expression !"b"; +Statement.Expression !"c"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with (yield from a): b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [+Expression.YieldFrom !"a", None];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "async with a: b\n"
           ~expected:
             [
               +Statement.With
                  { With.items = [!"a", None]; body = [+Statement.Expression !"b"]; async = true };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with a as b: b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", Some !"b"];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with a as b, c as d: b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", Some !"b"; !"c", Some !"d"];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with a, c as d: b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", None; !"c", Some !"d"];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with (a as b, c as d,): b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", Some !"b"; !"c", Some !"d"];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "with (\n  a as b,\n  c as d\n):\n  b\n"
           ~expected:
             [
               +Statement.With
                  {
                    With.items = [!"a", Some !"b"; !"c", Some !"d"];
                    body = [+Statement.Expression !"b"];
                    async = false;
                  };
             ];
    ]


let test_assign =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a = b"
           ~expected:
             [+Statement.Assign { Assign.target = !"a"; annotation = None; value = Some !"b" }];
      (*TODO (T148669698): assert_parsed "a = b # type: int" ~expected: [ +Statement.Assign {
        Assign.target = !"a"; annotation = Some (+Expression.Constant (Constant.String
        (StringLiteral.create "int"))); value = !"b"; }; ];*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a = b or c"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = !"a";
                    annotation = None;
                    value =
                      Some
                        (+Expression.BooleanOperator
                            {
                              BooleanOperator.left = !"b";
                              operator = BooleanOperator.Or;
                              right = !"c";
                            });
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a: int"
           ~expected:
             [+Statement.Assign { Assign.target = !"a"; annotation = Some !"int"; value = None }];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a: int = 1"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = !"a";
                    annotation = Some !"int";
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.b = 1"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target =
                      +Expression.Name
                         (Name.Attribute
                            { Name.Attribute.base = !"a"; attribute = "b"; special = false });
                    annotation = None;
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.b: int = 1"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target =
                      +Expression.Name
                         (Name.Attribute
                            { Name.Attribute.base = !"a"; attribute = "b"; special = false });
                    annotation = Some !"int";
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
             ];
      (*TODO (T148669698): assert_parsed "a.b = 1 # type: int" ~expected: [ +Statement.Assign {
        Assign.target = +Expression.Name (Name.Attribute { Name.Attribute.base = !"a"; attribute =
        "b"; special = false }); annotation = Some (+Expression.Constant (Constant.String
        (StringLiteral.create "int"))); value = +Expression.Constant (Constant.Integer 1); }; ];*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a, b = 1"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = +Expression.Tuple [!"a"; !"b"];
                    annotation = None;
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a = a().foo()"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = !"a";
                    annotation = None;
                    value =
                      Some
                        (+Expression.Call
                            {
                              Call.callee =
                                +Expression.Name
                                   (Name.Attribute
                                      {
                                        Name.Attribute.base =
                                          +Expression.Call { Call.callee = !"a"; arguments = [] };
                                        attribute = "foo";
                                        special = false;
                                      });
                              arguments = [];
                            });
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a = b = 1"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = !"a";
                    annotation = None;
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
               +Statement.Assign
                  {
                    Assign.target = !"b";
                    annotation = None;
                    value = Some (+Expression.Constant (Constant.Integer 1));
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a += 1"
           ~expected:
             [
               +Statement.AugmentedAssign
                  {
                    AugmentedAssign.target = !"a";
                    operator = BinaryOperator.Add;
                    value = +Expression.Constant (Constant.Integer 1);
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.b += 1"
           ~expected:
             [
               +Statement.AugmentedAssign
                  {
                    AugmentedAssign.target =
                      +Expression.Name
                         (Name.Attribute
                            { Name.Attribute.base = !"a"; attribute = "b"; special = false });
                    operator = BinaryOperator.Add;
                    value = +Expression.Constant (Constant.Integer 1);
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "i[j] = 3"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = +Expression.Subscript { Subscript.base = !"i"; index = !"j" };
                    value = Some (+Expression.Constant (Constant.Integer 3));
                    annotation = None;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "i[j]: int = 3"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target = +Expression.Subscript { Subscript.base = !"i"; index = !"j" };
                    value = Some (+Expression.Constant (Constant.Integer 3));
                    annotation = Some !"int";
                  };
             ];
      (*TODO (T148669698): assert_parsed "i[j] = 3 # type: int" ~expected: [ +Statement.Expression
        (+Expression.Call { Call.callee = +Expression.Name (Name.Attribute { Name.Attribute.base =
        !"i"; attribute = "__setitem__"; special = true }); arguments = [ { Call.Argument.name =
        None; value = !"j" }; { Call.Argument.name = None; value = +Expression.Constant
        (Constant.Integer 3); }; ]; }); ];*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "i[j] += 3"
           ~expected:
             [
               +Statement.AugmentedAssign
                  {
                    AugmentedAssign.target =
                      +Expression.Subscript { Subscript.base = !"i"; index = !"j" };
                    operator = BinaryOperator.Add;
                    value = +Expression.Constant (Constant.Integer 3);
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "i[j][7] = 8"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target =
                      +Expression.Subscript
                         {
                           Subscript.base =
                             +Expression.Subscript { Subscript.base = !"i"; index = !"j" };
                           index = +Expression.Constant (Constant.Integer 7);
                         };
                    value = Some (+Expression.Constant (Constant.Integer 8));
                    annotation = None;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "i[j::1] = i[:j]"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target =
                      +Expression.Subscript
                         {
                           Subscript.base = !"i";
                           index =
                             +Expression.Slice
                                {
                                  Slice.start = Some !"j";
                                  stop = None;
                                  step = Some (+Expression.Constant (Constant.Integer 1));
                                };
                         };
                    value =
                      Some
                        (+Expression.Subscript
                            {
                              Subscript.base = !"i";
                              index =
                                +Expression.Slice
                                   { Slice.start = None; stop = Some !"j"; step = None };
                            });
                    annotation = None;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x = i[j] = y"
           ~expected:
             [
               +Statement.Assign { Assign.target = !"x"; annotation = None; value = Some !"y" };
               +Statement.Assign
                  {
                    Assign.target = +Expression.Subscript { Subscript.base = !"i"; index = !"j" };
                    value = Some !"y";
                    annotation = None;
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x, i[j] = y"
           ~expected:
             [
               +Statement.Assign
                  {
                    Assign.target =
                      +Expression.Tuple
                         [!"x"; +Expression.Subscript { Subscript.base = !"i"; index = !"j" }];
                    annotation = None;
                    value = Some !"y";
                  };
             ];
    ]


let test_define =
  let assert_parsed = assert_parsed in
  (*let assert_not_parsed = assert_not_parsed in*)
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(*, a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "*"; value = None; annotation = None };
                            +{ Parameter.name = "a"; value = None; annotation = None };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a, /, b):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "a"; value = None; annotation = None };
                            +{ Parameter.name = "/"; value = None; annotation = None };
                            +{ Parameter.name = "b"; value = None; annotation = None };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(**a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "**a"; value = None; annotation = None }];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a, b,) -> c:\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "a"; value = None; annotation = None };
                            +{ Parameter.name = "b"; value = None; annotation = None };
                          ];
                        decorators = [];
                        return_annotation = Some !"c";
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "async def foo():\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [];
                        return_annotation = None;
                        async = true;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "async def foo():\n  ..."
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [];
                        return_annotation = None;
                        async = true;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant Constant.Ellipsis)];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@foo\nasync def foo():\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [!"foo"];
                        return_annotation = None;
                        async = true;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@decorator\ndef foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators = [!"decorator"];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@decorator(a=b, c=d)\ndef foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators =
                          [
                            +Expression.Call
                               {
                                 Call.callee = !"decorator";
                                 arguments =
                                   [
                                     { Call.Argument.name = Some ~+"a"; value = !"b" };
                                     { Call.Argument.name = Some ~+"c"; value = !"d" };
                                   ];
                               };
                          ];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@foo\n\n@bar\ndef foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators = [!"foo"; !"bar"];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@x[0].y\ndef foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators =
                          [
                            +Expression.Name
                               (Name.Attribute
                                  {
                                    Name.Attribute.base =
                                      +Expression.Subscript
                                         {
                                           Subscript.base = !"x";
                                           index = +Expression.Constant (Constant.Integer 0);
                                         };
                                    attribute = "y";
                                    special = false;
                                  });
                          ];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@(x<y)\ndef foo(a):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [+{ Parameter.name = "a"; value = None; annotation = None }];
                        decorators =
                          [
                            +Expression.ComparisonOperator
                               {
                                 ComparisonOperator.left = !"x";
                                 operator = ComparisonOperator.LessThan;
                                 right = !"y";
                               };
                          ];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a, b):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "a"; value = None; annotation = None };
                            +{ Parameter.name = "b"; value = None; annotation = None };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a, b = 1):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "a"; value = None; annotation = None };
                            +{
                               Parameter.name = "b";
                               value = Some (+Expression.Constant (Constant.Integer 1));
                               annotation = None;
                             };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a=()):\n  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{
                               Parameter.name = "a";
                               value = Some (+Expression.Tuple []);
                               annotation = None;
                             };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(): 1; 2"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body =
                      [
                        +Statement.Expression (+Expression.Constant (Constant.Integer 1));
                        +Statement.Expression (+Expression.Constant (Constant.Integer 2));
                      ];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo():\n  1\n  2\n3"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body =
                      [
                        +Statement.Expression (+Expression.Constant (Constant.Integer 1));
                        +Statement.Expression (+Expression.Constant (Constant.Integer 2));
                      ];
                  };
               +Statement.Expression (+Expression.Constant (Constant.Integer 3));
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo():\n  def bar():\n    1\n    2\n3"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters = [];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body =
                      [
                        +Statement.Define
                           {
                             Define.signature =
                               {
                                 Define.Signature.name = !&"bar";
                                 parameters = [];
                                 decorators = [];
                                 return_annotation = None;
                                 async = false;
                                 generator = false;
                                 parent = None;
                                 nesting_define = None;
                               };
                             captures = [];
                             unbound_names = [];
                             body =
                               [
                                 +Statement.Expression (+Expression.Constant (Constant.Integer 1));
                                 +Statement.Expression (+Expression.Constant (Constant.Integer 2));
                               ];
                           };
                      ];
                  };
               +Statement.Expression (+Expression.Constant (Constant.Integer 3));
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a: int):  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [+{ Parameter.name = "a"; value = None; annotation = Some !"int" }];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a: int = 1):  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{
                               Parameter.name = "a";
                               value = Some (+Expression.Constant (Constant.Integer 1));
                               annotation = Some !"int";
                             };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "def foo(a: int, b: str):  1"
           ~expected:
             [
               +Statement.Define
                  {
                    Define.signature =
                      {
                        Define.Signature.name = !&"foo";
                        parameters =
                          [
                            +{ Parameter.name = "a"; value = None; annotation = Some !"int" };
                            +{ Parameter.name = "b"; value = None; annotation = Some !"str" };
                          ];
                        decorators = [];
                        return_annotation = None;
                        async = false;
                        generator = false;
                        parent = None;
                        nesting_define = None;
                      };
                    captures = [];
                    unbound_names = [];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                  };
             ];
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(): # type: () -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = []; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = None; nesting_define = None; }; captures = []; unbound_names =
        []; body = [ +Statement.Return { Return.expression = Some (+Expression.Constant
        (Constant.Integer 4)); is_implicit = false; }; ]; }; ]; *)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(): # type: () -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = []; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = None; nesting_define = None; }; captures = []; unbound_names =
        []; body = [ +Statement.Return { Return.expression = Some (+Expression.Constant
        (Constant.Integer 4)); is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(a): # type: (str) -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = [+{ Parameter.name = "a"; value = None; annotation = Some !"str" }];
        decorators = []; return_annotation = Some !"str"; async = false; generator = false; parent =
        None; nesting_define = None; }; captures = []; unbound_names = []; body = [
        +Statement.Return { Return.expression = Some (+Expression.Constant (Constant.Integer 4));
        is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| class A: def foo(self, a): #
        type: (str) -> str return 4 |}) ~expected: [ +Statement.Class { Define.Signature.name =
        !&"A"; base_arguments = []; decorators = []; top_level_unbound_names = []; body = [
        +Statement.Define { Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name =
        "self"; value = None; annotation = None }; +{ Parameter.name = "a"; value = None; annotation
        = Some !"str" }; ]; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = Some !&"A"; nesting_define = None; }; captures = [];
        unbound_names = []; body = [ +Statement.Return { Return.expression = Some
        (+Expression.Constant (Constant.Integer 4)); is_implicit = false; }; ]; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| class A: def foo(self, a): #
        type: (A, str) -> str return 4 |}) ~expected: [ +Statement.Class { Define.Signature.name =
        !&"A"; base_arguments = []; decorators = []; top_level_unbound_names = []; body = [
        +Statement.Define { Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name =
        "self"; value = None; annotation = Some !"A" }; +{ Parameter.name = "a"; value = None;
        annotation = Some !"str" }; ]; decorators = []; return_annotation = Some !"str"; async =
        false; generator = false; parent = Some !&"A"; nesting_define = None; }; captures = [];
        unbound_names = []; body = [ +Statement.Return { Return.expression = Some
        (+Expression.Constant (Constant.Integer 4)); is_implicit = false; }; ]; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo( a, # type: bool b #
        type: bool ): pass |}) ~expected: [ +Statement.Define { Define.signature = {
        Define.Signature.name = !&"foo"; parameters = [ +{ Parameter.name = "a"; value = None;
        annotation = Some (+Expression.Constant (Constant.String (StringLiteral.create "bool"))); };
        +{ Parameter.name = "b"; value = None; annotation = Some (+Expression.Constant
        (Constant.String (StringLiteral.create "bool"))); }; ]; decorators = []; return_annotation =
        None; async = false; generator = false; parent = None; nesting_define = None; }; captures =
        []; unbound_names = []; body = [+Statement.Pass]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| async def foo( a, # type: bool b
        # type: bool ): # type: (...) -> int pass |}) ~expected: [ +Statement.Define {
        Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name = "a"; value = None;
        annotation = Some (+Expression.Constant (Constant.String (StringLiteral.create "bool"))); };
        +{ Parameter.name = "b"; value = None; annotation = Some (+Expression.Constant
        (Constant.String (StringLiteral.create "bool"))); }; ]; decorators = []; return_annotation =
        Some !"int"; async = true; generator = false; parent = None; nesting_define = None; };
        captures = []; unbound_names = []; body = [+Statement.Pass]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo( *args, **kwargs): #
        type: ( *str, **str) -> str return 4 |}) ~expected: [ +Statement.Define { Define.signature =
        { Define.Signature.name = !&"foo"; parameters = [ +{ Parameter.name = "*args"; value = None;
        annotation = Some !"str" }; +{ Parameter.name = "**kwargs"; value = None; annotation = Some
        !"str" }; ]; decorators = []; return_annotation = Some !"str"; async = false; generator =
        false; parent = None; nesting_define = None; }; captures = []; unbound_names = []; body = [
        +Statement.Return { Return.expression = Some (+Expression.Constant (Constant.Integer 4));
        is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(): # type: () -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = []; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = None; nesting_define = None; }; captures = []; unbound_names =
        []; body = [ +Statement.Return { Return.expression = Some (+Expression.Constant
        (Constant.Integer 4)); is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(): # type: () -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = []; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = None; nesting_define = None; }; captures = []; unbound_names =
        []; body = [ +Statement.Return { Return.expression = Some (+Expression.Constant
        (Constant.Integer 4)); is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo(a): # type: (str) -> str
        return 4 |}) ~expected: [ +Statement.Define { Define.signature = { Define.Signature.name =
        !&"foo"; parameters = [+{ Parameter.name = "a"; value = None; annotation = Some !"str" }];
        decorators = []; return_annotation = Some !"str"; async = false; generator = false; parent =
        None; nesting_define = None; }; captures = []; unbound_names = []; body = [
        +Statement.Return { Return.expression = Some (+Expression.Constant (Constant.Integer 4));
        is_implicit = false; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| class A: def foo(self, a): #
        type: (str) -> str return 4 |}) ~expected: [ +Statement.Class { Define.Signature.name =
        !&"A"; base_arguments = []; decorators = []; top_level_unbound_names = []; body = [
        +Statement.Define { Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name =
        "self"; value = None; annotation = None }; +{ Parameter.name = "a"; value = None; annotation
        = Some !"str" }; ]; decorators = []; return_annotation = Some !"str"; async = false;
        generator = false; parent = Some !&"A"; nesting_define = None; }; captures = [];
        unbound_names = []; body = [ +Statement.Return { Return.expression = Some
        (+Expression.Constant (Constant.Integer 4)); is_implicit = false; }; ]; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| class A: def foo(self, a): #
        type: (A, str) -> str return 4 |}) ~expected: [ +Statement.Class { Define.Signature.name =
        !&"A"; base_arguments = []; decorators = []; top_level_unbound_names = []; body = [
        +Statement.Define { Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name =
        "self"; value = None; annotation = Some !"A" }; +{ Parameter.name = "a"; value = None;
        annotation = Some !"str" }; ]; decorators = []; return_annotation = Some !"str"; async =
        false; generator = false; parent = Some !&"A"; nesting_define = None; }; captures = [];
        unbound_names = []; body = [ +Statement.Return { Return.expression = Some
        (+Expression.Constant (Constant.Integer 4)); is_implicit = false; }; ]; }; ]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo( a, # type: bool b #
        type: bool ): pass |}) ~expected: [ +Statement.Define { Define.signature = {
        Define.Signature.name = !&"foo"; parameters = [ +{ Parameter.name = "a"; value = None;
        annotation = Some (+Expression.Constant (Constant.String (StringLiteral.create "bool"))); };
        +{ Parameter.name = "b"; value = None; annotation = Some (+Expression.Constant
        (Constant.String (StringLiteral.create "bool"))); }; ]; decorators = []; return_annotation =
        None; async = false; generator = false; parent = None; nesting_define = None; }; captures =
        []; unbound_names = []; body = [+Statement.Pass]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| async def foo( a, # type: bool b
        # type: bool ): # type: (...) -> int pass |}) ~expected: [ +Statement.Define {
        Define.signature = { name = !&"foo"; parameters = [ +{ Parameter.name = "a"; value = None;
        annotation = Some (+Expression.Constant (Constant.String (StringLiteral.create "bool"))); };
        +{ Parameter.name = "b"; value = None; annotation = Some (+Expression.Constant
        (Constant.String (StringLiteral.create "bool"))); }; ]; decorators = []; return_annotation =
        Some !"int"; async = true; generator = false; parent = None; nesting_define = None; };
        captures = []; unbound_names = []; body = [+Statement.Pass]; }; ];*)
      (*TODO (T148669698): assert_parsed (trim_extra_indentation {| def foo( *args, **kwargs): #
        type: ( *str, **str) -> str return 4 |}) ~expected: [ +Statement.Define { Define.signature =
        { Define.Signature.name = !&"foo"; parameters = [ +{ Parameter.name = "*args"; value = None;
        annotation = Some !"str" }; +{ Parameter.name = "**kwargs"; value = None; annotation = Some
        !"str" }; ]; decorators = []; return_annotation = Some !"str"; async = false; generator =
        false; parent = None; nesting_define = None; }; captures = []; unbound_names = []; body = [
        +Statement.Return { Return.expression = Some (+Expression.Constant (Constant.Integer 4));
        is_implicit = false; }; ]; }; ];*)

      (*TODO (T148669698): assert_not_parsed (trim_extra_indentation {| def foo(x): # type: (str,
        str) -> str return 4 |});*)
    ]


let test_class =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo: pass"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments = [];
                    body = [+Statement.Pass];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "@bar\nclass foo():\n\tpass"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments = [];
                    body = [+Statement.Pass];
                    decorators = [!"bar"];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo():\n\tdef bar(): pass"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments = [];
                    body =
                      [
                        +Statement.Define
                           {
                             Define.signature =
                               {
                                 Define.Signature.name = !&"bar";
                                 parameters = [];
                                 decorators = [];
                                 return_annotation = None;
                                 async = false;
                                 generator = false;
                                 parent = Some !&"foo";
                                 nesting_define = None;
                               };
                             captures = [];
                             unbound_names = [];
                             body = [+Statement.Pass];
                           };
                      ];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo():\n\tdef bar():\n\t\tdef baz(): pass"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments = [];
                    body =
                      [
                        +Statement.Define
                           {
                             Define.signature =
                               {
                                 Define.Signature.name = !&"bar";
                                 parameters = [];
                                 decorators = [];
                                 return_annotation = None;
                                 async = false;
                                 generator = false;
                                 parent = Some !&"foo";
                                 nesting_define = None;
                               };
                             captures = [];
                             unbound_names = [];
                             body =
                               [
                                 +Statement.Define
                                    {
                                      Define.signature =
                                        {
                                          Define.Signature.name = !&"baz";
                                          parameters = [];
                                          decorators = [];
                                          return_annotation = None;
                                          async = false;
                                          generator = false;
                                          parent = None;
                                          nesting_define = None;
                                        };
                                      captures = [];
                                      unbound_names = [];
                                      body = [+Statement.Pass];
                                    };
                               ];
                           };
                      ];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo(1, 2):\n\t1"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments =
                      [
                        {
                          Call.Argument.name = None;
                          value = +Expression.Constant (Constant.Integer 1);
                        };
                        {
                          Call.Argument.name = None;
                          value = +Expression.Constant (Constant.Integer 2);
                        };
                      ];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo(init_subclass_arg=\"literal_string\"):\n\t1"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments =
                      [
                        {
                          Call.Argument.name = Some ~+"init_subclass_arg";
                          value =
                            +Expression.Constant
                               (Constant.String (StringLiteral.create "literal_string"));
                        };
                      ];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo(1, **kwargs):\n\t1"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments =
                      [
                        {
                          Call.Argument.name = None;
                          value = +Expression.Constant (Constant.Integer 1);
                        };
                        {
                          Call.Argument.name = None;
                          value = +Expression.Starred (Starred.Twice !"kwargs");
                        };
                      ];
                    body = [+Statement.Expression (+Expression.Constant (Constant.Integer 1))];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class foo(superfoo):\n\tdef bar(): pass"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"foo";
                    base_arguments = [{ Call.Argument.name = None; value = !"superfoo" }];
                    body =
                      [
                        +Statement.Define
                           {
                             Define.signature =
                               {
                                 Define.Signature.name = !&"bar";
                                 parameters = [];
                                 decorators = [];
                                 return_annotation = None;
                                 async = false;
                                 generator = false;
                                 parent = Some !&"foo";
                                 nesting_define = None;
                               };
                             captures = [];
                             unbound_names = [];
                             body = [+Statement.Pass];
                           };
                      ];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "class A:\n\tdef foo(): pass\n\tclass B:\n\t\tdef bar(): pass\n"
           ~expected:
             [
               +Statement.Class
                  {
                    Class.name = !&"A";
                    base_arguments = [];
                    body =
                      [
                        +Statement.Define
                           {
                             Define.signature =
                               {
                                 Define.Signature.name = !&"foo";
                                 parameters = [];
                                 decorators = [];
                                 return_annotation = None;
                                 async = false;
                                 generator = false;
                                 parent = Some !&"A";
                                 nesting_define = None;
                               };
                             captures = [];
                             unbound_names = [];
                             body = [+Statement.Pass];
                           };
                        +Statement.Class
                           {
                             Class.name = !&"B";
                             base_arguments = [];
                             body =
                               [
                                 +Statement.Define
                                    {
                                      Define.signature =
                                        {
                                          Define.Signature.name = !&"bar";
                                          parameters = [];
                                          decorators = [];
                                          return_annotation = None;
                                          async = false;
                                          generator = false;
                                          parent = Some !&"B";
                                          nesting_define = None;
                                        };
                                      captures = [];
                                      unbound_names = [];
                                      body = [+Statement.Pass];
                                    };
                               ];
                             decorators = [];
                             top_level_unbound_names = [];
                           };
                      ];
                    decorators = [];
                    top_level_unbound_names = [];
                  };
             ];
    ]


let test_match =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  let assert_case_parsed case_source ~expected_pattern ~expected_guard =
    assert_parsed
      ("match x:\n " ^ case_source ^ ":\n pass")
      ~expected:
        [
          +Statement.Match
             {
               Match.subject = !"x";
               cases =
                 [
                   {
                     Match.Case.pattern = expected_pattern;
                     guard = expected_guard;
                     body = [+Statement.Pass];
                   };
                 ];
             };
        ]
  in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case 1"
           ~expected_pattern:(+Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 1)))
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case 2 as y"
           ~expected_pattern:
             (+Match.Pattern.MatchAs
                 {
                   pattern =
                     Some (+Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 2)));
                   name = "y";
                 })
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case 3 | 4"
           ~expected_pattern:
             (+Match.Pattern.MatchOr
                 [
                   +Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 3));
                   +Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 4));
                 ])
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case None"
           ~expected_pattern:(+Match.Pattern.MatchSingleton Constant.NoneLiteral)
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case [y, z, *rest]"
           ~expected_pattern:
             (+Match.Pattern.MatchSequence
                 [
                   +Match.Pattern.MatchAs { pattern = None; name = "y" };
                   +Match.Pattern.MatchAs { pattern = None; name = "z" };
                   +Match.Pattern.MatchStar (Some "rest");
                 ])
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case [y, z, *_]"
           ~expected_pattern:
             (+Match.Pattern.MatchSequence
                 [
                   +Match.Pattern.MatchAs { pattern = None; name = "y" };
                   +Match.Pattern.MatchAs { pattern = None; name = "z" };
                   +Match.Pattern.MatchStar None;
                 ])
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case Foo(5, y=6)"
           ~expected_pattern:
             (+Match.Pattern.MatchClass
                 {
                   class_name = +Name.Identifier "Foo";
                   patterns =
                     [+Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 5))];
                   keyword_attributes = ["y"];
                   keyword_patterns =
                     [+Match.Pattern.MatchValue (+Expression.Constant (Constant.Integer 6))];
                 })
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case {7: y, 8: z, **rest}"
           ~expected_pattern:
             (+Match.Pattern.MatchMapping
                 {
                   keys =
                     [
                       +Expression.Constant (Constant.Integer 7);
                       +Expression.Constant (Constant.Integer 8);
                     ];
                   patterns =
                     [
                       +Match.Pattern.MatchAs { pattern = None; name = "y" };
                       +Match.Pattern.MatchAs { pattern = None; name = "z" };
                     ];
                   rest = Some "rest";
                 })
           ~expected_guard:None;
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_case_parsed
           "case _ if True"
           ~expected_pattern:(+Match.Pattern.MatchWildcard)
           ~expected_guard:(Some (+Expression.Constant Constant.True));
      (*assert_not_parsed "match x:\n case 1 as _:\n pass"; assert_not_parsed "match x:\n\n case y |
        z:\n pass"; assert_not_parsed "match x:\n case (1 as y) | (2 as z):\n pass";
        assert_not_parsed "match x:\n case [1, *_, 5, *_, 10]:\n pass";*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_not_parsed "match x:\n case\n  x:\n pass\n case x:\n pass";
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_not_parsed "match x:\n case _:\n pass\n case 42:\n pass";
    ]


let () =
  "parse_statements"
  >::: [
         test_pass_break_continue;
         test_global_nonlocal;
         test_expression_return_raise;
         test_assert_delete;
         test_import;
         test_for_while_if;
         test_try;
         test_with;
         test_assign;
         test_define;
         test_class;
         test_match;
       ]
  |> Test.run
