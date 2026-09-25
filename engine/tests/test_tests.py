"""The test stage: which test files run, where, with what, and why not. docs/Terraform-tests.md §3-§4.

The adapter reports the committed test files, the directories holding `.tf` files and each
environment's lock (provider to version); the engine derives roots, lanes, environments, provider
sets and rows, and validates the lanes.
"""

import copy
import unittest

import support
from dsb_tf_engine import decide

TEST_INPUTS = {"terraform-test-enabled": True, "allow-failing-terraform-tests": False,
               "terraform-test-runs-on": "ubuntu-latest", "terraform-test-timeout-minutes": 30,
               "terraform-test-lanes-yml": "", "terraform-test-exclude-paths-yml": "", "terraform-version": "1.15.x"}
ENVS = [{"environment": "prod"}, {"environment": "staging"}]
LOCK_A = {"registry.terraform.io/hashicorp/azurerm": "4.30.0", "registry.terraform.io/hashicorp/random": "3.7.2"}
LOCK_B = {"registry.terraform.io/hashicorp/azurerm": "4.31.0", "registry.terraform.io/hashicorp/random": "3.7.2"}
DIRS = ["envs/prod", "envs/staging", "main", "modules/net"]


def document(files, lanes=None, dirs=None, locks=None, event="pull_request", inputs=None, exclude=None,
             environments=None, actor="octocat", is_fork=False, action="synchronize", workflow="CI build", tests=True):
    environments = ENVS if environments is None else environments
    env_yaml = [{key: support.parsed(value) for key, value in e.items() if key.endswith("-yml")} for e in environments]
    directories = {f"./envs/{e['environment']}": True for e in environments if "project-dir" not in e}
    directories.update({e["project-dir"]: True for e in environments if "project-dir" in e})
    doc = support.document(environments=environments, inputs={**TEST_INPUTS, **(inputs or {})}, env_yaml=env_yaml,
                           directories=directories)
    doc["yaml"]["inputs"]["terraform-test-lanes-yml"] = support.parsed(lanes)
    doc["yaml"]["inputs"]["terraform-test-exclude-paths-yml"] = support.parsed(exclude)
    doc["caller"]["workflow_name"] = workflow
    doc["event"].update(name=event, actor=actor)
    if event == "pull_request":
        doc["event"]["action"] = action
        doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": is_fork}
    doc["run"] = {"id": 4711, "attempt": 1}
    if tests:
        doc["tests"] = {"files": files, "directories_with_tf": DIRS if dirs is None else dirs,
                        "environment_locks": {"envs/prod": LOCK_A, "envs/staging": LOCK_A} if locks is None else locks}
    return doc


def decided(*args, **kwargs):
    output = decide.decide(document(*args, **kwargs))
    assert output["errors"] == [], output["errors"]
    return output


def rows(*args, **kwargs):
    return decided(*args, **kwargs)["tests"]["matrix"]["include"]


def errors(*args, **kwargs):
    output = decide.decide(document(*args, **kwargs))
    if output["errors"]:
        assert "tests" not in output and output["matrices"] == {}
    return output["errors"]


class RootRuleTest(unittest.TestCase):
    def test_the_layouts_of_the_spec(self):
        cases = [
            ("tests/unit-x.tftest.hcl", ".", "tests/unit-x.tftest.hcl", "repo-root"),
            ("modules/net/tests/unit-net.tftest.hcl", "modules/net", "tests/unit-net.tftest.hcl", "module"),
            ("main/tests/unit-main.tftest.hcl", "main", "tests/unit-main.tftest.hcl", "module"),
            ("envs/prod/tests/smoke.tftest.hcl", "envs/prod", "tests/smoke.tftest.hcl", "environment"),
            ("modules/net/net.tftest.hcl", "modules/net", "net.tftest.hcl", "module"),
            ("root.tftest.json", ".", "root.tftest.json", "repo-root"),
        ]
        for file, root, rel, kind in cases:
            with self.subTest(file=file):
                row = rows([file])[0]["test"]
                self.assertEqual((file, root, rel, kind), (row["file"], row["root"], row["rel"], row["root-kind"]))

    def test_misplaced_files_get_no_job_and_are_listed(self):
        for file in ("tests/setup/helper.tftest.hcl", "tests/scenario-a/x.tftest.hcl", "docs/x.tftest.hcl",
                     "modules/net/tests/sub/y.tftest.hcl"):
            with self.subTest(file=file):
                output = decided([file], dirs=DIRS + ["tests/setup"])
                self.assertEqual([], output["tests"]["matrix"]["include"])
                self.assertEqual([{"file": file, "lane": "default", "reason": "misplaced"}], output["tests"]["not_run"])
                self.assertEqual([f"test file '{file}' is misplaced: Terraform finds test files only beside the root "
                                  "module's .tf files or in its tests/ directory (docs/Terraform-tests.md §4.2)"],
                                 output["warnings"])

    def test_an_environment_root_is_one_whatever_its_project_dir_spelling(self):
        environments = [{"environment": "prod", "project-dir": "./envs/prod/"}]
        row = rows(["envs/prod/tests/smoke.tftest.hcl"], environments=environments, locks={"envs/prod": LOCK_A})[0]
        self.assertEqual(("environment", "", "", []),
                         (row["test"]["root-kind"], row["test"]["provider-set"], row["test"]["provider-set-lock"],
                          row["test"]["provider-set-environments"]))


