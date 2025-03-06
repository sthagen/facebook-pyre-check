/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::test::util::TestEnv;
use crate::testcase;
use crate::testcase_with_bug;

testcase_with_bug!(
    "Error message is really bad",
    test_subscript_unpack_assign,
    r#"
from typing import assert_type

x: list[int] = [0, 1, 2]
x[0], x[1] = 3, 4
x[0], x[1] = 3, "foo"  # E: No matching overload found
"#,
);

testcase!(
    test_subscript_assign,
    r#"
from typing import assert_type

x = []
x[0] = 1
assert_type(x, list[int])

y = [1, 2, 3]
y[0] = 1
assert_type(y, list[int])

z = [1, 2, 3]
z[0] = "oops"  # E: No matching overload found

a: int = 1
a[0] = 1  # E: `Literal[1]` has no attribute `__setitem__`

def f(x: int) -> None:
    x[0] = 1  # E: `int` has no attribute `__setitem__`
"#,
);

testcase!(
    test_error_assign,
    r#"
x: str = 1  # E: `Literal[1]` is not assignable to `str`
y = x
"#,
);

testcase!(
    test_assign_twice_empty,
    r#"
from typing import assert_type
def b() -> bool:
    return True

if b():
    x = []
else:
    x = [3]
y = x
assert_type(y, list[int])
"#,
);

testcase!(
    test_assign_widen,
    r#"
from typing import Literal, LiteralString, Any
a: Literal['test'] = "test"
b: LiteralString = "test"
c: str = "test"
d: Any = "test"
"#,
);

testcase!(
    test_assign_widen_list,
    r#"
from typing import Literal, LiteralString, Any
a: list[Literal['test']] = ["test"]
b: list[LiteralString] = ["test"]
c: list[str] = ["test"]
d: list[Any] = ["test"]
"#,
);

testcase!(
    test_assign_at_types,
    r#"
a: int = 3
a = "test"  # E: `Literal['test']` is not assignable to variable `a` with type `int`
"#,
);

testcase!(
    test_optional_assign,
    r#"
from typing import Optional
x: Optional[int] = 42
y: Optional[str] = 43  # E: `Literal[43]` is not assignable to `str | None`
    "#,
);

testcase!(
    test_assign_ellipse,
    TestEnv::one_with_path("foo", "x: int = ...", "foo.pyi"),
    r#"
from typing import assert_type
from types import EllipsisType
from foo import x
assert_type(x, int)
y: int = ...  # E: `Ellipsis` is not assignable to `int`
z: EllipsisType = ...
"#,
);

testcase!(
    test_assign_unpack,
    r#"
from typing import assert_type, Literal
a, b = (1, "test")
assert_type(a, Literal[1])
assert_type(b, Literal["test"])
    "#,
);

testcase!(
    test_assign_unpack_unpack,
    r#"
from typing import assert_type, Literal
(a, b), c, d = ((1, "test"), 2, 3)
assert_type(a, Literal[1])
assert_type(b, Literal["test"])
assert_type(c, Literal[2])
assert_type(d, Literal[3])
    "#,
);

testcase!(
    test_assign_unpack_ambiguous,
    r#"
from typing import assert_type
def f(x: list[str]):
    a, b = x
    assert_type(a, str)
    assert_type(b, str)
    "#,
);

testcase!(
    test_assign_multiple,
    r#"
from typing import assert_type, Literal
a = b = 1
assert_type(a, Literal[1])
assert_type(b, Literal[1])
    "#,
);

testcase!(
    test_assign_list,
    r#"
from typing import assert_type, Literal
[a, b] = (1, "test")
assert_type(a, Literal[1])
assert_type(b, Literal["test"])
    "#,
);

testcase!(
    test_unpack_too_many,
    r#"
(a, b, c, d) = (1, 2)  # E: Cannot unpack tuple[Literal[1], Literal[2]] (of size 2) into 4 values
    "#,
);

