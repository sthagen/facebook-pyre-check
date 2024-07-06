(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis
open Test
open OUnit2
open Pyre

module ReadWriteHelpers = struct
  let read_only environment =
    AstEnvironment.as_source_code_incremental environment |> SourceCodeIncrementalApi.Base.read_only


  let overlay environment =
    AstEnvironment.as_source_code_incremental environment |> SourceCodeIncrementalApi.Base.overlay


  let update environment =
    AstEnvironment.as_source_code_incremental environment |> SourceCodeIncrementalApi.Base.update
end

module ReadOnlyHelpers = struct
  let source_of_qualifier_tracked read_only ~dependency =
    SourceCodeIncrementalApi.ReadOnly.get_tracked_api ~dependency read_only
    |> SourceCodeApi.source_of_qualifier


  let parse_result_of_qualifier_tracked read_only ~dependency =
    SourceCodeIncrementalApi.ReadOnly.get_tracked_api ~dependency read_only
    |> SourceCodeApi.parse_result_of_qualifier


  let source_of_qualifier_untracked read_only =
    SourceCodeIncrementalApi.ReadOnly.get_untracked_api read_only
    |> SourceCodeApi.source_of_qualifier


  let parse_result_of_qualifier_untracked read_only =
    SourceCodeIncrementalApi.ReadOnly.get_untracked_api read_only
    |> SourceCodeApi.parse_result_of_qualifier
end

let test_basic context =
  let handle_a = "a.py" in
  let source_a = trim_extra_indentation {|
    def foo(x: int) -> int:
      return x
    |} in
  let handle_b = "b.py" in
  let source_b =
    trim_extra_indentation {|
    def bar(y: str) -> str:
      return "hello" + y
    |}
  in
  let handle_c = "c.py" in
  let source_c = trim_extra_indentation {|
      def baz() -> int:
        return 42
      |} in
  let project =
    ScratchProject.setup ~context [handle_a, source_a; handle_b, source_b; handle_c, source_c]
  in
  let configuration = ScratchProject.configuration_of project in
  let module_tracker =
    ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.module_tracker project
    |> ModuleTracker.read_only
  in
  let { Configuration.Analysis.local_root; _ } = configuration in
  let assert_module_path ~module_tracker ~expected reference =
    match ModuleTracker.ReadOnly.look_up_qualifier module_tracker reference with
    | SourceCodeApi.ModuleLookup.Explicit module_path ->
        let actual = ArtifactPaths.artifact_path_of_module_path ~configuration module_path in
        assert_equal
          ~cmp:[%compare.equal: ArtifactPath.t]
          ~printer:ArtifactPath.show
          expected
          actual
    | SourceCodeApi.ModuleLookup.Implicit
    | SourceCodeApi.ModuleLookup.NotFound ->
        let message =
          Format.asprintf "Cannot find reference %a in the AST environment" Reference.pp reference
        in
        assert_failure message
  in
  assert_module_path
    !&"a"
    ~module_tracker
    ~expected:(Test.relative_artifact_path ~root:local_root ~relative:handle_a);
  assert_module_path
    !&"b"
    ~module_tracker
    ~expected:(Test.relative_artifact_path ~root:local_root ~relative:handle_b);
  ()


let test_parse_stubs_modules_list context =
  let read_only =
    let stub_content = "def f()->int: ...\n" in
    let source_content = "def f()->int:\n    return 1\n" in
    ScratchProject.setup
      ~context
      [
        "a.pyi", stub_content;
        "dir/b.pyi", stub_content;
        "2/c.pyi", stub_content;
        "2and3/d.pyi", stub_content;
        "moda.py", source_content;
        "dir/modb.py", source_content;
        "2/modc.py", source_content;
        "2and3/modd.py", source_content;
      ]
    |> ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.ast_environment
    |> ReadWriteHelpers.read_only
  in
  let assert_function_matches_name ~qualifier ?(is_stub = false) define =
    let name =
      match ReadOnlyHelpers.source_of_qualifier_untracked read_only qualifier with
      | Some
          {
            Source.statements =
              [
                {
                  Node.value = Define ({ Statement.Define.signature = { name; _ }; _ } as define);
                  _;
                };
              ];
            _;
          }
        when Bool.equal (Statement.Define.is_stub define) is_stub ->
          name
      | _ -> failwith "Could not get source."
    in
    assert_equal ~cmp:Reference.equal ~printer:Reference.show (Reference.create define) name
  in
  assert_function_matches_name ~qualifier:!&"a" ~is_stub:true "a.f";
  assert_function_matches_name ~qualifier:!&"dir.b" ~is_stub:true "dir.b.f";
  assert_function_matches_name ~qualifier:!&"2.c" ~is_stub:true "2.c.f";
  assert_function_matches_name ~qualifier:!&"2and3.d" ~is_stub:true "2and3.d.f";
  assert_function_matches_name ~qualifier:!&"moda" "moda.f";
  assert_function_matches_name ~qualifier:!&"dir.modb" "dir.modb.f";
  assert_function_matches_name ~qualifier:!&"2.modc" "2.modc.f";
  assert_function_matches_name ~qualifier:!&"2and3.modd" "2and3.modd.f"


let test_parse_source context =
  let read_only, global_module_paths_api =
    let project =
      ScratchProject.setup
        ~context
        ~include_typeshed_stubs:false
        ["x.py", "def foo()->int:\n    return 1\n"]
    in
    ( ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.ast_environment project
      |> ReadWriteHelpers.read_only,
      ScratchProject.global_module_paths_api project )
  in
  let sources =
    List.filter_map
      (GlobalModulePathsApi.type_check_qualifiers global_module_paths_api)
      ~f:(ReadOnlyHelpers.source_of_qualifier_untracked read_only)
  in
  let handles =
    List.map sources ~f:(fun { Source.module_path; _ } -> ModulePath.relative module_path)
  in
  assert_equal handles ["x.py"];
  let source = ReadOnlyHelpers.source_of_qualifier_untracked read_only !&"x" in
  assert_equal (Option.is_some source) true;
  let { Source.module_path; statements; _ } = Option.value_exn source in
  assert_equal (ModulePath.relative module_path) "x.py";
  match statements with
  | [{ Node.value = Define { Statement.Define.signature = { name; _ }; _ }; _ }] ->
      assert_equal ~cmp:Reference.equal ~printer:Reference.show name (Reference.create "x.foo")
  | _ -> assert_unreached ()


let test_parse_sources context =
  (* Following symbolic links is needed to avoid should_type_check being always true on macos *)
  let create_path = PyrePath.create_absolute ~follow_symbolic_links:true in
  let local_root = create_path (bracket_tmpdir context) in
  let module_root = create_path (bracket_tmpdir context) in
  let link_root = create_path (bracket_tmpdir context) in
  let stub_root = PyrePath.create_relative ~root:local_root ~relative:"stubs" in
  let typeshed_root =
    PyrePath.create_relative ~root:local_root ~relative:".pyre/resource_cache/typeshed"
  in
  let write_file ?(content = "def foo() -> int: ...") root relative =
    File.create ~content (PyrePath.create_relative ~root ~relative) |> File.write
  in
  let source_handles, ast_environment =
    PyrePath.create_directory_recursively typeshed_root |> Result.ok_or_failwith;
    write_file local_root "a.pyi";
    write_file local_root "a.py";
    write_file module_root "b.pyi";
    write_file local_root "b.py";
    write_file local_root "c.py";
    write_file local_root ".pyre/resource_cache/typeshed/foo.pyi";
    write_file link_root "link.py";
    write_file link_root "seemingly_unrelated.pyi";
    CamlUnix.symlink
      (PyrePath.absolute link_root ^/ "link.py")
      (PyrePath.absolute local_root ^/ "d.py");
    CamlUnix.symlink
      (PyrePath.absolute link_root ^/ "seemingly_unrelated.pyi")
      (PyrePath.absolute local_root ^/ "d.pyi");
    let configuration =
      Configuration.Analysis.create
        ~local_root
        ~source_paths:[SearchPath.Root local_root]
        ~search_paths:
          [SearchPath.Root module_root; SearchPath.Root typeshed_root; SearchPath.Root stub_root]
        ~filter_directories:[local_root]
        ~track_dependencies:true
        ()
    in
    let ast_environment =
      EnvironmentControls.create configuration |> Analysis.AstEnvironment.create
    in
    let type_check_qualifiers =
      AstEnvironment.module_tracker ast_environment
      |> ModuleTracker.AssumeGlobalModuleListing.global_module_paths_api
      |> GlobalModulePathsApi.type_check_qualifiers
    in
    let sources =
      List.filter_map
        type_check_qualifiers
        ~f:
          (ReadOnlyHelpers.source_of_qualifier_untracked
             (ReadWriteHelpers.read_only ast_environment))
    in
    let sorted_handles =
      List.map sources ~f:(fun { Source.module_path; _ } -> ModulePath.relative module_path)
      |> List.sort ~compare:String.compare
    in
    sorted_handles, ast_environment
  in
  (* Load a raw source with a dependency and verify that it appears in `triggered_dependencies`
     after an update. *)
  let type_check_foo = SharedMemoryKeys.TypeCheckDefine (Reference.create "foo") in
  ReadOnlyHelpers.parse_result_of_qualifier_tracked
    (ReadWriteHelpers.read_only ast_environment)
    ~dependency:(SharedMemoryKeys.DependencyKey.Registry.register type_check_foo)
    (Reference.create "c")
  |> ignore;
  let triggered_dependencies =
    (* Re-write the file, otherwise RawSources won't trigger dependencies *)
    write_file ~content:"def foo() -> int: ...  # pyre-ignore" local_root "c.py";
    ReadWriteHelpers.update
      ~scheduler:(mock_scheduler ())
      ast_environment
      [
        (Test.relative_artifact_path ~root:local_root ~relative:"c.py"
        |> ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged));
      ]
    |> SourceCodeIncrementalApi.UpdateResult.triggered_dependencies
    |> SharedMemoryKeys.DependencyKey.RegisteredSet.to_seq
    |> Seq.fold_left
         (fun sofar registered -> SharedMemoryKeys.DependencyKey.get_key registered :: sofar)
         []
  in
  assert_equal
    ~printer:[%show: SharedMemoryKeys.dependency list]
    ~cmp:[%compare.equal: SharedMemoryKeys.dependency list]
    [SharedMemoryKeys.WildcardImport !&"c"; type_check_foo]
    triggered_dependencies;
  (* Add some new modules and verify the update *)
  assert_equal
    ~cmp:(List.equal String.equal)
    ~printer:(String.concat ~sep:", ")
    (* Because `d` is a symlink that points outside of the source directory, it does not get
       included in `type_check_qualifiers` *)
    ["a.pyi"; "c.py"; "foo.pyi"]
    source_handles;
  let source_handles =
    write_file local_root "new_local.py";
    write_file stub_root "new_stub.pyi";
    let invalidated_modules =
      ReadWriteHelpers.update
        ~scheduler:(mock_scheduler ())
        ast_environment
        [
          (Test.relative_artifact_path ~root:local_root ~relative:"new_local.py"
          |> ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged));
          (Test.relative_artifact_path ~root:stub_root ~relative:"new_stub.pyi"
          |> ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged));
        ]
      |> SourceCodeIncrementalApi.UpdateResult.invalidated_modules
    in
    let sources =
      List.filter_map
        invalidated_modules
        ~f:
          (ReadOnlyHelpers.source_of_qualifier_untracked
             (ReadWriteHelpers.read_only ast_environment))
    in
    List.map sources ~f:(fun { Source.module_path; _ } -> ModulePath.relative module_path)
  in
  (* Note that the stub gets parsed twice due to appearing both in the local root and stubs, but
     consistently gets mapped to the correct handle. *)
  assert_equal
    ~printer:(String.concat ~sep:", ")
    ~cmp:(fun left_handles right_handles ->
      let left_handles = List.sort ~compare:String.compare left_handles in
      let right_handles = List.sort ~compare:String.compare right_handles in
      List.equal String.equal left_handles right_handles)
    ["new_local.py"; "new_stub.pyi"]
    source_handles;
  ()


