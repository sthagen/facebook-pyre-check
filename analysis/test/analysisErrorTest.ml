(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Ast
open Analysis
open Pyre
open Statement
open Test

let signature_value ?(return_annotation = Some !"int") ?(name = "foo") () =
  {
    Define.Signature.name = Reference.create name |> Node.create_with_default_location;
    parameters = [];
    decorators = [];
    docstring = None;
    return_annotation;
    async = false;
    generator = false;
    parent = None;
    nesting_define = None;
  }


let define_value ?(return_annotation = Some !"int") ?(body = []) ?(name = "foo") () =
  { Define.signature = signature_value ~return_annotation ~name (); captures = []; body }


let untyped_signature = +signature_value ~return_annotation:None ()

let signature () = +signature_value ()

let define ?(body = []) () = +define_value ~body ()

let mock_signature = signature ()

let mock_define = define ()

let mock_parent = Type.Primitive "foo"

let error ?(signature = mock_signature) ?(location = Location.Reference.any) kind =
  { Error.location; kind; signature }


let revealed_type expression annotation =
  Error.RevealedType { expression = parse_single_expression expression; annotation }


let missing_return annotation =
  Error.MissingReturnAnnotation
    {
      name = !&"$return_annotation";
      annotation = Some annotation;
      given_annotation = None;
      evidence_locations = [];
      thrown_at_source = true;
    }


let incompatible_return_type
    ?(is_unimplemented = false)
    ?(due_to_invariance = false)
    actual
    expected
  =
  Error.IncompatibleReturnType
    {
      mismatch = { Error.actual; expected; due_to_invariance };
      is_implicit = false;
      is_unimplemented;
      define_location = Node.location mock_define;
    }


let undefined_attribute actual =
  Error.UndefinedAttribute
    { attribute = "foo"; origin = Error.Class { annotation = actual; class_attribute = false } }


let unexpected_keyword name callee =
  Error.UnexpectedKeyword { name; callee = callee >>| Reference.create }


let configuration = Configuration.Analysis.create ()

let test_due_to_analysis_limitations _ =
  let assert_due_to_analysis_limitations kind =
    assert_true (Error.due_to_analysis_limitations (error kind))
  in
  let assert_not_due_to_analysis_limitations kind =
    assert_false (Error.due_to_analysis_limitations (error kind))
  in
  (* IncompatibleAttributeType. *)
  assert_due_to_analysis_limitations
    (Error.IncompatibleAttributeType
       {
         parent = mock_parent;
         incompatible_type =
           {
             Error.name = !&"";
             mismatch = { Error.actual = Type.Top; expected = Type.Top; due_to_invariance = false };
             declare_location = Location.Instantiated.any;
           };
       });
  assert_due_to_analysis_limitations
    (Error.IncompatibleAttributeType
       {
         parent = mock_parent;
         incompatible_type =
           {
             Error.name = !&"";
             mismatch =
               { Error.actual = Type.Top; expected = Type.string; due_to_invariance = false };
             declare_location = Location.Instantiated.any;
           };
       });
  assert_not_due_to_analysis_limitations
    (Error.IncompatibleAttributeType
       {
         parent = mock_parent;
         incompatible_type =
           {
             Error.name = !&"";
             mismatch =
               { Error.actual = Type.string; expected = Type.Top; due_to_invariance = false };
             declare_location = Location.Instantiated.any;
           };
       });

  (* Initialization *)
  assert_due_to_analysis_limitations
    (Error.UninitializedAttribute
       {
         name = "";
         parent = mock_parent;
         mismatch =
           { Error.actual = Type.Top; expected = Type.Optional Type.Top; due_to_invariance = false };
         kind = Class;
       });
  assert_not_due_to_analysis_limitations
    (Error.UninitializedAttribute
       {
         name = "";
         parent = mock_parent;
         mismatch =
           {
             Error.actual = Type.string;
             expected = Type.Optional Type.string;
             due_to_invariance = false;
           };
         kind = Class;
       });

  (* MissingParameterAnnotation. *)
  assert_not_due_to_analysis_limitations
    (Error.MissingParameterAnnotation
       {
         name = !&"";
         annotation = Some Type.Top;
         given_annotation = None;
         evidence_locations = [];
         thrown_at_source = true;
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingParameterAnnotation
       {
         name = !&"";
         annotation = None;
         given_annotation = Some Type.Top;
         evidence_locations = [];
         thrown_at_source = true;
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingParameterAnnotation
       {
         name = !&"";
         annotation = Some Type.string;
         given_annotation = None;
         evidence_locations = [];
         thrown_at_source = true;
       });

  (* MissingReturnAnnotation. *)
  assert_not_due_to_analysis_limitations
    (Error.MissingReturnAnnotation
       {
         name = !&"$return_annotation";
         annotation = Some Type.Top;
         given_annotation = None;
         evidence_locations = [];
         thrown_at_source = true;
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingReturnAnnotation
       {
         name = !&"$return_annotation";
         annotation = None;
         given_annotation = Some Type.Top;
         evidence_locations = [];
         thrown_at_source = true;
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingReturnAnnotation
       {
         name = !&"$return_annotation";
         annotation = Some Type.string;
         given_annotation = None;
         evidence_locations = [];
         thrown_at_source = true;
       });

  (* MissingAttributeAnnotation *)
  assert_not_due_to_analysis_limitations
    (Error.MissingAttributeAnnotation
       {
         parent = mock_parent;
         missing_annotation =
           {
             Error.name = !&"";
             annotation = Some Type.Top;
             given_annotation = None;
             evidence_locations = [];
             thrown_at_source = true;
           };
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingAttributeAnnotation
       {
         parent = mock_parent;
         missing_annotation =
           {
             Error.name = !&"";
             annotation = None;
             given_annotation = Some Type.Top;
             evidence_locations = [];
             thrown_at_source = true;
           };
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingAttributeAnnotation
       {
         parent = mock_parent;
         missing_annotation =
           {
             Error.name = !&"";
             annotation = Some Type.string;
             given_annotation = None;
             evidence_locations = [];
             thrown_at_source = true;
           };
       });
  assert_not_due_to_analysis_limitations
    (Error.MissingAttributeAnnotation
       {
         parent = mock_parent;
         missing_annotation =
           {
             Error.name = !&"";
             annotation = None;
             given_annotation = None;
             evidence_locations = [];
             thrown_at_source = true;
           };
       });

  (* Parameter. *)
  assert_due_to_analysis_limitations
    (Error.IncompatibleParameterType
       {
         name = Some "";
         position = 1;
         callee = Some !&"callee";
         mismatch = { Error.actual = Type.Top; expected = Type.Top; due_to_invariance = false };
       });
  assert_due_to_analysis_limitations
    (Error.IncompatibleParameterType
       {
         name = Some "";
         position = 1;
         callee = Some !&"callee";
         mismatch = { Error.actual = Type.Top; expected = Type.string; due_to_invariance = false };
       });
  assert_not_due_to_analysis_limitations
    (Error.IncompatibleParameterType
       {
         name = Some "";
         position = 1;
         callee = Some !&"callee";
         mismatch = { Error.actual = Type.string; expected = Type.Top; due_to_invariance = false };
       });
  assert_due_to_analysis_limitations
    (Error.IncompatibleParameterType
       {
         name = Some "";
         position = 1;
         callee = Some !&"callee";
         mismatch =
           {
             Error.actual = Type.Primitive "typing.TypeAlias";
             expected = Type.Top;
             due_to_invariance = false;
           };
       });

  (* Return. *)
  assert_due_to_analysis_limitations
    (Error.IncompatibleReturnType
       {
         mismatch = { Error.actual = Type.Top; expected = Type.Top; due_to_invariance = false };
         is_implicit = false;
         is_unimplemented = false;
         define_location = Node.location mock_define;
       });
  assert_due_to_analysis_limitations
    (Error.IncompatibleReturnType
       {
         mismatch = { Error.actual = Type.Top; expected = Type.string; due_to_invariance = false };
         is_implicit = false;
         is_unimplemented = false;
         define_location = Node.location mock_define;
       });
  assert_not_due_to_analysis_limitations
    (Error.IncompatibleReturnType
       {
         mismatch = { Error.actual = Type.string; expected = Type.Top; due_to_invariance = false };
         is_implicit = false;
         is_unimplemented = false;
         define_location = Node.location mock_define;
       });

  (* UndefinedType. *)
  assert_not_due_to_analysis_limitations (Error.UndefinedType Type.Top);
  assert_not_due_to_analysis_limitations (Error.UndefinedType Type.string);

  (* Unpack. *)
  assert_not_due_to_analysis_limitations
    (Error.Unpack { expected_count = 2; unpack_problem = CountMismatch 3 });
  assert_not_due_to_analysis_limitations
    (Error.Unpack { expected_count = 2; unpack_problem = UnacceptableType Type.integer });
  assert_due_to_analysis_limitations
    (Error.Unpack { expected_count = 2; unpack_problem = UnacceptableType Type.Top })


let test_join context =
  let resolution = ScratchProject.setup ~context [] |> ScratchProject.build_global_resolution in
  let assert_join left right expected =
    let result = Error.join ~resolution left right in
    assert_equal ~printer:Error.show ~cmp:Error.equal expected result
  in
  assert_join
    (error
       (Error.IncompatibleAttributeType
          {
            parent = mock_parent;
            incompatible_type =
              {
                Error.name = !&"";
                mismatch =
                  { Error.actual = Type.Top; expected = Type.Top; due_to_invariance = false };
                declare_location = Location.Instantiated.any;
              };
          }))
    (error
       (Error.IncompatibleVariableType
          {
            Error.name = !&"";
            mismatch = { Error.actual = Type.Top; expected = Type.Top; due_to_invariance = false };
            declare_location = Location.Instantiated.any;
          }))
    (error Error.Top);
  assert_join
    (error
       (Error.IncompatibleParameterType
          {
            name = Some "";
            position = 1;
            callee = Some !&"callee";
            mismatch =
              { Error.actual = Type.integer; expected = Type.string; due_to_invariance = false };
          }))
    (error
       (Error.IncompatibleParameterType
          {
            name = Some "";
            position = 1;
            callee = Some !&"callee";
            mismatch =
              { Error.actual = Type.float; expected = Type.string; due_to_invariance = false };
          }))
    (error
       (Error.IncompatibleParameterType
          {
            name = Some "";
            position = 1;
            callee = Some !&"callee";
            mismatch =
              { Error.actual = Type.float; expected = Type.string; due_to_invariance = false };
          }));
  let create_mock_location path =
    {
      Location.path;
      start = { Location.line = 1; column = 1 };
      stop = { Location.line = 1; column = 1 };
    }
  in
  assert_join
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.integer;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }));
  assert_join
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.integer;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = None;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.integer;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }));
  assert_join
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = None;
            given_annotation = None;
            evidence_locations = [];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = None;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }));
  assert_join
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = Some Type.Any;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = true;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.integer;
            given_annotation = Some Type.Any;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = false;
          }))
    (error
       (Error.MissingGlobalAnnotation
          {
            Error.name = !&"";
            annotation = Some Type.float;
            given_annotation = Some Type.Any;
            evidence_locations = [create_mock_location "derp.py"];
            thrown_at_source = true;
          }));
  assert_join
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }))
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }))
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }));
  assert_join
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }))
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 4 }))
    (error Error.Top);
  assert_join
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }))
    (error (Error.Unpack { expected_count = 3; unpack_problem = Error.CountMismatch 3 }))
    (error Error.Top);
  assert_join
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer }))
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }))
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }));
  assert_join
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }))
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer }))
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }));
  assert_join
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }))
    (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 }))
    (error Error.Top);
  assert_join
    (error
       (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }))
    (error
       (Error.Unpack { expected_count = 3; unpack_problem = Error.UnacceptableType Type.float }))
    (error Error.Top);
  assert_join
    (error (Error.UndefinedType (Type.Primitive "derp")))
    (error (Error.UndefinedType (Type.Primitive "derp")))
    (error (Error.UndefinedType (Type.Primitive "derp")));
  assert_join
    (error (Error.UndefinedType (Type.Primitive "derp")))
    (error (Error.UndefinedType (Type.Primitive "herp")))
    (error Error.Top);
  assert_join
    (error (Error.AnalysisFailure (Type.Primitive "derp")))
    (error (Error.AnalysisFailure (Type.Primitive "derp")))
    (error (Error.AnalysisFailure (Type.Primitive "derp")));
  assert_join
    (error (Error.AnalysisFailure (Type.Primitive "derp")))
    (error (Error.AnalysisFailure (Type.Primitive "herp")))
    (error (Error.AnalysisFailure (Type.union [Type.Primitive "derp"; Type.Primitive "herp"])));
  assert_join
    (error (revealed_type "a" (Annotation.create Type.integer)))
    (error (revealed_type "a" (Annotation.create Type.float)))
    (error (revealed_type "a" (Annotation.create Type.float)));
  assert_join
    (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.integer)))
    (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.float)))
    (error Error.Top);
  assert_join
    (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.integer)))
    (error (revealed_type "a" (Annotation.create_immutable ~global:false Type.integer)))
    (error Error.Top);
  assert_join
    (error (revealed_type "a" (Annotation.create Type.integer)))
    (error (revealed_type "b" (Annotation.create Type.float)))
    (error Error.Top);
  assert_join
    (error
       ~location:
         { Location.Reference.synthetic with Location.start = { Location.line = 1; column = 0 } }
       (revealed_type "a" (Annotation.create Type.integer)))
    (error
       ~location:
         { Location.Reference.synthetic with Location.start = { Location.line = 2; column = 1 } }
       (revealed_type "a" (Annotation.create Type.float)))
    (error
       ~location:
         { Location.Reference.synthetic with Location.start = { Location.line = 1; column = 0 } }
       (revealed_type "a" (Annotation.create Type.float)))


