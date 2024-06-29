(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Base
open OUnit2
open TestHelper
module Request = CodeNavigationServer.Testing.Request
module Response = CodeNavigationServer.Testing.Response
module BuildSystem = CodeNavigationServer.BuildSystem

let assert_artifact_events_equal ~context ~expected actual =
  assert_equal
    ~ctxt:context
    ~cmp:[%compare.equal: ArtifactPath.Event.t list]
    ~printer:(fun event -> Sexp.to_string_hum ([%sexp_of: ArtifactPath.Event.t list] event))
    (List.sort ~compare:ArtifactPath.Event.compare expected)
    (List.sort ~compare:ArtifactPath.Event.compare actual)


let create_buck_build_system_initializer_for_testing
    ~source_root
    ~artifact_root
    ~construct_build_map
    ()
  =
  Buck.Interface.Lazy.create_for_testing ~construct_build_map ()
  |> Buck.Builder.Lazy.create ~source_root ~artifact_root
  |> BuildSystem.Initializer.buck ~artifact_root


let create_buck_build_system_for_testing ~source_root ~artifact_root ~construct_build_map () =
  create_buck_build_system_initializer_for_testing
    ~source_root
    ~artifact_root
    ~construct_build_map
    ()
  |> BuildSystem.Initializer.initialize


let create_build_system_initializer_for_testing
    ?update_working_set
    ?update_sources
    ?lookup_source
    ?lookup_artifact
    ?(cleanup = fun () -> ())
    ()
  =
  let initialize () =
    BuildSystem.create_for_testing
      ?update_working_set
      ?update_sources
      ?lookup_source
      ?lookup_artifact
      ()
  in
  BuildSystem.Initializer.create_for_testing ~initialize ~cleanup ()


(* Construct a simple build map { artifact0: source0, artifact1: source1 } for testing, shrink the
   map accordingly if source0 or source1 is not included in the working set. *)
let construct_two_file_build_map working_set =
  let mappings = [] in
  let mappings =
    if List.exists working_set ~f:(String.equal "source0.py") then
      ("artifact0.py", "source0.py") :: mappings
    else
      mappings
  in
  let mappings =
    if List.exists working_set ~f:(String.equal "source1.py") then
      ("artifact1.py", "source1.py") :: mappings
    else
      mappings
  in
  Buck.BuildMap.(Partial.of_alist_exn mappings |> create) |> Lwt.return


let test_buck_update_working_set context =
  let source_root = bracket_tmpdir context |> PyrePath.create_absolute in
  let artifact_root = bracket_tmpdir context |> PyrePath.create_absolute in
  let raw_source_path0 = PyrePath.create_relative ~root:source_root ~relative:"source0.py" in
  let raw_source_path1 = PyrePath.create_relative ~root:source_root ~relative:"source1.py" in
  File.create raw_source_path0 ~content:"" |> File.write;
  File.create raw_source_path1 ~content:"" |> File.write;
  let source_path0 = SourcePath.create raw_source_path0 in
  let source_path1 = SourcePath.create raw_source_path1 in
  let artifact_path0 =
    PyrePath.create_relative ~root:artifact_root ~relative:"artifact0.py" |> ArtifactPath.create
  in
  let artifact_path1 =
    PyrePath.create_relative ~root:artifact_root ~relative:"artifact1.py" |> ArtifactPath.create
  in

  let build_system =
    create_buck_build_system_for_testing
      ~source_root
      ~artifact_root
      ~construct_build_map:construct_two_file_build_map
      ()
  in

  let%lwt result = BuildSystem.update_working_set build_system [source_path0] in
  assert_artifact_events_equal
    ~context
    ~expected:[ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged artifact_path0)]
    result;

  let%lwt result = BuildSystem.update_working_set build_system [source_path0; source_path1] in
  assert_artifact_events_equal
    ~context
    ~expected:[ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged artifact_path1)]
    result;

  let%lwt result = BuildSystem.update_working_set build_system [] in
  assert_artifact_events_equal
    ~context
    ~expected:
      [
        ArtifactPath.Event.(create ~kind:Kind.Deleted artifact_path0);
        ArtifactPath.Event.(create ~kind:Kind.Deleted artifact_path1);
      ]
    result;
  Lwt.return_unit


