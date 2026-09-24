"""The seed manifest: the pull request heads and tag purges the seed job reconciles.

docs/Path-relevance.md §6.1-§6.3. Group heads are always placeholders; an ungrouped environment's
head is a placeholder when it is affected and its final "not affected" body when it is not; an
unaffected commenting environment's old tags are purged. In mode `all` the manifest is the one the
seed job composed before relevance, byte for byte.
"""

import unittest

import support
from dsb_tf_engine import decide

WAIT = "⏳ Awaiting results (run #4711 attempt #2)…"


def document(environments, files=None, event="pull_request", action="synchronize", is_fork=False, run=True,
             count=None):
    env_yaml = [{key: support.parsed(value) for key, value in e.items() if key.endswith("-yml")} for e in environments]
    doc = support.document(environments=environments, env_yaml=env_yaml)
    doc["event"]["name"] = event
    if event == "pull_request":
        doc["event"]["action"] = action
        doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": is_fork}
    if run:
        doc["run"] = {"id": 4711, "attempt": 2}
    if files is not None:
        doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                                "count": len(files) if count is None else count, "files": files}
    return doc


def comments(environments, **kwargs):
    output = decide.decide(document(environments, **kwargs))
    assert output["errors"] == [], output["errors"]
    return output["comments"]


def heads(environments, **kwargs):
    return [(head["marker"], head["body"]) for head in comments(environments, **kwargs)["heads"]]


def gc(*names):
    return [{"marker-prefix": f"<!-- tf:tag:{kind}:{name}:", "keep-marker-substring": ""}
            for name in names for kind in ("plan", "apply", "destroy-plan", "destroy")]


class ModeAllTest(unittest.TestCase):
    """What the seed job composed from the matrix before relevance, pinned from its jq."""

    def test_ungrouped_environments_get_placeholders_in_declaration_order(self):
        environments = [{"environment": "prod"}, {"environment": "dev", "github-environment": "dev-gh"}]
        self.assertEqual([
            ("<!-- tf:head:env:prod -->", f"### Terraform validation summary for environment: `prod`\n\n{WAIT}"),
            ("<!-- tf:head:env:dev-gh -->", f"### Terraform validation summary for environment: `dev-gh`\n\n{WAIT}"),
        ], heads(environments))

    def test_an_environment_that_mutates_on_pull_request_gets_the_short_title_and_the_mode_line(self):
        environments = [{"environment": "a", "goals-yml": ["all", "apply-on-pr"]},
                        {"environment": "b", "goals-yml": ["destroy-on-pr", "apply-on-pr"]},
                        {"environment": "c", "goals-yml": ["destroy-on-pr"]}]
        self.assertEqual([
            ("<!-- tf:head:env:a -->", f"### Terraform summary for environment: `a`\n\n{WAIT}\n\n🐙 applies on PR"),
            ("<!-- tf:head:env:b -->",
             f"### Terraform summary for environment: `b`\n\n{WAIT}\n\n🐙 applies on PR · ☠ destroys on PR"),
            ("<!-- tf:head:env:c -->", f"### Terraform summary for environment: `c`\n\n{WAIT}\n\n☠ destroys on PR"),
        ], heads(environments))

    def test_group_heads_come_first_sorted_and_grouped_environments_get_none(self):
        environments = [{"environment": "a", "pr-comment-group": "zeta"}, {"environment": "b"},
                        {"environment": "c", "pr-comment-group": "alpha"},
                        {"environment": "d", "pr-comment-group": "zeta", "goals-yml": ["apply-on-pr"]}]
        self.assertEqual([
            ("<!-- tf:head:group:alpha -->", f"### Terraform validation summary for group: `alpha`\n\n{WAIT}"),
            ("<!-- tf:head:group:zeta -->", f"### Terraform summary for group: `zeta`\n\n{WAIT}"),
            ("<!-- tf:head:env:b -->", f"### Terraform validation summary for environment: `b`\n\n{WAIT}"),
        ], heads(environments))

    def test_a_group_without_a_commenting_member_gets_no_head(self):
        environments = [{"environment": "a", "pr-comment-group": "g", "add-pr-comment": False},
                        {"environment": "b", "add-pr-comment": "false"}]
        self.assertEqual([], heads(environments))

    def test_a_non_commenting_member_still_sets_the_group_title(self):
        environments = [{"environment": "a", "pr-comment-group": "g"},
                        {"environment": "b", "pr-comment-group": "g", "add-pr-comment": False,
                         "goals-yml": ["apply-on-pr"]}]
        self.assertEqual([("<!-- tf:head:group:g -->", f"### Terraform summary for group: `g`\n\n{WAIT}")],
                         heads(environments))

    def test_a_global_group_applies_to_every_environment(self):
        doc = document([{"environment": "a"}, {"environment": "b", "pr-comment-group": "own"}])
        doc["workflow_inputs"]["pr-comment-group"] = "shared"
        markers = [head["marker"] for head in decide.decide(doc)["comments"]["heads"]]
        self.assertEqual(["<!-- tf:head:group:own -->", "<!-- tf:head:group:shared -->"], markers)

    def test_mode_all_purges_nothing(self):
        manifest = comments([{"environment": "a"}], files=[".github/workflows/x.yml"])
        self.assertEqual(([], []), (manifest["purge_tags_for"], manifest["gc"]))

    def test_every_head_is_a_placeholder_with_its_kind_key_and_title(self):
        manifest = comments([{"environment": "a", "pr-comment-group": "g"}, {"environment": "b"}])
        self.assertEqual([("group", "g", "placeholder", "Terraform validation summary"),
                          ("env", "b", "placeholder", "Terraform validation summary")],
                         [(h["kind"], h["key"], h["state"], h["title"]) for h in manifest["heads"]])


