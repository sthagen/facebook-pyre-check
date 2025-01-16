/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;
use crate::testcase_with_bug;

testcase!(
    test_simple_function_decorator,
    r#"
from typing import assert_type, Callable, Any

def decorator(f: Callable[[int], int]) -> int: ...

@decorator
def decorated(x: int) -> int:
   return x

assert_type(decorated, int)
    "#,
);

testcase_with_bug!(
    "The logic tested here passes, but assert_type is running into a problem we need to debug.",
    test_identity_function_decorator,
    r#"
from typing import assert_type, Callable, Any

def decorator[T](f: T) -> T: ...

@decorator
def decorated(x: int) -> str:
   return f"{x}"

assert_type(decorated, Callable[[int], str])  # E: assert_type(Callable[[int], str], Callable[[int], str])
    "#,
);

testcase!(
    test_signature_modifying_function_decorator,
    r#"
from typing import assert_type, Callable, Any

def decorator[T, R](f: Callable[[T], R]) -> Callable[[T, T], R]: ...

@decorator
def decorated(x: int) -> str:
   return f"{x}"

assert_type(decorated, Callable[[int, int], str])
    "#,
);