class DiscoveryTest(unittest.TestCase):
    def test_hidden_segments_and_excluded_patterns_are_ignored(self):
        output = decided(["tests/a.tftest.hcl", ".github/tests/x.tftest.hcl", "modules/.cache/tests/y.tftest.hcl",
                          "modules/net/tests/slow.tftest.hcl"], exclude=["**/slow.tftest.hcl"])
        self.assertEqual(["tests/a.tftest.hcl"], [r["test"]["file"] for r in output["tests"]["matrix"]["include"]])
        self.assertEqual([], output["tests"]["not_run"])

    def test_rows_are_in_path_order(self):
        files = ["modules/net/tests/b.tftest.hcl", "main/tests/a.tftest.hcl", "modules/net/tests/a.tftest.hcl"]
        self.assertEqual(sorted(files), [r["test"]["file"] for r in rows(files)])

    def test_the_slug_and_the_name(self):
        row = rows(["modules/net/tests/unit-net.tftest.hcl"])[0]
        self.assertEqual("modules-net--unit-net", row["slug"])
        self.assertEqual("Terraform test (modules/net/tests/unit-net.tftest.hcl)", row["test"]["name"])
        self.assertEqual("root--unit-x", rows(["tests/unit-x.tftest.hcl"])[0]["slug"])
        self.assertEqual("root--r", rows(["r.tftest.json"])[0]["slug"])

    def test_a_slug_keeps_only_safe_characters_and_at_most_100_of_them(self):
        long_dir = "modules/" + "a" * 120
        slug = rows([f"{long_dir}/tests/x y+z.tftest.hcl"], dirs=DIRS + [long_dir])[0]["slug"]
        self.assertEqual(100, len(slug))
        self.assertRegex(slug, r"^[A-Za-z0-9._-]+$")
        self.assertEqual("modules-a-b--x-y-z", rows(["modules/a b/tests/x y+z.tftest.hcl"],
                                                     dirs=DIRS + ["modules/a b"])[0]["slug"])

    def test_a_colliding_long_slug_keeps_its_suffix_within_the_cap(self):
        long_dir = "modules/" + "a" * 120
        files = [f"{long_dir}/tests/x.tftest.hcl", f"{long_dir}-/tests/x.tftest.hcl"]
        slugs = [r["slug"] for r in rows(files, dirs=DIRS + [long_dir, long_dir + "-"])]
        self.assertEqual(("modules-" + "a" * 92, 100), (slugs[0], len(slugs[0])))
        # sha256("modules/<120 a>/tests/x.tftest.hcl")[:6]; '-' sorts before '/', so this file is second.
        self.assertEqual("modules-" + "a" * 85 + "-9069be", slugs[1])

    def test_a_colliding_slug_gets_a_deterministic_suffix(self):
        files = ["modules/a-b/tests/x.tftest.hcl", "modules/a/b/tests/x.tftest.hcl"]
        slugs = [r["slug"] for r in rows(files, dirs=DIRS + ["modules/a-b", "modules/a/b"])]
        self.assertEqual("modules-a-b--x", slugs[0])
        # sha256("modules/a/b/tests/x.tftest.hcl")[:6]
        self.assertEqual("modules-a-b--x-b0c007", slugs[1])

    def test_more_than_256_rows_is_an_error(self):
        files = [f"tests/t{index:03}.tftest.hcl" for index in range(257)]
        self.assertEqual(["257 test jobs exceed GitHub's cap of 256 jobs in one matrix; exclude files with "
                          "terraform-test-exclude-paths-yml!"], errors(files))
        self.assertEqual(256, len(rows(files[:256])))


