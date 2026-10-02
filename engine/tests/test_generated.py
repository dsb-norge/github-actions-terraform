"""Generated and random cases: the invariants hold on every one, and the engine never crashes.

The generated cases enumerate, deterministically, the combinations the port's rules branch
on: per-environment value shapes for every YAML field against global value shapes, the
ref against the default branch, and parse failures. The random cases walk the same space
with a seeded generator and add malformed values. docs/Decision-engine.md §8, kinds 3 and 4.
"""

import copy
import itertools
import random
import unittest

import invariants
import support
from dsb_tf_engine import decide, environments, values

ABSENT = object()

# The value shapes the rules branch on, per-environment and global alike.
SHAPES = (ABSENT, None, False, True, 0, 3, "", "text", [], ["a"], {}, {"plan": {"A": "1"}}, {"A": None})

YML_FIELDS = environments.REPLACE_FIELDS + environments.MERGE_FIELDS


def build(env_value, global_value, field, ref_name="main", env_parses=True, global_parses=True):
    environment = {"environment": "env-a"}
    env_yaml = {}
    if env_value is not ABSENT:
        environment[field] = env_value
        env_yaml[field] = support.parsed(env_value if env_parses else None, env_parses)
    document = support.document(environments=[environment], env_yaml=[env_yaml], ref_name=ref_name)
    if global_value is not ABSENT:
        document["yaml"]["inputs"][field] = support.parsed(global_value if global_parses else None, global_parses)
    return document


def permuted(value):
    """The same value with every object's keys in reverse order (I12)."""
    if isinstance(value, dict):
        return {key: permuted(value[key]) for key in reversed(list(value))}
    if isinstance(value, list):
        return [permuted(item) for item in value]
    return value


