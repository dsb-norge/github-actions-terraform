"""Configuration validation (docs/Configuration-validation.md): the keys of an environments-yml entry,
the variables, the additional init directories and the auto-merge settings.

Every message is compared as a literal, and every known key is listed here rather than read from
the module, so a key added or dropped there fails here too.
"""

import os
import re
import unittest

import invariants
import support
from dsb_tf_engine import decide, environments

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(support.TESTS_DIR)),
                        ".github", "workflows", "terraform-ci-cd-default.yml")
DOC = "The settings an environment may hold are listed in docs/Configuration-validation.md §3.1."
PER_ENVIRONMENT = {"add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
                   "format-check-in-root-dir", "pr-auto-merge-enabled", "pr-comment-group", "runs-on",
                   "terraform-version", "tflint-version", "verify-lock-file"}
YAML_SETTINGS = {"goals-yml", "terraform-init-additional-dirs-yml", "extra-envs-yml", "extra-envs-from-secrets-yml",
                 "extra-envs-per-goal-yml", "extra-envs-from-secrets-per-goal-yml", "pr-auto-merge-from-actors-yml",
                 "pr-auto-merge-limits-yml", "notifications-yml"}
WORKFLOW_ONLY = {"environments-yml", "trigger-events-yml", "path-relevance-enabled", "allow-failing-terraform-tests",
                 "terraform-test-enabled", "terraform-test-exclude-paths-yml", "terraform-test-lanes-yml",
                 "terraform-test-runs-on", "terraform-test-timeout-minutes", "pr-auto-merge-app-id",
                 "pr-auto-merge-app-private-key-secret", "dependabot-admission-enabled", "dependabot-admission-yml"}


def errors(*entries):
    document = support.document(environments=list(entries))
    output = decide.decide(document)
    assert invariants.check(document, output) == [], invariants.check(document, output)
    return output["errors"]