class LaneTest(unittest.TestCase):
    LANES = [{"name": "unit", "match": ["**/unit-*.tftest.hcl"]},
             {"name": "integration", "match": ["**/int-*.tftest.hcl", "**/unit-special.tftest.hcl"],
              "extra-envs-from-secrets-yml": {"ARM_CLIENT_ID": "REPO_TESTS_CLIENT_ID"}}]

    def lane(self, file, lanes=None):
        return rows([file], lanes=self.LANES if lanes is None else lanes)[0]["test"]["lane"]

    def test_first_match_wins_and_unmatched_files_go_to_default(self):
        self.assertEqual("unit", self.lane("tests/unit-special.tftest.hcl"))
        self.assertEqual("integration", self.lane("tests/int-a.tftest.hcl"))
        self.assertEqual("default", self.lane("tests/other.tftest.hcl"))

    def test_a_fallback_lane_takes_the_unmatched_files(self):
        self.assertEqual("rest", self.lane("tests/other.tftest.hcl", self.LANES + [{"name": "rest"}]))

    def test_a_fallback_declared_first_does_not_take_what_a_later_lane_matches(self):
        lanes = [{"name": "rest"}] + self.LANES
        self.assertEqual("unit", self.lane("tests/unit-a.tftest.hcl", lanes))
        self.assertEqual("rest", self.lane("tests/other.tftest.hcl", lanes))

    def test_the_defaults_come_from_the_workflow_inputs(self):
        row = rows(["tests/other.tftest.hcl"], lanes=self.LANES)[0]["test"]
        self.assertEqual({"runs-on": "ubuntu-latest", "terraform-version": "1.15.x", "timeout-minutes": 30,
                          "allow-failing-terraform-tests": False, "cache-terraform-modules": "true",
                          "github-environment": "", "fork-safe": True, "extra-envs": {}, "extra-envs-from-secrets": {}},
                         {key: row[key] for key in ("runs-on", "terraform-version", "timeout-minutes",
                                                    "allow-failing-terraform-tests", "cache-terraform-modules",
                                                    "github-environment", "fork-safe", "extra-envs",
                                                    "extra-envs-from-secrets")})

    def test_absent_inputs_take_the_documented_defaults(self):
        # terraform-version and cache-terraform-modules set per environment only, not as workflow inputs.
        environments = [{"environment": "prod", "terraform-version": "1.13.0", "cache-terraform-modules": False}]
        doc = document(["tests/x.tftest.hcl"], environments=environments, locks={})
        for name in ("terraform-test-enabled", "allow-failing-terraform-tests", "terraform-test-runs-on",
                     "terraform-test-timeout-minutes", "terraform-version", "cache-terraform-modules"):
            del doc["workflow_inputs"][name]
        row = decide.decide(doc)["tests"]["matrix"]["include"][0]["test"]
        self.assertEqual(("ubuntu-latest", 30, False, "true", "latest"),
                         (row["runs-on"], row["timeout-minutes"], row["allow-failing-terraform-tests"],
                          row["cache-terraform-modules"], row["terraform-version"]))

    def test_boolean_inputs_as_strings_and_a_one_minute_timeout(self):
        inputs = {"allow-failing-terraform-tests": "true", "cache-terraform-modules": "false",
                  "terraform-test-enabled": "true", "terraform-test-timeout-minutes": 1}
        row = rows(["tests/x.tftest.hcl"], inputs=inputs)[0]["test"]
        self.assertEqual((True, "false", 1), (row["allow-failing-terraform-tests"], row["cache-terraform-modules"],
                                              row["timeout-minutes"]))
        self.assertEqual([], rows(["tests/x.tftest.hcl"], inputs={"terraform-test-enabled": "false"}))

    def test_a_declared_lane_takes_the_global_cache_setting(self):
        row = rows(["tests/x.tftest.hcl"], lanes=[{"name": "u"}], inputs={"cache-terraform-modules": False})[0]["test"]
        self.assertEqual(("u", "false"), (row["lane"], row["cache-terraform-modules"]))

    def test_the_global_inputs_change_the_defaults(self):
        inputs = {"terraform-test-runs-on": "big-runners", "terraform-test-timeout-minutes": 45,
                  "allow-failing-terraform-tests": True, "cache-terraform-modules": False, "terraform-version": "1.14.0"}
        row = rows(["tests/x.tftest.hcl"], inputs=inputs)[0]["test"]
        self.assertEqual(("big-runners", 45, True, "false", "1.14.0"),
                         (row["runs-on"], row["timeout-minutes"], row["allow-failing-terraform-tests"],
                          row["cache-terraform-modules"], row["terraform-version"]))

    def test_a_lane_key_overrides_the_global_input(self):
        lanes = [{"name": "slow", "runs-on": "group-x", "terraform-version": "1.12.0", "timeout-minutes": 60,
                  "allow-failing-terraform-tests": "true", "cache-terraform-modules": False,
                  "extra-envs-yml": {"TF_CLI_ARGS_test": "-verbose", "N": 3, "B": True}}]
        row = rows(["tests/x.tftest.hcl"], lanes=lanes)[0]["test"]
        self.assertEqual(("slow", "group-x", "1.12.0", 60, True, "false",
                          {"TF_CLI_ARGS_test": "-verbose", "N": "3", "B": "true"}),
                         (row["lane"], row["runs-on"], row["terraform-version"], row["timeout-minutes"],
                          row["allow-failing-terraform-tests"], row["cache-terraform-modules"], row["extra-envs"]))

    def test_the_workflows_own_extra_envs_never_reach_a_test_row(self):
        doc = document(["tests/x.tftest.hcl"])
        doc["yaml"]["inputs"]["extra-envs-yml"] = support.parsed({"ARM_CLIENT_ID": "apply-identity"})
        row = decide.decide(doc)["tests"]["matrix"]["include"][0]["test"]
        self.assertEqual(({}, {}), (row["extra-envs"], row["extra-envs-from-secrets"]))

    def test_a_mapped_lane_is_credentialed(self):
        row = rows(["tests/int-a.tftest.hcl"], lanes=self.LANES)[0]["test"]
        self.assertEqual(({"ARM_CLIENT_ID": "REPO_TESTS_CLIENT_ID"}, False),
                         (row["extra-envs-from-secrets"], row["fork-safe"]))


