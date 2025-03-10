/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;
use crate::testcase_with_bug;

testcase!(
    test_new_type_simple,
    r#"
from typing import NewType, assert_type

UserId = NewType("UserId", int)
UserId("user")  # E: Argument `Literal['user']` is not assignable to parameter `_x` with type `int` in function `UserId.__new__`
u1: UserId = 42 # E: `Literal[42]` is not assignable to `UserId`
u2: UserId = UserId(42)

assert_type(UserId(5) + 1, int)

isinstance(u2, UserId) # E: NewType `UserId` not allowed in isinstance

class UserIdDerived(UserId): # E: Subclassing a NewType not allowed
    pass
     "#,
);

testcase!(
    test_new_type_naming,
    r#"
from typing import NewType 

GoodName = NewType("BadName", int) # E: Expected string literal "GoodName"  

GoodNewType1 = NewType("GoodNewType1", list)  

GoodNewType2 = NewType("GoodNewType2", GoodNewType1) 

nt1: GoodNewType1[int] # E: Expected 0 type arguments for `GoodNewType1`, got 1

     "#,
);

testcase_with_bug!(
    "TODO: None of these types are allowed for a NewType. We will add checks for that.",
    test_new_type_generic,
    r#"
from typing import NewType, TypeVar, Hashable, Literal

BadNewType1 = NewType("BadNewType1", int | str) # E: Second argument to NewType is incorrect

T = TypeVar("T")
BadNewType2 = NewType("BadNewType2", list[T])

BadNewType3 = NewType("BadNewType3", Hashable) # E: Second argument to NewType cannot be a protocol

BadNewType4 = NewType("BadNewType4", Literal[7]) # E: Second argument to NewType is incorrect
     "#,
);

testcase!(
    test_new_type_wrong_arity,
    r#"
from typing import NewType 
UserId = NewType("UserId", int, int) # E: Expected 2 positional arguments, got 3
UserId = NewType("UserId") # E: Missing argument `tp`
userId = NewType() # E: Missing argument `name` # E: Missing argument `tp`
     "#,
);

testcase!(
    test_new_type_not_allowed,
    r#"
from typing import NewType , TypedDict, Any

class TD1(TypedDict):
    a: int

BadNewType1 = NewType("BadNewType1", TD1)  # E: Second argument to NewType is incorrect

BadNewType2 = NewType("BadNewType2", Any)  # E: Second argument to NewType is incorrect
     "#,
);
