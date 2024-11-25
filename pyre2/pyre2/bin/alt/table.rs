/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

//! Things that abstract over the binding types.

use std::fmt::Debug;
use std::fmt::Display;
use std::hash::Hash;

use ruff_text_size::Ranged;

use crate::alt::binding::Binding;
use crate::alt::binding::BindingAnnotation;
use crate::alt::binding::BindingBaseClass;
use crate::alt::binding::BindingLegacyTypeParam;
use crate::alt::binding::BindingMro;
use crate::alt::binding::BindingTypeParams;
use crate::alt::binding::Key;
use crate::alt::binding::KeyAnnotation;
use crate::alt::binding::KeyBaseClass;
use crate::alt::binding::KeyExported;
use crate::alt::binding::KeyLegacyTypeParam;
use crate::alt::binding::KeyMro;
use crate::alt::binding::KeyTypeParams;
use crate::alt::bindings::Bindings;
use crate::types::annotation::Annotation;
use crate::types::base_class::BaseClass;
use crate::types::mro::Mro;
use crate::types::types::LegacyTypeParameterLookup;
use crate::types::types::QuantifiedVec;
use crate::types::types::Type;
use crate::util::display::DisplayWith;

pub trait Keyed: Hash + Eq + Clone + Display + Debug + Ranged + 'static {
    type Value: Debug + DisplayWith<Bindings>;
    type Answer: Clone + Debug + Display;
}

impl Keyed for Key {
    type Value = Binding;
    type Answer = Type;
}
impl Keyed for KeyExported {
    type Value = Binding;
    type Answer = Type;
}
impl Keyed for KeyAnnotation {
    type Value = BindingAnnotation;
    type Answer = Annotation;
}
impl Keyed for KeyBaseClass {
    type Value = BindingBaseClass;
    type Answer = BaseClass;
}
impl Keyed for KeyMro {
    type Value = BindingMro;
    type Answer = Mro;
}
impl Keyed for KeyLegacyTypeParam {
    type Value = BindingLegacyTypeParam;
    type Answer = LegacyTypeParameterLookup;
}
impl Keyed for KeyTypeParams {
    type Value = BindingTypeParams;
    type Answer = QuantifiedVec;
}

pub trait TableKeyed<K> {
    type Value;
    fn get(&self) -> &Self::Value;
    fn get_mut(&mut self) -> &mut Self::Value;
}

#[macro_export]
macro_rules! table {
    (#[$($derive:tt)*] pub struct $name:ident(pub $t:tt)) => {
        table!(@impl, [pub], #[$($derive)*] pub struct $name($t));
    };
    (#[$($derive:tt)*] pub struct $name:ident($t:tt)) => {
        table!(@impl, [], #[$($derive)*] pub struct $name($t));
    };
    (@impl, [$($vis:tt)*], #[$($derive:tt)*] pub struct $name:ident($t:tt)) => {
        #[$($derive)*]
        pub struct $name {
            $($vis)* types: $t<Key>,
            $($vis)* exported_types: $t<KeyExported>,
            $($vis)* annotations: $t<KeyAnnotation>,
            $($vis)* base_classes: $t<KeyBaseClass>,
            $($vis)* mros: $t<KeyMro>,
            $($vis)* legacy_tparams: $t<KeyLegacyTypeParam>,
            $($vis)* tparams: $t<KeyTypeParams>,
        }

        impl $crate::alt::table::TableKeyed<Key> for $name {
            type Value = $t<Key>;
            fn get(&self) -> &Self::Value { &self.types }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.types }
        }

        impl $crate::alt::table::TableKeyed<KeyExported> for $name {
            type Value = $t<KeyExported>;
            fn get(&self) -> &Self::Value { &self.exported_types }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.exported_types }
        }

        impl $crate::alt::table::TableKeyed<KeyAnnotation> for $name {
            type Value = $t<KeyAnnotation>;
            fn get(&self) -> &Self::Value { &self.annotations }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.annotations }
        }

        impl $crate::alt::table::TableKeyed<KeyBaseClass> for $name {
            type Value = $t<KeyBaseClass>;
            fn get(&self) -> &Self::Value { &self.base_classes }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.base_classes }
        }

        impl $crate::alt::table::TableKeyed<KeyMro> for $name {
            type Value = $t<KeyMro>;
            fn get(&self) -> &Self::Value { &self.mros }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.mros }
        }

        impl $crate::alt::table::TableKeyed<KeyLegacyTypeParam> for $name {
            type Value = $t<KeyLegacyTypeParam>;
            fn get(&self) -> &Self::Value { &self.legacy_tparams }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.legacy_tparams }
        }

        impl $crate::alt::table::TableKeyed<KeyTypeParams> for $name {
            type Value = $t<KeyTypeParams>;
            fn get(&self) -> &Self::Value { &self.tparams }
            fn get_mut(&mut self) -> &mut Self::Value { &mut self.tparams }
        }

        impl $name {
            #[allow(dead_code)]
            fn get<K>(&self) -> &<Self as $crate::alt::table::TableKeyed<K>>::Value
            where
                Self: $crate::alt::table::TableKeyed<K>,
            {
                $crate::alt::table::TableKeyed::<K>::get(self)
            }

            #[allow(dead_code)]
            fn get_mut<K>(&mut self) -> &mut <Self as $crate::alt::table::TableKeyed<K>>::Value
            where
                Self: $crate::alt::table::TableKeyed<K>,
            {
                $crate::alt::table::TableKeyed::<K>::get_mut(self)
            }
        }
    };
}

#[macro_export]
macro_rules! table_for_each(
    ($e:expr, $f:expr) => {
        $f(&($e).types);
        $f(&($e).exported_types);
        $f(&($e).annotations);
        $f(&($e).base_classes);
        $f(&($e).mros);
        $f(&($e).legacy_tparams);
        $f(&($e).tparams);
    };
);

#[macro_export]
macro_rules! table_mut_for_each(
    ($e:expr, $f:expr) => {
        $f(&mut ($e).types);
        $f(&mut ($e).exported_types);
        $f(&mut ($e).annotations);
        $f(&mut ($e).base_classes);
        $f(&mut ($e).mros);
        $f(&mut ($e).legacy_tparams);
        $f(&mut ($e).tparams);
    };
);

#[macro_export]
macro_rules! table_try_for_each(
    ($e:expr, $f:expr) => {
        $f(&($e).types)?;
        $f(&($e).exported_types)?;
        $f(&($e).annotations)?;
        $f(&($e).base_classes)?;
        $f(&($e).mros)?;
        $f(&($e).legacy_tparams)?;
        $f(&($e).tparams)?;
    };
);