class EnvironmentLaneTest(unittest.TestCase):
    def test_auto_resolves_to_the_prefixed_lane_name(self):
        row = rows(["tests/x.tftest.hcl"], lanes=[{"name": "directory", "github-environment": "auto"}])[0]["test"]
        self.assertEqual(("tftest-directory", False, {"ARM_USE_OIDC": "true"}),
                         (row["github-environment"], row["fork-safe"], row["extra-envs"]))

    def test_an_explicit_name_and_the_lanes_own_oidc_setting(self):
        lanes = [{"name": "sub", "github-environment": "tftest-shared", "extra-envs-yml": {"ARM_USE_OIDC": False}}]
        row = rows(["tests/x.tftest.hcl"], lanes=lanes)[0]["test"]
        self.assertEqual(("tftest-shared", {"ARM_USE_OIDC": "false"}), (row["github-environment"], row["extra-envs"]))

    def test_names_outside_the_pattern_are_errors(self):
        for name in ("prod", "TfTest-x", "tftest-", "tftest-a_b", "tftest-" + "a" * 41, 5):
            with self.subTest(name=name):
                shown = repr(name) if isinstance(name, str) else str(name)
                self.assertEqual([f"The test lane 'x' sets 'github-environment' to {shown}; it must be 'auto' or "
                                  "match ^tftest-[a-z0-9-]{1,40}$!"],
                                 errors(["tests/a.tftest.hcl"], lanes=[{"name": "x", "github-environment": name}]))

    def test_a_lane_environment_may_not_be_a_terraform_environment(self):
        environments = [{"environment": "prod", "github-environment": "TFTEST-X"}]
        self.assertEqual(["The test lane 'x' runs in 'tftest-x', which is also the github-environment of the "
                          "environment 'prod'; a test lane needs an environment of its own!"],
                         errors(["tests/a.tftest.hcl"], lanes=[{"name": "x", "github-environment": "auto"}],
                                environments=environments, locks={}))


