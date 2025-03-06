/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::test::util::TestEnv;
use crate::testcase;
use crate::testcase_with_bug;

fn env_class_x() -> TestEnv {
    TestEnv::one(
        "foo",
        r#"
class X: ...
x: X = X()
"#,
    )
}

fn env_class_x_deeper() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "", "foo/__init__.pyi");
    t.add_with_path(
        "foo.bar",
        r#"
class X: ...
x: X = X()
"#,
        "foo/bar.pyi",
    );
    t
}

testcase!(
    test_imports_works,
    env_class_x(),
    r#"
from typing import assert_type
from foo import x, X
assert_type(x, X)
"#,
);

testcase!(
    test_imports_broken,
    env_class_x(),
    r#"
from foo import x, X
class Y: ...
b: Y = x  # E: `X` is not assignable to `Y`
"#,
);

testcase!(
    test_imports_star,
    env_class_x(),
    r#"
from typing import assert_type
from foo import *
y: X = x
assert_type(y, X)
"#,
);

testcase!(
    test_imports_module_single,
    env_class_x(),
    r#"
from typing import assert_type
import foo
y: foo.X = foo.x
assert_type(y, foo.X)
"#,
);

testcase!(
    test_imports_module_as,
    env_class_x(),
    r#"
from typing import assert_type
import foo as bar
y: bar.X = bar.x
assert_type(y, bar.X)
"#,
);

testcase!(
    test_imports_module_nested,
    env_class_x_deeper(),
    r#"
from typing import assert_type
import foo.bar
y: foo.bar.X = foo.bar.x
assert_type(y, foo.bar.X)
"#,
);

testcase!(
    test_import_overwrite,
    env_class_x(),
    r#"
from foo import X, x
class X: ...
y: X = x  # E: `foo.X` is not assignable to `main.X`
"#,
);

fn env_imports_dot() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "", "foo/__init__.pyi");
    t.add_with_path("foo.bar", "", "foo/bar/__init__.pyi");
    t.add_with_path("foo.bar.baz", "from .qux import x", "foo/bar/baz.pyi");
    t.add_with_path("foo.bar.qux", "x: int = 1", "foo/bar/qux.pyi");
    t
}

testcase!(
    test_imports_dot,
    env_imports_dot(),
    r#"
from typing import assert_type
from foo.bar.baz import x
assert_type(x, int)
"#,
);

testcase!(
    test_access_nonexistent_module,
    env_imports_dot(),
    r#"
import foo.bar.baz
foo.qux.wibble.wobble # E: No attribute `qux` in module `foo`
"#,
);

fn env_star_reexport() -> TestEnv {
    let mut t = TestEnv::new();
    t.add("base", "class Foo: ...");
    t.add("second", "from base import *");
    t
}

testcase!(
    test_imports_star_transitive,
    env_star_reexport(),
    r#"
from typing import assert_type
from second import *
assert_type(Foo(), Foo)
"#,
);

fn env_redefine_class() -> TestEnv {
    TestEnv::one("foo", "class Foo: ...")
}

testcase_with_bug!(
    "The anywhere lookup of Foo in the function body finds both the imported and locally defined classes",
    test_redefine_class,
    env_redefine_class(),
    r#"
from typing import assert_type
from foo import *
class Foo: ...
def f(x: Foo) -> Foo:
    return Foo() # E: Returned type `foo.Foo | main.Foo` is not assignable to declared return type `main.Foo`
assert_type(f(Foo()), Foo)
"#,
);

testcase!(
    test_dont_export_underscore,
    TestEnv::one("foo", "x: int = 1\n_y: int = 2"),
    r#"
from typing import assert_type, Any
from foo import *
assert_type(x, int)
assert_type(_y, Any)  # E: Could not find name `_y`
"#,
);

fn env_import_different_submodules() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "", "foo/__init__.pyi");
    t.add_with_path("foo.bar", "x: int = 1", "foo/bar.pyi");
    t.add_with_path("foo.baz", "x: str = 'a'", "foo/baz.pyi");
    t
}

testcase!(
    test_import_different_submodules,
    env_import_different_submodules(),
    r#"
from typing import assert_type
import foo.bar
import foo.baz

assert_type(foo.bar.x, int)
assert_type(foo.baz.x, str)
"#,
);

