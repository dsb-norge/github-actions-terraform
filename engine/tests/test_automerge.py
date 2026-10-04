"""Module auto-merge: whose pull request merges without review, and in which run (docs/Module-auto-merge.md)."""

import json
import unittest

import support
import test_module
from dsb_tf_engine import adapter, automerge, automerge_facts, decide, model
from dsb_tf_engine.environments import ConfigError
from test_adapter import FakeTools, Runner

DEPENDABOT = "dependabot[bot]"
APP = "ci-app[bot]"
HEAD = "c" * 40
RELEASE_BRANCH = "release-please--branches--main"
SKIP = "terraform-docs: automated action [dependabot skip]"


def changed(name="README.md", status="modified", previous=None):
    return {"name": name, "status": status, "previous": previous}


def commit(sha=HEAD, author=DEPENDABOT, committer="web-flow", verified=True, files=None, parents=1, truncated=False,
           message="chore(deps): bump hashicorp/random from 3.6.0 to 3.9.1"):
    """A listed commit: by default the author's, signed by GitHub, changing versions.tf."""
    return {"sha": sha, "parents": parents, "author": author, "committer": committer, "verified": verified,
            "message": message, "files": [changed("versions.tf")] if files is None else files,
            "files_truncated": truncated}


def docs(sha, files=None, message=SKIP):
    """A docs commit as the docs job pushes it in Dependabot's admitted run: unsigned, committed with git."""
    return commit(sha, author="github-actions[bot]", committer="github-actions[bot]", verified=False,
                  files=[changed()] if files is None else files, message=message)


def release(sha=HEAD, files=None):
    return commit(sha, author=APP, files=[changed("CHANGELOG.md"), changed(".release-please-manifest.json")]
                  if files is None else files, message="chore(main): release 1.2.3")


def document(commits=None, author=DEPENDABOT, actor=None, actors=(DEPENDABOT, APP), enabled=True, admission=True,
             head_ref="dependabot/terraform/hashicorp/azurerm-4.42.0", count=None, facts=True, event="pull_request",
             action="synchronize", base_ref="main", admission_facts=None, inputs=None):
    """A module pull request run with auto-merge on; Dependabot's own, admitted, one commit, unless changed."""
    doc = test_module.document(["tests/unit-tests.tftest.hcl"], dirs=["."], event=event, action=action, inputs=inputs)
    doc["workflow_inputs"].update({"pr-auto-merge-enabled": enabled, "dependabot-admission-enabled": admission})
    doc["yaml"]["inputs"]["pr-auto-merge-from-actors-yml"] = support.parsed(list(actors))
    doc["event"]["actor"] = author if actor is None else actor
    if event != "pull_request":
        return doc
    doc["event"]["base_ref"] = base_ref
    doc["event"]["pull_request"].update({"author": author, "head_sha": HEAD})
    if admission and doc["event"]["actor"] == DEPENDABOT:
        doc["admission"] = admission_facts or support.admission_facts(locks={})
    commits = [commit()] if commits is None else commits
    if facts:
        doc["automerge"] = {"available": True, "reason": None, "head_ref": head_ref,
                            "count": len(commits) if count is None else count, "commits": commits}
    return doc


def verdict(*args, **kwargs):
    output = decide.decide(document(*args, **kwargs))
    assert output["errors"] == [], output["errors"]
    return output["automerge"]


def reason(*args, **kwargs):
    result = verdict(*args, **kwargs)
    assert not result["eligible"], result
    return result["reason"]


POLICY = {"enabled": True, "actors": [DEPENDABOT, APP]}
ADMITTED = {"applies": True, "push_run": False, "admitted": True}


class TableTest(unittest.TestCase):
    """docs/Module-auto-merge.md §3, the table."""

    def test_dependabots_own_admitted_run_merges(self):
        self.assertEqual({"applies": True, "author": DEPENDABOT, "actor": DEPENDABOT, "eligible": True, "reason": "",
                          "confirm_app": False, "commits": [{"sha": HEAD, "author": DEPENDABOT, "kind": "author"}]},
                         verdict())

    def test_the_run_the_docs_commit_starts_merges_once_the_app_is_confirmed(self):
        result = verdict([commit("a" * 40), docs(HEAD)], actor=APP)
        self.assertEqual((True, True), (result["eligible"], result["confirm_app"]))
        self.assertEqual([("a" * 40, DEPENDABOT, "author"), (HEAD, "github-actions[bot]", "docs")],
                         [(item["sha"], item["author"], item["kind"]) for item in result["commits"]])

    def test_a_persons_run_on_dependabots_pull_request_does_not(self):
        self.assertEqual("the run was started by octocat, neither the author (dependabot[bot]) nor the CI App's docs "
                         "commit", reason(actor="octocat"))
        self.assertEqual("the run was started by octocat, not by the CI App's docs commit",
                         reason([commit("a" * 40), docs(HEAD)], actor="octocat"))

    def test_a_persons_commit_or_update_does_not(self):
        self.assertEqual("commit aaaaaaa by octocat is neither the author's (dependabot[bot]), signed by GitHub, nor a "
                         "docs commit (modified versions.tf)",
                         reason([commit("a" * 40, author="octocat"), commit()]))
        self.assertEqual("commit ccccccc by dependabot[bot] is a merge commit", reason([commit(parents=2)]))

    def test_the_verdict_lists_every_commits_kind(self):
        result = verdict([commit("a" * 40, author="octocat"), commit("b" * 40, parents=2, files=[changed()]),
                          docs("d" * 40), commit()])
        self.assertEqual(["other", "other", "docs", "author"], [item["kind"] for item in result["commits"]])

    def test_release_pleases_pull_request_merges(self):
        result = verdict([release()], author=APP, head_ref=RELEASE_BRANCH, admission=False, actors=[APP])
        self.assertEqual((True, False, ""), (result["eligible"], result["confirm_app"], result["reason"]))

    def test_a_persons_pull_request_does_not(self):
        self.assertEqual("its author, octocat, is not in pr-auto-merge-from-actors-yml",
                         reason([commit(author="octocat")], author="octocat"))