let test_less_or_equal context =
  let resolution = ScratchProject.setup ~context [] |> ScratchProject.build_global_resolution in
  assert_true
    (Error.less_or_equal
       ~resolution
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer }))
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer })));
  assert_true
    (Error.less_or_equal
       ~resolution
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer }))
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float })));
  assert_false
    (Error.less_or_equal
       ~resolution
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.float }))
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer })));
  assert_false
    (Error.less_or_equal
       ~resolution
       (error
          (Error.Unpack { expected_count = 3; unpack_problem = Error.UnacceptableType Type.integer }))
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer })));
  assert_true
    (Error.less_or_equal
       ~resolution
       (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 2 }))
       (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 2 })));
  assert_false
    (Error.less_or_equal
       ~resolution
       (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 2 }))
       (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 3 })));
  assert_false
    (Error.less_or_equal
       ~resolution
       (error (Error.Unpack { expected_count = 2; unpack_problem = Error.CountMismatch 2 }))
       (error
          (Error.Unpack { expected_count = 2; unpack_problem = Error.UnacceptableType Type.integer })));
  assert_true
    (Error.less_or_equal
       ~resolution
       (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.integer)))
       (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.integer))));
  assert_false
    (Error.less_or_equal
       ~resolution
       (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.integer)))
       (error (revealed_type "a" (Annotation.create_immutable ~global:true Type.float))))