class GeneratedTest(unittest.TestCase):
    def assertSound(self, document):
        original = copy.deepcopy(document)
        output = decide.decide(document)
        self.assertEqual(original, document, "decide modified its input document")
        self.assertEqual([], invariants.check(document, output))
        self.assertEqual(output, decide.decide(permuted(copy.deepcopy(document))), "I12: key order changed the output")
        return output

    def test_every_field_shape_against_every_global_shape(self):
        count = 0
        for field, env_value, global_value, ref_name in itertools.product(
                YML_FIELDS, SHAPES, SHAPES, ("main", "feature/x")):
            with self.subTest(field=field, env=env_value, glob=global_value, ref=ref_name):
                self.assertSound(build(env_value, global_value, field, ref_name))
                count += 1
        self.assertGreater(count, 2000)

    def test_parse_failures_are_errors_naming_the_field(self):
        for field in YML_FIELDS:
            with self.subTest(field=field, side="environment"):
                output = self.assertSound(build(["x"], ABSENT, field, env_parses=False))
                self.assertEqual([f"the environment's '{field}' is not valid yaml!"], output["errors"])
            with self.subTest(field=field, side="global"):
                output = self.assertSound(build(ABSENT, ["x"], field, global_parses=False))
                self.assertEqual([f"The specification for input '{field}' is not valid yaml!"], output["errors"])

    def test_forwarded_input_shapes_become_strings(self):
        for value in SHAPES[1:]:
            with self.subTest(value=value):
                output = self.assertSound(support.document(inputs={"some-input": value}))
                forwarded = output["matrices"]["1"]["include"][0]["vars"]["some-input"]
                self.assertIsInstance(forwarded, str)

    def test_random_walk_never_crashes(self):
        rng = random.Random(20260923)
        keys = list(YML_FIELDS) + ["project-dir", "github-environment", "url", "environment",
                                   "allow-failing-terraform-operations", "runs-on", "goals", "terraform-version"]
        for _ in range(3000):
            environments_ = []
            env_yaml = []
            for index in range(rng.randint(0, 4)):
                environment = {} if rng.random() < 0.05 else {"environment": rng.choice(["env-a", "env-b", 1, None, ""])}
                parses = {}
                for key in rng.sample(keys, rng.randint(0, 4)):
                    value = rng.choice(SHAPES[1:])
                    environment[key] = value
                    if key.endswith("-yml"):
                        ok = rng.random() > 0.1
                        parses[key] = support.parsed(value if ok else None, ok)
                environments_.append(environment if rng.random() > 0.03 else rng.choice(["env-a", 5, None, []]))
                env_yaml.append(parses)
            document = support.document(environments=[], env_yaml=env_yaml, ref_name=rng.choice(["main", "x"]))
            document["yaml"]["inputs"]["environments-yml"] = support.parsed(environments_)
            for field in rng.sample(YML_FIELDS, rng.randint(0, 3)):
                ok = rng.random() > 0.1
                document["yaml"]["inputs"][field] = support.parsed(rng.choice(SHAPES[1:]) if ok else None, ok)
            for path in rng.sample(["./envs/env-a", "./envs/env-b", "./envs/1", "null", "./envs/"], 3):
                document["directories_exist"][path] = rng.random() > 0.2
            with self.subTest(document=document):
                self.assertSound(document)

    def test_random_relevance_never_crashes(self):
        rng = random.Random(20260924)
        pool = ["README.md", "envs/env-a/main.tf", "envs/env-b/x.md", "modules/m/main.tf", ".tflint.hcl", "envs/env-b/.tflint.hcl",
                ".github/workflows/ci.yml", "main/a.tf", "shared/x.tf", "docs/a.md"]
        rule_shapes = SHAPES[1:] + (["auto"], ["**"], ["auto", "shared/**"], ["envs/*/main.tf"], ["[x]"], ["auto", 5],
                                    ["**/*.md"], ["auto", "auto"], ["./main/**", "main/**"], ["/.tflint.hcl"],
                                    ["auto", "/*.md", "./x"], ["/"], ["//x"])
        verdicts = set()
        for _ in range(3000):
            environments_ = []
            for name in rng.sample(["env-a", "env-b", "env-c"], rng.randint(1, 3)):
                environment = {"environment": name}
                for key in rng.sample(["paths", "paths-ignore", "project-dir"], rng.randint(0, 3)):
                    environment[key] = rng.choice(rule_shapes if key != "project-dir" else
                                                  (".", "./", "envs/env-a/", "../x", "/abs", 5, "a//b"))
                environments_.append(environment)
            document = support.document(environments=environments_,
                                        inputs={"path-relevance-enabled": rng.choice([True, False, "true", "no"])})
            for environment in environments_:
                document["directories_exist"][values.render(environment.get("project-dir",
                                                                            f"./envs/{environment['environment']}"))] = True
            event = rng.choice(["pull_request", "push", "schedule", "workflow_dispatch"])
            document["event"]["name"] = event
            if event == "pull_request":
                document["event"]["pull_request"] = {"number": 1, "head_sha": "abc", "is_fork": rng.random() < 0.1}
                document["event"]["action"] = rng.choice(["opened", "synchronize", "closed", "converted_to_draft"])
            if rng.random() > 0.2:
                document["run"] = {"id": 7, "attempt": 1}
            if event == "push":
                document["event"]["push"] = {key: rng.random() < 0.2 for key in ("created", "forced", "deleted")}
            if rng.random() > 0.1:
                files = rng.sample(pool, rng.randint(0, 4))
                document["changed_files"] = {
                    "available": rng.random() > 0.1, "truncated": rng.random() < 0.1, "error": None,
                    "api_head_sha": rng.choice(["abc", "abc", "abc", "other", None]), "count": len(files),
                    "files": files}
            with self.subTest(document=document):
                output = self.assertSound(document)
                verdicts.update(entry["verdict"] for entry in output["environments"])
        self.assertEqual({"run", "skip"}, verdicts)


