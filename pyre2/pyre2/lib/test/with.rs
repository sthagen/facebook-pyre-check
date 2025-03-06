/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use crate::testcase;

testcase!(
    test_simple_with,
    r#"
from typing import assert_type
from types import TracebackType
class Foo:
    def __enter__(self) -> int:
        ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> None:
        ...

with Foo() as foo:
    assert_type(foo, int)

bar: str = "abc"
with Foo() as bar: # E: `int` is not assignable to variable `bar` with type `str`
    assert_type(bar, str)
    "#,
);

testcase!(
    test_simple_async_with,
    r#"
from typing import assert_type
from types import TracebackType
class Foo:
    async def __aenter__(self) -> int:
        ...
    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> None:
        ...

async def test() -> None:
    async with Foo() as foo:
        assert_type(foo, int)
    "#,
);

testcase!(
    test_simple_with_error,
    r#"
def test_sync() -> None:
    with 42 as foo:  # E: has no attribute `__enter__` # E: has no attribute `__exit__`
        pass

async def test_async() -> None:
    async with "abc" as bar:  # E: has no attribute `__aenter__` # E: has no attribute `__aexit__`
        pass
    "#,
);

testcase!(
    test_simple_with_wrong_enter_type,
    r#"
from types import TracebackType
class Foo:
    __enter__: int = 42
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> None:
        ...

with Foo() as foo:  # E: Expected `__enter__` to be a callable, got int
    pass
    "#,
);

testcase!(
    test_with_wrong_exit_attribute_type,
    r#"
from types import TracebackType
class Foo:
    def __enter__(self) -> int: ...
    __exit__: int = 42

with Foo() as foo:  # E: Expected `__exit__` to be a callable, got int
    pass
    "#,
);

testcase!(
    test_with_wrong_exit_argument_count,
    r#"
from typing import assert_type
class Foo:
    def __enter__(self) -> int:
        ...
    def __exit__(self) -> None:
        ...

with Foo() as foo:  # E: Expected 0 positional arguments, got 3
    pass
    "#,
);

testcase!(
    test_with_wrong_exit_argument_type,
    r#"
from typing import assert_type
class Foo:
    def __enter__(self) -> int:
        ...
    def __exit__(self, exc_type: int, exc_value: int, traceback: int) -> None:
        ...

with Foo() as foo: # E: Argument `BaseException | None` is not assignable to parameter `exc_value` with type `int` # E: Argument `TracebackType | None` is not assignable to parameter `traceback` with type `int` # E: Argument `type[BaseException] | None` is not assignable to parameter `exc_type` with type `int`
    pass
    "#,
);

testcase!(
    test_with_wrong_return_type,
    r#"
from typing import assert_type
from types import TracebackType
class Foo:
    def __enter__(self) -> int:
        ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> str:
        ...

with Foo() as foo:  # E: Cannot use `Foo` as a context manager\n  Return type `str` of function `Foo.__exit__` is not assignable to expected return type `bool | None`
    pass
    "#,
);

testcase!(
    test_async_with_dunder_aenter_not_async,
    r#"
from types import TracebackType
class Foo:
    def __aenter__(self) -> int:
        ...
    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> None:
        ...

async def test() -> None:
    async with Foo() as foo: # E: Expected `__aenter__` to be async
        ...
"#,
);

testcase!(
    test_async_with_dunder_aexit_not_async,
    r#"
from types import TracebackType
class Foo:
    async def __aenter__(self) -> int:
        ...
    def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
        /
    ) -> None:
        ...

async def test() -> None:
    async with Foo() as foo: # E: Expected `__aexit__` to be async
        ...
"#,
);
