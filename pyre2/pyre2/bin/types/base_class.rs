//! Something suitable as a base class.

use std::fmt;
use std::fmt::Display;

use ruff_text_size::TextRange;

use crate::error::collector::ErrorCollector;
use crate::module::module_info::ModuleInfo;
use crate::types::class::ClassType;
use crate::types::types::Type;
use crate::util::display::commas_iter;

#[derive(Debug, Clone)]
pub enum BaseClass {
    #[expect(dead_code)] // Will be used in the future
    NamedTuple,
    #[expect(dead_code)] // Will be used in the future
    TypedDict,
    Generic(Vec<Type>),
    Protocol(Vec<Type>),
    Type(Type),
}

impl Display for BaseClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BaseClass::NamedTuple => write!(f, "NamedTuple"),
            BaseClass::TypedDict => write!(f, "TypedDict"),
            BaseClass::Generic(xs) => write!(f, "Generic[{}]", commas_iter(|| xs.iter())),
            BaseClass::Protocol(xs) => write!(f, "Protocol[{}]", commas_iter(|| xs.iter())),
            BaseClass::Type(t) => write!(f, "{t}"),
        }
    }
}

impl BaseClass {
    pub fn visit_mut<'a>(&'a mut self, mut f: impl FnMut(&'a mut Type)) {
        match self {
            BaseClass::Generic(xs) | BaseClass::Protocol(xs) => xs.iter_mut().for_each(f),
            BaseClass::Type(t) => f(t),
            BaseClass::NamedTuple | BaseClass::TypedDict => {}
        }
    }

    pub fn subst_self_type_mut(&mut self, self_type: &Type) {
        self.visit_mut(|x| x.subst_self_type_mut(self_type));
    }

    pub fn can_apply(&self) -> bool {
        matches!(self, BaseClass::Generic(_) | BaseClass::Protocol(_))
    }

    pub fn apply(&mut self, args: Vec<Type>) {
        match self {
            BaseClass::Generic(xs) | BaseClass::Protocol(xs) => {
                xs.extend(args);
            }
            _ => panic!("cannot apply base class"),
        }
    }

    pub fn as_class_and_targs(&self) -> Option<ClassType> {
        match self {
            BaseClass::Type(Type::ClassType(c)) => Some(c.clone()),
            _ => None,
        }
    }

    /// If this is a `Generic` base class or `Protocol` base class with
    /// arguments, return those arguments, which in pre-PEP 695 syntax will
    /// determine the type parameters of the class.
    ///
    /// Otherwise, return `None`.
    #[allow(dead_code)]
    pub fn as_tparams(
        &self,
        module_info: &ModuleInfo,
        range: TextRange,
        errors: &ErrorCollector,
    ) -> Option<Vec<Type>> {
        match self {
            Self::Generic(targs) => {
                if targs.is_empty() {
                    // TODO: Base classes need to remember their location so we can do better here.
                    // For now, we're using the class name as the location for validation errors.
                    errors.add(
                        module_info,
                        range,
                        "A `Generic` base class must specify nonempty type parameters.".to_owned(),
                    );
                }
                Some(targs.clone())
            }
            Self::Protocol(targs) if !targs.is_empty() => Some(targs.clone()),
            _ => None,
        }
    }
}