let test_filter context =
  let open Error in
  let resolution =
    ScratchProject.setup
      ~context
      [
        ( "test.py",
          {|
            class Foo: ...
            class MockChild(unittest.mock.Mock): ...
            class NonCallableChild(unittest.mock.NonCallableMock): ...
            class NonMockChild(Foo): ...
          |}
        );
      ]
    |> ScratchProject.build_global_resolution
  in
  let assert_filtered ?(location = Location.Reference.any) ?(signature = mock_signature) kind =
    let errors = [error ~signature ~location kind] in
    assert_equal [] (filter ~resolution errors)
  in
  let assert_unfiltered ?(location = Location.Reference.any) ?(signature = mock_signature) kind =
    let errors = [error ~signature ~location kind] in
    assert_equal ~cmp:(List.equal equal) errors (filter ~resolution errors)
  in
  (* Suppress stub errors. *)
  let stub = { Location.Reference.any with Location.path = !&"stub" } in
  assert_unfiltered ~location:stub (undefined_attribute (Type.Primitive "Foo"));
  assert_unfiltered ~location:Location.Reference.any (undefined_attribute (Type.Primitive "Foo"));

  (* Suppress mock errors. *)
  assert_filtered (incompatible_return_type (Type.Primitive "unittest.mock.Mock") Type.integer);
  assert_unfiltered (incompatible_return_type Type.integer (Type.Primitive "unittest.mock.Mock"));
  assert_filtered (undefined_attribute (Type.Primitive "test.MockChild"));
  assert_filtered (undefined_attribute (Type.Primitive "test.NonCallableChild"));
  assert_unfiltered (undefined_attribute (Type.Primitive "test.NonMockChild"));
  assert_filtered (undefined_attribute (Type.Optional (Type.Primitive "test.NonCallableChild")));
  assert_unfiltered (incompatible_return_type (Type.Optional Type.Bottom) Type.integer);
  assert_filtered (unexpected_keyword "foo" (Some "unittest.mock.call"));
  assert_unfiltered (unexpected_keyword "foo" None);

  (* Always filter synthetic locations. *)
  assert_filtered ~location:Location.Reference.synthetic (missing_return Type.integer);

  (* Suppress return errors in unimplemented defines. *)
  assert_unfiltered (incompatible_return_type Type.integer Type.float);
  assert_filtered (incompatible_return_type Type.integer Type.float ~is_unimplemented:true);

  (* Suppress errors due to importing builtins. *)
  let undefined_import import = UndefinedImport !&import in
  assert_filtered (undefined_import "builtins");
  assert_unfiltered (undefined_import "sys");
  let inconsistent_override name override =
    InconsistentOverride
      {
        overridden_method = name;
        parent = !&(Type.show mock_parent);
        override;
        override_kind = Method;
      }
  in
  let abstract_class_instantiation name =
    InvalidClassInstantiation
      (AbstractClassInstantiation { class_name = !&name; abstract_methods = [] })
  in
  (* Suppress parameter errors on override of dunder methods *)
  assert_unfiltered
    (inconsistent_override "foo" (StrengthenedPrecondition (NotFound (Keywords Type.integer))));
  assert_unfiltered
    (inconsistent_override
       "__foo__"
       (WeakenedPostcondition
          { actual = Type.Top; expected = Type.integer; due_to_invariance = false }));
  assert_unfiltered
    (inconsistent_override
       "__foo__"
       (StrengthenedPrecondition
          (Found { actual = Type.none; expected = Type.integer; due_to_invariance = false })));
  assert_filtered
    (inconsistent_override "__foo__" (StrengthenedPrecondition (NotFound (Keywords Type.integer))));

  (* Suppress errors due to typeshed inconsistencies. *)
  assert_filtered (abstract_class_instantiation "int");
  assert_filtered (abstract_class_instantiation "float");
  assert_filtered (abstract_class_instantiation "bool");
  assert_unfiltered (abstract_class_instantiation "str")


