"""The input document's shape: a malformed document is the shim's fault and says where."""

import unittest

import support
from dsb_tf_engine import decide, model


class ModelTest(unittest.TestCase):
    def assertDocumentError(self, document, fragment):
        with self.assertRaises(model.DocumentError) as raised:
            decide.decide(document)
        self.assertIn(fragment, str(raised.exception))

    def test_a_valid_document_passes(self):
        model.check(support.document())

    def test_not_an_object(self):
        self.assertDocumentError([], "not a JSON object")

    def test_unknown_top_level_keys_are_rejected(self):
        document = support.document()
        document["secrets"] = {"TOKEN": "x"}
        self.assertDocumentError(document, "unknown key(s) ['secrets']")

    def test_missing_top_level_keys_are_named(self):
        document = support.document()
        del document["caller"], document["event"]
        self.assertDocumentError(document, "missing key(s) ['caller', 'event']")

    def test_schema_version_must_match(self):
        document = support.document()
        document["schema_version"] = 2
        self.assertDocumentError(document, "schema_version 2, expected 1")

    def test_caller_and_event_need_their_strings(self):
        for section, value in [("caller", {"repository": "o/r"}), ("caller", "o/r"),
                               ("event", {"name": "push", "ref_name": 1, "ref_type": "branch"}),
                               ("event", {"name": "push", "ref_name": "main"}),
                               ("event", {"name": "push", "ref_name": "main", "ref_type": "branches"}), ("event", None)]:
            with self.subTest(section=section, value=value):
                document = support.document()
                document[section] = value
                self.assertDocumentError(document, f"'{section}' needs the strings")

    def test_workflow_inputs_must_be_an_object(self):
        document = support.document()
        document["workflow_inputs"] = []
        self.assertDocumentError(document, "'workflow_inputs' is not an object")

    def test_yaml_needs_exactly_inputs_and_environments(self):
        document = support.document()
        document["yaml"]["extra"] = {}
        self.assertDocumentError(document, "'yaml' needs exactly")
        document["yaml"] = []
        self.assertDocumentError(document, "'yaml' needs exactly")

    def test_parse_results_must_be_ok_and_value(self):
        for bad in [{"x-yml": {"ok": True}}, {"x-yml": {"ok": "yes", "value": 1}}, {"x-yml": []}, []]:
            with self.subTest(bad=bad):
                document = support.document()
                document["yaml"]["inputs"] = bad
                self.assertDocumentError(document, "'yaml.inputs' is not a map of parse results")

    def test_environment_parse_results_must_be_a_list_of_maps(self):
        for bad in [{}, [{"x-yml": {"ok": True}}]]:
            with self.subTest(bad=bad):
                document = support.document()
                document["yaml"]["environments"] = bad
                self.assertDocumentError(document, "'yaml.environments' is not a list of maps")

    def test_directories_must_map_to_booleans(self):
        for bad in [[], {"./envs/env-a": "yes"}]:
            with self.subTest(bad=bad):
                document = support.document()
                document["directories_exist"] = bad
                self.assertDocumentError(document, "'directories_exist' is not a map of booleans")


MESSAGE = ("input document: 'changed_files' needs exactly 'available', 'truncated', 'error', 'api_head_sha', 'count' "
           "and 'files', typed as the adapter reports them")
CHANGED = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": 1, "files": ["a"]}


