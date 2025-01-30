/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;

testcase!(
    test_def,
    r#"
from typing import assert_type
import dataclasses
@dataclasses.dataclass
class Data:
    x: int
    y: str
assert_type(Data, type[Data])
    "#,
);

testcase!(
    test_fields,
    r#"
from typing import assert_type
import dataclasses
@dataclasses.dataclass
class Data:
    x: int
    y: str
def f(d: Data):
    assert_type(d.x, int)
    assert_type(d.y, str)
    "#,
);

testcase!(
    test_generic,
    r#"
from typing import assert_type
import dataclasses
@dataclasses.dataclass
class Data[T]:
    x: T
def f(d: Data[int]):
    assert_type(d.x, int)
assert_type(Data(x=0), Data[int])
Data[int](x=0)  # OK
Data[int](x="")  # E: EXPECTED Literal[''] <: int
    "#,
);

testcase!(
    test_construction,
    r#"
import dataclasses
@dataclasses.dataclass
class Data:
    x: int
    y: str
Data(0, "1")  # OK
Data(0, 1)  # E: EXPECTED Literal[1] <: str
    "#,
);

testcase!(
    test_inheritance,
    r#"
import dataclasses

@dataclasses.dataclass
class A:
    w: int

class B(A):
    x: str
# B is not decorated as a dataclass, so w is the only dataclass field
B(w=0)

@dataclasses.dataclass
class C(B):
    y: bytes
# C is decorated as a dataclass again, so w and y are the dataclass fields
C(w=0, y=b"1")

@dataclasses.dataclass
class D(C):
    z: float
# Make sure we get the parameters in the right order when there are multiple @dataclass bases
D(0, b"1", 2.0)
    "#,
);

testcase!(
    test_duplicate_field,
    r#"
import dataclasses
@dataclasses.dataclass
class A:
    x: int
    y: float
@dataclasses.dataclass
class B(A):
    x: str
# Overwriting x doesn't change the param order but does change its type
B('0', 1.0)  # OK
B(0, 1.0)  # E: EXPECTED Literal[0] <: str
    "#,
);

testcase!(
    test_inherit_from_multiple_dataclasses,
    r#"
import dataclasses
@dataclasses.dataclass
class A:
    x: int
@dataclasses.dataclass
class B:
    y: str

class C(B, A):
    pass
C(y="0")  # First base (B) wins

@dataclasses.dataclass
class D(B, A):
    z: float
D(0, "1", 2.0)
    "#,
);

testcase!(
    test_inherit_from_generic_dataclass,
    r#"
import dataclasses
@dataclasses.dataclass
class A[T]:
    x: T
@dataclasses.dataclass
class B(A[int]):
    y: str
B(x=0, y="1")  # OK
B(x="0", y="1")  # E: EXPECTED Literal['0'] <: int
    "#,
);
