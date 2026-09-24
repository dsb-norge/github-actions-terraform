"""Relevance: which environments a change is relevant to. docs/Path-relevance.md §3-§5.

The mode is derived from the facts the adapter reports, and every uncertainty fails open to mode
`all`. In mode `diff` an environment runs when a changed file matches one of its `paths` and none
of its `paths-ignore`; `auto` is the standard layout relative to its project directory.
"""

import copy
import unittest

import support
from dsb_tf_engine import decide

ENVS = [{"environment": "prod"}, {"environment": "staging", "pr-comment-group": "platform"},
        {"environment": "sandbox", "pr-comment-group": "platform"}]


def facts(files, **overrides):
    changed = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": len(files),
               "files": files}
    changed.update(overrides)
    return changed


def document(environments=None, files=None, event="pull_request", changed=None, enabled=True, push=None):
    environments = [{"environment": "prod"}] if environments is None else environments
    env_yaml = [{key: support.parsed(value) for key, value in e.items() if key.endswith("-yml")} for e in environments]
    doc = support.document(environments=environments, inputs={"path-relevance-enabled": enabled}, env_yaml=env_yaml)
    doc["event"]["name"] = event
    if event == "pull_request":
        doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": False}
    if event == "push":
        doc["event"]["push"] = {"created": False, "forced": False, "deleted": False, **(push or {})}
    if changed is None and files is not None:
        changed = facts(files)
    if changed is not None:
        doc["changed_files"] = changed
    return doc


def run(**kwargs):
    output = decide.decide(document(**kwargs))
    assert output["errors"] == [], output["errors"]
    return output


def verdicts(output):
    return {e["environment"]: (e["verdict"], e["reasons"]) for e in output["environments"]}


class ModeTest(unittest.TestCase):
    def mode(self, **kwargs):
        relevance = run(**kwargs)["relevance"]
        return relevance["mode"], relevance["reason"]

    def test_a_pull_request_or_a_push_with_facts_is_a_diff(self):
        self.assertEqual(("diff", "diff"), self.mode(files=["README.md"]))
        self.assertEqual(("diff", "diff"), self.mode(files=["README.md"], enabled="true"))
        self.assertEqual(("diff", "diff"), self.mode(files=["README.md"], event="push"))

    def test_each_fail_open_reason(self):
        cases = [
            ("disabled", dict(files=["README.md"], enabled=False)),
            ("disabled", dict(files=["README.md"], enabled="false")),
            ("event", dict(event="schedule")),
            ("event", dict(event="workflow_dispatch", files=["README.md"])),
            ("event", dict(event="pull_request_target", files=["README.md"])),
            ("forced", dict(event="push", files=["README.md"], push={"forced": True})),
            ("branch-deleted", dict(event="push", files=[], push={"deleted": True})),
            ("not-computed", dict()),
            ("not-computed", dict(event="push")),
            ("pr-head-moved", dict(changed=facts(["README.md"], api_head_sha="newer"))),
            ("too-many-files", dict(changed=facts(["README.md"], truncated=True))),
            ("api-error", dict(changed=facts([], available=False, error="HTTP 502", api_head_sha=None))),
            ("workflow-changed", dict(files=["README.md", ".github/workflows/ci.yml"])),
            ("workflow-changed", dict(files=[".github/workflows/sub/x.yaml"], event="push")),
        ]
        for reason, kwargs in cases:
            with self.subTest(reason=reason, kwargs=kwargs):
                self.assertEqual(("all", reason), self.mode(**kwargs))

    def test_the_reasons_are_evaluated_in_the_order_of_the_spec(self):
        broken = facts([".github/workflows/x.yml"], available=False, truncated=True, error="x", api_head_sha="newer")
        cases = [
            ("disabled", dict(event="schedule", enabled=False)),
            ("event", dict(event="workflow_dispatch", changed=broken)),
            ("forced", dict(event="push", changed=broken, push={"forced": True, "deleted": True})),
            ("branch-deleted", dict(event="push", changed=broken, push={"deleted": True})),
            ("pr-head-moved", dict(changed=broken)),
            ("too-many-files", dict(changed={**broken, "api_head_sha": "abc"})),
            ("api-error", dict(changed={**broken, "api_head_sha": "abc", "truncated": False})),
        ]
        for reason, kwargs in cases:
            with self.subTest(reason=reason):
                self.assertEqual(("all", reason), self.mode(**kwargs))

    def test_files_under_a_similar_directory_are_not_a_workflow_change(self):
        for path in (".github/workflows", ".github/workflowsx/a.yml", "x/.github/workflows/a.yml", ".github/a.yml"):
            with self.subTest(path=path):
                self.assertEqual(("diff", "diff"), self.mode(files=[path]))

    def test_a_created_branch_is_a_diff_on_the_adapters_compare(self):
        self.assertEqual(("diff", "diff"), self.mode(event="push", files=["envs/prod/main.tf"],
                                                     push={"created": True}))

    def test_the_head_check_applies_to_pull_requests_only(self):
        self.assertEqual(("diff", "diff"), self.mode(event="push", changed=facts(["x.md"], api_head_sha="other")))

    def test_an_unknown_live_head_is_not_a_moved_head(self):
        self.assertEqual(("diff", "diff"), self.mode(changed=facts(["x.md"], api_head_sha=None)))

    def test_the_relevance_block_counts_what_the_adapter_counted(self):
        self.assertEqual({"mode": "diff", "reason": "diff", "changed_count": 7},
                         run(changed=facts(["a.md", "b.md"], count=7))["relevance"])
        self.assertEqual({"mode": "all", "reason": "workflow-changed", "changed_count": 1},
                         run(files=[".github/workflows/a.yml"])["relevance"])
        self.assertEqual({"mode": "all", "reason": "event", "changed_count": 0}, run(event="schedule")["relevance"])

    def test_an_invalid_switch_is_an_error(self):
        for value, shown in (("yes", "'yes'"), (1, "1"), ([], "[]")):
            with self.subTest(value=value):
                output = decide.decide(document(files=[], enabled=value))
                self.assertEqual([f"The input 'path-relevance-enabled' is {shown}; it must be true or false!"],
                                 output["errors"])
                self.assertEqual(([], {}), (output["environments"], output["matrices"]))

    def test_the_switch_is_global_only(self):
        output = decide.decide(document(environments=[{"environment": "prod", "path-relevance-enabled": False}],
                                        files=[]))
        self.assertEqual(["The environment 'prod' sets 'path-relevance-enabled', which is a workflow input only; "
                          "to run it on every change, set its 'paths' to ['**']!"], output["errors"])


