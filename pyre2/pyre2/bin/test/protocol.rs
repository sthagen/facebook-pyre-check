/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;

testcase!(
    test_protocol,
    r#"
from typing import Protocol
class P(Protocol):
    x: int
    y: str
class C1:
    x: int
    y: str
class C2:
    x: str
class C3(P, C1): ...
class C4(P):
    y: int
class C5:
    x: int
    y: int
def f(proto: P) -> None: ...
def g(p: P, c1: C1, c2: C2, c3: C3, c4: C4, c5: C5) -> None:
    f(c1)
    f(c2)  # E: EXPECTED C2 <: P
    f(c3)
    f(c4)
    f(c5)  # E: EXPECTED C5 <: P
    c: C1 = p  # E: EXPECTED P <: C1
 "#,
);

testcase!(
    test_protocol_base,
    r#"
from typing import Protocol
class C1:
    x: int
    y: str
class P1(Protocol, C1):  # E: If `Protocol` is included as a base class, all other bases must be protocols.
    x: int
class P2(Protocol):
    x: int
class P3(Protocol, P2):
    y: str
 "#,
);

testcase!(
    test_callable_protocol,
    r#"
from typing import Callable, Protocol
class P(Protocol):
    def __call__(self, x: int) -> str: ...
def f1(x: int) -> str: ...
def f2(x: str) -> str: ...

p1: P = f1
p2: P = f2  # E: EXPECTED (x: str) -> str <: P

def g(p: P) -> None:
    c1: Callable[[int], str] = p
    c2: Callable[[str], str] = p  # E: EXPECTED P <: (str) -> str
 "#,
);

testcase!(
    test_protocol_readonly,
    r#"
from typing import Protocol
class P(Protocol):
    x: int
class C1:
    @property
    def x(self) -> int: ...
class C2:
    @property
    def x(self) -> int: ...
    @x.setter
    def x(self, value: int) -> None: ...
p1: P = C1()  # E: EXPECTED C1 <: P
p2: P = C2()
 "#,
);

testcase!(
    test_generic_protocol,
    r#"
from typing import Protocol, TypeVar
T = TypeVar("T")
class P(Protocol[T]):
   x: T
class C1:
   x: int
   y: str
class C2:
   x: str
   y: str
def f(proto: P[str]) -> None: ...
def g(c1: C1, c2: C2) -> None:
    f(c1)  # E: EXPECTED C1 <: P[str]
    f(c2)
"#,
);
