def parse(composite):
    kind, rest = composite.split("/", 1)
    name, _, inline_policy_name = rest.partition("#")
    return (kind, name, inline_policy_name or None)


def format_id(kind, name, inline_policy_name=None):
    if inline_policy_name:
        return f"{kind}/{name}#{inline_policy_name}"
    return f"{kind}/{name}"
