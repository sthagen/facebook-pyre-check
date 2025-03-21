/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::any;
use std::any::Any;

use const_str;
use ruff_python_ast::name::Name;
use ruff_text_size::TextRange;
use vec1::Vec1;

use crate::module::module_name::ModuleName;
use crate::util::uniques::Unique;

/// Visitors based on <https://ndmitchell.com/#uniplate_30_sep_2007>.
pub trait Visit<To: 'static = Self>: 'static + Sized {
    /// Whether the type contains `To` elements as children - is `visit` a no-op.
    const CONTAINS: bool = true;

    /// Whether the `visit0` is a no-op.
    const CONTAINS0: bool = Self::CONTAINS || type_eq::<To, Self>();

    /// Should call the function on all the `To` children of `Self`.
    ///
    /// Note the lifetime guarantee that every element will be contained in the original structure.
    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To));

    /// Like `visit`, but if `To == Self` then calls the function directly.
    fn visit0<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        if Self::CONTAINS0
            && let Some(to) = (self as &dyn Any).downcast_ref::<To>()
        {
            f(to);
        } else if Self::CONTAINS {
            self.visit(f)
        }
    }
}

/// Like `Visit`, but mutably.
pub trait VisitMut<To: 'static = Self>: 'static + Sized {
    const CONTAINS: bool = true;
    const CONTAINS0: bool = Self::CONTAINS || type_eq::<To, Self>();

    /// In contrast to `visit`, we don't have a guarantee that the results will be in
    /// the original structure. This decision is pragmatic - it's rare to mutate _and_
    /// store the values (since mutating probably means you can't capture them).
    /// Lacking the lifetimes means we can have an `Arc` implement `VisitMut` by doing
    /// a `clone()` first.
    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To));

    fn visit0_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        if let Some(to) = (self as &mut dyn Any).downcast_mut::<To>() {
            f(to);
        } else {
            self.visit_mut(f)
        }
    }
}

/// Type-level equality by types.
/// Seems to work, as we test it, but this is not ideal.
/// We'd really like to compare the `TypeId`, but that isn't `const` yet.
const fn type_eq<T1, T2>() -> bool {
    const_str::equal!(any::type_name::<T1>(), any::type_name::<T2>())
}

macro_rules! visit_nothing {
    ($t:ty) => {
        impl<To: 'static> Visit<To> for $t {
            const CONTAINS: bool = false;
            fn visit<'a>(&'a self, _: &mut dyn FnMut(&'a To)) {}
        }

        impl<To: 'static> VisitMut<To> for $t {
            const CONTAINS: bool = false;
            fn visit_mut(&mut self, _: &mut dyn FnMut(&mut To)) {}
        }
    };
}

visit_nothing!(bool);
visit_nothing!(u8);
visit_nothing!(u16);
visit_nothing!(u32);
visit_nothing!(u64);
visit_nothing!(u128);
visit_nothing!(usize);
visit_nothing!(i8);
visit_nothing!(i16);
visit_nothing!(i32);
visit_nothing!(i64);
visit_nothing!(i128);
visit_nothing!(isize);
visit_nothing!(());

// We can't visit `str` on its own, so this is atomic.
visit_nothing!(Box<str>);

// Pyrefly types that have nothing inside
visit_nothing!(Name);
visit_nothing!(Unique);
visit_nothing!(ModuleName);
visit_nothing!(TextRange);

impl<To: 'static, T: Visit<To>> Visit<To> for Vec<T> {
    const CONTAINS: bool = <T as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        for item in self {
            item.visit0(f);
        }
    }
}

impl<To: 'static, T: VisitMut<To>> VisitMut<To> for Vec<T> {
    const CONTAINS: bool = <T as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        for item in self {
            item.visit0_mut(f);
        }
    }
}

impl<To: 'static, T: Visit<To>> Visit<To> for Vec1<T> {
    const CONTAINS: bool = <T as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        for item in self {
            item.visit0(f);
        }
    }
}

impl<To: 'static, T: VisitMut<To>> VisitMut<To> for Vec1<T> {
    const CONTAINS: bool = <T as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        for item in self {
            item.visit0_mut(f);
        }
    }
}

impl<To: 'static, T: Visit<To>> Visit<To> for Box<[T]> {
    const CONTAINS: bool = <T as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        for item in self {
            item.visit0(f);
        }
    }
}