class ScopeTest(unittest.TestCase):
    def test_off_closing_or_another_event_does_not_apply(self):
        self.assertEqual({"applies": False}, verdict(enabled=False))
        self.assertEqual({"applies": False}, verdict(event="push", admission=False, actors=[APP]))
        for action in ("closed", "converted_to_draft"):
            with self.subTest(action=action):
                self.assertEqual({"applies": False}, verdict(action=action))

    def test_a_pull_request_event_without_its_pull_request_does_not_apply(self):
        doc = document()
        del doc["event"]["pull_request"]
        self.assertEqual({"applies": False}, automerge.judge(doc, POLICY, ADMITTED))

    def test_a_fork_or_another_base_is_not_considered(self):
        doc = document()
        doc["event"]["pull_request"]["is_fork"] = True
        self.assertEqual("it comes from a fork", automerge.judge(doc, POLICY, ADMITTED)["reason"])
        self.assertEqual("it is against release/v0, not the default branch main", reason(base_ref="release/v0"))
        doc = document()
        del doc["event"]["base_ref"]
        self.assertEqual("it is against an unknown branch, not the default branch main",
                         automerge.judge(doc, POLICY, ADMITTED)["reason"])

    def test_an_unknown_author_is_not_listed(self):
        doc = document()
        del doc["event"]["pull_request"]["author"]
        self.assertEqual("its author, unknown, is not in pr-auto-merge-from-actors-yml",
                         automerge.judge(doc, POLICY, ADMITTED)["reason"])

    def test_the_author_compares_without_case(self):
        self.assertTrue(verdict([commit(author="Dependabot[bot]")], actors=["Dependabot[bot]", APP])["eligible"])
        self.assertTrue(verdict([commit(author=DEPENDABOT)], author="Dependabot[bot]", actor=DEPENDABOT)["eligible"])

    def test_the_facts_are_gathered_only_for_a_listed_author_in_scope(self):
        self.assertTrue(automerge.wants_facts(document(), POLICY))
        doc = document()
        doc["event"]["pull_request"]["is_fork"] = True
        self.assertFalse(automerge.wants_facts(doc, POLICY))
        self.assertFalse(automerge.wants_facts(document(author="octocat"), POLICY))
        self.assertFalse(automerge.wants_facts(document(action="closed"), POLICY))
        self.assertFalse(automerge.wants_facts(document(), {"enabled": False, "actors": [DEPENDABOT]}))


class ListingTest(unittest.TestCase):
    """Rule 2: the commits are known."""

    def test_a_listing_that_failed_or_was_never_made(self):
        doc = document()
        doc["automerge"] = {"available": False, "reason": "gh api x failed: HTTP 502", "head_ref": "", "count": 0,
                            "commits": []}
        self.assertEqual("its commits could not be listed (gh api x failed: HTTP 502)",
                         automerge.judge(doc, POLICY, ADMITTED)["reason"])
        self.assertEqual("its commits could not be listed (not gathered)", reason(facts=False))

    def test_a_listing_without_commits(self):
        self.assertEqual("GitHub listed no commit", reason([], count=0))

    def test_a_capped_listing(self):
        commits = [commit(f"{index:040d}") for index in range(249)] + [commit()]
        self.assertEqual("it has 250 commits or more, more than GitHub lists", reason(commits))
        self.assertTrue(verdict(commits[1:])["eligible"])

    def test_a_listing_short_of_the_events_count(self):
        self.assertEqual("GitHub listed 1 of its 2 commits", reason(count=2))

    def test_a_listing_that_ends_elsewhere(self):
        self.assertEqual("its listed commits do not end with the head this run tested", reason([commit("a" * 40)]))


