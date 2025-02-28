/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;
use crate::testcase_with_bug;

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
    x: str # E:  Class member `x` overrides parent class `A` in an inconsistent manner
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

testcase!(
    test_decorate_with_call_return,
    r#"
from dataclasses import dataclass
@dataclass()
class C:
    x: int
C(x=0)  # OK
C(x='0')  # E: EXPECTED Literal['0'] <: int
    "#,
);

testcase!(
    test_init_already_defined,
    r#"
from dataclasses import dataclass
@dataclass
class C:
    x: int
    def __init__(self):
        self.x = 42
C()  # OK
C(x=0)  # E: Unexpected keyword argument
    "#,
);

testcase!(
    test_init_false,
    r#"
from dataclasses import dataclass
@dataclass(init=False)
class C:
    x: int = 0
C()  # OK
C(x=0)  # E: Unexpected keyword argument
    "#,
);

testcase!(
    test_with_methods,
    r#"
from typing import assert_type, Any, Literal
from dataclasses import dataclass
@dataclass
class C:
    x: int = 0
    def m(self) -> int: return self.x
c = C()  # Ok
assert_type(c.m(), int) # Ok
a: Any = ...
C(m=a)  # E: Unexpected keyword argument `m`
assert_type(c.__match_args__, tuple[Literal['x']])  # Ok
    "#,
);

testcase_with_bug!(
    "TODO: consider erroring on unannotated attributes",
    test_unannotated_attribute,
    r#"
import dataclasses
@dataclasses.dataclass
class C:
    # Not annotating a field with value dataclasses.field(...) is a runtime error, so we should
    # probably error on this.
    x = dataclasses.field()
    # This is confusing and likely indicative of a programming error; consider erroring on this, too.
    y = 3
    "#,
);

testcase!(
    test_frozen,
    r#"
from dataclasses import dataclass
@dataclass
class C:
    x: int

@dataclass(frozen=True)
class D:
    x: int

def f(c: C, d: D):
    c.x = 0
    d.x = 0  # E: Could not assign to read-only field `x`
    "#,
);

testcase!(
    test_match_args,
    r#"
from typing import assert_type, Literal
from dataclasses import dataclass
@dataclass
class C_has_match_args_default:
    x: int
@dataclass(match_args=True)
class C_has_match_args_explicit:
    x: int
@dataclass(match_args=False)
class C_no_match_args:
    x: int
assert_type(C_has_match_args_default.__match_args__, tuple[Literal['x']])
assert_type(C_has_match_args_explicit.__match_args__, tuple[Literal['x']])
C_no_match_args.__match_args__ # E: no class attribute `__match_args__`
    "#,
);

testcase!(
    test_match_args_no_overwrite,
    r#"
from typing import assert_type
from dataclasses import dataclass
@dataclass(match_args=True)
class C:
    __match_args__ = ()
    x: int
assert_type(C.__match_args__, tuple[()])
    "#,
);

testcase!(
    test_kw_only_arg,
    r#"
from typing import assert_type
from dataclasses import dataclass
@dataclass(kw_only=True)
class C:
    x: int
C(x=0)  # OK
C(0)  # E: Missing argument `x`  # E: Expected 0 positional arguments
assert_type(C.__match_args__, tuple[()])
    "#,
);

testcase!(
    test_kw_only_sentinel,
    r#"
from typing import assert_type, Literal
import dataclasses
@dataclasses.dataclass
class C:
    x: int
    _: dataclasses.KW_ONLY
    y: str
C(0, y="1")  # OK
C(x=0, y="1")  # OK
C(0, "1")  # E: Missing argument `y`  # E: Expected 1 positional argument
assert_type(C.__match_args__, tuple[Literal["x"]])
    "#,
);

testcase!(
    test_order,
    r#"
from dataclasses import dataclass
@dataclass
class D1:
    x: int
def f(d: D1, e: D1):
    if d < e: ...  # E: `<` not supported between `D1` and `D1`
    if d == e: ...  # OK: `==` and `!=` never error regardless

@dataclass(order=True)
class D2:
    x: int
@dataclass(order=True)
class D3:
    x: int
def f(d: D2, e: D2, f: D3):
    if d < e: ...  # OK
    if e < f: ...  # E: EXPECTED D3 <: D2
    if e != f: ...  # OK: `==` and `!=` never error regardless
    "#,
);

testcase!(
    test_bad_keyword,
    r#"
from dataclasses import dataclass
@dataclass(flibbertigibbet=True)  # E: No matching overload found
class C:
    pass
    "#,
);

testcase!(
    test_dataclasses_field,
    r#"
from dataclasses import dataclass, field
@dataclass
class C:
    x: int = field(init=False)
    y: str
C(y="")  # OK
C(x=0, y="")  # E: Unexpected keyword argument `x`
    "#,
);

testcase!(
    test_default,
    r#"
from dataclasses import dataclass
@dataclass
class C:
    x: int = 0
C()  # OK
C(x=1)  # OK
    "#,
);

testcase!(
    test_field_is_not_default,
    r#"
from dataclasses import dataclass, field
@dataclass
class C:
    x: int = field()
C()  # E: Missing argument `x`
    "#,
);

testcase!(
    test_field_kw_only,
    r#"
from dataclasses import dataclass, field
@dataclass
class C:
    x: int = field(kw_only=True)
C(1)  # E: Missing argument `x`  # E: Expected 0 positional arguments
C(x=1)  # OK
    "#,
);

testcase!(
    test_field_default,
    r#"
from dataclasses import dataclass, field
from typing import Callable

@dataclass
class C1:
    x: int = field(default=0)
C1()  # OK
C1(x=1)  # OK

factory: Callable[[], int] = lambda: 0

@dataclass
class C2:
    x: int = field(default_factory=factory)
C2()  # OK
C2(x=1)  # OK

@dataclass
class C3:
    x: int = field(default="oops")  # E: EXPECTED str <: int
    y: str = field(default_factory=factory)  # E: EXPECTED int <: str
    "#,
);

testcase!(
    test_classvar,
    r#"
from typing import ClassVar
from dataclasses import dataclass
@dataclass
class C:
    x: ClassVar[int] = 0
C()  # OK
C(x=1)  # E: Unexpected keyword argument `x`
    "#,
);

testcase!(
    test_hashable,
    r#"
from typing import Hashable
from dataclasses import dataclass

class Unhashable:
    __hash__ = None

def f(x: Hashable):
    pass

# When eq=frozen=True, __hash__ is implicitly created
@dataclass(eq=True, frozen=True)
class D1(Unhashable):
    pass
f(D1())  # OK

# When eq=True, frozen=False, __hash__ is set to None
@dataclass(eq=True, frozen=False)
class D2:
    pass
f(D2())  # E: EXPECTED D2 <: Hashable

# When eq=False, __hash__ is untouched
@dataclass(eq=False)
class D3:
    pass
@dataclass(eq=False)
class D4(Unhashable):
    pass
f(D3())  # OK
f(D4())  # E: EXPECTED D4 <: Hashable

# unsafe_hash=True forces __hash__ to be created
@dataclass(eq=False, unsafe_hash=True)
class D5(Unhashable):
    pass
f(D5())  # OK
    "#,
);

testcase!(
    test_bad_mro,
    r#"
from dataclasses import dataclass

@dataclass
class A:
  x: int

@dataclass
class B:
  pass

@dataclass
class C(A, B, A):  # E: nonlinearizable inheritance chain
  pass

def f(c: C):
    return c.x  # E: `C` has no attribute `x`
    "#,
);
