(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Test

let ( ! ) = PyrePath.create_absolute

let root context =
  let path = bracket_tmpdir context in
  let root = !path in
  path, root


let touch path = Stdio.Out_channel.write_all (PyrePath.absolute path) ~data:""

let test_create context =
  let path, root = root context in
  (* Create absolute paths. *)
  assert_equal (root |> PyrePath.show) path;

  (* Create relative paths. *)
  assert_equal
    (PyrePath.create_relative ~root ~relative:"some/path" |> PyrePath.show)
    (path ^/ "some/path");
  assert_equal
    (PyrePath.create_relative ~root ~relative:"/other/root/some/path" |> PyrePath.show)
    (path ^/ "other/root/some/path");
  ()


let test_absolute context =
  let path, root = root context in
  assert_equal
    (PyrePath.create_relative ~root ~relative:"some/path" |> PyrePath.absolute)
    (path ^/ "some/path");
  ()


let test_get_relative_to_root context =
  let _, root = root context in
  let some = PyrePath.create_relative ~root ~relative:"some/" in
  let relative = PyrePath.create_relative ~root:some ~relative:"path" in
  let unrelated = PyrePath.create_relative ~root ~relative:"other" in
  assert_equal (PyrePath.get_relative_to_root ~root ~path:relative) (Some "some/path");
  assert_equal (PyrePath.get_relative_to_root ~root:some ~path:relative) (Some "path");
  assert_equal (PyrePath.get_relative_to_root ~root:some ~path:unrelated) None;
  assert_equal (PyrePath.get_relative_to_root ~root ~path:unrelated) (Some "other")


let test_directory_exists context =
  let path, _ = bracket_tmpfile context in
  assert_false (!path |> PyrePath.directory_exists);
  let path = bracket_tmpdir context in
  assert_true (!path |> PyrePath.directory_exists)


let test_is_python_file _ =
  let assert_stub ~path expected =
    let actual = PyrePath.is_path_python_stub path in
    if expected then assert_true actual else assert_false actual
  in
  let assert_init ~path expected =
    let actual = PyrePath.is_path_python_init path in
    if expected then assert_true actual else assert_false actual
  in
  assert_stub ~path:"test.py" false;
  assert_stub ~path:"test.pyi" true;
  assert_stub ~path:"durp/test.pyi" true;
  assert_init ~path:"test.py" false;
  assert_init ~path:"test.pyi" false;
  assert_init ~path:"__init__.py" true;
  assert_init ~path:"__init__.pyi" true;
  assert_init ~path:"durp/__init__.py" true;
  assert_init ~path:"durp/__init__.pyi" true;

  assert_stub ~path:"root/test" false;
  assert_stub ~path:"root/test.py" false;
  assert_stub ~path:"root/test.pyi" true;
  assert_stub ~path:"root/durp/test.pyi" true;
  assert_init ~path:"root/test.py" false;
  assert_init ~path:"root/test.pyi" false;
  assert_init ~path:"root/__init__.py" true;
  assert_init ~path:"root/__init__.pyi" true;
  assert_init ~path:"root/durp/__init__.py" true;
  assert_init ~path:"root/durp/__init__.pyi" true


let test_file_exists context =
  let path, _ = bracket_tmpfile context in
  assert_true (!path |> PyrePath.file_exists);
  assert_false (PyrePath.create_relative ~root:!path ~relative:"durp" |> PyrePath.file_exists)


let test_last context =
  let _, root = root context in
  assert_equal (PyrePath.last (PyrePath.create_relative ~root ~relative:"some")) "some";
  assert_equal (PyrePath.last (PyrePath.create_relative ~root ~relative:"some/path")) "path"


let test_get_directory context =
  let _, root = root context in
  let assert_get_directory ~expected path =
    let actual = PyrePath.get_directory path in
    assert_equal ~printer:PyrePath.show ~cmp:PyrePath.equal expected actual
  in
  let create_absolute = PyrePath.create_absolute in
  assert_get_directory (create_absolute "/") ~expected:(create_absolute "/");
  assert_get_directory (create_absolute "/foo") ~expected:(create_absolute "/");
  assert_get_directory (create_absolute "/foo/bar") ~expected:(create_absolute "/foo");
  assert_get_directory (create_absolute "/foo/bar/baz") ~expected:(create_absolute "/foo/bar");
  assert_get_directory (PyrePath.create_relative ~root ~relative:"foo") ~expected:root;
  assert_get_directory
    (PyrePath.create_relative ~root ~relative:"foo/bar")
    ~expected:(PyrePath.create_relative ~root ~relative:"foo");
  assert_get_directory
    (PyrePath.create_relative ~root ~relative:"foo/bar/baz")
    ~expected:(PyrePath.create_relative ~root ~relative:"foo/bar")


let test_directory_contains context =
  let _, root = root context in
  assert_equal
    (PyrePath.directory_contains
       ~directory:root
       (PyrePath.create_relative ~root ~relative:"nonexistent.py"))
    true;
  assert_equal
    (PyrePath.directory_contains
       ~directory:(PyrePath.create_relative ~root ~relative:"non")
       (PyrePath.create_relative ~root ~relative:"nonexistent.py"))
    false


let test_create_directory_recursively context =
  let _, root = root context in
  let first_level = PyrePath.create_relative ~root ~relative:"a" in
  let second_level = PyrePath.create_relative ~root:first_level ~relative:"b" in
  let third_level = PyrePath.create_relative ~root:second_level ~relative:"c" in
  PyrePath.create_directory_recursively third_level |> Result.ok_or_failwith;

  assert_true (PyrePath.directory_exists first_level);
  assert_true (PyrePath.directory_exists second_level);
  assert_true (PyrePath.directory_exists third_level);
  ()


let test_unlink_if_exists context =
  let path, _ = bracket_tmpfile context in
  let path = !path in
  assert_true (PyrePath.file_exists path);
  PyrePath.unlink_if_exists path;
  assert_false (PyrePath.file_exists path);
  PyrePath.unlink_if_exists path


let test_remove_contents_of_directory context =
  let assert_success path =
    PyrePath.remove_contents_of_directory path |> Result.ok_or_failwith;
    let elements = PyrePath.read_directory_ordered path in
    assert_true (List.is_empty elements)
  in
  let assert_failure path =
    match PyrePath.remove_contents_of_directory path with
    | Result.Ok () -> assert_failure "Unexpected success on `ensure_parent_directory`"
    | _ -> ()
  in

  let _, root = root context in
  (* Empty directory *)
  let root0 = PyrePath.create_relative ~root ~relative:"test0" in
  CamlUnix.mkdir (PyrePath.absolute root0) 0o777;
  assert_success root0;

  (* Files *)
  let root1 = PyrePath.create_relative ~root ~relative:"test1" in
  CamlUnix.mkdir (PyrePath.absolute root1) 0o777;
  touch (PyrePath.create_relative ~root:root1 ~relative:"file");
  assert_success root1;

  (* Subdirectory *)
  let root2 = PyrePath.create_relative ~root ~relative:"test2" in
  let subdirectory = PyrePath.create_relative ~root:root2 ~relative:"subdirectory" in
  CamlUnix.mkdir (PyrePath.absolute root2) 0o777;
  CamlUnix.mkdir (PyrePath.absolute subdirectory) 0o777;
  touch (PyrePath.create_relative ~root:subdirectory ~relative:"file");
  assert_success root2;

  (* Mixed *)
  let root3 = PyrePath.create_relative ~root ~relative:"test3" in
  let subdirectory = PyrePath.create_relative ~root:root3 ~relative:"subdirectory" in
  CamlUnix.mkdir (PyrePath.absolute root3) 0o777;
  touch (PyrePath.create_relative ~root:root3 ~relative:"file0");
  CamlUnix.mkdir (PyrePath.absolute subdirectory) 0o777;
  touch (PyrePath.create_relative ~root:subdirectory ~relative:"file1");
  assert_success root3;

  (* Not a directory *)
  let not_a_directory = PyrePath.create_relative ~root ~relative:"not_a_directory" in
  touch not_a_directory;
  assert_failure not_a_directory;

  (* Directory does not exist *)
  let does_not_exist = PyrePath.create_relative ~root ~relative:"does_not_exist" in
  assert_failure does_not_exist;
  ()


let test_read_directory_ordered context =
  let _, root = root context in
  let should_be_empty = PyrePath.read_directory_ordered root in
  assert_equal ~ctxt:context ~printer:[%show: PyrePath.t list] should_be_empty [];
  let inner_directory = PyrePath.create_relative ~root ~relative:"inner_directory" in
  let inner_file = PyrePath.create_relative ~root ~relative:"inner_file.txt" in
  CamlUnix.mkdir (PyrePath.absolute inner_directory) 0o777;
  touch inner_file;
  let should_have_two_entries = PyrePath.read_directory_ordered root in
  assert_equal
    ~ctxt:context
    ~printer:[%show: PyrePath.t list]
    should_have_two_entries
    [inner_directory; inner_file];
  ()


let () =
  "path"
  >::: [
         "create" >:: test_create;
         "absolute" >:: test_absolute;
         "directory_contains" >:: test_directory_contains;
         "get_relative_to_root" >:: test_get_relative_to_root;
         "directory_exists" >:: test_directory_exists;
         "is_python_file" >:: test_is_python_file;
         "file_exists" >:: test_file_exists;
         "last" >:: test_last;
         "get_directory" >:: test_get_directory;
         "create_directory_recursively" >:: test_create_directory_recursively;
         "unlink_if_exists" >:: test_unlink_if_exists;
         "remove_contents_of_directory" >:: test_remove_contents_of_directory;
         "read_directory_ordered" >:: test_read_directory_ordered;
       ]
  |> Test.run