class CommitTest(unittest.TestCase):
    """Rules 3 and 4: one parent each; the author's, or a trailing docs commit."""

    def test_a_forged_unsigned_author(self):
        self.assertEqual("commit ccccccc by dependabot[bot] is neither the author's (dependabot[bot]), signed by "
                         "GitHub, nor a docs commit (modified versions.tf)",
                         reason([commit(verified=False, committer="octocat")]))

    def test_a_persons_signed_commit_with_a_forged_author(self):
        self.assertEqual("commit ccccccc by dependabot[bot] is neither the author's (dependabot[bot]), signed by "
                         "GitHub, nor a docs commit (modified versions.tf)", reason([commit(committer="octocat")]))

    def test_a_signed_commit_by_github_that_is_not_verified(self):
        self.assertIn("is neither the author's", reason([commit(verified=False)]))

    def test_a_commit_github_resolved_to_no_account(self):
        self.assertEqual("commit ccccccc by an account GitHub could not resolve is neither the author's "
                         "(dependabot[bot]), signed by GitHub, nor a docs commit (modified versions.tf)",
                         reason([commit(author=None)]))
        self.assertEqual("commit ccccccc by an account GitHub could not resolve is a merge commit",
                         reason([commit(author=None, parents=2)]))

    def test_a_root_commit_is_not_one_parent(self):
        self.assertIn("is a merge commit", reason([commit(parents=0)]))

    def test_a_merge_commit_of_docs_files_is_not_docs(self):
        self.assertIn("is a merge commit", reason([commit("a" * 40), commit(parents=2, files=[changed()])]))

    def test_a_docs_commit_that_is_not_only_docs(self):
        cases = [([changed(), changed("main.tf")], "modified main.tf"),
                 ([changed("README.md", "renamed", "main.tf")], "renamed README.md"),
                 ([changed("README.md", "modified", "main.tf")], "modified README.md"),
                 ([changed("README.md", "removed")], "removed README.md"),
                 ([changed("README.md", "added")], "added README.md"),
                 ([changed(".terraform-docs.yml", "removed")], "removed .terraform-docs.yml"),
                 ([changed(".terraform-docs.yml", "renamed", "x.yml")], "renamed .terraform-docs.yml"),
                 ([changed("examples/a/b/README.md")], "modified examples/a/b/README.md"),
                 ([changed("examples/README.md")], "modified examples/README.md"),
                 ([changed("modules/x/README.md")], "modified modules/x/README.md"),
                 ([], "no file")]
        for files, change in cases:
            with self.subTest(change=change):
                self.assertEqual(f"commit ccccccc by github-actions[bot] is neither the author's (dependabot[bot]), "
                                 f"signed by GitHub, nor a docs commit ({change})",
                                 reason([commit("a" * 40), docs(HEAD, files)], actor=APP))

    def test_a_docs_commit_whose_files_were_cut_short(self):
        truncated = docs(HEAD)
        truncated["files_truncated"] = True
        self.assertEqual("commit ccccccc by github-actions[bot] is neither the author's (dependabot[bot]), signed by "
                         "GitHub, nor a docs commit (too many files to list)",
                         reason([commit("a" * 40), truncated], actor=APP))
        unlisted = docs(HEAD)
        unlisted["files"] = None
        self.assertIn("nor a docs commit (no file)", reason([commit("a" * 40), unlisted], actor=APP))

    def test_the_docs_jobs_files(self):
        files = [changed(), changed("examples/01-basic/README.md"), changed(".terraform-docs.yml", "added"),
                 changed("examples/.terraform-docs.yml", "added"), changed(".terraform-docs.yml"),
                 changed("examples/.terraform-docs.yml")]
        self.assertTrue(verdict([commit("a" * 40), docs(HEAD, files)], actor=APP)["eligible"])

    def test_the_readme_follows_readme_file_path(self):
        moved = {"readme-file-path": "./modules/x/"}
        self.assertTrue(verdict([commit("a" * 40), docs(HEAD, [changed("modules/x/README.md")])], actor=APP,
                                inputs=moved)["eligible"])
        self.assertIn("(modified README.md)", reason([commit("a" * 40), docs(HEAD)], actor=APP, inputs=moved))
        doc = document([commit("a" * 40), docs(HEAD)], actor=APP)
        del doc["workflow_inputs"]["readme-file-path"]
        self.assertTrue(decide.decide(doc)["automerge"]["eligible"])

    def test_two_trailing_docs_commits(self):
        result = verdict([commit("a" * 40), docs("b" * 40), docs(HEAD)], actor=APP)
        self.assertEqual((True, ["author", "docs", "docs"]),
                         (result["eligible"], [item["kind"] for item in result["commits"]]))

    def test_a_docs_commit_before_the_authors(self):
        self.assertEqual("docs commit aaaaaaa is followed by a commit of the author's; docs commits come last",
                         reason([docs("a" * 40), commit()], actor=APP))
        self.assertEqual("docs commit bbbbbbb is followed by a commit of the author's; docs commits come last",
                         reason([commit("a" * 40), docs("b" * 40), commit("d" * 40), docs(HEAD)], actor=APP))

    def test_docs_commits_alone(self):
        self.assertEqual("it has no commit of its author's", reason([docs(HEAD)], actor=APP))