testcase!(
    test_unpack_not_enough,
    r#"
(a,) = (1, 2)  # E: Cannot unpack tuple[Literal[1], Literal[2]] (of size 2) into 1 value
() = (1, 2)  # E: Cannot unpack tuple[Literal[1], Literal[2]] (of size 2) into 0 values
    "#,
);

testcase!(
    test_splat_back,
    r#"
from typing import assert_type, Literal
(a, b, *c) = (1, 2, 3, "test")
assert_type(a, Literal[1])
assert_type(b, Literal[2])
assert_type(c, list[Literal["test", 3]])
    "#,
);

testcase!(
    test_splat_front,
    r#"
from typing import assert_type, Literal
(*a, b, c) = (1, 2, 3, "test")
assert_type(a, list[Literal[1, 2]])
assert_type(b, Literal[3])
assert_type(c, Literal["test"])
    "#,
);

testcase!(
    test_splat_middle,
    r#"
from typing import assert_type, Literal
(a, *b, c) = (1, True, 2, "test")
assert_type(a, Literal[1])
assert_type(b, list[Literal[True, 2]])
assert_type(c, Literal["test"])
    "#,
);

testcase!(
    test_splat_unpack,
    r#"
from typing import assert_type, Literal
(a, *(b,)) = (1, 2)
assert_type(a, Literal[1])
assert_type(b, Literal[2])
    "#,
);

testcase!(
    test_splat_nothing,
    r#"
from typing import assert_type, Never
(*a,) = ()
assert_type(a, list[Never])
    "#,
);

testcase!(
    test_never,
    r#"
from typing import Any, Never, NoReturn
def foo(x: Never) -> Any:
    y: NoReturn = x
    z: int = x
    return x
def bar(x: Never) -> NoReturn:
    return x
    "#,
);

testcase!(
    test_splat_ambiguous,
    r#"
from typing import assert_type
def f(x: list[str]):
    a, *b = x
    assert_type(a, str)
    assert_type(b, list[str])
    "#,
);

testcase!(
    test_splat_error,
    r#"
a, *b = (1,)  # OK
a, *b = ()  # E: Cannot unpack tuple[()] (of size 0) into 1+ values
    "#,
);

testcase!(
    test_multiple_annotations,
    r#"
from typing import Literal
def f(cond: bool):
    x: int = 0
    if cond:
        x: int = 1  # OK
    y: int = 0
    if cond:
        y: str = "oops"  # E: Inconsistent type annotations for y
    z: int = 0
    if cond:
        z: Literal[1] = 1  # E: Inconsistent type annotations for z
    "#,
);

testcase!(
    test_multiple_annotations_without_merge,
    r#"
x: int = 0
x: str = ""  # E: Inconsistent type annotations for x
    "#,
);

testcase!(
    test_hoist_ann,
    r#"
x = 0 # E: `Literal[0]` is not assignable to variable `x` with type `str`
x: str = ""
    "#,
);

testcase!(
    test_annot_flow_assign,
    r#"
from typing import Literal
x: int = 0
lit0: Literal[0] = x
x = 1
lit1: Literal[1] = x
x = "oops"  # E: `Literal['oops']` is not assignable to variable `x` with type `int`
lit2: Literal["oops"] = x  # E: `int` is not assignable to `Literal['oops']`
    "#,
);

testcase!(
    test_type_alias_simple,
    r#"
from typing import assert_type
type X = int
def f(x: X):
    assert_type(x, int)
    "#,
);

testcase!(
    test_type_alias_generic,
    r#"
from typing import assert_type
type X[T] = list[T]
def f(x: X[int]):
    assert_type(x, list[int])
    "#,
);

testcase!(
    test_aug_assign_simple,
    r#"
x: list[int] = []
x += [1]
x += ["foo"]  # E: Argument `list[str]` is not assignable to parameter with type `Iterable[int]`
"#,
);