class AutoTest(unittest.TestCase):
    def rules(self, environment, directories=None):
        doc = document(environments=[environment], files=[])
        if directories is not None:
            doc["directories_exist"] = directories
        output = decide.decide(doc)
        self.assertEqual([], output["errors"])
        entry = output["environments"][0]
        return entry["paths"], entry["paths-ignore"]

    def test_auto_is_the_standard_layout_relative_to_the_project_dir(self):
        self.assertEqual((["envs/prod/**", "main/**", "modules/**", ".tflint.hcl"], ["**/*.md"]),
                         self.rules({"environment": "prod"}))

    def test_the_project_dir_is_normalised(self):
        for project_dir, first in (("./envs/x", "envs/x/**"), ("envs/x/", "envs/x/**"), ("./a/b//", "a/b/**"),
                                   (".", "**"), ("./", "**")):
            with self.subTest(project_dir=project_dir):
                paths, _ = self.rules({"environment": "prod", "project-dir": project_dir}, {project_dir: True})
                self.assertEqual(first, paths[0])

    def test_additional_init_dirs_join_auto(self):
        environment = {"environment": "prod", "terraform-init-additional-dirs-yml": ["./shared", "lib/", "."]}
        paths, _ = self.rules(environment)
        self.assertEqual(["envs/prod/**", "main/**", "modules/**", ".tflint.hcl", "shared/**", "lib/**", "**"], paths)

    def test_the_global_additional_dirs_count_too(self):
        doc = document(files=[])
        doc["yaml"]["inputs"]["terraform-init-additional-dirs-yml"] = support.parsed(["common"])
        paths = decide.decide(doc)["environments"][0]["paths"]
        self.assertEqual(["envs/prod/**", "main/**", "modules/**", ".tflint.hcl", "common/**"], paths)

    def test_auto_with_extras_and_a_replacement_list(self):
        self.assertEqual(["scripts/**", "envs/prod/**", "main/**", "modules/**", ".tflint.hcl"],
                         self.rules({"environment": "prod", "paths": ["scripts/**", "auto"]})[0])
        self.assertEqual((["**"], []), self.rules({"environment": "prod", "paths": ["**"]}))

    def test_duplicates_are_dropped_keeping_the_first(self):
        self.assertEqual(["envs/prod/**", "main/**", "modules/**", ".tflint.hcl"],
                         self.rules({"environment": "prod", "paths": ["auto", "auto", "./main/**"]})[0])
        self.assertEqual(["**/*.md"], self.rules({"environment": "prod", "paths-ignore": ["**/*.md", "./**/*.md"]})[1])

    def test_the_implied_ignore_comes_only_with_auto(self):
        self.assertEqual(["**/*.md"], self.rules({"environment": "prod", "paths": ["x/**", "auto"]})[1])
        self.assertEqual([], self.rules({"environment": "prod", "paths": ["x/**"]})[1])
        self.assertEqual([], self.rules({"environment": "prod", "paths-ignore": []})[1])
        self.assertEqual(["**/*.txt"], self.rules({"environment": "prod", "paths-ignore": ["**/*.txt"]})[1])