class RunTest(unittest.TestCase):
    """Rule 5: the run is the right one."""

    def test_dependabots_docs_commits_were_made_in_its_admitted_run(self):
        # A person's run committed the README with a docs job from before the fix: nobody admitted the head beneath.
        self.assertEqual("docs commit ccccccc was not made in an admitted Dependabot run: its message is not "
                         "'terraform-docs: automated action [dependabot skip]'",
                         reason([commit("a" * 40), docs(HEAD, message="terraform-docs: automated action")], actor=APP))
        self.assertIn("docs commit bbbbbbb was not made",
                      reason([commit("a" * 40), docs("b" * 40, message="x"), docs(HEAD)], actor=APP))
        self.assertIn("docs commit ccccccc was not made",
                      reason([commit("a" * 40), docs("b" * 40), docs(HEAD, message="x")], actor=APP))
        self.assertIn("was not made", reason([commit("a" * 40), docs(HEAD, message=SKIP + " ")], actor=APP))

    def test_docs_commits_need_a_bot_other_than_dependabot(self):
        commits = [commit("a" * 40), docs(HEAD)]
        self.assertEqual("the run was started by dependabot[bot], not by the CI App's docs commit", reason(commits))
        self.assertEqual("the run was started by Dependabot[bot], not by the CI App's docs commit",
                         reason(commits, actor="Dependabot[bot]"))
        self.assertEqual("the run was started by an unknown actor, not by the CI App's docs commit",
                         reason(commits, actor=""))

    def test_without_docs_commits_the_actor_is_the_author(self):
        self.assertEqual("the run was started by an unknown actor, neither the author (dependabot[bot]) nor the CI "
                         "App's docs commit", reason(actor=""))
        self.assertEqual("the run was started by ci-app[bot], neither the author (dependabot[bot]) nor the CI App's "
                         "docs commit", reason(actor=APP))

    def test_dependabot_needs_the_admission_to_admit_the_run(self):
        refused = support.admission_facts([support.provider_dependency(published=support.NOW)], locks={})
        self.assertEqual("the Dependabot admission did not admit this run", reason(admission_facts=refused))
        doc = document()
        for admitted in ({"applies": False}, {**ADMITTED, "push_run": True}, {**ADMITTED, "admitted": False}):
            with self.subTest(admitted=admitted):
                self.assertEqual("the Dependabot admission did not admit this run",
                                 automerge.judge(doc, POLICY, admitted)["reason"])
        self.assertTrue(automerge.judge(doc, POLICY, ADMITTED)["eligible"])

    def test_another_bot_needs_no_admission(self):
        doc = document([release()], author=APP, head_ref=RELEASE_BRANCH, admission=False, actors=[APP])
        self.assertTrue(automerge.judge(doc, {"enabled": True, "actors": [APP]}, {"applies": False})["eligible"])


class ReleaseTest(unittest.TestCase):
    """Rule 6: another bot's pull request is a release."""

    def judged(self, commits, head_ref=RELEASE_BRANCH, actor=APP):
        return verdict(commits, author=APP, actor=actor, head_ref=head_ref, admission=False, actors=[APP])

    def test_another_branch(self):
        self.assertEqual("another bot's pull request merges only as a release, from release-please--branches--main; "
                         "this one is from feature/x", self.judged([release()], head_ref="feature/x")["reason"])

    def test_the_default_branch_names_the_release_branch(self):
        doc = document([release()], author=APP, head_ref="release-please--branches--trunk", admission=False,
                       actors=[APP])
        doc["caller"]["default_branch"] = "trunk"
        doc["event"]["base_ref"] = "trunk"
        self.assertTrue(decide.decide(doc)["automerge"]["eligible"])

    def test_another_file(self):
        self.assertEqual("release commit ccccccc changes versions.tf, not only CHANGELOG.md and "
                         ".release-please-manifest.json",
                         self.judged([release(files=[changed("CHANGELOG.md"), changed("versions.tf")])])["reason"])
        self.assertIn("changes README.md,", self.judged([release("a" * 40), release(files=[changed()])])["reason"])

    def test_files_that_were_not_listed(self):
        cut = release()
        cut["files_truncated"] = True
        self.assertEqual("release commit ccccccc changes files that were not listed, not only CHANGELOG.md and "
                         ".release-please-manifest.json", self.judged([cut])["reason"])
        unlisted = release()
        unlisted["files"] = None
        self.assertIn("changes files that were not listed", self.judged([unlisted])["reason"])

    def test_one_file_is_enough(self):
        self.assertTrue(self.judged([release(files=[changed("CHANGELOG.md")])])["eligible"])

    def test_dependabot_is_no_release(self):
        self.assertTrue(verdict(head_ref="anything")["eligible"])

    def test_a_trailing_docs_commit_is_not_judged_as_release(self):
        self.assertTrue(self.judged([release("a" * 40), docs(HEAD)], actor="other-app[bot]")["eligible"])
        # The App's own run commits the README with the plain message; only Dependabot's needs the admitted one.
        self.assertTrue(self.judged([release("a" * 40), docs(HEAD, message="terraform-docs: automated action")],
                                    actor="other-app[bot]")["eligible"])


class NoticeTest(unittest.TestCase):
    def notices(self, *args, **kwargs):
        output = decide.decide(document(*args, **kwargs))
        return [line for line in output["notices"] if line.startswith("auto-merge:")]

    def test_eligible(self):
        self.assertEqual(["auto-merge: eligible: dependabot[bot]'s pull request, 1 commit (1 the author's, 0 docs)"],
                         self.notices())
        self.assertEqual(["auto-merge: eligible: dependabot[bot]'s pull request, 3 commits (2 the author's, 1 docs)"],
                         self.notices([commit("a" * 40), commit("b" * 40), docs(HEAD)], actor=APP))

    def test_not_eligible(self):
        self.assertEqual(["auto-merge: not eligible: the run was started by octocat, neither the author "
                          "(dependabot[bot]) nor the CI App's docs commit"], self.notices(actor="octocat"))

    def test_none_when_it_does_not_apply(self):
        self.assertEqual([], self.notices(enabled=False, admission=False))
        self.assertIsNone(automerge.notice({"applies": False}))

    def test_after_the_admissions_and_the_tests(self):
        notices = decide.decide(document())["notices"]
        self.assertEqual(("admission: admitted (1 dependency)", "auto-merge: eligible"),
                         (notices[0], notices[-1][:len("auto-merge: eligible")]))


