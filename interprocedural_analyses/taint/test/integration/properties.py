from typing import Optional


class Class:
    def __init__():
        self.tainted = ""
        self.untainted = ""

    @property
    def my_property(self) -> str:
        return self.tainted

    def uses_property(self):
        self.tainted = __test_source()
        return self.my_property

    def uses_property_but_no_tito_taint(self):
        self.untainted = __test_source()
        return self.my_property

    def uses_other(self, other: Optional[Class]):
        if other:
            return other.my_property
        else:
            return None


class Derived(Class):
    def uses_property(self):
        self.tainted = __test_source()
        return self.my_property

    def uses_property_but_no_tito_taint(self):
        self.untainted = __test_source()
        return self.my_property


class OtherDerived(Class):
    @property
    def my_property(self) -> str:
        return __test_source()

    def uses_property_but_no_tito_taint(self):
        self.untainted = __test_source()
        return self.my_property


class TaintedGetterAndSetter:
    # This will be the model.
    @property
    def my_property(self) -> str:
        # Ensure that setter taint doesn't pollute the getter, there shouldn't
        # be an issue here.
        __test_sink(self)
        return ""

    @my_property.setter
    def my_property(self, value) -> None:
        pass

    def uses_property(self):
        return self.my_property

    # TODO(T52657355): Handle the property write here.
    def writes_to_property(self):
        self.my_property = __test_source()


class DerivedTaintedSetter(TaintedGetterAndSetter):
    @property
    def my_property(self) -> str:
        return ""

    @my_property.setter
    def my_property(self, value) -> None:
        __test_sink(value)


class GrandDerived(DerivedTaintedSetter):
    @property
    def my_property(self) -> str:
        return ""

    @my_property.setter
    def my_property(self, value) -> None:
        return None


def sets_tainted_value(t: TaintedGetterAndSetter) -> None:
    t.my_property = __test_source()