class MatchingTest(unittest.TestCase):
    def affected(self, files, environments=ENVS):
        return {name: verdict for name, (verdict, _) in verdicts(run(environments=environments, files=files)).items()}

    def test_the_examples_of_the_spec(self):
        cases = [
            (["README.md", "docs/runbook.md"], {"prod": "skip", "staging": "skip", "sandbox": "skip"}),
            (["envs/staging/main.tf"], {"prod": "skip", "staging": "run", "sandbox": "skip"}),
            (["modules/net/main.tf"], {"prod": "run", "staging": "run", "sandbox": "run"}),
            (["envs/prod/README.md"], {"prod": "skip", "staging": "skip", "sandbox": "skip"}),
            ([".tflint.hcl"], {"prod": "run", "staging": "run", "sandbox": "run"}),
            # A pattern without a slash matches the basename, so auto's `.tflint.hcl` matches every one:
            # an over-run, the safe direction.
            (["envs/staging/.tflint.hcl"], {"prod": "run", "staging": "run", "sandbox": "run"}),
            (["envs/stagingx/main.tf"], {"prod": "skip", "staging": "skip", "sandbox": "skip"}),
            ([], {"prod": "skip", "staging": "skip", "sandbox": "skip"}),
        ]
        for files, expected in cases:
            with self.subTest(files=files):
                self.assertEqual(expected, self.affected(files))

    def test_an_empty_ignore_makes_markdown_relevant(self):
        self.assertEqual({"prod": "run"}, self.affected(["envs/prod/README.md"], [{"environment": "prod",
                                                                                   "paths-ignore": []}]))

    def test_ignore_is_applied_per_file_after_paths(self):
        environments = [{"environment": "prod", "paths": ["**"], "paths-ignore": ["docs/**"]}]
        self.assertEqual({"prod": "skip"}, self.affected(["docs/a.tf"], environments))
        self.assertEqual({"prod": "run"}, self.affected(["docs/a.tf", "x.tf"], environments))

    def test_the_reasons_name_the_first_relevant_file_s_rule(self):
        output = run(environments=ENVS, files=["README.md", "envs/staging/a.tf", "modules/x.tf"])
        self.assertEqual({"prod": ("run", ["relevance: modules/**"]),
                          "staging": ("run", ["relevance: envs/staging/**"]),
                          "sandbox": ("run", ["relevance: modules/**"])}, verdicts(output))
        output = run(environments=ENVS, files=["envs/prod/README.md", "envs/prod/x.tf"])
        self.assertEqual({"prod": ("run", ["relevance: envs/prod/**"]),
                          "staging": ("skip", ["relevance: no changed file matches"]),
                          "sandbox": ("skip", ["relevance: no changed file matches"])}, verdicts(output))

    def test_mode_all_runs_everything_and_says_why(self):
        for kwargs, reason in ((dict(event="schedule"), "event"), (dict(files=[], enabled=False), "disabled")):
            with self.subTest(reason=reason):
                output = run(environments=ENVS, **kwargs)
                self.assertEqual({(e["verdict"], tuple(e["reasons"])) for e in output["environments"]},
                                 {("run", (f"relevance: all:{reason}",))})

    def test_the_matrix_holds_the_affected_rows_in_declaration_order(self):
        output = run(environments=ENVS, files=["envs/sandbox/a.tf", "envs/prod/a.tf"])
        self.assertEqual(["prod", "sandbox"], output["matrices"]["1"]["environment"])
        self.assertEqual(["prod", "sandbox"], [row["environment"] for row in output["matrices"]["1"]["include"]])
        self.assertEqual({"affected": 2, "unaffected": 1}, output["counts"])

    def test_nothing_affected_is_an_empty_matrix(self):
        output = run(environments=ENVS, files=["README.md"])
        self.assertEqual({"1": {"environment": [], "include": []}}, output["matrices"])
        self.assertEqual({"affected": 0, "unaffected": 3}, output["counts"])

    def test_mode_all_reproduces_the_rows_without_relevance(self):
        with_rules = run(environments=[{"environment": "prod", "paths": ["x/**"], "paths-ignore": ["y/**"]}],
                         event="schedule")
        without = run(environments=[{"environment": "prod"}], event="schedule")
        self.assertEqual(without["matrices"], with_rules["matrices"])

    def test_the_rules_are_not_row_variables(self):
        output = run(environments=[{"environment": "prod", "paths": ["**"], "paths-ignore": ["x/**"]}], files=["a"])
        self.assertEqual(set(), {"paths", "paths-ignore"} & set(output["matrices"]["1"]["include"][0]["vars"]))

    def test_the_entry_carries_what_the_jobs_after_the_matrix_read(self):
        environments = [{"environment": "prod", "github-environment": "gh-prod", "pr-comment-group": "g",
                         "goals-yml": ["plan", "apply-on-pr"], "pr-auto-merge-enabled": True,
                         "pr-auto-merge-from-actors-yml": ["bot"]}]
        entry = run(environments=environments, files=["README.md"])["environments"][0]
        self.assertEqual({"environment": "prod", "verdict": "skip", "reasons": ["relevance: no changed file matches"],
                          "github-environment": "gh-prod", "add-pr-comment": "true", "pr-comment-group": "g",
                          "mutates-on-pr": ["apply-on-pr"], "pr-auto-merge-enabled": "true",
                          "pr-auto-merge-from-actors": ["bot"], "pr-auto-merge-limits": None,
                          "paths": ["envs/prod/**", "main/**", "modules/**", ".tflint.hcl"],
                          "paths-ignore": ["**/*.md"]}, entry)

    def test_mutates_on_pr_lists_the_on_pr_goals_in_a_fixed_order(self):
        for goals, expected in ((["destroy-on-pr", "apply-on-pr"], ["apply-on-pr", "destroy-on-pr"]),
                                (["all"], []), (["apply"], []), ("apply-on-pr", ["apply-on-pr"]), (None, []),
                                ({"plan": 1}, [])):
            with self.subTest(goals=goals):
                environments = [{"environment": "prod", "goals-yml": goals}]
                self.assertEqual(expected, run(environments=environments, files=[])["environments"][0]["mutates-on-pr"])

    def test_the_notice(self):
        self.assertEqual(["relevance diff (diff): 1 of 3 environments affected"],
                         run(environments=ENVS, files=["envs/prod/a.tf"])["notices"])
        self.assertEqual(["relevance diff (diff): 0 of 3 environments affected; nothing to verify for this change"],
                         run(environments=ENVS, files=["README.md"])["notices"])
        self.assertEqual(["relevance all (event): 3 of 3 environments affected"],
                         run(environments=ENVS, event="schedule")["notices"])
        self.assertEqual(["relevance diff (diff): 1 of 1 environment affected"],
                         run(files=["envs/prod/a.tf"])["notices"])