class InputClassificationTest(unittest.TestCase):
    def test_every_declared_input_is_per_environment_or_workflow_only(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        inputs = text[text.index("    inputs:\n"):text.index("\n    secrets:") if "\n    secrets:" in text else None]
        declared = set(re.findall(r"^      ([a-z0-9-]+):\n        type:", inputs, re.M))
        self.assertGreater(len(declared), 25, "the scan found too few inputs to be trusted")
        self.assertEqual(set(), PER_ENVIRONMENT & WORKFLOW_ONLY)
        self.assertEqual(declared, PER_ENVIRONMENT | YAML_SETTINGS | WORKFLOW_ONLY)
        self.assertEqual(PER_ENVIRONMENT, set(environments.PER_ENVIRONMENT_INPUTS))
        self.assertEqual(WORKFLOW_ONLY, set(environments.WORKFLOW_ONLY_INPUTS))
        self.assertEqual(YAML_SETTINGS, set(environments.REPLACE_FIELDS + environments.MERGE_FIELDS))


class EntryKeysTest(unittest.TestCase):
    def test_every_known_key_is_accepted(self):
        values = {"project-dir": "./envs/prod", "github-environment": "prod-gh", "url": "https://x", "paths": ["**"],
                  "paths-ignore": [], "trigger-events": ["push"], "depends-on": [],
                  "allow-failing-terraform-operations": True,
                  "add-pr-comment": True, "apply-extract-include-outputs": False, "cache-terraform-modules": True,
                  "format-check-in-root-dir": False, "pr-auto-merge-enabled": False, "pr-comment-group": "g",
                  "runs-on": "ubuntu-latest", "terraform-version": "1.16", "tflint-version": "latest",
                  "verify-lock-file": True}
        for key, value in values.items():
            with self.subTest(key=key):
                self.assertEqual([], errors({"environment": "prod", key: value}))

    def test_an_unsuffixed_yaml_setting_names_its_spelling(self):
        for key in ("goals", "extra-envs", "extra-envs-from-secrets", "extra-envs-per-goal",
                    "extra-envs-from-secrets-per-goal", "pr-auto-merge-from-actors", "pr-auto-merge-limits",
                    "terraform-init-additional-dirs"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which is not a setting: per environment it "
                                  f"is '{key}-yml'. Written like this it would have been ignored, and the environment "
                                  "would have run with the global value."], errors({"environment": "prod", key: []}))

    def test_a_suffixed_plain_setting_names_its_spelling(self):
        for key in ("paths", "paths-ignore", "trigger-events"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}-yml', which is not a setting: per environment "
                                  f"it is '{key}', a list written directly in the entry."],
                                 errors({"environment": "prod", f"{key}-yml": ["x"]}))

    def test_a_suffixed_single_value_setting_names_its_spelling(self):
        self.assertEqual(["The environment 'prod' sets 'schedule-goal-yml', which is not a setting: per environment "
                          "it is 'schedule-goal', a value written directly in the entry."],
                         errors({"environment": "prod", "schedule-goal-yml": "plan"}))

    def test_a_schedule_goal_is_a_known_key(self):
        self.assertEqual([], errors({"environment": "prod", "trigger-events": ["schedule"], "schedule-goal": "plan"}))
        self.assertEqual(["The environment 'prod' sets 'schedule-goals', which is not a setting; did you mean "
                          "'schedule-goal'? The settings an environment may hold are listed in "
                          "docs/Configuration-validation.md §3.1."], errors({"environment": "prod", "schedule-goals": "plan"}))

    def test_a_workflow_only_input_is_refused(self):
        # path-relevance-enabled keeps its own advice; trigger-events-yml gets the suffixed-setting message.
        for key in sorted(WORKFLOW_ONLY - {"path-relevance-enabled", "trigger-events-yml"}):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which is a workflow input only: it applies to "
                                  "every environment at once. Set it in the calling workflow's 'with:'."],
                                 errors({"environment": "prod", key: "x"}))

    def test_path_relevance_enabled_keeps_its_own_advice(self):
        self.assertEqual(["The environment 'prod' sets 'path-relevance-enabled', which is a workflow input only; to run "
                          "it on every change, set its 'paths' to ['**']!"],
                         errors({"environment": "prod", "path-relevance-enabled": False}))

    def test_a_value_the_engine_sets_is_refused(self):
        for key in ("goals-granted", "caller-repo-default-branch", "caller-repo-calling-branch",
                    "caller-repo-is-on-default-branch"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which the workflow works out itself; remove it."],
                                 errors({"environment": "prod", key: "x"}))

    def test_a_near_miss_is_suggested(self):
        cases = [("github_environment", "github-environment"),   # distance 1
                 ("githubenvironment", "github-environment"),    # distance 1
                 ("Project-Dir", "project-dir"),                 # case only
                 ("goals-ymll", "goals-yml"),                    # distance 1
                 ("add-pr-coment", "add-pr-comment"),            # distance 1
                 ("url-s", "url")]                               # distance 2
        for written, meant in cases:
            with self.subTest(written=written):
                self.assertEqual([f"The environment 'prod' sets '{written}', which is not a setting; did you mean "
                                  f"'{meant}'? {DOC}"], errors({"environment": "prod", written: "x"}))

    def test_no_suggestion_when_nothing_is_near_or_two_are(self):
        for written in ("description", "zzzzzz", "paths-xyz"):
            with self.subTest(written=written):
                self.assertEqual([f"The environment 'prod' sets '{written}', which is not a setting. {DOC}"],
                                 errors({"environment": "prod", written: "x"}))

    def test_a_key_that_is_not_text(self):
        self.assertEqual([f"The environment 'prod' sets 7, which is not a setting. {DOC}"],
                         errors({"environment": "prod", 7: "x"}))

    def test_every_problem_of_every_environment_is_reported_in_key_order(self):
        self.assertEqual([f"The environment 'a' sets 'zeta', which is not a setting. {DOC}",
                          "The environment 'b' sets 'goals', which is not a setting: per environment it is 'goals-yml'. "
                          "Written like this it would have been ignored, and the environment would have run with the "
                          "global value.",
                          f"The environment 'b' sets 'other', which is not a setting. {DOC}"],
                         errors({"environment": "a", "zeta": 1}, {"environment": "b", "other": 1, "goals": ["plan"]}))

    def test_an_entry_without_a_valid_name_is_left_to_the_name_rule(self):
        self.assertEqual(["The environment name 'a b' must be 1 to 255 of the characters A-Z a-z 0-9 . _ - starting "
                          "with a letter or a digit!"], errors({"environment": "a b", "zeta": 1}))