testcase!(
    test_import_flow,
    env_import_different_submodules(),
    r#"
from typing import assert_type
import foo.bar

def test():
    assert_type(foo.bar.x, int)
    assert_type(foo.baz.x, str)

import foo.baz
"#,
);

testcase!(
    test_bad_import,
    r#"
from typing import assert_type, Any
from builtins import not_a_real_value  # E: Could not import `not_a_real_value` from `builtins`
assert_type(not_a_real_value, Any)
"#,
);

testcase!(
    test_bad_relative_import,
    r#"
from ... import does_not_exist  # E: Could not resolve relative import `...`
"#,
);

fn env_all_x() -> TestEnv {
    TestEnv::one(
        "foo",
        r#"
__all__ = ["x"]
x: int = 1
y: int = 3
    "#,
    )
}

testcase!(
    test_import_all,
    env_all_x(),
    r#"
from foo import *
z = y  # E: Could not find name `y`
"#,
);

fn env_broken_export() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "from foo.bar import *", "foo/__init__.pyi");
    t.add_with_path(
        "foo.bar",
        r#"
from foo import baz  # E: Could not import `baz` from `foo`
__all__ = []
"#,
        "foo/bar.pyi",
    );
    t
}

testcase!(
    test_broken_export,
    env_broken_export(),
    r#"
import foo
"#,
);

fn env_relative_import_star() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "from .bar import *", "foo/__init__.pyi");
    t.add_with_path("foo.bar", "x: int = 5", "foo/bar.pyi");
    t
}

testcase!(
    test_relative_import_star,
    env_relative_import_star(),
    r#"
from typing import assert_type
import foo

assert_type(foo.x, int)
"#,
);

fn env_dunder_init_with_submodule() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "x: str = ''", "foo/__init__.py");
    t.add_with_path("foo.bar", "x: int = 0", "foo/bar.py");
    t
}

testcase!(
    test_from_package_import_module,
    env_dunder_init_with_submodule(),
    r#"
from foo import bar
from typing import assert_type
assert_type(bar.x, int)
from foo import baz  # E: Could not import `baz` from `foo`
"#,
);

testcase!(
    test_import_dunder_init_and_submodule,
    env_dunder_init_with_submodule(),
    r#"
from typing import assert_type
import foo
import foo.bar
assert_type(foo.x, str)
assert_type(foo.bar.x, int)
"#,
);

testcase!(
    test_import_dunder_init_without_submodule,
    env_dunder_init_with_submodule(),
    r#"
from typing import assert_type
import foo
assert_type(foo.x, str)
foo.bar.x  # E: No attribute `bar` in module `foo`
"#,
);

fn env_dunder_init_with_submodule2() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "x: str = ''", "foo/__init__.py");
    t.add_with_path("foo.bar", "x: int = 0", "foo/bar/__init__.py");
    t.add_with_path("foo.bar.baz", "x: float = 4.2", "foo/bar/baz.py");
    t
}

testcase!(
    test_import_dunder_init_submodule_only,
    env_dunder_init_with_submodule2(),
    r#"
from typing import assert_type
import foo.bar.baz
assert_type(foo.x, str)
assert_type(foo.bar.x, int)
assert_type(foo.bar.baz.x, float)
"#,
);

fn env_dunder_init_overlap_submodule() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "bar: str = ''", "foo/__init__.py");
    t.add_with_path("foo.bar", "x: int = 0", "foo/bar.py");
    t
}

testcase_with_bug!(
    r#"
TODO: foo.bar should not be a str (it should be the module object)
TODO: foo.bar.x should exist and should be an int
    "#,
    test_import_dunder_init_overlap_submodule_last,
    env_dunder_init_overlap_submodule(),
    r#"
from typing import assert_type
import foo
import foo.bar
assert_type(foo.bar, str) # TODO: error
foo.bar.x # TODO # E: Object of class `str` has no attribute `x`
"#,
);