let test_ast_change _ =
  let assert_ast_changed ~old_source ~new_source ~expected =
    let handle = "test.py" in
    let old_source = Test.parse ~handle old_source in
    let new_source = Test.parse ~handle new_source in
    let compare_changed = not (Int.equal 0 (Source.compare old_source new_source)) in
    let hash_changed =
      let hash_source source = Hash.run Source.hash_fold_t source in
      not (Int.equal (hash_source old_source) (hash_source new_source))
    in
    assert_equal
      ~cmp:Bool.equal
      ~printer:(Format.sprintf "compare_changed = %b")
      expected
      compare_changed;

    (* This is not guaranteed to be the case in theory, but collisions should be rare in practice *)
    assert_equal ~cmp:Bool.equal ~printer:(Format.sprintf "hash changed = %b") expected hash_changed
  in
  (* TypecheckFlags *)
  assert_ast_changed ~old_source:"# pyre-strict" ~new_source:"# pyre-strict" ~expected:false;
  assert_ast_changed ~old_source:"# pyre-strict" ~new_source:"" ~expected:true;
  assert_ast_changed
    ~old_source:"# pyre-strict"
    ~new_source:"# pyre-ignore-all-errors"
    ~expected:true;

  (* Assignments. *)
  assert_ast_changed ~old_source:"a = 1" ~new_source:"a = 1" ~expected:false;
  assert_ast_changed ~old_source:"a: int = 1" ~new_source:"a: int = 1" ~expected:false;
  assert_ast_changed ~old_source:"a: str = 1" ~new_source:"a: int = 1" ~expected:true;
  assert_ast_changed ~old_source:"a = 2" ~new_source:"a = 1" ~expected:true;

  (* Defines *)
  assert_ast_changed
    ~old_source:"def foo() -> int: ..."
    ~new_source:"def foo() -> int: ..."
    ~expected:false;
  assert_ast_changed
    ~old_source:"def foo() -> int: ..."
    ~new_source:"def bar() -> int: ..."
    ~expected:true;
  assert_ast_changed
    ~old_source:"def foo(a: int): ..."
    ~new_source:"def foo(a: str): ..."
    ~expected:true;
  assert_ast_changed
    ~old_source:"def foo(a: int = 1): ..."
    ~new_source:"def foo(a: int = 2): ..."
    ~expected:true;
  assert_ast_changed
    ~old_source:"def foo() -> int: ..."
    ~new_source:"def foo() -> str: ..."
    ~expected:true;
  assert_ast_changed ~old_source:"def foo(): ..." ~new_source:"async def foo(): ..." ~expected:true;
  assert_ast_changed
    ~old_source:{|
        @decorator
        def foo(): ...
      |}
    ~new_source:{|
        @other_decorator
        def foo(): ...
      |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    def foo() -> int:
      return 42
    |}
    ~expected:false;
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    # pyre-ignore
    def foo() -> int:
      return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    # pyre-ignore-all-errors
    def foo() -> int:
      return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    # pyre-ignore
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    def foo() -> int: # pyre-ignore
      return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    # pyre-ignore[42]
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    # pyre-ignore[43]
    def foo() -> int:
      return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    # pyre-fixme
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    # pyre-ignore
    def foo() -> int:
      return 42
    |}
    ~expected:true;

  (* Classes *)
  assert_ast_changed
    ~old_source:{|
       @decorator
       class B(A):
         attribute: int = 1
     |}
    ~new_source:{|
       @decorator
       class B(A):
         attribute: int = 1
     |}
    ~expected:false;
  assert_ast_changed ~old_source:"class A: ..." ~new_source:"class B: ..." ~expected:true;
  assert_ast_changed ~old_source:"class A(B): ..." ~new_source:"class A(C): ..." ~expected:true;
  assert_ast_changed
    ~old_source:{|
       class A:
         attribute: int = 1
     |}
    ~new_source:{|
       class A:
         attribute: str = 1
     |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
       @decorator
       class A: ...
     |}
    ~new_source:{|
       @other_decorator
       class A: ...
     |}
    ~expected:true;

  (* If *)
  assert_ast_changed
    ~old_source:
      {|
        if test:
          attribute = 1
        else:
          attribute = 2
      |}
    ~new_source:
      {|
        if test:
          attribute = 1
        else:
          attribute = 2
      |}
    ~expected:false;
  assert_ast_changed
    ~old_source:{|
        if test:
          attribute = 1
      |}
    ~new_source:{|
        if other_test:
          attribute = 1
      |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
        if test:
          attribute = 1
      |}
    ~new_source:{|
        if test:
          attribute = 2
      |}
    ~expected:true;
  assert_ast_changed
    ~old_source:
      {|
        if test:
          attribute = 1
        else:
          attribute = 2
      |}
    ~new_source:
      {|
        if test:
          attribute = 1
        else:
          attribute = 3
      |}
    ~expected:true;

  (* Imports *)
  assert_ast_changed ~old_source:"from a import b" ~new_source:"from a import b" ~expected:false;
  assert_ast_changed ~old_source:"import a" ~new_source:"import a" ~expected:false;
  assert_ast_changed ~old_source:"from a import b" ~new_source:"from a import c" ~expected:true;
  assert_ast_changed ~old_source:"import a" ~new_source:"import b" ~expected:true;

  (* With *)
  assert_ast_changed
    ~old_source:{|
        with resource:
          attribute = 1
      |}
    ~new_source:{|
        with resource:
          attribute = 1
      |}
    ~expected:false;
  assert_ast_changed
    ~old_source:{|
        with resource:
          attribute = 1
      |}
    ~new_source:{|
        with resource:
          attribute = 2
      |}
    ~expected:true;

  (* Location-only change *)
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    def foo() -> int:
        return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    def foo(a: int, b: int) -> int:
      return a + b
    |}
    ~new_source:{|
    def foo(a: int,  b:    int) ->    int:
        return a   +   b
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    def foo() -> int:

      return 42
    |}
    ~expected:true;
  assert_ast_changed
    ~old_source:{|
      class Foo:
        x: int = 1
    |}
    ~new_source:{|

      class Foo:
        x: int = 1
    |}
    ~expected:true;

  (* Trailing comment/spaces/empty lines shouldn't matter as they don't affect any AST locations. *)
  (* They may affect line counts and raw hashes, but they are ignored by the
     Source.TypecheckFlags.compare/hash *)
  assert_ast_changed
    ~old_source:{|
    def foo() -> int:
      return 42
    |}
    ~new_source:{|
    def foo() -> int:
      return 42  # some comment
    |}
    ~expected:false;
  assert_ast_changed
    ~old_source:{|
      class Foo:
        x: int = 1
    |}
    ~new_source:{|
      class Foo:
        x: int = 1

    |}
    ~expected:false;

  (* TODO: This should be false. It seems that docstrings are still counted as part of the function
     body *)
  assert_ast_changed
    ~old_source:
      {|
    def foo() -> int:
      '''Lets just wait it out. You know, we could be all poetic and lose our minds together.'''
      return 42
    |}
    ~new_source:
      {|
    def foo() -> int:
      '''I'm still waiting for my turn.'''
      return 42
    |}
    ~expected:true;
  ()