class RelevanceFactsTest(unittest.TestCase):
    """The optional sections the changed-file fetching adds: absent is fine, present must be whole."""

    assertDocumentError = ModelTest.assertDocumentError

    def test_the_sections_are_optional_and_pass_when_whole(self):
        document = support.document()
        document["event"]["push"] = {"created": True, "forced": False, "deleted": False}
        document["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": False}
        document["event"]["action"] = "opened"
        document["run"] = {"id": 4711, "attempt": 1}
        document["changed_files"] = dict(CHANGED)
        model.check(document)
        model.check(support.document())

    def test_changed_files_needs_every_fact_with_its_type(self):
        for key, bad in (("available", "yes"), ("truncated", None), ("error", 5), ("api_head_sha", 1),
                         ("count", "3"), ("count", True), ("count", -1), ("files", "a"), ("files", [1])):
            with self.subTest(key=key, bad=bad):
                document = support.document()
                document["changed_files"] = {**CHANGED, key: bad}
                self.assertDocumentError(document, MESSAGE)
        for missing in CHANGED:
            with self.subTest(missing=missing):
                document = support.document()
                document["changed_files"] = {k: v for k, v in CHANGED.items() if k != missing}
                self.assertDocumentError(document, MESSAGE)
        document = support.document()
        document["changed_files"] = []
        self.assertDocumentError(document, MESSAGE)

    def test_the_facts_may_be_unknown(self):
        document = support.document()
        document["changed_files"] = {**CHANGED, "error": "HTTP 502", "api_head_sha": None, "count": 0}
        model.check(document)

    def test_the_push_facts_are_booleans(self):
        for bad in ({"created": "true", "forced": False, "deleted": False}, {"created": False, "forced": False},
                    {"created": False, "forced": None, "deleted": False}, []):
            with self.subTest(bad=bad):
                document = support.document()
                document["event"]["push"] = bad
                self.assertDocumentError(document, "'event.push' needs the booleans 'created', 'forced' and 'deleted'")

    def test_the_pull_request_needs_its_number_and_head(self):
        for bad in ({"number": "87", "head_sha": "abc", "is_fork": False}, {"number": 87, "is_fork": False},
                    {"number": True, "head_sha": "a", "is_fork": False}, {"number": 87, "head_sha": None, "is_fork": False},
                    {"number": 87, "head_sha": "a"}, {"number": 87, "head_sha": "a", "is_fork": "false"}, None):
            with self.subTest(bad=bad):
                document = support.document()
                document["event"]["pull_request"] = bad
                self.assertDocumentError(document, "input document: 'event.pull_request' needs the integer 'number', "
                                                   "the string 'head_sha' and the boolean 'is_fork'")

    def test_the_action_is_a_string(self):
        document = support.document()
        document["event"]["action"] = None
        self.assertDocumentError(document, "input document: 'event.action' is not a string")

    def test_the_run_needs_its_id_and_attempt(self):
        for bad in ({"id": 1}, {"attempt": 1}, {"id": "1", "attempt": 1}, {"id": 1, "attempt": True},
                    {"id": 1, "attempt": -1}, []):
            with self.subTest(bad=bad):
                document = support.document()
                document["run"] = bad
                self.assertDocumentError(document, "input document: 'run' needs the integers 'id' and 'attempt'")


TESTS = {"files": ["tests/a.tftest.hcl"], "directories_with_tf": ["main"], "environment_locks": {"envs/a": {"p": "1"}, "envs/b": None}}
TESTS_MESSAGE = ("input document: 'tests' needs exactly 'files' and 'directories_with_tf' (lists of strings) and "
                 "'environment_locks' (a map of lock maps or null)")


class TestFactsTest(unittest.TestCase):
    """The test stage's facts, the actor and the workflow name: absent is fine, present must be whole."""

    assertDocumentError = ModelTest.assertDocumentError

    def test_whole_facts_pass(self):
        document = support.document()
        document["tests"] = dict(TESTS)
        document["event"]["actor"] = "octocat"
        document["caller"]["workflow_name"] = "CI"
        model.check(document)

    def test_the_tests_facts_need_every_part_with_its_type(self):
        for bad in ({**TESTS, "files": "a"}, {**TESTS, "files": [1]}, {**TESTS, "directories_with_tf": None},
                    {**TESTS, "directories_with_tf": [5]}, {**TESTS, "environment_locks": []},
                    {**TESTS, "environment_locks": {"envs/a": "1"}}, {**TESTS, "environment_locks": {"envs/a": {"p": 1}}},
                    {"files": [], "directories_with_tf": []}, {**TESTS, "extra": 1}, []):
            with self.subTest(bad=bad):
                document = support.document()
                document["tests"] = bad
                self.assertDocumentError(document, TESTS_MESSAGE)

    def test_the_actor_and_the_workflow_name_are_strings(self):
        for section, key, message in (("event", "actor", "input document: 'event.actor' is not a string"),
                                      ("event", "triggering_actor",
                                       "input document: 'event.triggering_actor' is not a string"),
                                      ("event", "base_ref", "input document: 'event.base_ref' is not a string"),
                                      ("caller", "workflow_name", "input document: 'caller.workflow_name' is not a string")):
            with self.subTest(key=key):
                document = support.document()
                document[section][key] = None
                self.assertDocumentError(document, message)