class GeneratedTriggersTest(unittest.TestCase):
    """Events x trigger-events x dispatch inputs x branch x goals (docs/Dispatch-and-triggers.md §9): every
    combination decides soundly, and the outcome kinds all occur."""

    GOALS = (["all"], ["all", "destroy-plan"], ["init", "format", "validate", "lint"], ["plan", "apply-on-pr"],
             ["init", "plan", "apply", "destroy-plan", "destroy"], ["destroy-on-pr", "destroy-plan"], "all",
             "destroy-plan", [], None, ["APPLY"])
    EVENTS = (None, ["push"], ["schedule"], ["pull_request", "push", "workflow_dispatch", "schedule"],
              ["workflow_dispatch"])
    DISPATCH = (None, {"block": False}, {"environment": ""}, {"environment": "a"}, {"environment": "b", "goal": "plan"},
                {"goal": "apply"}, {"environment": "a", "goal": "destroy-plan"}, {"environment": "z"}, {"goal": "x"})
    # Cycled through the combinations rather than multiplied in: every value meets every event and goal set.
    SCHEDULE_GOALS = (None, "default", "plan", "apply", "destroy-plan", None, "x")

    def test_every_combination_is_sound(self):
        kinds = set()
        for index, (event, goals, events, dispatch, ref, action) in enumerate(itertools.product(
                ("pull_request", "push", "workflow_dispatch", "schedule"), self.GOALS, self.EVENTS, self.DISPATCH,
                ("main", "feature/x"), ("opened", "closed"))):
            if event != "workflow_dispatch" and dispatch is not None or event != "pull_request" and action == "closed":
                continue
            environment = {"environment": "a", "goals-yml": goals}
            if events is not None:
                environment["trigger-events"] = events
            schedule_goal = self.SCHEDULE_GOALS[index % len(self.SCHEDULE_GOALS)]
            if schedule_goal is not None:
                environment["schedule-goal"] = schedule_goal
            document = support.document(environments=[environment, {"environment": "b", "goals-yml": ["all"]}],
                                        env_yaml=[{"goals-yml": support.parsed(goals)},
                                                  {"goals-yml": support.parsed(["all"])}], ref_name=ref)
            document["event"].update({"name": event, "action": action, "base_ref": "main"})
            if dispatch is not None:
                document["event"]["dispatch"] = {"block": True, "environment": "", "goal": "", "reason": "", "inputs": [], **dispatch}
            with self.subTest(event=event, goals=goals, events=events, dispatch=dispatch, ref=ref, action=action,
                              schedule_goal=schedule_goal):
                original = copy.deepcopy(document)
                output = decide.decide(document)
                self.assertEqual(original, document)
                self.assertEqual([], invariants.check(document, output))
                kinds.add("error" if output["errors"] else f"{output['counts']['affected']} run")
        self.assertEqual({"error", "0 run", "1 run", "2 run"}, kinds)


class GeneratedScheduleGoalTest(unittest.TestCase):
    """Every goal set under every schedule-goal on a schedule, on and off the default branch (docs/Dispatch-and-
    triggers.md §4.4, I25): each decides soundly, and capped, uncapped and refused cases all occur."""

    def test_every_schedule_goal_on_every_goal_set_is_sound(self):
        kinds = set()
        for goals, schedule_goal, ref in itertools.product(GeneratedTriggersTest.GOALS,
                                                           GeneratedTriggersTest.SCHEDULE_GOALS, ("main", "feature/x")):
            environment = {"environment": "a", "goals-yml": goals, "trigger-events": ["schedule"]}
            if schedule_goal is not None:
                environment["schedule-goal"] = schedule_goal
            document = support.document(environments=[environment, {"environment": "b", "goals-yml": ["all"],
                                                                     "trigger-events": ["push", "schedule"]}],
                                        env_yaml=[{"goals-yml": support.parsed(goals)},
                                                  {"goals-yml": support.parsed(["all"])}], ref_name=ref)
            document["event"]["name"] = "schedule"
            with self.subTest(goals=goals, schedule_goal=schedule_goal, ref=ref):
                output = decide.decide(document)
                self.assertEqual([], invariants.check(document, output))
                if output["errors"]:
                    kinds.add("refused")
                    continue
                granted = output["environments"][0]["goals"]
                kinds.add("applies" if "apply" in granted else "plans" if "plan" in granted else "neither")
        self.assertEqual({"refused", "applies", "plans", "neither"}, kinds)


