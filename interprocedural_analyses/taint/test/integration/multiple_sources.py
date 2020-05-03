class Node:
    def __init__(self, id) -> None:
        self.id = id

    def send(self, vc) -> None:
        ...

    @classmethod
    def get(cls, id) -> "Node":
        return cls(id)


def user_controlled_input():
    return "evil"


def permissive_context():
    return 0


def combine_tainted_user_and_dangerous_vc():
    id = user_controlled_input()
    vc = permissive_context()
    Node.get(id).send(vc)


def demonstrate_triggered_context(vc):
    id = user_controlled_input()
    Node.get(id).send(vc)


def demonstrate_triggered_input(id):
    vc = permissive_context()
    Node.get(id).send(vc)


def issue_with_triggered_input():
    id = user_controlled_input()
    demonstrate_triggered_input(id)


def issue_with_triggered_context():
    vc = permissive_context()
    demonstrate_triggered_context(vc)


def no_issue_with_wrong_label():
    vc = permissive_context()
    demonstrate_triggered_input(vc)