testcase_with_bug!(
    "TODO: Surprisingly (to Sam), importing __init__ after the submodule does not overwrite foo.bar with the global from __init__.py.",
    test_import_dunder_init_overlap_submodule_first,
    env_dunder_init_overlap_submodule(),
    r#"
from typing import assert_type
import foo.bar
import foo
assert_type(foo.bar, str) # TODO: error
foo.bar.x # TODO # E: Object of class `str` has no attribute `x`
"#,
);

testcase!(
    test_import_dunder_init_overlap_without_submodule,
    env_dunder_init_overlap_submodule(),
    r#"
from typing import assert_type
import foo
assert_type(foo.bar, str)
foo.bar.x # E: Object of class `str` has no attribute `x`
"#,
);

testcase_with_bug!(
    "`foo.bar` is explicitly imported as module so it should be treated as a module.",
    test_import_dunder_init_overlap_submodule_only,
    env_dunder_init_overlap_submodule(),
    r#"
from typing import assert_type
import foo.bar
assert_type(foo.bar, str) # This should fail: foo.bar is a module, not a str
foo.bar.x # This should not fail. The type is `int`. # E: Object of class `str` has no attribute `x`
"#,
);

fn env_dunder_init_reexport_submodule() -> TestEnv {
    let mut t = TestEnv::new();
    t.add_with_path("foo", "from .bar import x", "foo/__init__.py");
    t.add_with_path("foo.bar", "x: int = 0", "foo/bar.py");
    t
}

testcase_with_bug!(
    "We currently don't model auto re-exporting submodules in __init__.py",
    test_import_dunder_init_reexport_submodule,
    env_dunder_init_reexport_submodule(),
    r#"
from typing import assert_type
import foo
assert_type(foo.x, int)
foo.bar.x  # E: No attribute `bar` in module `foo`
"#,
);

fn env_export_all_wrongly() -> TestEnv {
    TestEnv::one(
        "foo",
        r#"
__all__ = ['bad_definition']
__all__.extend(bad_module.__all__)  # E: Could not find name `bad_module`
"#,
    )
}

testcase!(
    test_export_all_wrongly,
    env_export_all_wrongly(),
    r#"
from foo import bad_definition  # E: Could not import `bad_definition` from `foo`
"#,
);

testcase!(
    test_export_all_wrongly_star,
    env_export_all_wrongly(),
    r#"
from foo import *  # E: Could not import `bad_definition` from `foo`
"#,
);

testcase_with_bug!(
    "False negative",
    test_export_all_not_module,
    r#"
class not_module:
    __all__ = []

__all__ = []
__all__.extend(not_module.__all__)  # Should get an error about not_module not being imported
    # But Pyright doesn't give an error, so maybe we shouldn't either??
"#,
);

fn env_blank() -> TestEnv {
    TestEnv::one("foo", "")
}

testcase!(
    test_import_blank,
    env_blank(),
    r#"
import foo
x = foo.bar  # E: No attribute `bar` in module `foo`
"#,
);

testcase!(
    test_missing_import_named,
    r#"
from foo import bar  # E: Could not find import of `foo`
"#,
);

testcase!(
    test_missing_import_star,
    r#"
from foo import *  # E: Could not find import of `foo`
"#,
);

testcase!(
    test_missing_import_module,
    r#"
import foo, bar.baz  # E: Could not find import of `foo`  # E: Could not find import of `bar.baz`
"#,
);

testcase!(
    test_direct_import_toplevel,
    r#"
import typing

typing.assert_type(None, None)
"#,
);

testcase!(
    test_direct_import_function,
    r#"
import typing

def foo():
    typing.assert_type(None, None)
"#,
);

testcase!(
    test_import_blank_no_reexport_builtins,
    TestEnv::one("blank", ""),
    r#"
from blank import int as int_int # E: Could not import `int` from `blank`
"#,
);

#[test]
fn test_import_fail_to_load() {
    let temp = tempfile::tempdir().unwrap();
    let mut env = TestEnv::new();
    env.add_real_path("foo", temp.path().join("foo.py"));
    env.add("main", "import foo");
    let errs = env.to_state().0.collect_errors();
    assert_eq!(errs.len(), 1);
    let msg = errs[0].to_string();
    assert!(msg.contains("foo.py:1:1: Failed to load"));
}