class SettingsTest(unittest.TestCase):
    def errors(self, actors, enabled=True, admission=True, ok=True):
        doc = document(enabled=enabled, admission=admission)
        doc["yaml"]["inputs"]["pr-auto-merge-from-actors-yml"] = support.parsed(actors, ok)
        return decide.decide(doc)["errors"]

    def test_invalid_yaml(self):
        self.assertEqual(["The specification for input 'pr-auto-merge-from-actors-yml' is not valid yaml!"],
                         self.errors(None, ok=False))

    def test_the_shape_as_in_the_project_workflow(self):
        self.assertEqual(['pr-auto-merge-from-actors-yml is {"a": 1}; it must be a list of logins.'],
                         self.errors({"a": 1}))
        self.assertEqual(["pr-auto-merge-from-actors-yml holds 7, which is not a login; quote it if it is one."],
                         self.errors([7], enabled=False))

    def test_a_person_is_refused_on_every_event(self):
        message = ("pr-auto-merge-from-actors-yml names octocat, which is not a bot; the module workflow merges bots' "
                   "pull requests only (their commits are signed by GitHub, a person's web edits are too).")
        self.assertEqual([message], self.errors(["octocat", DEPENDABOT]))
        self.assertEqual([message], self.errors(["octocat"], enabled=False))

    def test_nobody_named_with_the_switch_on(self):
        message = ("Auto-merge is switched on (pr-auto-merge-enabled), but pr-auto-merge-from-actors-yml names nobody, "
                   'so there is no one whose pull requests may merge without review. Name the accounts, for example '
                   '["dependabot[bot]"].')
        self.assertEqual([message], self.errors([]))
        self.assertEqual([message], self.errors(None))
        self.assertEqual([], self.errors([], enabled=False))
        doc = document(enabled=False, admission=False)
        del doc["yaml"]["inputs"]["pr-auto-merge-from-actors-yml"]
        self.assertEqual([], decide.decide(doc)["errors"])

    def test_dependabot_needs_the_admission(self):
        message = ("Auto-merge may merge Dependabot's pull requests (pr-auto-merge-from-actors-yml names "
                   "dependabot[bot]), but the Dependabot admission is off, so nothing judges them before they run. "
                   "Switch dependabot-admission-enabled on, or remove dependabot[bot] from the list.")
        self.assertEqual([message], self.errors(["Dependabot[bot]"], admission=False))
        doc = document(admission=False)
        del doc["workflow_inputs"]["dependabot-admission-enabled"]
        self.assertEqual([message], decide.decide(doc)["errors"])
        self.assertEqual([], self.errors([DEPENDABOT], enabled=False, admission=False))
        self.assertEqual([], self.errors([APP], admission=False))

    def test_every_mistake_at_once(self):
        self.assertEqual(2, len(self.errors(["octocat", DEPENDABOT], admission=False)))

    def test_the_switch_is_a_boolean(self):
        doc = document()
        doc["workflow_inputs"]["pr-auto-merge-enabled"] = 1
        self.assertEqual(["The input 'pr-auto-merge-enabled' is 1; it must be true or false!"],
                         decide.decide(doc)["errors"])
        for value, expected in ((True, True), ("true", True), (False, False), ("false", False)):
            with self.subTest(value=value):
                doc["workflow_inputs"]["pr-auto-merge-enabled"] = value
                self.assertEqual({"enabled": expected, "actors": [DEPENDABOT, APP]}, automerge.settings(doc))
        del doc["workflow_inputs"]["pr-auto-merge-enabled"]
        self.assertEqual(False, automerge.settings(doc)["enabled"])

    def test_the_actors_are_compared_without_case(self):
        doc = document(actors=["CI-App[bot]"])
        self.assertEqual(["ci-app[bot]"], automerge.settings(doc)["actors"])

    def test_a_settings_error_is_a_config_error(self):
        doc = document(actors=["octocat"])
        with self.assertRaises(ConfigError):
            automerge.settings(doc)