class ValidationTest(unittest.TestCase):
    def errors(self, lanes, **kwargs):
        return errors(["tests/a.tftest.hcl"], lanes=lanes, **kwargs)

    def test_yaml_that_does_not_parse_is_an_error(self):
        for name in ("terraform-test-lanes-yml", "terraform-test-exclude-paths-yml"):
            with self.subTest(name=name):
                doc = document(["tests/a.tftest.hcl"])
                doc["yaml"]["inputs"][name] = support.parsed(None, ok=False)
                self.assertEqual([f"The specification for input '{name}' is not valid yaml!"], decide.decide(doc)["errors"])

    def test_an_environment_lane_with_bad_variables_is_an_error_not_a_crash(self):
        self.assertEqual(["The test lane 'e' sets 'extra-envs-yml' to [\"X\"]; it must be a mapping of variable names "
                          "to values!"], self.errors([{"name": "e", "github-environment": "auto", "extra-envs-yml": ["X"]}]))

    def test_the_lanes_input_must_be_a_list_of_mappings(self):
        self.assertEqual(["The input 'terraform-test-lanes-yml' must be a list of lanes!"], self.errors({"name": "x"}))
        self.assertEqual(["Test lane 1 is not a mapping!"], self.errors(["x"]))

    def test_each_rule_of_a_lane(self):
        cases = [
            ([{"match": ["**"]}], "Test lane 1 has no 'name'!"),
            ([{"name": "Unit"}], "The test lane name 'Unit' must be 1 to 40 of the characters a-z 0-9 -!"),
            ([{"name": "a"}, {"name": "a", "match": ["x"]}], "The test lane name 'a' is used twice!"),
            ([{"name": "a"}, {"name": "b"}], "The test lanes 'a' and 'b' both have no 'match'; only one lane may be "
                                             "the fallback!"),
            ([{"name": "a", "colour": "red"}], "The test lane 'a' has the unknown key 'colour'!"),
            ([{"name": "a", "match": "**"}], "The test lane 'a' sets 'match' to '**'; it must be a list of patterns!"),
            ([{"name": "a", "match": 5}], "The test lane 'a' sets 'match' to 5; it must be a list of patterns!"),
            ([{"name": "a", "match": []}], "The test lane 'a' sets 'match' to []; leave it out for a fallback lane!"),
            ([{"name": "a", "match": ["[x]"]}], "The test lane 'a' has an invalid entry in 'match': the pattern '[x]' "
                                                "is not supported: character classes!"),
            ([{"name": "a", "extra-envs-yml": ["X"]}], "The test lane 'a' sets 'extra-envs-yml' to [\"X\"]; it must be "
                                                       "a mapping of variable names to values!"),
            ([{"name": "a", "extra-envs-yml": {"X": {"y": 1}}}], "The test lane 'a' sets the variable 'X' in "
                                                                 "'extra-envs-yml' to {\"y\": 1}; it must be a "
                                                                 "string, a number or a boolean!"),
            ([{"name": "a", "extra-envs-from-secrets-yml": {"X": 5}}], "The test lane 'a' maps 'X' in "
                                                                       "'extra-envs-from-secrets-yml' to 5; it must be "
                                                                       "a secret name!"),
            ([{"name": "a", "extra-envs-from-secrets-yml": "X"}], "The test lane 'a' sets 'extra-envs-from-secrets-yml' "
                                                                  "to 'X'; it must be a mapping of variable names to "
                                                                  "secret names!"),
            ([{"name": "a", "runs-on": 5}], "The test lane 'a' sets 'runs-on' to 5, which is not a string; quote it!"),
            ([{"name": "a", "terraform-version": 1.12}], "The test lane 'a' sets 'terraform-version' to 1.12, which is "
                                                         "not a string; quote it!"),
            ([{"name": "a", "timeout-minutes": 0}], "The test lane 'a' sets 'timeout-minutes' to 0; it must be a "
                                                    "positive whole number!"),
            ([{"name": "a", "timeout-minutes": "30"}], "The test lane 'a' sets 'timeout-minutes' to '30'; it must be a "
                                                       "positive whole number!"),
            ([{"name": "a", "allow-failing-terraform-tests": "yes"}], "The test lane 'a' sets "
                                                                      "'allow-failing-terraform-tests' to 'yes'; it "
                                                                      "must be true or false!"),
            ([{"name": "a", "cache-terraform-modules": None}], "The test lane 'a' sets 'cache-terraform-modules' to "
                                                               "null; it must be true or false!"),
            ([{"name": "a", "providers-from": "prod"}], "The test lane 'a' sets 'providers-from' to 'prod'; it must be "
                                                        "a list of environment names!"),
            ([{"name": "a", "providers-from": ["prod", "qa"]}], "The test lane 'a' takes providers from 'qa', which is "
                                                                "not an environment of this workflow!"),
        ]
        for lanes, message in cases:
            with self.subTest(message=message):
                self.assertEqual([message], self.errors(lanes))

    def test_a_lane_without_a_usable_name_is_named_by_its_position(self):
        self.assertEqual(["The test lane name 5 must be 1 to 40 of the characters a-z 0-9 -!",
                          "The test lane '1' has the unknown key 'x'!"], self.errors([{"name": 5, "x": 1}]))

    def test_every_lanes_errors_are_collected(self):
        self.assertEqual(["The test lane 'a' has the unknown key 'x'!", "The test lane 'b' has the unknown key 'y'!"],
                         self.errors([{"name": "a", "x": 1}, {"name": "b", "y": 1, "match": ["**"]}]))

    def test_the_exclude_input_must_be_a_list_of_patterns(self):
        self.assertEqual(["The input 'terraform-test-exclude-paths-yml' must be a list of patterns!"],
                         errors(["tests/a.tftest.hcl"], exclude="x"))
        self.assertEqual(["The input 'terraform-test-exclude-paths-yml' has an invalid entry: the pattern '!x' is not "
                          "supported: negation; use paths-ignore!"], errors(["tests/a.tftest.hcl"], exclude=["!x"]))

    def test_the_global_inputs_are_checked(self):
        for inputs, message in (
                ({"terraform-test-enabled": "yes"}, "The input 'terraform-test-enabled' is 'yes'; it must be true or false!"),
                ({"allow-failing-terraform-tests": None}, "The input 'allow-failing-terraform-tests' is null; it must be "
                                                          "true or false!"),
                ({"terraform-test-timeout-minutes": -1}, "The input 'terraform-test-timeout-minutes' is -1; it must be a "
                                                         "positive whole number!"),
                ({"terraform-test-runs-on": ""}, "The input 'terraform-test-runs-on' is empty!")):
            with self.subTest(inputs=inputs):
                self.assertEqual([message], errors(["tests/a.tftest.hcl"], inputs=inputs))

    def test_lanes_are_validated_on_every_event_and_when_disabled(self):
        for kwargs in (dict(event="schedule"), dict(inputs={"terraform-test-enabled": False})):
            with self.subTest(kwargs=kwargs):
                self.assertEqual(["The test lane 'a' has the unknown key 'x'!"],
                                 errors(["tests/a.tftest.hcl"], lanes=[{"name": "a", "x": 1}], **kwargs))


