#!/usr/bin/env python3
"""Mutation testing of the engine: every small fault injected into dsb_tf_engine must fail a test.

Line and branch coverage proves each line ran; it does not prove a test would notice the line
deciding wrongly. This tool rewrites the package's syntax tree one fault at a time — a comparison
flipped, a boolean inverted, a condition forced, a statement deleted, a raise swallowed, an element
dropped from a constant list — and runs the suite against each mutant in its own copy of engine/.
A mutant that no test kills is a decision nothing checks.

Some mutants cannot change behaviour (they are equivalent to the original); each is listed in
mutation_equivalents.json with the reason. The gate fails on a surviving mutant that is not
listed, and on a listed one that no longer exists, so the list cannot go stale.

Each mutant runs the tests of the module it mutates first, then every other fast module, then the
two slow ones, stopping at the first failure: most mutants die within a second. A mutant still
running after three times the unmutated suite's duration (at least a minute) counts as killed: it
hangs, or slows the suite past anything a real run could be. Each run names the mutants that hung
and the slowest one that did not, the numbers the timeout and the shard count are tuned by.

Usage:
  mutation.py                    run every mutant, print survivors, exit 1 if the gate fails
  mutation.py --list             print every mutant's key without running anything
  mutation.py --shard K/N --out FILE
                                 run the K-th of N interleaved shards and write its survivors to
                                 FILE, judging nothing (CI runs the shards in parallel jobs)
  mutation.py --merge FILE...    apply the gate to the shards' files, which must cover every
                                 mutant exactly once
  mutation.py --run-suite [MODULE]
                                 (internal) run the suite of the engine copy in the working
                                 directory, the tests of MODULE first, stopping at the first failure
"""

import ast
import concurrent.futures
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(TESTS_DIR)
PACKAGE_DIR = os.path.join(ENGINE_DIR, "dsb_tf_engine")
EQUIVALENTS_FILE = os.path.join(TESTS_DIR, "mutation_equivalents.json")
REPO_GITHUB_DIR = os.path.join(os.path.dirname(ENGINE_DIR), ".github")

# Every other module takes a fraction of a second; these two take nearly all of the suite's time,
# so they run last and a mutant rarely reaches them.
SLOW_LAST = ("test_generated", "test_determinism")
# A module's own tests, where the name does not say it.
OWN_TESTS = {"__main__.py": "test_cli", "__init__.py": "test_model", "automerge_facts.py": "test_automerge"}
# A hung mutant counts as killed after this many baseline durations, and never before the floor.
TIMEOUT_FACTOR, TIMEOUT_FLOOR, BASELINE_TIMEOUT = 3, 60, 300

COMPARE_SWAPS = {
    ast.Eq: [ast.NotEq], ast.NotEq: [ast.Eq], ast.Lt: [ast.LtE, ast.GtE], ast.LtE: [ast.Lt, ast.Gt],
    ast.Gt: [ast.GtE, ast.LtE], ast.GtE: [ast.Gt, ast.Lt], ast.Is: [ast.IsNot], ast.IsNot: [ast.Is],
    ast.In: [ast.NotIn], ast.NotIn: [ast.In],
}
BINOP_SWAPS = {ast.Add: ast.Sub, ast.Sub: ast.Add}


def _is_docstring(node, parent):
    return (isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str) and parent is not None
            and isinstance(parent, (ast.Module, ast.FunctionDef, ast.ClassDef)) and parent.body
            and parent.body[0] is node)