class ModelTest(unittest.TestCase):
    MESSAGE = ("input document: 'automerge' needs exactly 'available', 'reason', 'head_ref', 'count' and 'commits', "
               "shaped as docs/Module-auto-merge.md §4 describes")

    def test_the_facts_shape(self):
        model.check(document())
        model.check(document([commit(author=None, committer=None, files=None)]))
        model.check(document([docs(HEAD, [changed("README.md", "renamed", "x.md")])], actor=APP))
        bad = [
            lambda facts: facts.pop("reason"),
            lambda facts: facts.update(extra=1),
            lambda facts: facts.update(available="true"),
            lambda facts: facts.update(reason=1),
            lambda facts: facts.update(head_ref=None),
            lambda facts: facts.update(count=-1),
            lambda facts: facts.update(count=True),
            lambda facts: facts.update(commits={}),
            lambda facts: facts["commits"].append("abc"),
            lambda facts: facts["commits"][0].pop("verified"),
            lambda facts: facts["commits"][0].update(extra=1),
            lambda facts: facts["commits"][0].update(sha=1),
            lambda facts: facts["commits"][0].update(parents=-1),
            lambda facts: facts["commits"][0].update(parents=True),
            lambda facts: facts["commits"][0].update(author=1),
            lambda facts: facts["commits"][0].update(committer=1),
            lambda facts: facts["commits"][0].update(verified="yes"),
            lambda facts: facts["commits"][0].update(message=None),
            lambda facts: facts["commits"][0].update(files_truncated=None),
            lambda facts: facts["commits"][0].update(files="README.md"),
            lambda facts: facts["commits"][0]["files"].append("README.md"),
            lambda facts: facts["commits"][0]["files"].append({"name": "a", "status": "added"}),
            lambda facts: facts["commits"][0]["files"].append({"name": "a", "status": "added", "previous": None, "x": 1}),
            lambda facts: facts["commits"][0]["files"].append({"name": 1, "status": "added", "previous": None}),
            lambda facts: facts["commits"][0]["files"].append({"name": "a", "status": None, "previous": None}),
            lambda facts: facts["commits"][0]["files"].append({"name": "a", "status": "added", "previous": 1}),
        ]
        for index, spoil in enumerate(bad):
            with self.subTest(index=index):
                doc = document()
                spoil(doc["automerge"])
                with self.assertRaises(model.DocumentError) as raised:
                    model.check(doc)
                self.assertEqual(self.MESSAGE, str(raised.exception))

    def test_the_facts_are_not_a_mapping(self):
        doc = document()
        doc["automerge"] = []
        with self.assertRaises(model.DocumentError):
            model.check(doc)


def listed(sha=HEAD, author=DEPENDABOT, committer="web-flow", verified=True, parents=1,
           message="chore(deps): bump hashicorp/random from 3.6.0 to 3.9.1\n\nBumps the version.\n"):
    """A commit as the pull request's commit listing answers it."""
    return {"sha": sha, "parents": [{"sha": "p"}] * parents, "author": {"login": author} if author else None,
            "committer": {"login": committer} if committer else None,
            "commit": {"message": message, "verification": {"verified": verified, "reason": "valid"}}}


def files_answer(*names):
    return {"sha": HEAD, "files": [{"filename": name, "status": "modified"} for name in names]}


COMMITS = "repos/o/r/pulls/12/commits?per_page=100&page={}"
FILES = "repos/o/r/commits/{}?per_page=300&page={}"
PAYLOAD = {"pull_request": {"number": 12, "commits": 1, "head": {"ref": "dependabot/x", "sha": HEAD}}}


