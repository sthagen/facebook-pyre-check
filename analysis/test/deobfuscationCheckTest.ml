(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Analysis
open Test

let assert_deobfuscation ~context source expected =
  let configuration, environment =
    let project = ScratchProject.setup ~context [] in
    let { ScratchProject.BuiltTypeEnvironment.type_environment; _ } =
      ScratchProject.build_type_environment project
    in
    ScratchProject.configuration_of project, type_environment
  in
  let handle = "qualifier.py" in
  let actual =
    let source = parse ~handle source in
    let errors =
      DeobfuscationCheck.run
        ~configuration
        ~environment:(TypeEnvironment.read_only environment)
        ~source
    in
    match errors with
    | [{ Error.kind = Error.Deobfuscation actual; _ }] -> actual
    | _ -> failwith "Did not generate a source"
  in
  (assert_source_equal ~location_insensitive:true) (parse ~handle expected) actual;
  Memory.reset_shared_memory ()


let test_forward context =
  let assert_deobfuscation = assert_deobfuscation ~context in
  (* Basic propagation. *)
  assert_deobfuscation {|
      a = 1
      b = a
      c = b
      c
    |} {|
      1
    |};
  assert_deobfuscation {|
      a = 'string'
      a
    |} {|
      'string'
    |};
  assert_deobfuscation {|
      a = True
      a
    |} {|
      True
    |};
  assert_deobfuscation {|
      a = None
      a
    |} {|
      None
    |};
  assert_deobfuscation {|
      a = 1
      a = 2
      a
    |} {|
      2
    |};
  assert_deobfuscation {|
      a = 1
      foo(a)
    |} {|
      foo(1)
    |};

  (* Deletion. *)
  assert_deobfuscation
    {|
      a = 1
      a = foo()
      b = a
      b
    |}
    {|
      a = foo()
      a
    |};
  assert_deobfuscation
    {|
      a = 1
      a = a + 1
      a
    |}
    {|
      a = 1 + 1
      a
    |};

  (* Control flow. *)
  assert_deobfuscation
    {|
      if True:
        a = 1
      else:
        a = 2
      a
    |}
    {|
      if True:
        a = 1
      else:
        a = 2
      a
    |};
  assert_deobfuscation
    {|
      if True:
        a = 1
      else:
        a = 1
      a
    |}
    {|
      if True:
        pass
      1
    |};

  (* Assertions. *)
  assert_deobfuscation {|
      a = False
      assert a
    |} {|
      assert False
    |};
  assert_deobfuscation
    {|
      a = False
      if a:
        pass
    |}
    {|
      if False:
        pass
    |};
  assert_deobfuscation
    {|
      a = False
      b = 1
      if a:
        foo(b)
    |}
    {|
      if False:
        foo(1)
    |};

  (* Functions. *)
  assert_deobfuscation {|
      a = len
      a
    |} {|
      len
    |};
  assert_deobfuscation {|
      a = len
      a(b)
    |} {|
      len(b)
    |};
  assert_deobfuscation {|
      a = len
      a(b).imag
    |} {|
      len(b).imag
    |};

  (* Constructors. *)
  assert_deobfuscation
    {|
      import threading
      t = threading.Thread
      t()
    |}
    {|
      import threading
      threading.Thread()
    |};

  (* Global constants. *)
  assert_deobfuscation
    {|
      import logging
      d = logging.DEBUG
      d
      i = logging.INFO_1
      i
    |}
    {|
      import logging
      logging.DEBUG
      logging.INFO_1
    |}


let test_scheduling context =
  let assert_deobfuscation = assert_deobfuscation ~context in
  assert_deobfuscation
    {|
      a = 1
      def nested():
        b
    |}
    {|
      def nested():
        b
    |};
  assert_deobfuscation
    {|
      def nested():
        a = 1
        a
    |}
    {|
      def nested():
        1
    |};
  assert_deobfuscation
    {|
      def nested():
        def nested():
          a = 1
          a
    |}
    {|
      def nested():
        def nested():
          1
    |};
  assert_deobfuscation
    {|
      def nested():
        a = 1
        def nested():
          a
    |}
    {|
      def nested():
        def nested():
          1
    |};
  assert_deobfuscation
    {|
      def nested():
        def nested():
          a
        a = 1
    |}
    {|
      def nested():
        def nested():
          a
    |}


let test_dead_store_elimination context =
  let assert_deobfuscation = assert_deobfuscation ~context in
  assert_deobfuscation {|
      a = 1
      a
    |} {|
      1
    |};
  assert_deobfuscation
    {|
      if True:
        a = 1
      else:
        a = 1
      a
    |}
    {|
      if True:
        pass
      1
    |};
  assert_deobfuscation
    {|
      f = foo()
      f.connect()
    |}
    {|
      f = foo()
      f.connect()
    |}


let test_fixup context =
  let assert_deobfuscation = assert_deobfuscation ~context in
  (* Fix empty bodies. *)
  assert_deobfuscation
    {|
      if True:
        dead = 1
    |}
    {|
      if True:
        pass
    |};
  assert_deobfuscation
    {|
      def foo():
        dead = 1
    |}
    {|
      def foo():
        pass
    |};

  (* Remove docstrings. *)
  assert_deobfuscation
    {|
      def foo():
        "docstring"
        pass
    |}
    {|
      def foo():
        pass
    |};

  (* Sanitize accesses. *)
  assert_deobfuscation {|
      $local_qualifier$variable
    |} {|
      variable
    |};
  assert_deobfuscation
    {|
      def foo($parameter$parameter):
        pass
    |}
    {|
      def foo(parameter):
        pass
    |};
  assert_deobfuscation
    {|
      foo($parameter$parameter = 1)
    |}
    {|
      foo(parameter = 1)
    |};
  assert_deobfuscation
    {|
      try:
        pass
      except Exception as $target$e:
        pass
    |}
    {|
      try:
        pass
      except Exception as e:
        pass
    |};

  (* Drop qualifier. *)
  assert_deobfuscation
    {|
      def qualifier.foo():
        qualifier.bar()
    |}
    {|
      def foo():
        bar()
    |};

  (* Naming heuristics. *)
  assert_deobfuscation
    {|
      if True:
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc = 1
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
      if True:
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpYd = 2
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpYd
    |}
    {|
      if True:
        a = 1
      a
      if True:
        b = 2
      b
    |};
  assert_deobfuscation
    {|
      (
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc,
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpYd
      ) = foo()
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpYd
    |}
    {|
      a, b = foo()
      a
      b
    |};
  assert_deobfuscation
    {|
      if True:
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc = 1
      else:
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc = 2
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      if True:
        a = 1
      else:
        a = 2
      a
    |};
  assert_deobfuscation
    {|
      def FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc():
        pass
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc()
    |}
    {|
      def a():
        pass
      a()
    |};
  assert_deobfuscation
    {|
      def foo($parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc):
        $parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      def foo(a):
        a
    |};
  assert_deobfuscation
    {|
      def foo($parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc):
        $parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
      def bar($parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc):
        $parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      def foo(a):
        a
      def bar(b):
        b
    |};
  assert_deobfuscation
    {|
      def foo($parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc):
        pass
      foo($parameter$FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc = 1)
    |}
    {|
      def foo(a):
        pass
      foo(FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc = 1)
    |};
  assert_deobfuscation
    {|
      def other.FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc():
        pass
      other.FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc()
    |}
    {|
      def other.a():
        pass
      other.a()
    |};
  assert_deobfuscation
    {|
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc()
      def FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc():
        pass
    |}
    {|
      a()
      def a():
        pass
    |};

  (* For. *)
  assert_deobfuscation
    {|
      for FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc in []:
        FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      for a in []:
        a
    |};

  (* Globals. *)
  assert_deobfuscation
    {|
      global FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      global a
      a
    |};
  assert_deobfuscation
    {|
      FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
      global FafJsUlzgBbRAOWSEqDLIQvnVrMkhCjGeXwioHKPutxTmNpdc
    |}
    {|
      a
      global a
    |}


let () =
  "deobfuscation"
  >::: [
         "forward" >:: test_forward;
         "scheduling" >:: test_scheduling;
         "dead_store_elimination" >:: test_dead_store_elimination;
         "fixup" >:: test_fixup;
       ]
  |> Test.run