class ActiveTest(unittest.TestCase):
    def test_active_on_pull_requests_and_pushes_with_rows(self):
        for kwargs in (dict(), dict(event="push"), dict(action="opened")):
            with self.subTest(kwargs=kwargs):
                tests = decided(["tests/a.tftest.hcl"], **kwargs)["tests"]
                self.assertEqual((True, 1), (tests["active"], tests["count"]))

    def test_inactive_elsewhere(self):
        for kwargs in (dict(event="schedule"), dict(event="workflow_dispatch"), dict(action="closed"),
                       dict(action="converted_to_draft"), dict(inputs={"terraform-test-enabled": False}),
                       dict(files=[]), dict(tests=False)):
            with self.subTest(kwargs=kwargs):
                files = kwargs.pop("files", ["tests/a.tftest.hcl"])
                tests = decided(files, **kwargs)["tests"]
                # With the stage on and no files, the provider sets are still known; elsewhere nothing is.
                sets = tests["provider_sets"] if files == [] else []
                self.assertEqual({"matrix": {"include": []}, "count": 0, "active": False, "not_run": [],
                                  "provider_sets": sets}, tests)


class SecretsUnavailableTest(unittest.TestCase):
    LANES = [{"name": "env", "match": ["**/env-*.tftest.hcl"], "github-environment": "auto"},
             {"name": "mapped", "match": ["**/map-*.tftest.hcl"], "extra-envs-from-secrets-yml": {"X": "S"}}]
    FILES = ["tests/env-a.tftest.hcl", "tests/map-a.tftest.hcl", "tests/unit-a.tftest.hcl"]

    def test_credentialed_rows_are_dropped_on_a_fork_and_on_dependabot(self):
        for kwargs in (dict(is_fork=True), dict(actor="dependabot[bot]"), dict(actor="dependabot[bot]", event="push")):
            with self.subTest(kwargs=kwargs):
                tests = decided(self.FILES, lanes=self.LANES, **kwargs)["tests"]
                self.assertEqual(["tests/unit-a.tftest.hcl"], [r["test"]["file"] for r in tests["matrix"]["include"]])
                self.assertEqual([{"file": "tests/env-a.tftest.hcl", "lane": "env", "reason": "secrets unavailable"},
                                  {"file": "tests/map-a.tftest.hcl", "lane": "mapped", "reason": "secrets unavailable"}],
                                 tests["not_run"])

    def test_they_run_otherwise(self):
        self.assertEqual(3, decided(self.FILES, lanes=self.LANES)["tests"]["count"])
        self.assertEqual(3, decided(self.FILES, lanes=self.LANES, event="push")["tests"]["count"])