let test_buck_update_sources context =
  let source_root = bracket_tmpdir context |> PyrePath.create_absolute in
  let artifact_root = bracket_tmpdir context |> PyrePath.create_absolute in
  let raw_source_path0 = PyrePath.create_relative ~root:source_root ~relative:"source0.py" in
  let raw_source_path1 = PyrePath.create_relative ~root:source_root ~relative:"source1.py" in
  File.create raw_source_path0 ~content:"" |> File.write;
  File.create raw_source_path1 ~content:"" |> File.write;
  let source_path0 = SourcePath.create raw_source_path0 in
  let source_path1 = SourcePath.create raw_source_path1 in

  let update_build_map_flag = ref false in
  let build_system =
    let construct_build_map _ =
      (* Note how the build map does not vary with working set. This means working set values do not
         matter in this test. *)
      if not !update_build_map_flag then
        Buck.BuildMap.(Partial.of_alist_exn ["artifact0.py", "source0.py"] |> create) |> Lwt.return
      else
        Buck.BuildMap.(Partial.of_alist_exn ["artifact1.py", "source1.py"] |> create) |> Lwt.return
    in
    create_buck_build_system_for_testing ~source_root ~artifact_root ~construct_build_map ()
  in
  let%lwt _ =
    (* Force the lazy builder to populate the initial build map. *)
    BuildSystem.update_working_set build_system []
  in

  let%lwt result =
    BuildSystem.update_sources
      build_system
      ~working_set:[]
      [SourcePath.Event.(create ~kind:Kind.CreatedOrChanged source_path0)]
  in
  assert_artifact_events_equal ~context ~expected:[] result;

  let%lwt result =
    BuildSystem.update_sources
      build_system
      ~working_set:[]
      [SourcePath.Event.(create ~kind:Kind.CreatedOrChanged source_path1)]
  in
  assert_artifact_events_equal ~context ~expected:[] result;

  let%lwt result =
    BuildSystem.update_sources
      build_system
      ~working_set:[]
      [
        SourcePath.Event.(create ~kind:Kind.CreatedOrChanged source_path0);
        SourcePath.Event.(create ~kind:Kind.CreatedOrChanged source_path1);
      ]
  in
  assert_artifact_events_equal ~context ~expected:[] result;

  let source_path2 =
    PyrePath.create_relative ~root:source_root ~relative:"BUCK" |> SourcePath.create
  in
  let%lwt result =
    BuildSystem.update_sources
      build_system
      ~working_set:[]
      [SourcePath.Event.(create ~kind:Kind.CreatedOrChanged source_path2)]
  in
  assert_artifact_events_equal ~context ~expected:[] result;

  update_build_map_flag := true;
  PyrePath.unlink_if_exists raw_source_path0;
  let artifact_path0 =
    PyrePath.create_relative ~root:artifact_root ~relative:"artifact0.py" |> ArtifactPath.create
  in
  let artifact_path1 =
    PyrePath.create_relative ~root:artifact_root ~relative:"artifact1.py" |> ArtifactPath.create
  in
  let%lwt result =
    BuildSystem.update_sources
      build_system
      ~working_set:[]
      [SourcePath.Event.(create ~kind:Kind.Deleted source_path0)]
  in
  assert_artifact_events_equal
    ~context
    ~expected:
      [
        ArtifactPath.Event.(create ~kind:Kind.Deleted artifact_path0);
        ArtifactPath.Event.(create ~kind:Kind.CreatedOrChanged artifact_path1);
      ]
    result;
  Lwt.return_unit