class DispatchShapeTest(unittest.TestCase):
    MESSAGE = ("input document: 'event.dispatch' needs exactly the boolean 'block', the strings 'environment', "
               "'goal' and 'reason', and the list of strings 'inputs'")

    def test_the_dispatch_inputs_have_their_shape(self):
        good = {"block": True, "environment": "", "goal": "", "reason": "", "inputs": []}
        for bad in (None, [], {}, {**good, "block": "true"}, {**good, "goal": None}, {**good, "environment": 1},
                    {**good, "reason": False}, {**good, "extra": ""}, {**good, "inputs": None},
                    {**good, "inputs": [1]},
                    {key: value for key, value in good.items() if key != "reason"}):
            with self.subTest(bad=bad):
                document = support.document()
                document["event"]["dispatch"] = bad
                with self.assertRaises(model.DocumentError) as raised:
                    model.check(document)
                self.assertEqual(self.MESSAGE, str(raised.exception))
        document = support.document()
        document["event"]["dispatch"] = good
        model.check(document)


ADMISSION_MESSAGE = ("input document: 'admission' needs exactly 'now', 'files', 'dependencies' and 'locks', shaped as "
                     "docs/Dependabot-admission.md §8 describes")
TF_FILE = {"path": "a.tf", "status": "modified", "kind": "tf", "lines": [{"old": "a", "new": None}], "unmapped": []}
LOCK = {"registry.terraform.io/hashicorp/azurerm": {"version": "4.42.0", "constraints": None, "hashes": ["zh:aa"]}}
LOCK_FILE = {"path": "l", "status": "modified", "kind": "lock", "before": LOCK, "after": None}
OTHER_FILE = {"path": "x", "status": "added", "kind": "other"}