class ProviderSetTest(unittest.TestCase):
    FILE = "modules/net/tests/unit-net.tftest.hcl"

    def test_identical_locks_are_one_set(self):
        output = decided([self.FILE])
        row = output["tests"]["matrix"]["include"][0]
        self.assertEqual(("modules-net--unit-net", "Terraform test (modules/net/tests/unit-net.tftest.hcl)"),
                         (row["slug"], row["test"]["name"]))
        self.assertRegex(row["test"]["provider-set"], r"^[0-9a-f]{6}$")
        self.assertEqual(("envs/prod/.terraform.lock.hcl", ["prod", "staging"]),
                         (row["test"]["provider-set-lock"], row["test"]["provider-set-environments"]))
        self.assertEqual([{"id": row["test"]["provider-set"], "environments": ["prod", "staging"],
                           "lock": "envs/prod/.terraform.lock.hcl"}], output["tests"]["provider_sets"])

    def test_the_set_id_is_the_digest_of_the_sorted_provider_versions(self):
        # sha256("registry.terraform.io/hashicorp/azurerm=4.30.0\nregistry.terraform.io/hashicorp/random=3.7.2")[:6]
        self.assertEqual("98e750", decided([self.FILE])["tests"]["provider_sets"][0]["id"])

    def test_a_set_names_every_environment_that_shares_it(self):
        environments = [{"environment": "prod"}, {"environment": "qa"}, {"environment": "staging"}]
        got = rows([self.FILE], environments=environments,
                   locks={"envs/prod": LOCK_A, "envs/qa": LOCK_A, "envs/staging": LOCK_B})
        self.assertEqual(["Terraform test (modules/net/tests/unit-net.tftest.hcl) [providers: prod, qa]",
                          "Terraform test (modules/net/tests/unit-net.tftest.hcl) [providers: staging]"],
                         [r["test"]["name"] for r in got])

    def test_an_environment_at_the_repository_root(self):
        environments = [{"environment": "root", "project-dir": "."}, {"environment": "prod"}]
        output = decided(["tests/a.tftest.hcl", "modules/net/tests/b.tftest.hcl"], environments=environments,
                         locks={".": LOCK_A, "envs/prod": LOCK_B})
        self.assertEqual(".terraform.lock.hcl", output["tests"]["provider_sets"][0]["lock"])
        got = [(r["test"]["file"], r["test"]["root-kind"], r["test"]["provider-set-lock"])
               for r in output["tests"]["matrix"]["include"]]
        self.assertEqual([("modules/net/tests/b.tftest.hcl", "module", ".terraform.lock.hcl"),
                          ("modules/net/tests/b.tftest.hcl", "module", "envs/prod/.terraform.lock.hcl"),
                          ("tests/a.tftest.hcl", "environment", "")], got)

    def test_differing_locks_give_one_row_per_set(self):
        output = decided([self.FILE], locks={"envs/prod": LOCK_A, "envs/staging": LOCK_B})
        sets = output["tests"]["provider_sets"]
        self.assertEqual([["prod"], ["staging"]], [s["environments"] for s in sets])
        got = [(r["slug"], r["test"]["name"], r["test"]["provider-set-lock"]) for r in output["tests"]["matrix"]["include"]]
        self.assertEqual([(f"modules-net--unit-net--{sets[0]['id']}",
                           "Terraform test (modules/net/tests/unit-net.tftest.hcl) [providers: prod]",
                           "envs/prod/.terraform.lock.hcl"),
                          (f"modules-net--unit-net--{sets[1]['id']}",
                           "Terraform test (modules/net/tests/unit-net.tftest.hcl) [providers: staging]",
                           "envs/staging/.terraform.lock.hcl")], got)
        self.assertNotEqual(sets[0]["id"], sets[1]["id"])

    def test_the_set_id_depends_only_on_the_provider_versions(self):
        first = decided([self.FILE])["tests"]["provider_sets"][0]["id"]
        again = decided([self.FILE], locks={"envs/prod": dict(reversed(list(LOCK_A.items()))),
                                            "envs/staging": LOCK_A})["tests"]["provider_sets"][0]["id"]
        other = decided([self.FILE], locks={"envs/prod": LOCK_B, "envs/staging": LOCK_B})["tests"]["provider_sets"][0]["id"]
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)

    def test_providers_from_narrows_a_lane(self):
        lanes = [{"name": "net", "providers-from": ["staging"]}]
        got = rows([self.FILE], lanes=lanes, locks={"envs/prod": LOCK_A, "envs/staging": LOCK_B})
        self.assertEqual([["staging"]], [r["test"]["provider-set-environments"] for r in got])
        self.assertEqual("modules-net--unit-net", got[0]["slug"])

    def test_an_environment_without_a_lock_is_reported_and_contributes_no_set(self):
        output = decided([self.FILE], locks={"envs/prod": LOCK_A, "envs/staging": None})
        self.assertEqual([["prod"]], [s["environments"] for s in output["tests"]["provider_sets"]])
        self.assertIn("the environment 'staging' has no .terraform.lock.hcl; its providers take no part in the test "
                      "stage", output["notices"])

    def test_no_lock_at_all_runs_each_file_once_without_a_copy(self):
        row = rows([self.FILE], locks={"envs/prod": None, "envs/staging": None})[0]["test"]
        self.assertEqual(("", "", []), (row["provider-set"], row["provider-set-lock"], row["provider-set-environments"]))

    def test_a_project_dir_is_the_lock_key_however_it_is_spelled(self):
        environments = [{"environment": "prod", "project-dir": "./envs/prod/"}]
        row = rows([self.FILE], environments=environments, locks={"envs/prod": LOCK_A})[0]["test"]
        self.assertEqual("envs/prod/.terraform.lock.hcl", row["provider-set-lock"])