let test_build_system_path_lookup context =
  let project =
    let build_system_initializer =
      (* We create a fake build system that always translate artifacts with name "a.py" into sources
         with name "b.py" under the same directory *)
      let lookup_source artifact_path =
        let raw_path = ArtifactPath.raw artifact_path in
        if String.equal (PyrePath.last raw_path) "a.py" then
          PyrePath.create_relative ~root:(PyrePath.get_directory raw_path) ~relative:"b.py"
          |> SourcePath.create
          |> Option.some
        else
          None
      in
      let lookup_artifact source_path =
        let raw_path = SourcePath.raw source_path in
        if String.equal (PyrePath.last raw_path) "b.py" then
          [
            PyrePath.create_relative ~root:(PyrePath.get_directory raw_path) ~relative:"a.py"
            |> ArtifactPath.create;
          ]
        else
          []
      in
      create_build_system_initializer_for_testing ~lookup_source ~lookup_artifact ()
    in
    ScratchProject.setup
      ~context
      ~build_system_initializer
      ["a.py", "x: float = 4.2\nreveal_type(x)"]
  in
  let root = ScratchProject.source_root_of project in
  let path_a = PyrePath.create_relative ~root ~relative:"a.py" |> PyrePath.absolute in
  let path_b = PyrePath.create_relative ~root ~relative:"b.py" |> PyrePath.absolute in
  let path_c = PyrePath.create_relative ~root ~relative:"c.py" |> PyrePath.absolute in
  let expected_error =
    Analysis.AnalysisError.Instantiated.of_yojson
      (`Assoc
        [
          "line", `Int 2;
          "column", `Int 0;
          "stop_line", `Int 2;
          "stop_column", `Int 11;
          (* Paths in type errors always refer to source paths *)
          "path", `String path_b;
          "code", `Int (-1);
          "name", `String "Revealed type";
          "description", `String "Revealed type [-1]: Revealed type for `x` is `float`.";
          "long_description", `String "Revealed type [-1]: Revealed type for `x` is `float`.";
          "concise_description", `String "Revealed type [-1]: Revealed type for `x` is `float`.";
          (* Note how the module qualifier a does not match the file path b.py due to build system
             path translation *)
          "define", `String "a.$toplevel";
        ])
    |> Result.ok_or_failwith
  in
  let open TestHelper in
  let client_id = "foo" in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        register_client ~client_id;
        (* Server should not be aware of `a.py` on type error query *)
        ScratchProject.ClientConnection.assert_error_response
          ~request:Request.(Query (Query.GetTypeErrors { paths = [path_a]; client_id }))
          ~kind:"FileNotOpened";
        (* Server should be aware of `a.py` on gotodef query *)
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              Query
                (Query.LocationOfDefinition { path = path_a; client_id; position = position 2 12 }))
          ~expected:
            Response.(
              LocationOfDefinition
                {
                  definitions = [{ DefinitionLocation.path = path_b; range = range 1 0 1 1 }];
                  empty_reason = None;
                  duration = 0.;
                });
        (* Try open `a.py` (no artifact path), `b.py` (artifact path), and `c.py` (nonexistent) *)
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(Command (Command.FileOpened { path = path_a; content = None; client_id }))
          ~expected:Response.Ok_;
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(Command (Command.FileOpened { path = path_b; content = None; client_id }))
          ~expected:Response.Ok_;
        ScratchProject.ClientConnection.assert_error_response
          ~request:
            Request.(Command (Command.FileOpened { path = path_c; content = None; client_id }))
          ~kind:"ModuleNotTracked";
        (* Server should be aware of `b.py` on type error query *)
        ScratchProject.ClientConnection.assert_response
          ~request:Request.(Query (Query.GetTypeErrors { paths = [path_b]; client_id }))
          ~expected:(Response.TypeErrors { errors = [expected_error] });
        (* Server should be aware of `b.py` on gotodef query *)
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              (* This location points to `x` in "reveal_type(x)" *)
              Query
                (Query.LocationOfDefinition { client_id; path = path_b; position = position 2 12 }))
          ~expected:
            Response.(
              LocationOfDefinition
                {
                  definitions = [{ DefinitionLocation.path = path_b; range = range 1 0 1 1 }];
                  empty_reason = None;
                  duration = 0.;
                });
      ]


let assert_file_not_opened ~client_id path =
  ScratchProject.ClientConnection.assert_error_response
    ~request:Request.(Query (Query.GetTypeErrors { paths = [PyrePath.absolute path]; client_id }))
    ~kind:"FileNotOpened"


let test_build_system_open_close context =
  let source_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let artifact_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let raw_source_path0 = PyrePath.create_relative ~root:source_root ~relative:"source0.py" in
  let raw_source_path1 = PyrePath.create_relative ~root:source_root ~relative:"source1.py" in
  File.create raw_source_path0 ~content:"reveal_type(0)" |> File.write;
  File.create raw_source_path1 ~content:"reveal_type(1)\nreveal_type(2)" |> File.write;

  let project =
    let build_system_initializer =
      create_buck_build_system_initializer_for_testing
        ~source_root
        ~artifact_root
        ~construct_build_map:construct_two_file_build_map
        ()
    in
    ScratchProject.setup
      ~context
      ~source_root:artifact_root
      ~filter_directories:[source_root]
      ~build_system_initializer
      []
  in
  let open TestHelper in
  let client_id = "foo" in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        (* Register client *)
        register_client ~client_id;
        (* Initially nothing exists *)
        assert_file_not_opened ~client_id raw_source_path0;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Open source0.py *)
        open_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        assert_type_error_count_for_path
          ~client_id
          ~path:(PyrePath.absolute raw_source_path0)
          ~expected:1;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Open source1.py *)
        open_file ~path:(PyrePath.absolute raw_source_path1) ~client_id;
        assert_type_error_count_for_path
          ~client_id
          ~path:(PyrePath.absolute raw_source_path1)
          ~expected:2;
        assert_type_error_count_for_path
          ~client_id
          ~path:(PyrePath.absolute raw_source_path0)
          ~expected:1;
        (* Close source0.py *)
        close_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        assert_file_not_opened ~client_id raw_source_path0;
        assert_type_error_count_for_path
          ~client_id
          ~path:(PyrePath.absolute raw_source_path1)
          ~expected:2;
        (* Close source1.py *)
        close_file ~path:(PyrePath.absolute raw_source_path1) ~client_id;
        assert_file_not_opened ~client_id raw_source_path0;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Dispose client *)
        dispose_client ~client_id;
      ]