let test_suppress _ =
  let assert_suppressed mode ?(ignore_codes = []) ?(signature = mock_signature) ?location kind =
    assert_equal true (Error.suppress ~mode ~ignore_codes (error ~signature ?location kind))
  in
  let assert_not_suppressed mode ?(ignore_codes = []) ?(signature = mock_signature) kind =
    assert_equal false (Error.suppress ~mode ~ignore_codes (error ~signature kind))
  in
  (* Test different modes. *)
  assert_not_suppressed Source.Debug (missing_return Type.Top);
  assert_not_suppressed Source.Debug (missing_return Type.Any);
  assert_not_suppressed Source.Debug (Error.UndefinedType Type.integer);
  assert_not_suppressed Source.Debug (Error.AnalysisFailure Type.Top);
  assert_suppressed Source.Infer (missing_return Type.Top);
  assert_suppressed Source.Infer (missing_return Type.Any);
  assert_not_suppressed Source.Infer (missing_return Type.integer);
  assert_suppressed Source.Infer (Error.UndefinedType Type.integer);
  assert_suppressed Source.Infer (Error.AnalysisFailure Type.integer);
  assert_not_suppressed Source.Strict (missing_return Type.Top);
  assert_suppressed Source.Strict (Error.IncompatibleAwaitableType Type.Top);
  assert_not_suppressed Source.Strict (missing_return Type.Any);
  assert_not_suppressed Source.Strict (Error.AnalysisFailure Type.integer);
  assert_not_suppressed Source.Unsafe (missing_return Type.integer);
  assert_suppressed Source.Unsafe (missing_return Type.Top);
  assert_not_suppressed Source.Unsafe (incompatible_return_type Type.integer Type.float);

  (* Should not be made *)
  assert_not_suppressed Source.Unsafe (incompatible_return_type Type.integer Type.Any);
  assert_not_suppressed Source.Unsafe (revealed_type "a" (Annotation.create Type.integer));
  assert_not_suppressed
    ~signature:untyped_signature
    Source.Unsafe
    (revealed_type "a" (Annotation.create Type.integer));
  assert_suppressed Source.Unsafe (Error.UndefinedName !&"reveal_type");
  assert_not_suppressed Source.Unsafe (Error.AnalysisFailure Type.integer);
  assert_suppressed
    Source.Unsafe
    (Error.InvalidTypeParameters
       { name = "dict"; kind = IncorrectNumberOfParameters { expected = 2; actual = 0 } });
  assert_not_suppressed
    Source.Unsafe
    (Error.InvalidTypeParameters
       { name = "dict"; kind = IncorrectNumberOfParameters { expected = 2; actual = 1 } });
  assert_not_suppressed
    Source.Strict
    (Error.InvalidTypeParameters
       { name = "dict"; kind = IncorrectNumberOfParameters { expected = 2; actual = 0 } });
  let suppress_missing_return = [Error.code (error (missing_return Type.Any))] in
  assert_suppressed
    Source.Unsafe
    ~ignore_codes:suppress_missing_return
    (missing_return Type.integer);
  assert_suppressed
    Source.Strict
    ~ignore_codes:suppress_missing_return
    (missing_return Type.integer);
  assert_suppressed Source.Unsafe ~ignore_codes:suppress_missing_return (missing_return Type.Any);

  (* Defer to Default policy if not specifically suppressed *)
  assert_not_suppressed
    Source.Unsafe
    ~ignore_codes:suppress_missing_return
    (incompatible_return_type Type.integer Type.float);
  assert_suppressed
    Source.Unsafe
    ~ignore_codes:suppress_missing_return
    (Error.UndefinedName !&"reveal_type");

  assert_suppressed
    Source.Declare
    (incompatible_return_type (Type.Primitive "donotexist") (Type.Primitive "meneither"));
  assert_not_suppressed
    Source.Unsafe
    (incompatible_return_type (Type.Primitive "donotexist") (Type.Primitive "meneither"));
  assert_not_suppressed
    Source.Strict
    (incompatible_return_type (Type.Primitive "donotexist") (Type.Primitive "meneither"))


let test_namespace_insensitive_set _ =
  let no_namespace_variable = Type.Variable.Unary.create "A" in
  let namespaced_variable_1 =
    let namespace = Type.Variable.Namespace.create_fresh () in
    Type.Variable { no_namespace_variable with namespace }
  in
  let namespaced_variable_2 =
    let namespace = Type.Variable.Namespace.create_fresh () in
    Type.Variable { no_namespace_variable with namespace }
  in
  let error_1 = error (Error.NotCallable (Type.list namespaced_variable_1)) in
  let error_2 = error (Error.NotCallable (Type.list namespaced_variable_2)) in
  assert_true (Error.compare error_1 error_2 == 0);
  let set_containing_error_1 = Error.Set.add Error.Set.empty error_1 in
  assert_true (Error.Set.mem set_containing_error_1 error_2)


let () =
  "error"
  >::: [
         "due_to_analysis_limitations" >:: test_due_to_analysis_limitations;
         "join" >:: test_join;
         "less_or_equal" >:: test_less_or_equal;
         "filter" >:: test_filter;
         "suppress" >:: test_suppress;
         "namespace_insensitive_set" >:: test_namespace_insensitive_set;
       ]
  |> Test.run
