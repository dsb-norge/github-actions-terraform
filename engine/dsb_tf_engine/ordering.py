"""Ordering between environments: rule 6 of docs/Decision-engine.md §6, docs/Environment-ordering.md.

An environment declares what it follows in `depends-on`; the declared graph is validated whatever
the run, and the environments that run are assigned stages: one more than the highest stage among
their dependencies in the run, free-standing environments in the last stage in use. A run that
mutates nothing, or a dispatch naming one environment, is one stage.
"""

from .environments import ConfigError, as_list, near_miss, shown
from .triggers import DISPATCH, dispatch_inputs

FIELD = "depends-on"
# One job per stage in the workflow; raising the cap is one job block and this constant.
CAP = 3
STAGES = tuple(str(stage) for stage in range(1, CAP + 1))
MUTATING = ("apply", "destroy")
BYPASS = "single-environment-dispatch"


def declared_dependencies(entry):
    """What an environments-yml entry declares it depends on, as a list."""
    return as_list(entry.get(FIELD))


def _name_problems(names, entry):
    name = entry["environment"]
    value = entry.get(FIELD)
    dependencies = as_list(value)
    if not isinstance(dependencies, list):
        return [f"The environment '{name}' sets '{FIELD}' to {shown(value)}; it must be a list of environment names."]
    problems = []
    for dependency in dependencies:
        if isinstance(dependency, (int, float)) and not isinstance(dependency, bool):
            problems.append(f"The environment '{name}' depends on {shown(dependency)}, which is not an environment "
                            "name; quote it if it is one.")
        elif not isinstance(dependency, str):
            problems.append(f"The environment '{name}' depends on {shown(dependency)}, which is not an environment "
                            "name.")
        elif dependency == name:
            problems.append(f"The environment '{name}' depends on itself, so it could never run; remove '{name}' "
                            f"from its {FIELD}.")
        elif dependency not in names:
            guess = near_miss(dependency, names)
            hint = f"; did you mean '{guess}'?" if guess else f". The environments are {', '.join(names)}."
            problems.append(f"The environment '{name}' depends on {shown(dependency)}, which is not an environment "
                            f"of environments-yml{hint}")
    return problems


def _cycle(graph, names):
    """One cycle of the graph in run order (a dependency before what depends on it), starting at its
    member declared first, or None. Peel off every environment whose dependencies are all peeled;
    what is left depends on a cycle or is on one, so following dependencies within it must repeat."""
    left = names
    free = [None]
    while free:
        free = [name for name in left if not any(dependency in left for dependency in graph[name])]
        left = [name for name in left if name not in free]
    if not left:
        return None
    path, step = [], left[0]
    while step not in path:
        path.append(step)
        step = next(dependency for dependency in graph[step] if dependency in left)
    loop = list(reversed(path[path.index(step):]))
    first = loop.index(min(loop, key=names.index))
    return loop[first:] + loop[:first + 1]


def _longest_chain(graph, names):
    """The longest chain of the acyclic graph in run order, the first in declaration order on a tie,
    by relaxation: the graph may be deep and wide until the cap is checked."""
    depth = {name: 1 for name in names}
    for _ in names:
        for name in names:
            for dependency in graph[name]:
                depth[name] = max(depth[name], depth[dependency] + 1)
    chain = [max(names, key=depth.get)]
    while depth[chain[-1]] > 1:
        chain.append(next(dependency for dependency in graph[chain[-1]] if depth[dependency] == depth[chain[-1]] - 1))
    return list(reversed(chain))


def check(declared):
    """Every problem of the declared graph (docs/Environment-ordering.md §5), or a ConfigError. The rows
    are built, so every entry is a mapping with a unique, valid name."""
    names = [entry["environment"] for entry in declared]
    problems = [problem for entry in declared for problem in _name_problems(names, entry)]
    if problems:
        raise ConfigError(problems)
    graph = {entry["environment"]: declared_dependencies(entry) for entry in declared}
    loop = _cycle(graph, names)
    if loop:
        raise ConfigError([f"{FIELD} forms a cycle, {' → '.join(loop)}, so none of them could ever run first; "
                           "remove one of the dependencies."])
    longest = _longest_chain(graph, names)
    if len(longest) > CAP:
        raise ConfigError([f"{FIELD} needs {len(longest)} stages, but the workflow runs at most {CAP}: "
                           f"{' → '.join(longest)}. Flatten the chain, or split the repository."])


def _stages(graph, running):
    """Each running environment's stage: 1 without a dependency in the run, else one more than the
    highest stage among its dependencies in the run. The graph is at most three deep by now, so the
    recursion is short."""

    def stage(name):
        return 1 + max((stage(dependency) for dependency in graph[name] if dependency in running), default=0)

    return {name: stage(name) for name in running}


def assign(document, declared, rows, entries, granted):
    """Stage every running environment, record why on its entry, and return the ordering block, the
    stage of each running row by index, and the notices."""
    names = [row["environment"] for row in rows]
    graph = {entry["environment"]: declared_dependencies(entry) for entry in declared}
    running = [names[index] for index, entry in enumerate(entries) if entry["verdict"] == "run"]
    mutating = any(goal in granted[index] for index in granted for goal in MUTATING)
    named = document["event"]["name"] == DISPATCH and dispatch_inputs(document)["environment"] != ""
    block = {"declared": any(graph.values()), "stages_used": 1, "cap": CAP, "bypass": BYPASS if named else None}
    notices = []
    if named or not mutating:
        stages = {name: 1 for name in running}
    else:
        stages = _stages(graph, running)
        # Something mutates, so something runs.
        last = max(stages.values())
        dependents = {dependency for dependencies in graph.values() for dependency in dependencies}
        for name in running:
            if not graph[name] and name not in dependents:
                stages[name] = last
        block["stages_used"] = last
    for index, entry in enumerate(entries):
        entry[FIELD] = graph[names[index]]
        if entry["verdict"] != "run":
            continue
        name = names[index]
        entry["stage"] = stages[name]
        missing = [dependency for dependency in graph[name] if dependency not in stages]
        if named and graph[name]:
            entry["reasons"].append("ordering: single-environment dispatch, stage 1")
            notices.append(f"ordering bypassed: '{name}' depends on {', '.join(repr(each) for each in graph[name])}, "
                           "which a single-environment dispatch does not run")
            continue
        if block["stages_used"] > 1:
            entry["reasons"].append(f"ordering: stage {stages[name]}")
        if mutating:
            for dependency in missing:
                why = entries[names.index(dependency)]["reasons"][0]
                entry["reasons"].append(f"ordering: depends-on '{dependency}' not in this run ({why})")
                notices.append(f"ordering: '{name}' depends on '{dependency}', which is not in this run ({why}), so it "
                               "runs without waiting for it")
    return block, {index: stages[names[index]] for index, entry in enumerate(entries) if entry["verdict"] == "run"}, \
        notices