class NearMissTest(unittest.TestCase):
    def test_near_miss(self):
        known = ("apply", "plan", "planx")
        self.assertEqual("apply", environments.near_miss("aply", known))
        self.assertEqual("apply", environments.near_miss("APPLY", known))
        self.assertIsNone(environments.near_miss("xyzzyq", known))
        self.assertIsNone(environments.near_miss("plany", known))   # one edit from both plan and planx
        self.assertEqual("plan", environments.near_miss("pl", ("plan",)))   # two edits
        self.assertIsNone(environments.near_miss("p", ("plan",)))   # three edits

    def test_the_distance_is_levenshtein_s(self):
        cases = {("", ""): 0, ("", "ab"): 2, ("abc", ""): 3, ("kitten", "sitting"): 3, ("flaw", "lawn"): 2,
                 ("goals", "goals"): 0}
        self.assertEqual(cases, {pair: environments._distance(*pair) for pair in cases})



class VariablesTest(unittest.TestCase):
    """The job-wide variable maps (docs/Configuration-validation.md §3.5)."""

    def output(self, env_value=None, global_value=None, field="extra-envs-yml"):
        environment = {"environment": "prod"}
        env_yaml = {}
        if env_value is not None:
            environment[field] = env_value
            env_yaml[field] = support.parsed(env_value)
        document = support.document(environments=[environment], env_yaml=[env_yaml])
        if global_value is not None:
            document["yaml"]["inputs"][field] = support.parsed(global_value)
        output = decide.decide(document)
        self.assertEqual([], invariants.check(document, output))
        return output

    def row(self, output, field):
        return output["matrices"]["1"]["include"][0]["vars"][field]

    def test_a_null_is_not_set_and_a_per_environment_null_removes_a_global_variable(self):
        for field in ("extra-envs-yml", "extra-envs-from-secrets-yml"):
            with self.subTest(field=field):
                output = self.output({"GONE": None, "LOCAL": "b"}, {"GONE": "global", "KEPT": "a", "NULL": None}, field)
                self.assertEqual({"KEPT": "a", "LOCAL": "b"}, self.row(output, field[:-4]))

    def test_names_follow_the_variable_rule(self):
        for key in ("1ABC", "A-B", "A B", ""):
            with self.subTest(key=key):
                self.assertEqual([f"The variable {key!r} of the environment 'prod' in 'extra-envs-yml' is not a variable "
                                  "name: a name is letters, digits and underscores, not starting with a digit."],
                                 self.output({key: "x"})["errors"])
        self.assertEqual([], self.output({"_A1": "x", "a": "y"})["errors"])

    def test_a_value_is_text(self):
        cases = [({"TAGS": {"a": "b"}}, "is a mapping; a variable's value is text. Quote it if the braces are part of "
                                        "the value."),
                 ({"TAGS": ["a"]}, "is a list; a variable's value is text. Quote it if the brackets are part of the "
                                   "value."),
                 ({"TAGS": 3}, "is 3, which is not text; quote it."),
                 ({"TAGS": True}, "is true, which is not text; quote it.")]
        for value, tail in cases:
            with self.subTest(value=value):
                self.assertEqual([f"The variable 'TAGS' of the environment 'prod' in 'extra-envs-yml' {tail}"],
                                 self.output(value)["errors"])

    def test_every_problem_of_the_map_is_reported(self):
        self.assertEqual(["The variable '1A' of the environment 'prod' in 'extra-envs-from-secrets-yml' is not a "
                          "variable name: a name is letters, digits and underscores, not starting with a digit.",
                          "The variable 'B' of the environment 'prod' in 'extra-envs-from-secrets-yml' is a list; a "
                          "variable's value is text. Quote it if the brackets are part of the value."],
                         self.output({"1A": "S", "B": ["x"]}, field="extra-envs-from-secrets-yml")["errors"])

    def test_a_global_problem_names_the_input_once(self):
        document = support.document(environments=[{"environment": "a"}, {"environment": "b"}], env_yaml=[{}, {}])
        document["yaml"]["inputs"]["extra-envs-yml"] = support.parsed({"TAGS": {"team": "x"}, "OK": "y"})
        self.assertEqual(["The variable 'TAGS' in 'extra-envs-yml' is a mapping; a variable's value is text. Quote it "
                          "if the braces are part of the value."], decide.decide(document)["errors"])

    def test_every_environment_s_problems_are_reported_together(self):
        environments = [{"environment": "a", "extra-envs-yml": {"X": 1}},
                        {"environment": "b", "extra-envs-from-secrets-yml": {"1Y": "S"}}]
        document = support.document(environments=environments,
                                    env_yaml=[{key: support.parsed(value) for key, value in entry.items()
                                               if key.endswith("-yml")} for entry in environments])
        self.assertEqual(["The variable 'X' of the environment 'a' in 'extra-envs-yml' is 1, which is not text; quote "
                          "it.",
                          "The variable '1Y' of the environment 'b' in 'extra-envs-from-secrets-yml' is not a variable "
                          "name: a name is letters, digits and underscores, not starting with a digit."],
                         decide.decide(document)["errors"])

    def test_a_map_that_is_not_a_mapping_is_left_to_its_own_rules(self):
        output = self.output(global_value="text")
        self.assertEqual("text", self.row(output, "extra-envs"))