class AdmissionFactsTest(unittest.TestCase):
    """docs/Dependabot-admission.md §8: absent is fine, present must be whole."""

    assertDocumentError = ModelTest.assertDocumentError

    def facts(self, **overrides):
        document = support.dependabot_pull_request(support.document())
        document["admission"].update(overrides)
        return document

    def test_whole_facts_pass(self):
        model.check(self.facts(files=[TF_FILE, LOCK_FILE, OTHER_FILE],
                               dependencies=[support.provider_dependency(), support.module_dependency(),
                                             support.provider_dependency(published=None)]))

    def test_the_sections(self):
        for bad in ([], {"now": 1, "files": [], "dependencies": []},
                    {"now": 1, "files": [], "dependencies": [], "locks": {}, "x": 1}):
            with self.subTest(bad=bad):
                document = support.dependabot_pull_request(support.document())
                document["admission"] = bad
                self.assertDocumentError(document, ADMISSION_MESSAGE)
        for key, bad in (("now", -1), ("now", True), ("now", "1"), ("files", {}), ("dependencies", {}),
                         ("locks", []), ("locks", {"a": "yes"})):
            with self.subTest(key=key, bad=bad):
                self.assertDocumentError(self.facts(**{key: bad}), ADMISSION_MESSAGE)

    def test_the_files(self):
        bad_files = [
            "x", {**OTHER_FILE, "path": 5}, {**OTHER_FILE, "status": "moved"}, {**OTHER_FILE, "kind": 5},
            {**OTHER_FILE, "lines": []},
            {**TF_FILE, "lines": "a"}, {**TF_FILE, "lines": ["a"]}, {**TF_FILE, "lines": [{"old": "a"}]},
            {**TF_FILE, "lines": [{"old": 5, "new": "b"}]}, {**TF_FILE, "lines": [{"old": "a", "new": 5}]},
            {"path": "a.tf", "status": "modified", "kind": "tf"}, {**TF_FILE, "before": None},
            {**TF_FILE, "unmapped": "x"}, {**TF_FILE, "unmapped": [1]},
            {key: value for key, value in TF_FILE.items() if key != "unmapped"},
            {**LOCK_FILE, "before": []}, {**LOCK_FILE, "after": {"a": "x"}},
            {**LOCK_FILE, "after": {"a": {"version": "1", "constraints": None}}},
            {**LOCK_FILE, "after": {"a": {"version": 1, "constraints": None, "hashes": []}}},
            {**LOCK_FILE, "after": {"a": {"version": "1", "constraints": 1, "hashes": []}}},
            {**LOCK_FILE, "after": {"a": {"version": "1", "constraints": None, "hashes": [1]}}},
            {"path": "l", "status": "modified", "kind": "lock", "before": None},
        ]
        for bad in bad_files:
            with self.subTest(bad=bad):
                self.assertDocumentError(self.facts(files=[bad]), ADMISSION_MESSAGE)
        model.check(self.facts(files=[{**LOCK_FILE, "after": {"a": {"version": "1", "constraints": "1", "hashes": []}}},
                                      {**TF_FILE, "lines": [], "unmapped": ["x"]}]
                               + [{**OTHER_FILE, "status": status} for status in ("modified", "added", "removed",
                                                                                   "renamed", "changed")]))

    def test_the_dependencies(self):
        provider, module = support.provider_dependency(), support.module_dependency()
        bad_dependencies = [
            "x", {**provider, "kind": "thing"}, {**provider, "address": 5}, {**provider, "from": None},
            {**provider, "to": 1}, {**provider, "files": "a"}, {**provider, "files": [1]}, {**provider, "facts": []},
            {**provider, "locked": "yes"}, {**provider, "extra": 1},
            {**provider, "facts": {**provider["facts"], "published": -1}},
            {**provider, "facts": {**provider["facts"], "published": "x"}},
            {**provider, "facts": {**provider["facts"], "vouched": "yes"}},
            {**provider, "facts": {**provider["facts"], "keys_to": "A"}},
            {**provider, "facts": {**provider["facts"], "zh": [1]}},
            {**provider, "facts": {**provider["facts"], "shasums": None}},
            {**provider, "facts": {**provider["facts"], "keys_from": [None]}},
            {**provider, "facts": {**provider["facts"], "class_to": None}},
            {**provider, "facts": {**provider["facts"], "class_from": 1}},
            {**provider, "facts": {key: value for key, value in provider["facts"].items() if key != "zh"}},
            {key: value for key, value in provider.items() if key != "locked"},
            {**module, "locked": True}, {**module, "source_kind": 5}, {**module, "namespace": None},
            {**module, "name": 1}, {**module, "facts": {"published": "x"}}, {**module, "facts": {}},
            {**module, "facts": {"published": 1, "x": 2}},
        ]
        for bad in bad_dependencies:
            with self.subTest(bad=bad):
                self.assertDocumentError(self.facts(dependencies=[bad]), ADMISSION_MESSAGE)
        model.check(self.facts(dependencies=[{**module, "facts": {"published": None}}]))

    def test_the_pull_request_s_author_is_a_string(self):
        document = support.dependabot_pull_request(support.document())
        model.check(document)
        document["event"]["pull_request"]["author"] = None
        self.assertDocumentError(document, "input document: 'event.pull_request.author' is not a string")


if __name__ == "__main__":
    unittest.main()