class NotAffectedTest(unittest.TestCase):
    ENVS = [{"environment": "prod"}, {"environment": "staging", "pr-comment-group": "platform"},
            {"environment": "sandbox", "pr-comment-group": "platform"}]

    def test_an_unaffected_ungrouped_environment_gets_its_final_body(self):
        body = ("### Terraform validation summary for environment: `prod`\n\n"
                "➖ Not affected by this pull request: no changed file matches this environment's paths "
                "(run #4711 attempt #2).\n\n"
                "<details><summary>Path rules</summary>\n\n"
                "Included: `envs/prod/**` · `main/**` · `modules/**` · `.tflint.hcl`\n"
                "Ignored: `**/*.md`\n"
                "Relevance: `diff`, pull request #87, 3 changed files\n\n"
                "</details>")
        self.assertEqual([
            ("<!-- tf:head:group:platform -->", f"### Terraform validation summary for group: `platform`\n\n{WAIT}"),
            ("<!-- tf:head:env:prod -->", body),
        ], heads(self.ENVS, files=["README.md"], count=3))

    def test_the_body_keeps_the_title_says_one_file_and_no_ignore(self):
        environments = [{"environment": "a", "goals-yml": ["apply-on-pr"], "paths": ["x/**"]}]
        body = heads(environments, files=["README.md"])[0][1]
        self.assertEqual("### Terraform summary for environment: `a`\n\n"
                         "➖ Not affected by this pull request: no changed file matches this environment's paths "
                         "(run #4711 attempt #2).\n\n"
                         "<details><summary>Path rules</summary>\n\n"
                         "Included: `x/**`\n"
                         "Ignored: none\n"
                         "Relevance: `diff`, pull request #87, 1 changed file\n\n"
                         "</details>", body)

    def test_every_ignore_pattern_is_listed(self):
        body = heads([{"environment": "a", "paths-ignore": ["**/*.md", "docs/**"]}], files=["docs/x.tf"])[0][1]
        self.assertIn("\nIgnored: `**/*.md` · `docs/**`\n", body)

    def test_affected_environments_keep_their_placeholders(self):
        manifest = comments(self.ENVS, files=["envs/prod/main.tf"])
        self.assertEqual([("group", "platform", "placeholder"), ("env", "prod", "placeholder")],
                         [(h["kind"], h["key"], h["state"]) for h in manifest["heads"]])
        self.assertEqual(["staging", "sandbox"], manifest["purge_tags_for"])
        self.assertEqual(gc("staging", "sandbox"), manifest["gc"])

    def test_an_all_unaffected_group_keeps_its_placeholder(self):
        manifest = comments(self.ENVS, files=["README.md"])
        self.assertEqual([("group", "platform", "placeholder"), ("env", "prod", "not-affected")],
                         [(h["kind"], h["key"], h["state"]) for h in manifest["heads"]])

    def test_unaffected_commenting_environments_have_their_tags_purged(self):
        environments = [{"environment": "a", "github-environment": "a-gh"}, {"environment": "b", "add-pr-comment": False},
                        {"environment": "c", "pr-comment-group": "g"}, {"environment": "d", "paths": ["**"]}]
        manifest = comments(environments, files=["README.md"])
        self.assertEqual(["a-gh", "c"], manifest["purge_tags_for"])
        self.assertEqual(gc("a-gh", "c"), manifest["gc"])


class WhenTest(unittest.TestCase):
    ENVS = [{"environment": "a"}]
    EMPTY = {"heads": [], "purge_tags_for": [], "gc": []}

    def test_only_a_pull_request_that_is_open_and_not_from_a_fork_is_seeded(self):
        for kwargs in (dict(event="push"), dict(event="schedule"), dict(is_fork=True), dict(action="closed"),
                       dict(action="converted_to_draft"), dict(run=False)):
            with self.subTest(kwargs=kwargs):
                self.assertEqual(self.EMPTY, comments(self.ENVS, files=["README.md"], **kwargs))

    def test_other_pull_request_actions_are_seeded(self):
        for action in ("opened", "reopened", "synchronize", "ready_for_review", ""):
            with self.subTest(action=action):
                self.assertEqual(1, len(comments(self.ENVS, files=["README.md"], action=action)["heads"]))

    def test_an_error_leaves_no_manifest(self):
        output = decide.decide(document([{"environment": "a", "paths": "x"}]))
        self.assertNotIn("comments", output)


if __name__ == "__main__":
    unittest.main()