class GeneratedOrderingTest(unittest.TestCase):
    """depends-on graphs over four environments, valid and not, across events, goals, changed files and
    dispatches (docs/Environment-ordering.md §12): the invariants I18 to I24 hold on every case, and
    every outcome kind occurs."""

    NAMES = ("a", "b", "c", "d")

    def test_random_graphs_are_sound(self):
        rng = random.Random(6)
        kinds = set()
        for _ in range(600):
            environments = []
            for name in self.NAMES:
                entry = {"environment": name}
                choice = rng.random()
                if choice < 0.55:
                    entry["depends-on"] = rng.sample(self.NAMES + ("z",), rng.randint(1, 2))
                elif choice < 0.62:
                    entry["depends-on"] = rng.choice(self.NAMES)
                if rng.random() < 0.2:
                    entry["goals-yml"] = rng.choice([["init", "plan"], ["all", "apply-on-pr"], ["all", "destroy-plan",
                                                                                              "destroy"]])
                if rng.random() < 0.15:
                    entry["trigger-events"] = rng.choice([["push"], ["pull_request"], ["schedule"]])
                if rng.random() < 0.3:
                    entry["schedule-goal"] = rng.choice(["default", "plan", "default"])
                environments.append(entry)
            document = support.document(environments=environments, env_yaml=[
                {key: support.parsed(value) for key, value in entry.items() if key.endswith("-yml")}
                for entry in environments])
            document["yaml"]["inputs"]["goals-yml"] = support.parsed(rng.choice([["all"], ["init", "plan"]]))
            event = rng.choice(("push", "pull_request", "workflow_dispatch", "schedule"))
            document["event"].update({"name": event, "ref_name": rng.choice(("main", "main", "feature/x"))})
            if event == "push":
                document["event"]["push"] = {"created": False, "forced": False, "deleted": False}
            if event == "pull_request":
                document["event"].update({"action": "synchronize", "base_ref": "main",
                                          "pull_request": {"number": 1, "head_sha": "a", "is_fork": False}})
            if event == "workflow_dispatch":
                document["event"]["dispatch"] = {"block": True, "environment": rng.choice(("", "", "a", "c")),
                                                 "goal": rng.choice(("default", "plan", "apply")), "reason": "",
                                                 "inputs": ["environment", "goal", "reason"]}
            if event in ("push", "pull_request") and rng.random() < 0.7:
                files = rng.sample([f"envs/{name}/main.tf" for name in self.NAMES] + ["README.md", "main/x.tf"],
                                   rng.randint(0, 3))
                document["changed_files"] = {"available": True, "truncated": False, "error": None,
                                             "api_head_sha": "a", "count": len(files), "files": files}
            with self.subTest(environments=environments, event=event):
                output = decide.decide(document)
                self.assertEqual([], invariants.check(document, output))
                if output["errors"]:
                    kinds.add("error")
                else:
                    kinds.add(f"{output['ordering']['stages_used']} stages")
                    kinds.add(f"bypass {output['ordering']['bypass']}")
        self.assertEqual({"error", "1 stages", "2 stages", "3 stages", "bypass None",
                          "bypass single-environment-dispatch"}, kinds)


class GeneratedTestsTest(unittest.TestCase):
    """The test stage's random walk: rules, lanes, events and facts; the invariants hold, nothing crashes."""

    def test_random_tests_never_crash(self):
        import test_tests
        rng = random.Random(20260925)
        pool = ["tests/unit-a.tftest.hcl", "modules/net/tests/int-b.tftest.hcl", "main/main.tftest.hcl",
                "envs/prod/tests/smoke.tftest.hcl", "tests/sub/x.tftest.hcl", ".github/t.tftest.hcl", "docs/d.tftest.json",
                "modules/net/tests/unit-c.tftest.hcl"]
        lane_shapes = [{"name": "unit", "match": ["**/unit-*.tftest.hcl"]}, {"name": "rest"},
                       {"name": "env", "match": ["**/int-*"], "github-environment": "auto"},
                       {"name": "map", "match": ["main/**"], "extra-envs-from-secrets-yml": {"X": "S"}},
                       {"name": "narrow", "match": ["modules/**"], "providers-from": ["staging"]},
                       {"name": "Bad"}, "not a lane", {"name": "x", "match": "**"}, {"name": "y", "timeout-minutes": 0}]
        locks = [test_tests.LOCK_A, test_tests.LOCK_B, None]
        outcomes = set()
        for _ in range(1500):
            lanes = rng.sample(lane_shapes, rng.randint(0, 3))
            doc = test_tests.document(rng.sample(pool, rng.randint(0, len(pool))), lanes=lanes,
                                      event=rng.choice(["pull_request", "push", "schedule"]),
                                      actor=rng.choice(["octocat", "dependabot[bot]"]), is_fork=rng.random() < 0.2,
                                      exclude=rng.choice([None, ["**/unit-c.tftest.hcl"], "x"]),
                                      locks={"envs/prod": rng.choice(locks), "envs/staging": rng.choice(locks)},
                                      inputs={"terraform-test-enabled": rng.choice([True, True, False])})
            with self.subTest(document=doc):
                original = copy.deepcopy(doc)
                output = decide.decide(doc)
                self.assertEqual(original, doc)
                self.assertEqual([], invariants.check(doc, output))
                outcomes.add("error" if output["errors"] else ("active" if output["tests"]["active"] else "inactive"))
        self.assertEqual({"error", "active", "inactive"}, outcomes)


if __name__ == "__main__":
    unittest.main()