def output_of(environments=None, env_yaml=None, inputs=None, **yaml_inputs):
    """The decision for `environments`, each YAML input given by its name with underscores."""
    document = support.document(environments=environments, env_yaml=env_yaml, inputs=inputs)
    for name, value in yaml_inputs.items():
        document["yaml"]["inputs"][name.replace("_", "-")] = support.parsed(value)
    output = decide.decide(document)
    assert invariants.check(document, output) == [], invariants.check(document, output)
    return output


def rows_of(output):
    assert output["errors"] == [], output["errors"]
    return [row["vars"] for row in output["matrices"]["1"]["include"]]


def with_yaml(*entries):
    """The entries and their YAML fields as the adapter hands them over."""
    return {"environments": list(entries),
            "env_yaml": [{key: support.parsed(value) for key, value in entry.items() if key.endswith("-yml")}
                         for entry in entries]}


class InitDirsTest(unittest.TestCase):
    """The additional init directories (docs/Configuration-validation.md §3.4)."""

    def test_a_directory_written_alone_is_that_one_directory(self):
        output = output_of(**with_yaml({"environment": "a"}, {"environment": "b",
                                                               "terraform-init-additional-dirs-yml": "./b"}),
                           terraform_init_additional_dirs_yml="./main")
        self.assertEqual([["./main"], ["./b"]], [row["terraform-init-additional-dirs"] for row in rows_of(output)])

    def test_none_is_an_empty_list(self):
        self.assertEqual([[]], [row["terraform-init-additional-dirs"] for row in rows_of(output_of())])

    def test_an_empty_directory_is_refused(self):
        self.assertEqual(["terraform-init-additional-dirs-yml has the additional init directory '', which is empty.",
                          "The environment 'b' has the additional init directory '', which is empty."],
                         output_of(**with_yaml({"environment": "a"}, {"environment": "c"},
                                               {"environment": "b", "terraform-init-additional-dirs-yml": ["./x", ""]}),
                                   terraform_init_additional_dirs_yml=[""])["errors"])

    def test_a_directory_is_text(self):
        self.assertEqual(["The environment 'a' has the additional init directory 5, which is not text; quote it."],
                         output_of(**with_yaml({"environment": "a", "terraform-init-additional-dirs-yml": [5]}))["errors"])

    def test_the_value_is_a_list(self):
        self.assertEqual(['terraform-init-additional-dirs-yml is {"main": true}; it must be a list of directories.',
                          "The environment 'a' sets 'terraform-init-additional-dirs-yml' to 7; it must be a list of "
                          "directories."],
                         output_of(**with_yaml({"environment": "a", "terraform-init-additional-dirs-yml": 7}),
                                   terraform_init_additional_dirs_yml={"main": True})["errors"])


ON = {"pr-auto-merge-enabled": True}
NOBODY = ('so there is no one whose pull requests may merge without review. Name the accounts{}, for example '
          '["dependabot[bot]"].')
LOGIN_RULE = ("which is not a login: a login is letters, digits and hyphens, up to 39, not starting with a hyphen, and "
              "a bot's ends in [bot].")
LIMITS = {"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0,
          "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": 0}
SIX = "the six limits are plan-max-count-add, -change, -destroy, -import, -move and -remove."