class GatherTest(unittest.TestCase):
    """The adapter's facts (docs/Module-auto-merge.md §4)."""

    def gather(self, api, payload=None, missing=()):
        tools = FakeTools(api=api, missing=missing)
        return automerge_facts.gather(tools, "o/r", PAYLOAD if payload is None else payload), tools

    def test_answered(self):
        facts, tools = self.gather({COMMITS.format(1): [listed()], FILES.format(HEAD, 1): files_answer("versions.tf")})
        self.assertEqual({"available": True, "reason": None, "head_ref": "dependabot/x", "count": 1,
                          "commits": [{"sha": HEAD, "parents": 1, "author": DEPENDABOT, "committer": "web-flow",
                                       "verified": True, "files_truncated": False,
                                       "message": "chore(deps): bump hashicorp/random from 3.6.0 to 3.9.1",
                                       "files": [{"name": "versions.tf", "status": "modified", "previous": None}]}]},
                         facts)
        self.assertEqual([COMMITS.format(1), FILES.format(HEAD, 1)], tools.endpoints())

    def test_a_rename_keeps_its_previous_name(self):
        answer = {"files": [{"filename": "README.md", "status": "renamed", "previous_filename": "main.tf"}]}
        facts, _ = self.gather({COMMITS.format(1): [listed()], FILES.format(HEAD, 1): answer})
        self.assertEqual([{"name": "README.md", "status": "renamed", "previous": "main.tf"}],
                         facts["commits"][0]["files"])

    def test_no_resolved_account(self):
        entry = listed(author=None, committer=None)
        facts, _ = self.gather({COMMITS.format(1): [entry], FILES.format(HEAD, 1): files_answer()})
        self.assertEqual((None, None), (facts["commits"][0]["author"], facts["commits"][0]["committer"]))
        entry = {**listed(), "author": {"login": 7}, "committer": {"id": 1}}
        facts, _ = self.gather({COMMITS.format(1): [entry], FILES.format(HEAD, 1): files_answer()})
        self.assertEqual((None, None), (facts["commits"][0]["author"], facts["commits"][0]["committer"]))

    def test_paginated(self):
        first = [listed(f"{index:040d}") for index in range(100)]
        api = {COMMITS.format(1): first, COMMITS.format(2): [listed(parents=2)]}
        api.update({FILES.format(entry["sha"], 1): files_answer("a.tf") for entry in first})
        api[FILES.format(HEAD, 1)] = files_answer(*[f"f{index}.tf" for index in range(300)])
        api[FILES.format(HEAD, 2)] = files_answer("last.tf")
        facts, tools = self.gather(api, payload={"pull_request": {**PAYLOAD["pull_request"], "commits": 101}})
        self.assertEqual((True, 101, 2, 301, False),
                         (facts["available"], len(facts["commits"]), facts["commits"][-1]["parents"],
                          len(facts["commits"][-1]["files"]), facts["commits"][-1]["files_truncated"]))
        self.assertEqual("last.tf", facts["commits"][-1]["files"][-1]["name"])
        self.assertEqual(103 + 1, len(tools.endpoints()))

    def test_capped_at_three_pages_of_commits(self):
        api = {COMMITS.format(page): [listed(f"{page}{index:039d}") for index in range(100)] for page in (1, 2, 3)}
        for page in (1, 2, 3):
            api.update({FILES.format(entry["sha"], 1): files_answer() for entry in api[COMMITS.format(page)]})
        api[COMMITS.format(4)] = [listed()]
        facts, tools = self.gather(api)
        self.assertEqual((True, 300), (facts["available"], len(facts["commits"])))
        self.assertNotIn(COMMITS.format(4), tools.endpoints())

    def test_capped_at_3000_files(self):
        api = {COMMITS.format(1): [listed()]}
        api.update({FILES.format(HEAD, page): files_answer(*[f"{page}-{index}" for index in range(300)])
                    for page in range(1, 12)})
        facts, tools = self.gather(api)
        self.assertEqual((3000, True), (len(facts["commits"][0]["files"]), facts["commits"][0]["files_truncated"]))
        self.assertNotIn(FILES.format(HEAD, 11), tools.endpoints())

    def unavailable(self, api, payload=None, missing=()):
        facts, _ = self.gather(api, payload, missing)
        self.assertEqual((False, "dependabot/x", 1, []),
                         (facts["available"], facts["head_ref"], facts["count"], facts["commits"]))
        return facts["reason"]

    def test_failing(self):
        self.assertEqual(f"gh api {COMMITS.format(1)} failed: gh: Not Found (HTTP 404) for {COMMITS.format(1)}",
                         self.unavailable({}))
        self.assertEqual(f"gh api {COMMITS.format(1)} failed: rate limited",
                         self.unavailable({COMMITS.format(1): (1, "rate limited\n", "")}))
        self.assertEqual("'gh' cannot be run on this runner: [Errno 2] No such file or directory: 'gh'",
                         self.unavailable({}, missing=("gh",)))
        self.assertEqual(f"gh api {COMMITS.format(1)} did not answer with JSON",
                         self.unavailable({COMMITS.format(1): (0, "<html>", "")}))
        self.assertEqual(f"gh api {FILES.format(HEAD, 1)} failed: gh: Not Found (HTTP 404) for "
                         f"{FILES.format(HEAD, 1)}", self.unavailable({COMMITS.format(1): [listed()]}))

    def test_an_error_is_capped(self):
        reason = self.unavailable({COMMITS.format(1): (1, "", "x" * 400)})
        self.assertEqual(f"gh api {COMMITS.format(1)} failed: " + "x" * 300, reason)

    def test_an_answer_of_the_wrong_shape(self):
        listing = f"gh api {COMMITS.format(1)}"
        self.assertEqual(f"{listing} answered without a list of commits",
                         self.unavailable({COMMITS.format(1): {"message": "x"}}))
        for spoil in ({"sha": 1}, {"parents": {}}, {"commit": None}, {"commit": {"message": "m", "verification": None}},
                      {"commit": {"message": "m", "verification": {"verified": "true"}}},
                      {"commit": {"message": None, "verification": {"verified": True}}}):
            with self.subTest(spoil=spoil):
                self.assertEqual(f"{listing} answered a commit without its SHA, parents, message or verification",
                                 self.unavailable({COMMITS.format(1): [{**listed(), **spoil}]}))
        self.assertEqual(f"{listing} answered a commit without its SHA, parents, message or verification",
                         self.unavailable({COMMITS.format(1): ["abc"]}))
        files = f"gh api {FILES.format(HEAD, 1)}"
        for answer in ([], {"files": None}):
            with self.subTest(answer=answer):
                self.assertEqual(f"{files} answered without a list of files",
                                 self.unavailable({COMMITS.format(1): [listed()], FILES.format(HEAD, 1): answer}))
        for entry in ("README.md", {"status": "modified"}, {"filename": "a", "status": 1},
                      {"filename": "a", "status": "renamed", "previous_filename": None}):
            with self.subTest(entry=entry):
                self.assertEqual(f"{files} answered a file without its name and status",
                                 self.unavailable({COMMITS.format(1): [listed()],
                                                   FILES.format(HEAD, 1): {"files": [entry]}}))

    def test_a_payload_without_the_head_branch_or_count(self):
        missing = {"available": False, "reason": "the event names no head branch and commit count", "head_ref": "",
                   "count": 0, "commits": []}
        for payload in ([], {}, {"pull_request": []}, {"pull_request": {"commits": 1}},
                        {"pull_request": {"commits": 1, "head": []}}, {"pull_request": {"commits": 1, "head": {}}},
                        {"pull_request": {"commits": 1, "head": {"ref": 1}}},
                        {"pull_request": {"head": {"ref": "x"}}},
                        {"pull_request": {"commits": True, "head": {"ref": "x"}}},
                        {"pull_request": {"commits": "1", "head": {"ref": "x"}}},
                        {"pull_request": {"commits": -1, "head": {"ref": "x"}}}):
            with self.subTest(payload=payload):
                facts, tools = self.gather({}, payload=payload)
                self.assertEqual((missing, []), (facts, tools.endpoints()))
        facts, _ = self.gather({COMMITS.format(1): []},
                               payload={"pull_request": {"number": 12, "commits": 0, "head": {"ref": "x"}}})
        self.assertEqual((True, 0), (facts["available"], facts["count"]))