testcase!(
    test_aug_assign_function,
    r#"
def foo(y: list[int]) -> None:
    y += [1]
    y += ["foo"]  # E: Argument `list[str]` is not assignable to parameter with type `Iterable[int]`
    z: list[int] = []
    z += [1]
    z += ["foo"]  # E: Argument `list[str]` is not assignable to parameter with type `Iterable[int]`
"#,
);

testcase!(
    test_aug_assign_attr,
    r#"
class C:
    foo: list[int]

    def __init__(self) -> None:
        self.foo = []

c: C = C()
c.foo += [1]
c.foo += ["foo"]  # E: Argument `list[str]` is not assignable to parameter with type `Iterable[int]`
"#,
);

testcase!(
    test_aug_assign_attr_self,
    r#"
class C:
    foo: list[int]

    def __init__(self) -> None:
        self.foo = []
        self.foo += [1]
        self.foo += ["foo"]  # E: Argument `list[str]` is not assignable to parameter with type `Iterable[int]`
"#,
);

testcase!(
    test_aug_assign_subscript,
    r#"
x: list[list[int]] = []
x += [[1]]
x[0] += [1]
x += [1]  # E: Argument `list[int]` is not assignable to parameter with type `Iterable[list[int]]`
"#,
);

testcase!(
    test_assign_special_subtype,
    r#"
from types import NoneType, EllipsisType

def foo(a: tuple[int, ...], b: NoneType, c: EllipsisType) -> None:
    a2: tuple = a
    b = None
    b2: object = b
    b3: None = b
    b4: int | None = b
    c = ...
    c2: object = c
"#,
);

testcase!(
    test_subscript_assign_any_check_rhs,
    r#"
from typing import Any
def expect_str(x: str): ...
def test(x: Any):
    x[0] += expect_str(0) # E: Argument `Literal[0]` is not assignable to parameter `x` with type `str`
"#,
);

testcase!(
    test_aug_assign_any_check_rhs,
    r#"
from typing import Any
def expect_str(x: str): ...
def test(x: Any):
    x += expect_str(0) # E: Argument `Literal[0]` is not assignable to parameter `x` with type `str`
"#,
);

testcase!(
    test_aug_assign_error_not_class_check_rhs,
    r#"
def expect_str(x: str): ...
def test(x: None):
    x += expect_str(0) # E: `None` has no attribute `__iadd__` # E: Argument `Literal[0]` is not assignable to parameter `x` with type `str`
"#,
);

testcase!(
    test_aug_assign_error_not_callable_check_rhs,
    r#"
def expect_str(x: str): ...
class C:
    __iadd__: None = None
def test(x: C):
    x += expect_str(0) # E: Expected `__iadd__` to be a callable, got None # E: Argument `Literal[0]` is not assignable to parameter `x` with type `str`
"#,
);

testcase!(
    test_walrus_simple,
    r#"
from typing import assert_type, Literal
(x := True)
assert_type(x, Literal[True])
    "#,
);

testcase!(
    test_walrus_use_value,
    r#"
from typing import assert_type
class A: pass
class B(A): pass

y1 = (x1 := B())
assert_type(y1, B)

y2: A = (x2 := B())

y3: list[A] = (x3 := [B()])

y4: B = (x4 := A())  # E: `A` is not assignable to `B`
    "#,
);

testcase!(
    test_walrus_annotated_target,
    r#"
from typing import assert_type
class A: pass
class B(A): pass

x1: A
(x1 := B())

x2: list[A]
(x2 := [B()])

x3: B
(x3 := A())  # E: `A` is not assignable to variable `x3` with type `B`
    "#,
);

testcase_with_bug!(
    "False negative",
    test_read_before_write,
    r#"
x = y  # this should be an error
y = 42
    "#,
);

testcase_with_bug!(
    "We never validate that assignments to unpacked targets are valid",
    test_assign_unpacked_with_existing_annotations,
    r#"
x: int
y: str
z: tuple[bool, ...]
x, *z, y = True, 1, 2, "test"
    "#,
);