def _candidates(tree):
    """Yield (node, parent, field, index, operator, replacement-factory) for every mutation point."""
    parents = {}
    for parent in ast.walk(tree):
        for child in ast.iter_child_nodes(parent):
            parents[child] = parent

    for node in ast.walk(tree):
        parent = parents.get(node)
        if isinstance(node, ast.Compare):
            for position, op in enumerate(node.ops):
                for swap in COMPARE_SWAPS.get(type(op), []):
                    yield node, f"{type(op).__name__}->{swap.__name__}", \
                        lambda n, p=position, s=swap: _set_op(n, p, s)
        elif isinstance(node, ast.BoolOp):
            other = ast.Or if isinstance(node.op, ast.And) else ast.And
            yield node, f"{type(node.op).__name__}->{other.__name__}", lambda n, o=other: _replace_attr(n, "op", o())
        elif isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            yield node, "drop not", lambda n: n.operand
        elif isinstance(node, ast.BinOp) and type(node.op) in BINOP_SWAPS:
            yield node, f"{type(node.op).__name__}->{BINOP_SWAPS[type(node.op)].__name__}", \
                lambda n: _replace_attr(n, "op", BINOP_SWAPS[type(n.op)]())
        elif isinstance(node, ast.Constant) and not isinstance(parent, ast.JoinedStr):
            if parent is not None and _is_docstring(parent, parents.get(parent)):
                continue
            value = node.value
            if value is True or value is False:
                yield node, f"{value}->{not value}", lambda n: ast.Constant(not n.value)
            elif isinstance(value, int):
                yield node, f"{value}->{value + 1}", lambda n: ast.Constant(n.value + 1)
                if value != 0:
                    yield node, f"{value}->0", lambda n: ast.Constant(0)
            elif isinstance(value, str) and value != "":
                yield node, "string->empty", lambda n: ast.Constant("")
        elif isinstance(node, (ast.Tuple, ast.List)) and len(node.elts) > 1 and all(
                isinstance(e, ast.Constant) for e in node.elts):
            for position in range(len(node.elts)):
                yield node, f"drop element {position}", lambda n, p=position: _drop(n, p)
        if isinstance(node, ast.comprehension):
            for position in range(len(node.ifs)):
                for value in (True, False):
                    yield node, f"comprehension filter {position}->{value}", \
                        lambda n, p=position, v=value: _set_if(n, p, v)
        if isinstance(node, ast.ExceptHandler) and isinstance(node.type, ast.Tuple) and len(node.type.elts) > 1:
            for position in range(len(node.type.elts)):
                yield node, f"drop exception {position}", lambda n, p=position: _drop_exception(n, p)
        if (isinstance(node, ast.Call) and len(node.args) == 1 and not node.keywords
                and ast.unparse(node.func) in ("dict", "list", "copy.deepcopy")):
            yield node, "copy->alias", lambda n: n.args[0]
        if isinstance(node, (ast.If, ast.IfExp, ast.While)):
            yield node, "condition->True", lambda n: _replace_attr(n, "test", ast.Constant(True))
            yield node, "condition->False", lambda n: _replace_attr(n, "test", ast.Constant(False))
        if isinstance(node, ast.Return) and node.value is not None and not (
                isinstance(node.value, ast.Constant) and node.value.value is None):
            yield node, "return None", lambda n: _replace_attr(n, "value", ast.Constant(None))
        if isinstance(node, ast.Raise):
            yield node, "raise->pass", lambda n: ast.Pass()
        elif isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Expr)) and not _is_docstring(node, parent):
            if isinstance(parent, (ast.FunctionDef, ast.If, ast.For, ast.While, ast.With, ast.Try)):
                yield node, "delete statement", lambda n: ast.Pass()


def _set_op(node, position, swap):
    node.ops[position] = swap()
    return node


def _replace_attr(node, attr, value):
    setattr(node, attr, value)
    return node


def _set_if(node, position, value):
    node.ifs[position] = ast.Constant(value)
    return node


def _drop_exception(node, position):
    del node.type.elts[position]
    return node


def _drop(node, position):
    del node.elts[position]
    return node


class _Apply(ast.NodeTransformer):
    """Replace the target-th candidate node with its mutation."""

    def __init__(self, target, factory):
        self.target, self.factory = target, factory

    def generic_visit(self, node):
        super().generic_visit(node)
        return self.factory(node) if node is self.target else node