let test_parse_repository context =
  let assert_repository_parses_to repository ~expected =
    let actual =
      let read_only, global_module_paths_api =
        let project = ScratchProject.setup ~context ~include_typeshed_stubs:false repository in

        ( ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.ast_environment project
          |> ReadWriteHelpers.read_only,
          ScratchProject.global_module_paths_api project )
      in
      let sources =
        List.filter_map
          (GlobalModulePathsApi.type_check_qualifiers global_module_paths_api)
          ~f:(ReadOnlyHelpers.source_of_qualifier_untracked read_only)
      in
      List.map sources ~f:(fun ({ Source.module_path; _ } as source) ->
          ModulePath.relative module_path, source)
      |> List.sort ~compare:(fun (left_handle, _) (right_handle, _) ->
             String.compare left_handle right_handle)
    in
    let equal
        (expected_handle, { Ast.Source.statements = expected_source; _ })
        (handle, { Ast.Source.statements; _ })
      =
      let equal left right = Statement.location_insensitive_compare left right = 0 in
      String.equal expected_handle handle && List.equal equal expected_source statements
    in
    let printer (handle, source) = Format.sprintf "%s: %s" handle (Ast.Source.show source) in
    let expected =
      List.map expected ~f:(fun (handle, parsed_source) ->
          handle, Test.parse ~handle parsed_source |> Preprocessing.qualify)
    in
    assert_equal ~cmp:(List.equal equal) ~printer:(List.to_string ~f:printer) expected actual
  in
  assert_repository_parses_to
    ["a.py", "def foo() -> int: ..."]
    ~expected:["a.py", "def foo() -> int: ..."];
  assert_repository_parses_to
    ["a.py", "def foo() -> int: ..."; "b.pyi", "from a import *"]
    ~expected:["a.py", "def foo() -> int: ..."; "b.pyi", "from a import foo as foo"];
  assert_repository_parses_to
    ["a.py", "def foo() -> int: ..."; "b.pyi", "from a import *"; "c.py", "from b import *"]
    ~expected:
      [
        "a.py", "def foo() -> int: ...";
        "b.pyi", "from a import foo as foo";
        "c.py", "from b import foo as foo";
      ];
  (* Unparsable source turns into getattr-any *)
  assert_repository_parses_to
    ["a.py", "def foo() -> int:"]
    ~expected:["a.py", "import typing\ndef __getattr__(name: str) -> typing.Any: ..."];
  ()