class AutoMergeActorsTest(unittest.TestCase):
    """Who may auto-merge (docs/Configuration-validation.md §3.6)."""

    def actors(self, output):
        return [row["pr-auto-merge-from-actors"] for row in rows_of(output)]

    def test_switched_on_the_global_list_names_someone(self):
        for enabled in (True, "true"):
            with self.subTest(enabled=enabled):
                self.assertEqual(["Auto-merge is switched on (pr-auto-merge-enabled), but pr-auto-merge-from-actors-yml "
                                  "names nobody, " + NOBODY.format("")],
                                 output_of([{"environment": "a"}, {"environment": "b"}],
                                           inputs={"pr-auto-merge-enabled": enabled},
                                           pr_auto_merge_from_actors_yml=[])["errors"])

    def test_an_absent_global_list_names_nobody(self):
        self.assertEqual(["Auto-merge is switched on (pr-auto-merge-enabled), but pr-auto-merge-from-actors-yml names "
                          "nobody, " + NOBODY.format("")], output_of(inputs=ON)["errors"])

    def test_an_environment_whose_list_names_nobody_is_named(self):
        message = ("Auto-merge is switched on (pr-auto-merge-enabled), but the actor list that applies to the "
                   "environment '{}' names nobody, " + NOBODY.format(" in pr-auto-merge-from-actors-yml"))
        self.assertEqual([message.format("b")],
                         output_of(inputs=ON, pr_auto_merge_from_actors_yml=[],
                                   **with_yaml({"environment": "a", "pr-auto-merge-from-actors-yml": ["x"]},
                                               {"environment": "b"}))["errors"])
        self.assertEqual([message.format("a")],
                         output_of(inputs=ON, pr_auto_merge_from_actors_yml=["x"],
                                   **with_yaml({"environment": "a", "pr-auto-merge-from-actors-yml": []},
                                               {"environment": "b"}))["errors"])

    def test_an_environment_with_auto_merge_off_needs_nobody(self):
        output = output_of(inputs=ON, pr_auto_merge_from_actors_yml=[],
                           environments=[{"environment": "a", "pr-auto-merge-enabled": False}])
        self.assertEqual([[]], self.actors(output))

    def test_switched_off_an_empty_list_is_allowed(self):
        self.assertEqual([[]], self.actors(output_of(pr_auto_merge_from_actors_yml=[])))

    def test_an_environment_s_list_replaces_the_global_one(self):
        output = output_of(inputs=ON, pr_auto_merge_from_actors_yml=["global"],
                           **with_yaml({"environment": "a", "pr-auto-merge-from-actors-yml": ["own"]},
                                       {"environment": "b"}))
        self.assertEqual([["own"], ["global"]], self.actors(output))

    def test_a_login_written_alone_is_that_one_account(self):
        self.assertEqual([["dependabot[bot]"]],
                         self.actors(output_of(inputs=ON, pr_auto_merge_from_actors_yml="dependabot[bot]")))

    def test_a_login_follows_github_s_form(self):
        accepted = ["a" * 39, "a-b", "renovate[bot]", "7", "A1"]
        self.assertEqual([accepted], self.actors(output_of(inputs=ON, pr_auto_merge_from_actors_yml=accepted)))
        for login in ("-abc", "a" * 40, "abc[bot]x", "", "a.b", "[bot]"):
            with self.subTest(login=login):
                self.assertEqual([f"pr-auto-merge-from-actors-yml holds {login!r}, {LOGIN_RULE}"],
                                 output_of(pr_auto_merge_from_actors_yml=[login])["errors"])

    def test_a_list_written_without_its_dashes_is_recognised(self):
        for written in ("dependabot[bot] renovate[bot]", "dependabot[bot], renovate[bot]"):
            with self.subTest(written=written):
                self.assertEqual([f"pr-auto-merge-from-actors-yml holds {written!r}, which is not a login. It looks like "
                                  "a list written without its dashes: write one account per line starting with '- ', "
                                  'or ["dependabot[bot]", "renovate[bot]"].'],
                                 output_of(pr_auto_merge_from_actors_yml=written)["errors"])
        self.assertEqual([f"pr-auto-merge-from-actors-yml holds 'a b.c', {LOGIN_RULE}"],
                         output_of(pr_auto_merge_from_actors_yml="a b.c")["errors"])

    def test_a_block_s_trailing_newline_is_a_list_without_dashes_and_a_stray_separator_is_no_list(self):
        self.assertEqual(["pr-auto-merge-from-actors-yml holds 'dependabot[bot]\\nrenovate[bot]\\n', which is not a "
                          "login. It looks like a list written without its dashes: write one account per line starting "
                          "with '- ', or [\"dependabot[bot]\", \"renovate[bot]\"]."],
                         output_of(pr_auto_merge_from_actors_yml="dependabot[bot]\nrenovate[bot]\n")["errors"])
        self.assertEqual([f"pr-auto-merge-from-actors-yml holds 'renovate[bot], ', {LOGIN_RULE}"],
                         output_of(pr_auto_merge_from_actors_yml="renovate[bot], ")["errors"])

    def test_a_number_is_quoted_and_a_boolean_is_not_a_login(self):
        self.assertEqual(["The pr-auto-merge-from-actors-yml of the environment 'a' holds 7, which is not a login; "
                          "quote it if it is one.",
                          f"The pr-auto-merge-from-actors-yml of the environment 'a' holds true, {LOGIN_RULE}"],
                         output_of(**with_yaml({"environment": "a", "pr-auto-merge-from-actors-yml": [7, True]}))["errors"])

    def test_the_value_is_a_list(self):
        self.assertEqual(['pr-auto-merge-from-actors-yml is {"a": 1}; it must be a list of logins.',
                          "The environment 'a' sets 'pr-auto-merge-from-actors-yml' to 3; it must be a list of logins."],
                         output_of(pr_auto_merge_from_actors_yml={"a": 1},
                                   **with_yaml({"environment": "a", "pr-auto-merge-from-actors-yml": 3}))["errors"])