impl<To: 'static, T: VisitMut<To>> VisitMut<To> for Box<[T]> {
    const CONTAINS: bool = <T as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        for item in self {
            item.visit0_mut(f);
        }
    }
}

impl<To: 'static, T: Visit<To>> Visit<To> for Option<T> {
    const CONTAINS: bool = <T as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        if let Some(item) = self {
            item.visit0(f)
        }
    }
}

impl<To: 'static, T: VisitMut<To>> VisitMut<To> for Option<T> {
    const CONTAINS: bool = <T as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        if let Some(item) = self {
            item.visit0_mut(f);
        }
    }
}

impl<To: 'static, T: Visit<To>> Visit<To> for Box<T> {
    const CONTAINS: bool = <T as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        (**self).visit0(f)
    }
}

impl<To: 'static, T: VisitMut<To>> VisitMut<To> for Box<T> {
    const CONTAINS: bool = <T as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        (**self).visit0_mut(f)
    }
}

impl<To: 'static, T0: Visit<To>, T1: Visit<To>> Visit<To> for (T0, T1) {
    const CONTAINS: bool = <T0 as Visit<To>>::CONTAINS0 || <T1 as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        self.0.visit0(f);
        self.1.visit0(f);
    }
}

impl<To: 'static, T0: VisitMut<To>, T1: VisitMut<To>> VisitMut<To> for (T0, T1) {
    const CONTAINS: bool = <T0 as VisitMut<To>>::CONTAINS0 || <T1 as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        self.0.visit0_mut(f);
        self.1.visit0_mut(f);
    }
}

impl<To: 'static, T0: Visit<To>, T1: Visit<To>, T2: Visit<To>> Visit<To> for (T0, T1, T2) {
    const CONTAINS: bool = <T0 as Visit<To>>::CONTAINS0
        || <T1 as Visit<To>>::CONTAINS0
        || <T2 as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        self.0.visit0(f);
        self.1.visit0(f);
        self.2.visit0(f);
    }
}

impl<To: 'static, T0: VisitMut<To>, T1: VisitMut<To>, T2: VisitMut<To>> VisitMut<To>
    for (T0, T1, T2)
{
    const CONTAINS: bool = <T0 as VisitMut<To>>::CONTAINS0
        || <T1 as VisitMut<To>>::CONTAINS0
        || <T2 as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        self.0.visit0_mut(f);
        self.1.visit0_mut(f);
        self.2.visit0_mut(f);
    }
}

impl<To: 'static, T0: Visit<To>, T1: Visit<To>, T2: Visit<To>, T3: Visit<To>> Visit<To>
    for (T0, T1, T2, T3)
{
    const CONTAINS: bool = <T0 as Visit<To>>::CONTAINS0
        || <T1 as Visit<To>>::CONTAINS0
        || <T2 as Visit<To>>::CONTAINS0
        || <T3 as Visit<To>>::CONTAINS0;

    fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a To)) {
        self.0.visit0(f);
        self.1.visit0(f);
        self.2.visit0(f);
        self.3.visit0(f);
    }
}

impl<To: 'static, T0: VisitMut<To>, T1: VisitMut<To>, T2: VisitMut<To>, T3: VisitMut<To>>
    VisitMut<To> for (T0, T1, T2, T3)
{
    const CONTAINS: bool = <T0 as VisitMut<To>>::CONTAINS0
        || <T1 as VisitMut<To>>::CONTAINS0
        || <T2 as VisitMut<To>>::CONTAINS0
        || <T3 as VisitMut<To>>::CONTAINS0;

    fn visit_mut(&mut self, f: &mut dyn FnMut(&mut To)) {
        self.0.visit0_mut(f);
        self.1.visit0_mut(f);
        self.2.visit0_mut(f);
        self.3.visit0_mut(f);
    }
}

#[cfg(test)]
mod tests {
    use pyrefly_derive::Visit;
    use pyrefly_derive::VisitMut;
    use static_assertions::const_assert;

    use super::*;