let assert_single_file_update path =
  ScratchProject.ClientConnection.assert_response
    ~request:
      Request.(
        Command
          (Command.FileUpdate
             [
               {
                 FileUpdateEvent.path = PyrePath.absolute path;
                 kind = FileUpdateEvent.Kind.CreatedOrChanged;
               };
             ]))
    ~expected:Response.Ok_


let test_build_system_file_update context =
  let source_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let artifact_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let raw_source_path0 = PyrePath.create_relative ~root:source_root ~relative:"source0.py" in
  let raw_source_path1 = PyrePath.create_relative ~root:source_root ~relative:"source1.py" in
  let other_path = PyrePath.create_relative ~root:source_root ~relative:"BUCK" in
  File.create raw_source_path1 ~content:"reveal_type(1)" |> File.write;
  File.create other_path ~content:"" |> File.write;

  let update_flag = ref false in
  let project =
    let build_system_initializer =
      let construct_build_map _ =
        let mappings =
          if not !update_flag then
            ["artifact0.py", "source1.py"]
          else
            ["artifact0.py", "source0.py"; "artifact1.py", "source1.py"]
        in
        Buck.BuildMap.(Partial.of_alist_exn mappings |> create) |> Lwt.return
      in
      create_buck_build_system_initializer_for_testing
        ~source_root
        ~artifact_root
        ~construct_build_map
        ()
    in
    ScratchProject.setup
      ~context
      ~source_root:artifact_root
      ~filter_directories:[source_root]
      ~build_system_initializer
      []
  in
  let open TestHelper in
  let client_id = "foo" in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        register_client ~client_id;
        (* Initial request to just get the link tree populated *)
        assert_single_file_update other_path;
        assert_file_not_opened ~client_id raw_source_path1;
        open_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:1;
        close_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        (* Update pre-existing file in build map *)
        (fun _ ->
          File.create raw_source_path1 ~content:"reveal_type(2)\nreveal_type(3)" |> File.write;
          Lwt.return_unit);
        assert_single_file_update raw_source_path1;
        open_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:2;
        close_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        (* Update build map *)
        (fun _ ->
          update_flag := true;
          File.create raw_source_path0 ~content:"reveal_type(0)" |> File.write;
          Lwt.return_unit);
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              Command
                (Command.FileUpdate
                   [
                     {
                       FileUpdateEvent.path = PyrePath.absolute raw_source_path0;
                       kind = FileUpdateEvent.Kind.CreatedOrChanged;
                     };
                     {
                       FileUpdateEvent.path = PyrePath.absolute other_path;
                       kind = FileUpdateEvent.Kind.CreatedOrChanged;
                     };
                   ]))
          ~expected:Response.Ok_;
        open_file ~client_id ~path:(PyrePath.absolute raw_source_path0);
        open_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path0)
          ~client_id
          ~expected:1;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:2;
        close_file ~client_id ~path:(PyrePath.absolute raw_source_path0);
        close_file ~client_id ~path:(PyrePath.absolute raw_source_path1);
        dispose_client ~client_id;
      ]