module IncrementalTest = struct
  type t = {
    handle: string;
    old_source: string option;
    new_source: string option;
  }

  module Expectation = struct
    type t = { dependencies: Reference.t list }

    let create dependencies = { dependencies }
  end

  let assert_parser_update
      ?(external_setups = [])
      ?(preprocess_all_sources = false)
      ?(force_load_external_sources = true)
      ~context
      ~expected:{ Expectation.dependencies = expected_dependencies }
      setups
    =
    let get_old_inputs setups =
      List.filter_map setups ~f:(fun { handle; old_source; _ } ->
          old_source >>| fun source -> handle, source)
    in
    let update_filesystem_state { Configuration.Analysis.local_root; search_paths; _ } =
      let update_file ~root { handle; old_source; new_source } =
        let path = PyrePath.create_relative ~root ~relative:handle in
        match old_source, new_source with
        | Some old_source, Some new_source
          when String.equal (trim_extra_indentation old_source) (trim_extra_indentation new_source)
          ->
            (* File content did not change *)
            None
        | _, Some source ->
            (* A file is added/updated *)
            File.create path ~content:(trim_extra_indentation source) |> File.write;
            Some ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged (ArtifactPath.create path))
        | Some _, None ->
            (* A file is removed *)
            PyrePath.unlink_if_exists path;
            Some ArtifactPath.Event.(create ~kind:Kind.Deleted (ArtifactPath.create path))
        | _, _ -> None
      in
      let paths = List.filter_map setups ~f:(update_file ~root:local_root) in
      let external_paths =
        let external_root = List.hd_exn search_paths |> SearchPath.get_root in
        List.filter_map external_setups ~f:(update_file ~root:external_root)
      in
      List.append external_paths paths
    in
    (* Set up the initial project *)
    let old_external_sources = get_old_inputs external_setups in
    let old_sources = get_old_inputs setups in
    let project =
      ScratchProject.setup
        ~context
        ~external_sources:old_external_sources
        ~in_memory:false
        old_sources
    in
    let configuration = ScratchProject.configuration_of project in
    let () =
      let read_only =
        ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.ast_environment project
        |> ReadWriteHelpers.read_only
      in
      (if force_load_external_sources then
         (* If we don't do this, external sources are ignored due to lazy loading *)
         let load_source { handle; _ } =
           let qualifier = ModulePath.qualifier_from_relative_path handle in
           let _ = ReadOnlyHelpers.parse_result_of_qualifier_untracked read_only qualifier in
           ()
         in
         List.iter external_setups ~f:load_source);
      if preprocess_all_sources then
        (* Preprocess invalidated modules (which are internal sources) *)
        ScratchProject.global_module_paths_api project
        |> GlobalModulePathsApi.type_check_qualifiers
        |> List.iter ~f:(fun qualifier ->
               let dependency =
                 SharedMemoryKeys.DependencyKey.Registry.register (WildcardImport qualifier)
               in
               ReadOnlyHelpers.source_of_qualifier_tracked read_only ~dependency qualifier |> ignore)
    in
    (* Update filesystem *)
    (* Compute the dependencies *)
    let invalidated_modules =
      update_filesystem_state configuration
      |> ScratchProject.update_environment project
      |> ErrorsEnvironment.UpdateResult.invalidated_modules
    in
    (* Check dependency expectations *)
    let assert_parser_dependency expected actual =
      let expected_set = Reference.Set.of_list expected in
      let actual_set = Reference.Set.of_list actual in
      if not (Set.is_subset expected_set ~of_:actual_set) then
        assert_bool
          (Format.asprintf
             "Expected dependencies %s are not a subset of actual dependencies %s"
             (Reference.Set.sexp_of_t expected_set |> Sexp.to_string)
             (Reference.Set.sexp_of_t actual_set |> Sexp.to_string))
          false;
      if not (Set.is_subset actual_set ~of_:expected_set) then
        assert_bool
          (Format.asprintf
             "Actual dependencies %s are not a subset of expected dependencies %s"
             (Reference.Set.sexp_of_t actual_set |> Sexp.to_string)
             (Reference.Set.sexp_of_t expected_set |> Sexp.to_string))
          false;
      ()
    in
    assert_parser_dependency expected_dependencies invalidated_modules;

    Memory.reset_shared_memory ()
end

let test_parser_update context =
  (* TODO (T47159596): Automatic shared memory reset for ScratchProject *)
  Memory.reset_shared_memory ();

  let open IncrementalTest in
  let assert_parser_update = assert_parser_update ~context in

  (* Single project file update *)
  assert_parser_update
    [{ handle = "test.py"; old_source = None; new_source = Some "def foo() -> None: ..." }]
    ~expected:(Expectation.create [!&"test"]);

  assert_parser_update
    [{ handle = "test.py"; old_source = Some "def foo() -> None: ..."; new_source = None }]
    ~expected:(Expectation.create [!&"test"]);
  assert_parser_update
    [
      {
        handle = "test.py";
        old_source = Some "def foo() -> None: ...";
        (* Intentionally invalid syntax *)
        new_source = Some "def foo() -> None";
      };
    ]
    ~expected:(Expectation.create [!&"test"]);
  assert_parser_update
    [
      {
        handle = "test.py";
        old_source = Some "def foo() -> None: ...";
        new_source = Some "def foo() -> None: ...";
      };
    ]
    ~expected:(Expectation.create []);
  assert_parser_update
    [
      {
        handle = "test.py";
        old_source = Some "def foo(x: int) -> None: ...";
        new_source = Some "def foo   (x  :    int)  ->    None: ...";
      };
    ]
    ~expected:(Expectation.create [!&"test"]);
  assert_parser_update
    [
      {
        handle = "test.py";
        old_source = Some "def foo() -> None: ...";
        new_source = Some "def foo(x: int) -> int: ...";
      };
    ]
    ~expected:(Expectation.create [!&"test"]);

  (* Single external file update. *)
  (* These tests rely on us force-loading sources, which causes them to be counted as invalidated.
     Otherwise, they would be ignored due to laziness. *)
  assert_parser_update
    ~external_setups:
      [{ handle = "test.pyi"; old_source = Some "def foo() -> None: ..."; new_source = None }]
    []
    ~expected:(Expectation.create [!&"test"]);
  assert_parser_update
    ~external_setups:
      [
        {
          handle = "test.pyi";
          old_source = Some "def foo() -> None: ...";
          new_source = Some "def foo() -> None: ...";
        };
      ]
    []
    ~expected:(Expectation.create []);
  assert_parser_update
    ~external_setups:
      [
        {
          handle = "test.pyi";
          old_source = Some "def foo() -> None: ...";
          new_source = Some "def foo(x: int) -> int: ...";
        };
      ]
    []
    ~expected:(Expectation.create [!&"test"]);
  assert_parser_update
    ~external_setups:
      [{ handle = "test.pyi"; old_source = None; new_source = Some "def foo() -> None: ..." }]
    []
    ~expected:(Expectation.create [!&"test"]);

  (* Multi-file updates *)
  assert_parser_update
    [
      { handle = "a.py"; old_source = None; new_source = Some "def foo() -> None: ..." };
      { handle = "b.py"; old_source = None; new_source = Some "def bar() -> None: ..." };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    [
      { handle = "a.py"; old_source = Some "def foo() -> None: ..."; new_source = None };
      { handle = "b.py"; old_source = Some "def bar() -> None: ..."; new_source = None };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    [
      { handle = "a.py"; old_source = Some "def foo() -> None: ..."; new_source = None };
      { handle = "b.py"; old_source = None; new_source = Some "def bar() -> None: ..." };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    [
      { handle = "a.py"; old_source = None; new_source = Some "def foo() -> None: ..." };
      {
        handle = "b.py";
        old_source = Some "def bar() -> None: ...";
        new_source = Some "def bar() -> None: ...";
      };
    ]
    ~expected:(Expectation.create [!&"a"]);
  assert_parser_update
    [
      {
        handle = "a.py";
        old_source = Some "def foo() -> None: ...";
        new_source = Some "def foo() -> None: ...";
      };
      { handle = "b.py"; old_source = Some "def bar() -> None: ..."; new_source = None };
    ]
    ~expected:(Expectation.create [!&"b"]);
  assert_parser_update
    ~external_setups:
      [
        {
          handle = "a.py";
          old_source = Some "def foo() -> None: ...";
          new_source = Some "def foo(x: int) -> int: ...";
        };
      ]
    [
      {
        handle = "b.py";
        old_source = Some "def bar() -> None: ...";
        new_source = Some "def bar(x: str) -> str: ...";
      };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"]);

  (* Wildcard export tests *)
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:[{ handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 1" }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create []);
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:[{ handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 2" }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:
      [{ handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 1\ny = 2" }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:
      [{ handle = "a.py"; old_source = Some "x = 1\ny = 2\n"; new_source = Some "x = 1" }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:
      [{ handle = "a.py"; old_source = Some "x = 1"; new_source = Some "def foo() -> int: ..." }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 2" };
      { handle = "b.py"; old_source = Some "y = 1"; new_source = Some "y = 2" };
      {
        handle = "c.py";
        old_source = Some "from a import *\nfrom b import *";
        new_source = Some "from a import *\nfrom b import *";
      };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"; !&"c"]);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "y = 2" };
      { handle = "b.py"; old_source = Some "y = 1"; new_source = Some "y = 1" };
      {
        handle = "c.py";
        old_source = Some "from a import *\nfrom b import *";
        new_source = Some "from a import *\nfrom b import *";
      };
    ]
    ~expected:(Expectation.create [!&"a"; !&"c"]);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 1" };
      { handle = "b.py"; old_source = Some "y = 1"; new_source = Some "x = 2" };
      {
        handle = "c.py";
        old_source = Some "from a import *\nfrom b import *";
        new_source = Some "from a import *\nfrom b import *";
      };
    ]
    ~expected:(Expectation.create [!&"b"; !&"c"]);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 1" };
      { handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" };
      { handle = "c.py"; old_source = Some "from b import *"; new_source = Some "from b import *" };
    ]
    ~expected:(Expectation.create []);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "x = 2" };
      { handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" };
      { handle = "c.py"; old_source = Some "from b import *"; new_source = Some "from b import *" };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"; !&"c"]);
  assert_parser_update
    ~preprocess_all_sources:true
    [
      { handle = "a.py"; old_source = Some "x = 1"; new_source = Some "y = 1" };
      { handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" };
      { handle = "c.py"; old_source = Some "from b import *"; new_source = Some "from b import *" };
    ]
    ~expected:(Expectation.create [!&"a"; !&"b"; !&"c"]);

  (* This is expected -- the parser knows only names, not types *)
  assert_parser_update
    ~preprocess_all_sources:true
    ~external_setups:
      [{ handle = "a.py"; old_source = Some "x = 1"; new_source = Some "def x() -> None: ..." }]
    [{ handle = "b.py"; old_source = Some "from a import *"; new_source = Some "from a import *" }]
    ~expected:(Expectation.create [!&"a"; !&"b"]);
  ()


let make_overlay_testing_functions ~context ~test_sources =
  let project = ScratchProject.setup ~context test_sources in
  let local_root = ScratchProject.local_root_of project in
  let parent = ScratchProject.ReadWrite.AssumeBackedByAstEnvironment.ast_environment project in
  let parent_read_only = ReadWriteHelpers.read_only parent in
  let overlay_environment = ReadWriteHelpers.overlay parent in
  let read_only = SourceCodeIncrementalApi.Overlay.read_only overlay_environment in
  let source_of_module_paths qualifier =
    let unpack_result = function
      (* Getting good failure errors here is important because it is easy to mess up indentation *)
      | Some (Ok source) -> source
      | Some (Error { Parsing.ParseResult.Error.message; _ }) ->
          failwith ("Loading source failed with message: " ^ message)
      | None -> failwith "Loading source produced None"
    in
    ( ReadOnlyHelpers.parse_result_of_qualifier_untracked parent_read_only qualifier |> unpack_result,
      ReadOnlyHelpers.parse_result_of_qualifier_untracked read_only qualifier |> unpack_result )
  in
  let assert_not_overlaid qualifier =
    let from_parent, from_overlay = source_of_module_paths qualifier in
    assert_equal ~ctxt:context ~printer:Source.show from_parent from_overlay
  in
  let assert_is_overlaid qualifier =
    let from_parent, from_overlay = source_of_module_paths qualifier in
    [%compare.equal: Source.t] from_parent from_overlay
    |> not
    |> assert_bool "Sources should be different, but are not"
  in
  let update_and_assert_invalidated_modules ~relative ~code ~expected =
    let invalidated_modules =
      let code_updates =
        [
          ( Test.relative_artifact_path ~root:local_root ~relative,
            SourceCodeIncrementalApi.Overlay.CodeUpdate.NewCode (trim_extra_indentation code) );
        ]
      in
      SourceCodeIncrementalApi.Overlay.update_overlaid_code overlay_environment ~code_updates
      |> SourceCodeIncrementalApi.UpdateResult.invalidated_modules
      |> List.sort ~compare:Reference.compare
    in
    assert_equal ~ctxt:context ~printer:[%show: Reference.t list] expected invalidated_modules
  in
  read_only, assert_not_overlaid, assert_is_overlaid, update_and_assert_invalidated_modules


let test_overlay context =
  let read_only, assert_not_overlaid, assert_is_overlaid, update_and_assert_invalidated_modules =
    let test_sources =
      [
        ( "module.py",
          trim_extra_indentation
            {|
            def foo(x: int) -> int:
              return x
            |} );
        ( "depends_on_module.py",
          trim_extra_indentation
            {|
            from module import *

            def bar(y: str) -> str:
              return "hello" + y
            |}
        );
        ( "does_not_depend.py",
          trim_extra_indentation
            {|
            def baz() -> int:
              return 42
            |} );
      ]
    in
    make_overlay_testing_functions ~context ~test_sources
  in
  (* Verify read-only behavior before update *)
  assert_not_overlaid !&"module";
  assert_not_overlaid !&"depends_on_module";
  assert_not_overlaid !&"does_not_depend";
  (* Perform the initial update *)
  update_and_assert_invalidated_modules
    ~relative:"module.py"
    ~code:{|
      def foo(x: str) -> str:
        return x
      |}
    ~expected:[!&"module"];
  (* Verify read-only behavior after update *)
  assert_is_overlaid !&"module";
  assert_not_overlaid !&"depends_on_module";
  assert_not_overlaid !&"does_not_depend";
  (* Verify wildcard import handling on a subsequent update. Note that the initial update can never
     trigger dependencies, because lazy loading means dependencies are not registered until they are
     used. *)
  let () =
    ReadOnlyHelpers.source_of_qualifier_tracked
      read_only
      ~dependency:
        (SharedMemoryKeys.DependencyKey.Registry.register (WildcardImport !&"depends_on_module"))
      !&"depends_on_module"
    |> Option.is_some
    |> assert_bool "Expected to be able to load processed source for b.py"
  in
  update_and_assert_invalidated_modules
    ~relative:"module.py"
    ~code:{|
      def foo(x: float) -> float:
        return x
      |}
    ~expected:[!&"module"];
  ()


let () =
  Test.sanitized_module_name __MODULE__
  >::: [
         "basic" >:: test_basic;
         "parse_stubs_modules_list" >:: test_parse_stubs_modules_list;
         "parse_source" >:: test_parse_source;
         "parse_sources" >:: test_parse_sources;
         "ast_change" >:: test_ast_change;
         "parse_repository" >:: test_parse_repository;
         "parser_update" >:: test_parser_update;
         "test_overlay" >:: test_overlay;
       ]
  |> Test.run