    #[test]
    fn test_visit() {
        let mut info = (vec![1, 2, 3], Some(4i32), vec![Some(5i32)]);
        let mut collect = Vec::new();
        info.visit(&mut |x: &i32| collect.push(*x));
        assert_eq!(&collect, &[1i32, 2, 3, 4, 5]);

        info.visit_mut(&mut |x: &mut i32| *x *= 2);
        collect.clear();
        info.visit(&mut |x: &i32| collect.push(*x));
        assert_eq!(&collect, &[2i32, 4, 6, 8, 10]);
    }

    #[test]
    fn test_visit_contains() {
        let xs = vec![1i32, 2, 3];
        let mut count = 0;
        xs.visit(&mut |_: &i32| count += 1);
        assert_eq!(count, 3);
        count = 0;
        xs.visit(&mut |_: &bool| count += 1);
        assert_eq!(count, 0);

        struct Foo;
        impl Visit<i32> for Foo {
            const CONTAINS: bool = false;
            fn visit<'a>(&'a self, _: &mut dyn FnMut(&'a i32)) {
                unreachable!("Should not be reaching here")
            }
            fn visit0<'a>(&'a self, _: &mut dyn FnMut(&'a i32)) {
                // Deliberately implement visit0 so the optimisation on this doesn't kick in,
                // only the optimisation on Vec itself.
                unreachable!("Should not be reaching here")
            }
        }

        const_assert!(!<Foo as Visit<i32>>::CONTAINS0);
        const_assert!(!type_eq::<Foo, i32>());
        const_assert!(!<Foo as Visit<i32>>::CONTAINS);
        const_assert!(!<Vec<Foo> as Visit<i32>>::CONTAINS);
        const_assert!(!<Vec<Foo> as Visit<i32>>::CONTAINS0);
        vec![Foo].visit0(&mut |_: &i32| ());
    }

    #[derive(Visit, VisitMut, PartialEq, Eq, Debug)]
    struct Foo {
        x: i32,
        f: (Bar, Baz),
    }

    #[derive(Visit, VisitMut, PartialEq, Eq, Debug)]
    struct Bar(i32, i32);

    #[derive(Visit, VisitMut, PartialEq, Eq, Debug)]
    enum Baz {
        A,
        B(bool, bool),
        C { x: i32, y: i32 },
    }

    #[derive(Visit, VisitMut, PartialEq, Eq, Debug)]
    struct Generic<T>(T);

    #[test]
    fn test_visit_derive() {
        let mut info = (
            Foo {
                x: 1,
                f: (Bar(2, 3), Baz::B(true, false)),
            },
            Generic(Baz::A),
            Baz::C { x: 4, y: 5 },
        );
        let mut collect = Vec::new();
        info.visit0(&mut |x: &i32| collect.push(*x));
        assert_eq!(&collect, &[1i32, 2, 3, 4, 5]);
        let mut collect = Vec::new();
        info.visit0_mut(&mut |x: &mut bool| collect.push(*x));
        assert_eq!(&collect, &[true, false]);
        let mut collect = Vec::new();
        info.visit0(&mut |x: &Bar| collect.push(x));
        assert_eq!(&collect, &[&Bar(2, 3)]);

        const_assert!(<Foo as Visit<i32>>::CONTAINS0);
        const_assert!(!<Foo as Visit<u8>>::CONTAINS0);
        const_assert!(<Generic<i32> as Visit<i32>>::CONTAINS0);
        const_assert!(!<Generic<i32> as Visit<u8>>::CONTAINS0);
    }

    #[test]
    fn test_visit_subset() {
        #[derive(PartialEq, Eq, Debug)]
        struct Foo(i32);

        impl Visit<i32> for Foo {
            fn visit<'a>(&'a self, f: &mut dyn FnMut(&'a i32)) {
                f(&self.0);
            }
        }

        impl VisitMut<i32> for Foo {
            fn visit_mut(&mut self, f: &mut dyn FnMut(&mut i32)) {
                f(&mut self.0);
            }
        }

        /// We derive Visit/VisitMut for `Foo`, but know it will only work for i32
        #[derive(Visit, VisitMut, PartialEq, Eq, Debug)]
        struct Bar(Foo);

        let mut info = Bar(Foo(1));
        info.visit0_mut(&mut |x: &mut i32| *x += 2);
        let mut collect = Vec::new();
        info.visit0(&mut |x: &i32| collect.push(*x));
        assert_eq!(&collect, &[3i32]);
    }
}