class CommentsTest(unittest.TestCase):
    def heads(self, *args, **kwargs):
        return [(h["kind"], h["key"], h["marker"], h["body"]) for h in decided(*args, **kwargs)["comments"]["heads"]]

    def test_the_tests_head_comes_after_the_environment_heads(self):
        heads = self.heads(["tests/a.tftest.hcl"])
        self.assertEqual(["env", "env", "tests"], [h[0] for h in heads])
        self.assertEqual(("tests", "CIbuild", "<!-- tf:head:tests:CIbuild -->",
                          "### Terraform tests summary\n\n⏳ Awaiting results (run #4711 attempt #1)…"), heads[-1])

    def test_the_tests_head_is_a_placeholder_titled_as_the_summary(self):
        head = decided(["tests/a.tftest.hcl"], inputs={"add-pr-comment": "true"})["comments"]["heads"][-1]
        self.assertEqual(("tests", "CIbuild", "placeholder", "Terraform tests summary"),
                         (head["kind"], head["key"], head["state"], head["title"]))

    def test_the_caller_is_the_workflow_name_reduced(self):
        self.assertEqual("<!-- tf:head:tests:Validate_and-plan2 -->",
                         self.heads(["tests/a.tftest.hcl"], workflow="Validate_and-plan 2 ✓")[-1][2])

    def test_no_tests_head_without_rows_or_comments(self):
        for kwargs in (dict(files=[]), dict(inputs={"add-pr-comment": False}), dict(inputs={"add-pr-comment": "false"}),
                       dict(event="push"),
                       dict(inputs={"terraform-test-enabled": False})):
            with self.subTest(kwargs=kwargs):
                files = kwargs.pop("files", ["tests/a.tftest.hcl"])
                self.assertNotIn("tests", [h[0] for h in self.heads(files, **kwargs)])


class NormaliseDirTest(unittest.TestCase):
    def test_every_spelling_of_a_directory_compares_equal(self):
        from dsb_tf_engine import tests
        for path, expected in (("envs/x", "envs/x"), ("./envs/x", "envs/x"), ("envs/x/", "envs/x"),
                               ("././envs/x//", "envs/x"), (".", "."), ("./", "."), ("", "."), ("/", ".")):
            with self.subTest(path=path):
                self.assertEqual(expected, tests.normalise_dir(path))


class RowsOfEnvironmentsTest(unittest.TestCase):
    def test_the_test_inputs_never_reach_an_environment_row(self):
        inputs = {"terraform-test-enabled": True, "allow-failing-terraform-tests": True, "terraform-test-runs-on": "x",
                  "terraform-test-timeout-minutes": 9, "terraform-test-lanes-yml": "- name: a\n",
                  "terraform-test-exclude-paths-yml": "- x\n"}
        variables = decided(["tests/a.tftest.hcl"], inputs=inputs)["matrices"]["1"]["include"][0]["vars"]
        self.assertEqual(set(), set(inputs) & set(variables))


class PurityTest(unittest.TestCase):
    def test_the_document_is_not_modified(self):
        doc = document(["modules/net/tests/a.tftest.hcl", "tests/b.tftest.hcl"],
                       lanes=[{"name": "u", "extra-envs-yml": {"A": 1}}])
        original = copy.deepcopy(doc)
        decide.decide(doc)
        self.assertEqual(original, doc)


if __name__ == "__main__":
    unittest.main()
