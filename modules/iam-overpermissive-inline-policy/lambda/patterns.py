def classify_action(action):
    if action == "*":
        return "full"
    if isinstance(action, str) and action.endswith(":*"):
        return "service"
    return None


def classify_statement(statement):
    if statement.get("Effect") != "Allow":
        return None
    actions = statement.get("Action")
    if actions is None:
        return None
    if isinstance(actions, str):
        actions = [actions]
    for action in actions:
        result = classify_action(action)
        if result is not None:
            return result
    return None
