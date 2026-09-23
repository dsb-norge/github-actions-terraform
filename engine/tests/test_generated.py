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
from dsb_tf_engine import decide, environments

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
        output = decide.decide(document)
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


if __name__ == "__main__":
    unittest.main()