MERGE_INPUTS = {**test_module.MODULE_RUNNER_INPUTS, "pr-auto-merge-enabled": True,
                "pr-auto-merge-from-actors-yml": json.dumps([APP])}
PULL_PAYLOAD = {"action": "synchronize", "number": 12, "repository": {"default_branch": "main"},
                "pull_request": {"number": 12, "commits": 1, "user": {"login": APP},
                                 "head": {"sha": HEAD, "ref": RELEASE_BRANCH, "repo": {"fork": False}}}}
GIT = {("*.tftest.hcl", "*.tftest.json"): (0, "tests/unit-tests.tftest.hcl\0", ""),
       ("*.tf", "*.tf.json"): (0, "main.tf\0", "")}


class AdapterTest(unittest.TestCase):
    def run_module(self, inputs=MERGE_INPUTS, payload=PULL_PAYLOAD, actor=APP, api=None):
        runner = Runner(self, inputs=inputs, payload=payload,
                        environ={"GITHUB_EVENT_NAME": "pull_request", "GITHUB_ACTOR": actor,
                                 "GITHUB_BASE_REF": "main", "GITHUB_REF_NAME": "12/merge"})
        tools = FakeTools(git=GIT, api={COMMITS.format(1): [listed(author=APP)],
                                        FILES.format(HEAD, 1): files_answer("CHANGELOG.md")} if api is None else api)
        code = adapter.run(runner.inputs_file, runner.environ, runner.log, tools, lambda path: True, True)
        self.assertEqual(0, code, runner.log.getvalue())
        return runner, tools

    def test_an_eligible_release_publishes_it(self):
        runner, tools = self.run_module()
        outputs = runner.outputs()
        self.assertEqual(("true", "false"), (outputs["automerge-eligible"], outputs["automerge-confirm-app"]))
        self.assertEqual([COMMITS.format(1), FILES.format(HEAD, 1)], tools.endpoints())
        with open(outputs["relevance-file"], encoding="utf-8") as handle:
            self.assertTrue(json.load(handle)["automerge"]["eligible"])
        self.assertIn("auto-merge: eligible: ci-app[bot]'s pull request, 1 commit (1 the author's, 0 docs)",
                      runner.log.getvalue())

    def test_the_docs_commits_run_asks_for_the_app(self):
        api = {COMMITS.format(1): [listed("a" * 40, author=APP), listed(author="github-actions[bot]",
                                                                        committer="github-actions[bot]",
                                                                        verified=False,
                                                                        message="terraform-docs: automated action")],
               FILES.format("a" * 40, 1): files_answer("CHANGELOG.md"), FILES.format(HEAD, 1): files_answer("README.md")}
        payload = {**PULL_PAYLOAD, "pull_request": {**PULL_PAYLOAD["pull_request"], "commits": 2}}
        runner, _ = self.run_module(payload=payload, actor="other-app[bot]", api=api)
        self.assertEqual(("true", "true"),
                         (runner.outputs()["automerge-eligible"], runner.outputs()["automerge-confirm-app"]))

    def test_an_unlisted_author_costs_no_call(self):
        payload = {**PULL_PAYLOAD, "pull_request": {**PULL_PAYLOAD["pull_request"], "user": {"login": "octocat"}}}
        runner, tools = self.run_module(payload=payload, actor="octocat")
        self.assertEqual(("false", "false"),
                         (runner.outputs()["automerge-eligible"], runner.outputs()["automerge-confirm-app"]))
        self.assertEqual([], tools.endpoints())

    def test_switched_off_or_invalid_costs_no_call(self):
        runner, tools = self.run_module(inputs={**MERGE_INPUTS, "pr-auto-merge-enabled": False})
        self.assertEqual(("false", []), (runner.outputs()["automerge-eligible"], tools.endpoints()))
        invalid = Runner(self, inputs={**MERGE_INPUTS, "pr-auto-merge-from-actors-yml": '["octocat"]'},
                         payload=PULL_PAYLOAD, environ={"GITHUB_EVENT_NAME": "pull_request", "GITHUB_ACTOR": APP,
                                                        "GITHUB_BASE_REF": "main"})
        tools = FakeTools(git=GIT)
        self.assertEqual(2, adapter.run(invalid.inputs_file, invalid.environ, invalid.log, tools, lambda path: True,
                                        True))
        self.assertEqual([], tools.endpoints())

    def test_an_invalid_setting_gathers_nothing(self):
        self.assertIs(False, adapter._automerge_applies(document(actors=["octocat"])))
        self.assertIs(True, adapter._automerge_applies(document()))

    def test_a_failed_listing_is_a_notice_not_a_failure(self):
        runner, _ = self.run_module(api={})
        self.assertEqual("false", runner.outputs()["automerge-eligible"])
        self.assertIn("auto-merge: not eligible: its commits could not be listed (gh api "
                      f"{COMMITS.format(1)} failed", runner.log.getvalue())

    def test_the_project_workflow_gathers_nothing(self):
        doc = support.document(inputs={"pr-auto-merge-enabled": True})
        self.assertNotIn("automerge", doc)
        runner = Runner(self)
        runner.run()
        self.assertNotIn("automerge-eligible", runner.outputs())


if __name__ == "__main__":
    unittest.main()
