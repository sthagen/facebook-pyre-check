/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use starlark_map::small_map::SmallMap;

use crate::module::module_name::ModuleName;

static ENUM: &str = r#"
class Enum: ...
class StrEnum(str, Enum): ...
class IntEnum(int, Enum): ...
"#;

static BUILTINS: &str = r#"
from typing import Iterable, Iterator, MutableMapping, MutableSet
class object: ...
class str:
    def __iter__(self) -> Iterator[str]: ...
class bool(int): ...
class int:
    def __add__(self: int, __x: int) -> int: ...
class tuple: ...
class bytes: ...
class float: ...
class complex: ...
class list[T](Iterable[T]):
    def __init__(self) -> None: ...
    def append(self, object: T) -> None: ...
    def extend(self, object: list[T]) -> None: ...
    def __getitem__(self, index: int) -> T: ...
    def __setitem__(self, index: int, value: T) -> None: ...
    def __iter__(self) -> Iterator[T]: ...
class Ellipsis: ...
class dict[K, V](MutableMapping[K, V]):
    def __getitem__(self, key: K) -> V: ...
class set[T](MutableSet[T]): ...
class slice: ...
class BaseException: ...
# Note that type does *not* inherit from Generic in the real builtins stub.
class type: ...
# TODO: overload for slice, tuple should be Sequence[T]
class tuple[T](Iterable[T]):
    def __getitem__(self, index: int) -> T: ...
"#;

static TYPING: &str = r#"
class _SpecialForm: ...
Optional: _SpecialForm
Literal: _SpecialForm
Final: _SpecialForm
class Any: ...
LiteralString: _SpecialForm
Union: _SpecialForm
Tuple: _SpecialForm
Type: _SpecialForm
TypeAlias: _SpecialForm
TypeGuard: _SpecialForm
TypeIs: _SpecialForm
Unpack: _SpecialForm
Self: _SpecialForm
Callable: _SpecialForm
Generic: _SpecialForm
Protocol: _SpecialForm
Never: _SpecialForm
NoReturn: _SpecialForm
Annotated: _SpecialForm
def assert_type(x, y) -> None: ...

class TypeVar:
    def __init__(self, name: str) -> None: ...

class ParamSpec:
    def __init__(self, name: str) -> None: ...

def reveal_type(obj, /):
    return obj

_T = TypeVar('_T', covariant=True)
class Iterable(Protocol[_T]):
    def __iter__(self) -> Iterator[_T]: ...
class Iterator(Iterable[_T], Protocol[_T]):
    def __next__(self) -> _T: ...
    def __iter__(self) -> Iterator[_T]: ...

_YieldT = TypeVar('_YieldT', covariant=True)
_SendT = TypeVar('_SendT', contravariant=True, default=None)
_ReturnT = TypeVar('_ReturnT', covariant=True, default=None)
class Generator(Iterator[_YieldT], Generic[_YieldT, _SendT, _ReturnT]):
    def __next__(self) -> _YieldT: ...
    def __iter__(self) -> Generator[_YieldT, _SendT, _ReturnT]: ...

class Awaitable(Protocol[_T]):
    def __await__(self) -> Generator[Any, Any, _T]: ...

class MutableSet(Iterable[_T]): ...

class MutableMapping[K, V](Iterable[K], Generic[K, V]): ...
"#;

static TYPES: &str = r#"
class EllipsisType: ...
class NoneType: ...
class TracebackType: ...
"#;

pub struct Stdlib(SmallMap<ModuleName, &'static str>);

impl Stdlib {
    pub fn new() -> Self {
        Self(
            [
                ("builtins", BUILTINS),
                ("typing", TYPING),
                ("types", TYPES),
                ("enum", ENUM),
            ]
            .iter()
            .map(|(k, v)| (ModuleName::from_str(k), *v))
            .collect(),
        )
    }

    pub fn lookup_content(&self, m: ModuleName) -> Option<&'static str> {
        self.0.get(&m).copied()
    }

    pub fn modules(&self) -> impl Iterator<Item = &ModuleName> {
        self.0.keys()
    }
}