let test_build_system_external_file_update context =
  let source_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let artifact_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let external_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let external_path = PyrePath.create_relative ~root:external_root ~relative:"external.py" in

  let project =
    let build_system_initializer =
      let construct_build_map _ = Buck.BuildMap.(Partial.of_alist_exn [] |> create) |> Lwt.return in
      create_buck_build_system_initializer_for_testing
        ~source_root
        ~artifact_root
        ~construct_build_map
        ()
    in
    ScratchProject.setup
      ~context
      ~source_root:artifact_root
      ~filter_directories:[source_root]
      ~build_system_initializer
      ~external_root
      []
  in
  let open TestHelper in
  let client_id = "foo" in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        register_client ~client_id;
        assert_file_not_opened ~client_id external_path;
        (fun _ ->
          File.create external_path ~content:"print('test')" |> File.write;
          Lwt.return_unit);
        assert_single_file_update external_path;
        open_file ~client_id ~path:(PyrePath.absolute external_path);
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              Command
                (Command.FileUpdate
                   [
                     {
                       FileUpdateEvent.path = PyrePath.absolute external_path;
                       kind = FileUpdateEvent.Kind.CreatedOrChanged;
                     };
                   ]))
          ~expected:Response.Ok_;
        (* Ensure not ModuleNotTracked *)
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute external_path)
          ~client_id
          ~expected:0;
        close_file ~client_id ~path:(PyrePath.absolute external_path);
        dispose_client ~client_id;
      ]


let test_build_system_file_open_and_update context =
  let source_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let artifact_root =
    bracket_tmpdir context |> PyrePath.create_absolute ~follow_symbolic_links:true
  in
  let raw_source_path0 = PyrePath.create_relative ~root:source_root ~relative:"source0.py" in
  let raw_source_path1 = PyrePath.create_relative ~root:source_root ~relative:"source1.py" in
  File.create raw_source_path0 ~content:"" |> File.write;
  File.create raw_source_path1 ~content:"reveal_type(0)" |> File.write;

  let project =
    let build_system_initializer =
      create_buck_build_system_initializer_for_testing
        ~source_root
        ~artifact_root
        ~construct_build_map:construct_two_file_build_map
        ()
    in
    ScratchProject.setup
      ~context
      ~source_root:artifact_root
      ~filter_directories:[source_root]
      ~build_system_initializer
      []
  in
  let open TestHelper in
  let client_id = "foo" in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        (* Register client *)
        register_client ~client_id;
        (* Initially nothing exists *)
        assert_file_not_opened ~client_id raw_source_path0;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Open source0.py *)
        open_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path0)
          ~client_id
          ~expected:0;
        assert_file_not_opened ~client_id raw_source_path1;
        close_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        (* Update source0.py *)
        (fun _ ->
          File.create raw_source_path0 ~content:"reveal_type(1)" |> File.write;
          Lwt.return_unit);
        assert_single_file_update raw_source_path0;
        open_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path0)
          ~client_id
          ~expected:1;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Update source1.py (should have no effect) *)
        (fun _ ->
          File.create raw_source_path1 ~content:"reveal_type(0)\nreveal_type(2)" |> File.write;
          Lwt.return_unit);
        assert_single_file_update raw_source_path1;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path0)
          ~client_id
          ~expected:1;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Open source1.py *)
        open_file ~path:(PyrePath.absolute raw_source_path1) ~client_id;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path0)
          ~client_id
          ~expected:1;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:2;
        (* Close source0.py *)
        close_file ~path:(PyrePath.absolute raw_source_path0) ~client_id;
        assert_file_not_opened ~client_id raw_source_path0;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:2;
        (* Update source0.py (should have no effect) *)
        (fun _ ->
          File.create raw_source_path0 ~content:"" |> File.write;
          Lwt.return_unit);
        assert_single_file_update raw_source_path0;
        assert_file_not_opened ~client_id raw_source_path0;
        assert_type_error_count_for_path
          ~path:(PyrePath.absolute raw_source_path1)
          ~client_id
          ~expected:2;
        (* Close source1.py *)
        close_file ~path:(PyrePath.absolute raw_source_path1) ~client_id;
        assert_file_not_opened ~client_id raw_source_path0;
        assert_file_not_opened ~client_id raw_source_path1;
        (* Dispose client *)
        dispose_client ~client_id;
      ]