class AutoMergeLimitsTest(unittest.TestCase):
    """Within which plan counts (docs/Configuration-validation.md §3.6)."""

    def limits(self, output):
        return [row["pr-auto-merge-limits"] for row in rows_of(output)]

    def test_an_absent_or_empty_global_value_is_the_documented_default(self):
        self.assertEqual({"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0,
                          "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": 0},
                         environments.default_limits())
        for global_value in (None, {}):
            with self.subTest(global_value=global_value):
                output = output_of(pr_auto_merge_limits_yml=global_value,
                                   **with_yaml({"environment": "a"},
                                               {"environment": "b", "pr-auto-merge-limits-yml": {"plan-max-count-add": 5}}))
                self.assertEqual([LIMITS, {**LIMITS, "plan-max-count-add": 5}], self.limits(output))

    def test_the_default_is_the_workflow_s(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        block = re.search(r"^      pr-auto-merge-limits-yml:\n.*?^        default: \|\n((?:          [^\n]*\n)+)", text,
                          re.M | re.S).group(1)
        written = dict(line.strip().split(": ") for line in block.splitlines())
        self.assertEqual(LIMITS, {key: int(value) for key, value in written.items()})

    def test_an_environment_s_limits_merge_into_the_global_ones(self):
        output = output_of(pr_auto_merge_limits_yml={**LIMITS, "plan-max-count-add": 3},
                           **with_yaml({"environment": "a", "pr-auto-merge-limits-yml": {"plan-max-count-move": 0}},
                                       {"environment": "b", "pr-auto-merge-limits-yml": None}))
        self.assertEqual([{**LIMITS, "plan-max-count-add": 3, "plan-max-count-move": 0},
                          {**LIMITS, "plan-max-count-add": 3}], self.limits(output))

    def test_a_limit_that_does_not_exist(self):
        self.assertEqual(["pr-auto-merge-limits-yml sets 'plan-max-count-destory', which is not a limit; did you mean "
                          "'plan-max-count-destroy'?",
                          "pr-auto-merge-limits-yml sets 'max', which is not a limit; " + SIX,
                          "The environment 'a' sets 'plan-max-count-ad' in 'pr-auto-merge-limits-yml', which is not a "
                          "limit; did you mean 'plan-max-count-add'?"],
                         output_of(pr_auto_merge_limits_yml={**LIMITS, "plan-max-count-destory": 1, "max": 1},
                                   **with_yaml({"environment": "a",
                                                "pr-auto-merge-limits-yml": {"plan-max-count-ad": 1}}))["errors"])

    def test_a_limit_is_a_whole_number_of_minus_one_or_more(self):
        self.assertEqual([LIMITS], self.limits(output_of(pr_auto_merge_limits_yml=LIMITS)))
        text = ", which is text; a limit is a whole number, written without quotes, and -1 means no limit."
        other = "; a limit is a whole number of -1 or more, and -1 means no limit."
        for value, tail in (("5", f" to '5'{text}"), (True, f" to true{other}"), (-2, f" to -2{other}"),
                            (1.5, f" to 1.5{other}"), (None, f" to null{other}")):
            with self.subTest(value=value):
                self.assertEqual([f"pr-auto-merge-limits-yml sets 'plan-max-count-add'{tail}",
                                  f"The environment 'a' sets 'plan-max-count-move' in 'pr-auto-merge-limits-yml'{tail}"],
                                 output_of(pr_auto_merge_limits_yml={**LIMITS, "plan-max-count-add": value},
                                           **with_yaml({"environment": "a", "pr-auto-merge-limits-yml":
                                                        {"plan-max-count-move": value}}))["errors"])

    def test_every_limit_is_set_after_the_merge(self):
        partial = {key: value for key, value in LIMITS.items() if key not in ("plan-max-count-import",
                                                                               "plan-max-count-move")}
        self.assertEqual(["pr-auto-merge-limits-yml lacks 'plan-max-count-import', 'plan-max-count-move'; " + SIX],
                         output_of([{"environment": "a"}, {"environment": "b"}],
                                   pr_auto_merge_limits_yml=partial)["errors"])
        self.assertEqual(["The limits of the environment 'b' lack 'plan-max-count-move'; " + SIX],
                         output_of(pr_auto_merge_limits_yml=partial,
                                   **with_yaml({"environment": "a", "pr-auto-merge-limits-yml":
                                                {"plan-max-count-import": 1, "plan-max-count-move": 1}},
                                               {"environment": "b", "pr-auto-merge-limits-yml":
                                                {"plan-max-count-import": 1}}))["errors"])

    def test_the_value_is_a_mapping(self):
        self.assertEqual(["pr-auto-merge-limits-yml is [1]; it must be a mapping of the six limits.",
                          "The environment 'a' sets 'pr-auto-merge-limits-yml' to 'x'; it must be a mapping of the six "
                          "limits."],
                         output_of(pr_auto_merge_limits_yml=[1],
                                   **with_yaml({"environment": "a", "pr-auto-merge-limits-yml": "x"}))["errors"])


class SettingsTogetherTest(unittest.TestCase):
    def test_every_problem_is_reported_in_one_run_globals_first(self):
        self.assertEqual([f"The environment 'a' sets 'zeta', which is not a setting. {DOC}",
                          "goals-yml has the goal 'aply', which is not a goal; did you mean 'apply'? A goal is one of "
                          "init, format, validate, lint, plan, apply, destroy-plan, destroy, all, apply-on-pr, "
                          "destroy-on-pr.",
                          "pr-auto-merge-from-actors-yml holds 7, which is not a login; quote it if it is one.",
                          "The environment 'a' has the goal 'plan' without 'init': a plan needs an initialised "
                          "directory, so it could never run. Add 'init', or use 'all'.",
                          "The environment 'a' has the additional init directory '', which is empty.",
                          "The environment 'a' sets 'pr-auto-merge-limits-yml' to 'x'; it must be a mapping of the six "
                          "limits."],
                         output_of(goals_yml=["aply"], pr_auto_merge_from_actors_yml=[7],
                                   **with_yaml({"environment": "a", "zeta": 1, "goals-yml": ["plan"],
                                                "terraform-init-additional-dirs-yml": [""],
                                                "pr-auto-merge-limits-yml": "x"}))["errors"])


class SettingWarningsTest(unittest.TestCase):
    def test_auto_merge_on_for_an_environment_while_off_for_the_run_is_a_warning(self):
        output = output_of([{"environment": "a", "pr-auto-merge-enabled": True},
                            {"environment": "b", "pr-auto-merge-enabled": False}, {"environment": "c"}])
        self.assertEqual([], output["errors"])
        self.assertEqual(["The environment 'a' sets pr-auto-merge-enabled: true, but auto-merge is switched off for the "
                          "whole run (the input pr-auto-merge-enabled is false), so it has no effect."],
                         output["warnings"])

    def test_no_warning_while_auto_merge_is_on(self):
        output = output_of([{"environment": "a", "pr-auto-merge-enabled": True}], inputs=ON,
                           pr_auto_merge_from_actors_yml=["x"])
        self.assertEqual(([], []), (output["errors"], output["warnings"]))


if __name__ == "__main__":
    unittest.main()