def _source(name):
    with open(os.path.join(PACKAGE_DIR, name), encoding="utf-8") as handle:
        return handle.read()


def mutants():
    """Yield (key, module file, line, index) for every mutant, in a stable order: one walk of each
    module's unmutated tree, which gives every candidate's key; the mutated source is built from the
    index where the mutant runs (mutated_source)."""
    for name in sorted(os.listdir(PACKAGE_DIR)):
        if not name.endswith(".py"):
            continue
        seen = {}
        for index, (node, operator, _factory) in enumerate(_candidates(ast.parse(_source(name)))):
            snippet = " ".join(ast.unparse(node).split())[:80]
            base = f"{name}: {operator}: {snippet}"
            seen[base] = seen.get(base, 0) + 1
            key = base if seen[base] == 1 else f"{base} #{seen[base]}"
            yield key, name, getattr(node, "lineno", 0), index


def mutated_source(name, index):
    """The module's source with its index-th candidate mutated, from a fresh tree."""
    tree = ast.parse(_source(name))
    node, _operator, factory = next(itertools.islice(_candidates(tree), index, None))
    return ast.unparse(ast.fix_missing_locations(_Apply(node, factory).visit(tree)))


def _run_mutant(args):
    """(key, module, line, killed, seconds); the baseline is (key, None, 0, None, timeout)."""
    key, name, line, index, timeout = args
    started = time.monotonic()
    work = tempfile.mkdtemp()
    try:
        copy_dir = os.path.join(work, "engine")
        shutil.copytree(ENGINE_DIR, copy_dir, ignore=shutil.ignore_patterns("__pycache__", ".coverage"))
        # The workflow-contract tests read the repository's workflow beside engine/.
        os.symlink(REPO_GITHUB_DIR, os.path.join(work, ".github"))
        command = [sys.executable, "-B", os.path.join(copy_dir, "tests", "mutation.py"), "--run-suite"]
        if name is not None:
            with open(os.path.join(copy_dir, "dsb_tf_engine", name), "w", encoding="utf-8") as handle:
                handle.write(mutated_source(name, index))
            command.append(name)
        try:
            proc = subprocess.run(command, cwd=copy_dir, capture_output=True, timeout=timeout,
                                  env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
            killed = proc.returncode != 0
        except subprocess.TimeoutExpired:
            killed = True
        return key, name, line, killed, time.monotonic() - started
    finally:
        shutil.rmtree(work, ignore_errors=True)


def suite_order(discovered, mutated=None):
    """The mutated module's own tests first, then the fast modules, then the slow ones."""
    own = OWN_TESTS.get(mutated, f"test_{mutated[:-3]}") if mutated else None
    first = [own] if own in discovered else []
    fast = sorted(discovered - set(first) - set(SLOW_LAST))
    return first + fast + [module for module in SLOW_LAST if module in discovered]


def run_suite(mutated=None):
    sys.path[:0] = [ENGINE_DIR, TESTS_DIR]
    loader = unittest.defaultTestLoader
    discovered = {name[:-3] for name in os.listdir(TESTS_DIR) if name.startswith("test_") and name.endswith(".py")}
    suite = unittest.TestSuite(loader.loadTestsFromName(module) for module in suite_order(discovered, mutated))
    with open(os.devnull, "w") as devnull:
        result = unittest.TextTestRunner(stream=devnull, failfast=True).run(suite)
    return 0 if result.wasSuccessful() else 1


def _run(selected, label):
    """Run the selected mutants; the survivors as (key, module, line), or None without a passing
    baseline, since then every mutant would count as killed for a reason no mutant caused."""
    _key, _name, _line, failed, seconds = _run_mutant(("baseline", None, 0, None, BASELINE_TIMEOUT))
    if failed:
        print("mutation: the unmutated engine fails its suite in a copy; no mutant can be judged")
        return None
    timeout = max(TIMEOUT_FLOOR, TIMEOUT_FACTOR * seconds)
    workers = max(1, os.cpu_count() or 1)
    print(f"mutation: {len(selected)} mutants of dsb_tf_engine{label}, {workers} workers, "
          f"baseline {seconds:.1f}s, timeout {timeout:.0f}s", flush=True)
    survivors, hung, slowest = [], [], 0.0
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
        for key, name, line, killed, seconds in pool.map(
                _run_mutant, [(key, name, line, index, timeout) for key, name, line, index in selected]):
            if seconds >= timeout:
                hung.append(key)
            else:
                slowest = max(slowest, seconds)
            if not killed:
                survivors.append((key, name, line))
    print(f"mutation: {len(hung)} hung past {timeout:.0f}s and count as killed; the slowest of the rest took "
          f"{slowest:.1f}s", flush=True)
    for key in hung:
        print(f"  HUNG {key}")
    return survivors


def _shard(value):
    number, _, total = value.partition("/")
    if not (number.isdigit() and total.isdigit() and 1 <= int(number) <= int(total)):
        raise SystemExit(f"mutation: --shard takes K/N with 1 <= K <= N, not {value!r}")
    return int(number), int(total)


def _merge(files, every):
    """The survivors of every shard, or None when the shards do not cover every mutant once."""
    ran, survivors = [], []
    for path in files:
        with open(path, encoding="utf-8") as handle:
            shard = json.load(handle)
        ran += shard["keys"]
        survivors += [tuple(survivor) for survivor in shard["survivors"]]
    keys = [key for key, *_ in every]
    if sorted(ran) != sorted(keys):
        missing = sorted(set(keys) - set(ran))
        extra = sorted(set(key for key in ran if key not in keys or ran.count(key) > 1))
        print(f"mutation: the shards ran {len(ran)} mutants of {len(keys)}, "
              f"{len(missing)} missing and {len(extra)} unknown or repeated; nothing is judged")
        for key in (missing + extra)[:20]:
            print(f"  {key}")
        return None
    return survivors


def main(argv):
    if "--run-suite" in argv:
        rest = argv[argv.index("--run-suite") + 1:]
        return run_suite(rest[0] if rest else None)
    every = list(mutants())
    if "--list" in argv:
        for key, *_ in every:
            print(key)
        return 0

    if "--shard" in argv:
        number, total = _shard(argv[argv.index("--shard") + 1])
        # Interleaved, so every shard holds a share of every module and of its slow mutants.
        selected = every[number - 1::total]
        survivors = _run(selected, f", shard {number}/{total}")
        if survivors is None:
            return 1
        with open(argv[argv.index("--out") + 1], "w", encoding="utf-8") as handle:
            json.dump({"keys": [key for key, *_ in selected], "survivors": survivors}, handle)
        print(f"mutation: shard {number}/{total}: {len(selected) - len(survivors)} killed, "
              f"{len(survivors)} survived; judged when the shards are merged")
        return 0
    if "--merge" in argv:
        survivors = _merge(argv[argv.index("--merge") + 1:], every)
    else:
        survivors = _run(every, "")
    if survivors is None:
        return 1

    with open(EQUIVALENTS_FILE, encoding="utf-8") as handle:
        equivalents = json.load(handle)
    keys = {key for key, *_ in every}
    unexplained = [s for s in survivors if s[0] not in equivalents]
    stale = sorted(k for k in equivalents if k not in keys)
    killed_listed = sorted(k for k in equivalents if k in keys and k not in {s[0] for s in survivors})
    print(f"mutation: {len(every) - len(survivors)} killed, {len(survivors)} survived, "
          f"{len(survivors) - len(unexplained)} of them listed as equivalent")
    for key, name, line in unexplained:
        print(f"  SURVIVED {name}:{line}  {key}")
    for key in stale:
        print(f"  STALE equivalent (no such mutant any more): {key}")
    for key in killed_listed:
        print(f"  LISTED AS EQUIVALENT BUT KILLED (remove it): {key}")
    return 1 if unexplained or stale or killed_listed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