let test_build_system_failure_in_update_sources context =
  let fail_switch = ref false in
  let update_sources ~working_set:_ _source_paths =
    if !fail_switch then
      raise
        Buck.Raw.(
          BuckError
            {
              buck_command = "fake_buck";
              arguments = ArgumentList.empty;
              description = "fake description";
              exit_code = None;
              additional_logs = [];
            })
    else
      Lwt.return []
  in
  let build_system_initializer = create_build_system_initializer_for_testing ~update_sources () in
  let file_path = "test.py" in
  let sources = [file_path, "x: float = 4.1"] in
  let project =
    ScratchProject.setup ~context ~build_system_initializer ~include_typeshed_stubs:false sources
  in
  let source_root = ScratchProject.source_root_of project in
  let path = PyrePath.append source_root ~element:file_path |> PyrePath.absolute in
  let client_id = "foo" in
  let inject_error ?(error = true) _ =
    fail_switch := error;
    Lwt.return ()
  in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        register_client ~client_id;
        open_file ~client_id ~path;
        assert_hover_contents ~client_id ~path ~position:(position 1 0) ~expected:(Some "float");
        inject_error;
        (* File update should succeed with Respnse.Ok even though it errored. *)
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(Command (Command.FileUpdate [FileUpdateEvent.{ kind = Kind.Deleted; path }]))
          ~expected:Response.Ok_;
        (* Should rely on old file while build system is broken. *)
        assert_hover_contents ~client_id ~path ~position:(position 1 0) ~expected:(Some "float");
        inject_error ~error:false;
        (* Unrelated file update should process the deferred update. *)
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              Command
                (Command.FileUpdate
                   [FileUpdateEvent.{ kind = Kind.CreatedOrChanged; path = "fake path" }]))
          ~expected:Response.Ok_;
        (* File should no loger exist until FileUpdateEvent adds it back. *)
        ScratchProject.ClientConnection.assert_error_response
          ~request:Request.(Query (Query.Hover { client_id; path; position = position 1 0 }))
          ~kind:"ModuleNotTracked";
        ScratchProject.ClientConnection.assert_response
          ~request:
            Request.(
              Command (Command.FileUpdate [FileUpdateEvent.{ kind = Kind.CreatedOrChanged; path }]))
          ~expected:Response.Ok_;
        assert_hover_contents ~client_id ~path ~position:(position 1 0) ~expected:(Some "float");
      ]


let test_build_system_failure_in_update_working_set context =
  let fail_switch = ref false in
  let update_working_set _ =
    if !fail_switch then
      raise
        Buck.Raw.(
          BuckError
            {
              buck_command = "fake_buck";
              arguments = ArgumentList.empty;
              description = "fake description";
              exit_code = None;
              additional_logs = [];
            })
    else
      Lwt.return []
  in
  let build_system_initializer =
    create_build_system_initializer_for_testing ~update_working_set ()
  in
  let file_path = "test.py" in
  let sources = [file_path, "x: float = 4.1"] in
  let project =
    ScratchProject.setup ~context ~build_system_initializer ~include_typeshed_stubs:false sources
  in
  let source_root = ScratchProject.source_root_of project in
  let path = PyrePath.append source_root ~element:file_path |> PyrePath.absolute in
  let client_id = "foo" in
  let inject_error ?(error = true) _ =
    fail_switch := error;
    Lwt.return ()
  in
  ScratchProject.test_server_with
    project
    ~style:ScratchProject.ClientConnection.Style.Sequential
    ~clients:
      [
        register_client ~client_id;
        open_file ~client_id ~path;
        assert_hover_contents ~client_id ~path ~position:(position 1 0) ~expected:(Some "float");
        inject_error;
        (* File should be open even though there was a build system error. *)
        ScratchProject.ClientConnection.assert_response
          ~request:Request.(Command (Command.FileOpened { content = None; path; client_id }))
          ~expected:Response.Ok_;
        assert_hover_contents ~client_id ~path ~position:(position 1 0) ~expected:(Some "float");
      ]


let () =
  "build_system_test"
  >::: [
         "test_buck_updaet_working_set" >:: OUnitLwt.lwt_wrapper test_buck_update_working_set;
         "test_buck_update_sources" >:: OUnitLwt.lwt_wrapper test_buck_update_sources;
         "test_build_system_path_lookup" >:: OUnitLwt.lwt_wrapper test_build_system_path_lookup;
         "test_build_system_open_close" >:: OUnitLwt.lwt_wrapper test_build_system_open_close;
         "test_build_system_file_update" >:: OUnitLwt.lwt_wrapper test_build_system_file_update;
         "test_build_system_file_open_and_update"
         >:: OUnitLwt.lwt_wrapper test_build_system_file_open_and_update;
         "test_build_system_failure_in_update_sources"
         >:: OUnitLwt.lwt_wrapper test_build_system_failure_in_update_sources;
         "test_build_system_failure_in_update_working_set"
         >:: OUnitLwt.lwt_wrapper test_build_system_failure_in_update_working_set;
         "test_build_system_external_file_update"
         >:: OUnitLwt.lwt_wrapper test_build_system_external_file_update;
       ]
  |> Test.run