class ValidationTest(unittest.TestCase):
    def errors(self, *environments, directories=None):
        doc = document(environments=list(environments), files=[])
        if directories is not None:
            doc["directories_exist"] = directories
        output = decide.decide(doc)
        if output["errors"]:
            self.assertEqual(([], {}), (output["environments"], output["matrices"]))
        return output["errors"]

    def test_paths_must_be_a_non_empty_list_of_patterns(self):
        for paths, message in (
                ("envs/**", "The environment 'prod' sets 'paths' to 'envs/**'; it must be a list of patterns!"),
                (None, "The environment 'prod' sets 'paths' to null; it must be a list of patterns!"),
                ([], "The environment 'prod' sets 'paths' to []; it would never run on a change: remove it for "
                     "auto, or say ['**']!"),
                ([5], "The environment 'prod' has an invalid entry in 'paths': the pattern 5 is not a string!"),
                (["envs/[a]/**"], "The environment 'prod' has an invalid entry in 'paths': the pattern 'envs/[a]/**' "
                                  "is not supported: character classes!"),
                (["auto/"], "The environment 'prod' has an invalid entry in 'paths': the pattern 'auto/' is not "
                            "supported: an empty segment!")):
            with self.subTest(paths=paths):
                self.assertEqual([message], self.errors({"environment": "prod", "paths": paths}))

    def test_paths_ignore_must_be_a_list_of_patterns(self):
        for ignore, message in (
                ("x", "The environment 'prod' sets 'paths-ignore' to 'x'; it must be a list of patterns!"),
                (["auto"], "The environment 'prod' has an invalid entry in 'paths-ignore': 'auto' belongs in "
                           "'paths'!"),
                (["!x"], "The environment 'prod' has an invalid entry in 'paths-ignore': the pattern '!x' is not "
                         "supported: negation; use paths-ignore!")):
            with self.subTest(ignore=ignore):
                self.assertEqual([message], self.errors({"environment": "prod", "paths-ignore": ignore}))

    def test_auto_needs_directories_it_can_match(self):
        self.assertEqual(["The environment 'prod' uses auto, but its project-dir '../x' cannot be matched: the "
                          "pattern '../x/**' is not supported: '.' or '..' segments; set its 'paths' explicitly!"],
                         self.errors({"environment": "prod", "project-dir": "../x"}, directories={"../x": True}))
        self.assertEqual(["The environment 'prod' uses auto, but its terraform-init-additional-dirs entry '/abs' "
                          "cannot be matched: the pattern '/abs/**' is not supported: an absolute path; patterns are "
                          "relative to the repository root; set its 'paths' explicitly!"],
                         self.errors({"environment": "prod", "terraform-init-additional-dirs-yml": ["/abs"]}))
        self.assertEqual(["The environment 'prod' uses auto, but its terraform-init-additional-dirs entry 5 cannot "
                          "be matched: the pattern 5 is not a string; set its 'paths' explicitly!"],
                         self.errors({"environment": "prod", "terraform-init-additional-dirs-yml": [5]}))

    def test_explicit_paths_need_no_matchable_directories(self):
        self.assertEqual([], self.errors({"environment": "prod", "project-dir": "../x", "paths": ["**"]},
                                         directories={"../x": True}))

    def test_every_environment_s_errors_are_collected(self):
        self.assertEqual(["The environment 'a' sets 'paths' to 'x'; it must be a list of patterns!",
                          "The environment 'b' sets 'paths-ignore' to 'y'; it must be a list of patterns!"],
                         self.errors({"environment": "a", "paths": "x"}, {"environment": "b", "paths-ignore": "y"},
                                     directories={"./envs/a": True, "./envs/b": True}))

    def test_one_environment_s_errors_are_collected_too(self):
        self.assertEqual(["The environment 'prod' sets 'paths' to 'x'; it must be a list of patterns!",
                          "The environment 'prod' has an invalid entry in 'paths-ignore': the pattern '' is not "
                          "supported: it is empty!"],
                         self.errors({"environment": "prod", "paths": "x", "paths-ignore": ["ok/**", ""]}))

    def test_rules_are_validated_whatever_the_mode(self):
        for kwargs in (dict(event="schedule"), dict(files=[], enabled=False)):
            with self.subTest(kwargs=kwargs):
                output = decide.decide(document(environments=[{"environment": "prod", "paths": "x"}], **kwargs))
                self.assertEqual(["The environment 'prod' sets 'paths' to 'x'; it must be a list of patterns!"],
                                 output["errors"])


class PurityTest(unittest.TestCase):
    def test_the_document_is_not_modified(self):
        doc = document(environments=ENVS, files=["envs/prod/a.tf"])
        original = copy.deepcopy(doc)
        decide.decide(doc)
        self.assertEqual(original, doc)


if __name__ == "__main__":
    unittest.main()
