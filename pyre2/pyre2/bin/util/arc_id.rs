/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

//! Like `Arc`, but the Eq/Ord/Hash implementations are based on the pointer.

use std::cmp::Ordering;
use std::fmt;
use std::fmt::Display;
use std::hash::Hash;
use std::hash::Hasher;
use std::ops::Deref;
use std::sync::Arc;

use dupe::Clone_;
use dupe::Dupe_;

/// An `Arc` where `Eq`, `Hash` and `Ord` are based on the pointer.
/// As a result, things like Hash/Ord might be unstable between multiple program runs.
#[derive(Debug, Clone_, Dupe_)]
pub struct ArcId<T: ?Sized>(Arc<T>);

impl<T: ?Sized> AsRef<T> for ArcId<T> {
    fn as_ref(&self) -> &T {
        self.0.as_ref()
    }
}

impl<T: ?Sized> Deref for ArcId<T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.0.deref()
    }
}

impl<T: Display + ?Sized> Display for ArcId<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        Display::fmt(&self.0, f)
    }
}

impl<T: ?Sized> PartialEq for ArcId<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id() == other.id()
    }
}

impl<T: ?Sized> Eq for ArcId<T> {}

impl<T: PartialOrd + ?Sized> PartialOrd for ArcId<T> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        if self.id() == other.id() {
            return Some(Ordering::Equal);
        }
        let res = self.0.partial_cmp(&other.0)?;
        if res == Ordering::Equal {
            // If they are equal, but we know they aren't equal from an Id perspective,
            // then we have to order them somehow - use the relative id ordering.
            Some(self.id().cmp(&other.id()))
        } else {
            Some(res)
        }
    }
}

impl<T: Ord + ?Sized> Ord for ArcId<T> {
    fn cmp(&self, other: &Self) -> Ordering {
        if self.id() == other.id() {
            return Ordering::Equal;
        }
        let res = self.0.cmp(&other.0);
        if res == Ordering::Equal {
            // If they are equal, but we know they aren't equal from an Id perspective,
            // then we have to order them somehow - use the relative id ordering.
            self.id().cmp(&other.id())
        } else {
            res
        }
    }
}

impl<T: ?Sized> Hash for ArcId<T> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.id().hash(state);
    }
}

impl<T: Default> Default for ArcId<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T> ArcId<T> {
    pub fn new(id: T) -> Self {
        Self(Arc::new(id))
    }
}

impl<T: ?Sized> ArcId<T> {
    // We can convert an `impl` into a `dyn` with `Arc::new`, but not `ArcId::new`.
    // Reason is we don't implemented `UnsizedCoerce` (which is unstable), but using
    // `from_arc` is a simple workaround.
    pub fn from_arc(x: Arc<T>) -> Self {
        Self(x)
    }

    pub fn id(&self) -> usize {
        Arc::as_ptr(&self.0) as *const () as usize
    }
}
