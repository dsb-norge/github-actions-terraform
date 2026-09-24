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

Usage:
  mutation.py              run every mutant, print survivors, exit 1 if the gate fails
  mutation.py --list       print every mutant's key without running anything
  mutation.py --run-suite  (internal) run the suite of the engine copy in the working directory,
                           fast modules first, stopping at the first failure
"""

import ast
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(TESTS_DIR)
PACKAGE_DIR = os.path.join(ENGINE_DIR, "dsb_tf_engine")
EQUIVALENTS_FILE = os.path.join(TESTS_DIR, "mutation_equivalents.json")
REPO_GITHUB_DIR = os.path.join(os.path.dirname(ENGINE_DIR), ".github")

# Fastest first, so most mutants die within a second; the subprocess-heavy modules run last.
SUITE_ORDER = ("test_values", "test_workflow", "test_purity", "test_model", "test_validation", "test_environments",
               "test_invariants", "test_adapter", "test_port", "test_cli", "test_entry", "test_generated",
               "test_determinism")

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


def mutants():
    """Yield (key, relative path, line, mutated source) for every mutant, in a stable order."""
    for name in sorted(os.listdir(PACKAGE_DIR)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(PACKAGE_DIR, name)
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        seen = {}
        count = sum(1 for _ in _candidates(ast.parse(source)))
        for index in range(count):
            tree = ast.parse(source)
            node, operator, factory = list(_candidates(tree))[index]
            snippet = " ".join(ast.unparse(node).split())[:80]
            base = f"{name}: {operator}: {snippet}"
            seen[base] = seen.get(base, 0) + 1
            key = base if seen[base] == 1 else f"{base} #{seen[base]}"
            line = getattr(node, "lineno", 0)
            mutated = ast.fix_missing_locations(_Apply(node, factory).visit(tree))
            yield key, name, line, ast.unparse(mutated)


def _run_mutant(args):
    key, name, line, source = args
    work = tempfile.mkdtemp()
    try:
        copy_dir = os.path.join(work, "engine")
        shutil.copytree(ENGINE_DIR, copy_dir, ignore=shutil.ignore_patterns("__pycache__", ".coverage"))
        # The workflow-contract tests read the repository's workflow beside engine/.
        os.symlink(REPO_GITHUB_DIR, os.path.join(work, ".github"))
        if source is not None:
            with open(os.path.join(copy_dir, "dsb_tf_engine", name), "w", encoding="utf-8") as handle:
                handle.write(source)
        try:
            proc = subprocess.run([sys.executable, "-B", os.path.join(copy_dir, "tests", "mutation.py"), "--run-suite"],
                                  cwd=copy_dir, capture_output=True, timeout=300,
                                  env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
            killed = proc.returncode != 0
        except subprocess.TimeoutExpired:
            killed = True
        return key, name, line, killed
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_suite():
    sys.path[:0] = [ENGINE_DIR, TESTS_DIR]
    loader = unittest.defaultTestLoader
    discovered = {name[:-3] for name in os.listdir(TESTS_DIR) if name.startswith("test_") and name.endswith(".py")}
    order = [m for m in SUITE_ORDER if m in discovered] + sorted(discovered - set(SUITE_ORDER))
    suite = unittest.TestSuite(loader.loadTestsFromName(module) for module in order)
    with open(os.devnull, "w") as devnull:
        result = unittest.TextTestRunner(stream=devnull, failfast=True).run(suite)
    return 0 if result.wasSuccessful() else 1


def main(argv):
    if "--run-suite" in argv:
        return run_suite()
    every = list(mutants())
    if "--list" in argv:
        for key, *_ in every:
            print(key)
        return 0

    with open(EQUIVALENTS_FILE, encoding="utf-8") as handle:
        equivalents = json.load(handle)

    # Without a passing baseline every mutant would count as killed, for a reason no mutant caused.
    if _run_mutant(("baseline", None, 0, None))[3]:
        print("mutation: the unmutated engine fails its suite in a copy; no mutant can be judged")
        return 1
    workers = max(1, os.cpu_count() or 1)
    print(f"mutation: {len(every)} mutants of dsb_tf_engine, {workers} workers", flush=True)
    survivors = []
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
        for key, name, line, killed in pool.map(_run_mutant, every):
            if not killed:
                survivors.append((key, name, line))

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
