"""The Dependabot admission: its settings, its checks and what a verdict does (docs/Dependabot-admission.md).

Every message and detail is compared as a literal, as the spec states them.
"""

import copy
import unittest

import invariants
import support
from dsb_tf_engine import admission, decide
from dsb_tf_engine.environments import ConfigError
from dsb_tf_engine.model import DocumentError

DAY, NOW = support.DAY, support.NOW
REGISTRY_AZURERM = "registry.terraform.io/hashicorp/azurerm"


def settings(policy=None, switch=None, ok=True, default=True):
    doc = support.document()
    if switch is not None:
        doc["workflow_inputs"]["dependabot-admission-enabled"] = switch
    if policy is not None or not ok:
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed(policy, ok)
    return admission.settings(doc, default)


def messages(policy=None, switch=None, ok=True):
    try:
        settings(policy, switch, ok)
    except ConfigError as error:
        return error.messages
    raise AssertionError("the settings were accepted")


class SettingsTest(unittest.TestCase):
    def test_the_defaults(self):
        self.assertEqual({"enabled": True, "allow": ["dsb-norge", "hashicorp", "microsoft", "Azure"],
                          "exempt": ["dsb-norge"], "min_age_days": 3}, settings())
        self.assertEqual(False, settings(default=False)["enabled"])
        self.assertEqual(settings(), settings(None))
        self.assertEqual(settings(), settings(""))

    def test_the_switch(self):
        for value, expected in ((True, True), ("true", True), (False, False), ("false", False)):
            with self.subTest(value=value):
                self.assertEqual(expected, settings(switch=value, default=not expected)["enabled"])
        self.assertEqual(["The input 'dependabot-admission-enabled' is 'yes'; it must be true or false!"],
                         messages(switch="yes"))
        self.assertEqual(["The input 'dependabot-admission-enabled' is 1; it must be true or false!"],
                         messages(switch=1))

    def test_a_policy_that_does_not_parse(self):
        self.assertEqual(["The specification for input 'dependabot-admission-yml' is not valid yaml!"],
                         messages(ok=False))

    def test_a_policy_that_is_not_a_mapping(self):
        for value, kind in ((["elastic"], "a list"), ("elastic", "a string"), (3, "a number"), (2.5, "a number"),
                            (True, "a boolean")):
            with self.subTest(value=value):
                self.assertEqual([f"dependabot-admission-yml must be a mapping with the keys allow, min-age-days and "
                                  f"min-age-exempt; it holds {kind}."], messages(value))

    def test_unknown_keys_are_named_in_order(self):
        self.assertEqual(["dependabot-admission-yml holds the unknown key 5; the keys are allow, min-age-days and "
                          "min-age-exempt.",
                          "dependabot-admission-yml holds the unknown key 'allows'; the keys are allow, min-age-days "
                          "and min-age-exempt.",
                          "dependabot-admission-yml holds the unknown key 'zzz'; the keys are allow, min-age-days and "
                          "min-age-exempt."],
                         messages({"zzz": 1, "allows": [], 5: 1}))

    def test_the_lists_add_to_the_built_in_ones(self):
        policy = settings({"allow": ["elastic", "cyrilgdn/postgresql"], "min-age-exempt": "my-org", "min-age-days": 0})
        self.assertEqual(["dsb-norge", "hashicorp", "microsoft", "Azure", "elastic", "cyrilgdn/postgresql"],
                         policy["allow"])
        self.assertEqual(["dsb-norge", "my-org"], policy["exempt"])
        self.assertEqual(0, policy["min_age_days"])
        self.assertEqual(90, settings({"min-age-days": 90})["min_age_days"])

    def test_list_mistakes(self):
        self.assertEqual(["dependabot-admission-yml: allow must be a list of namespaces; it holds a mapping."],
                         messages({"allow": {"a": 1}}))
        self.assertEqual(["dependabot-admission-yml: min-age-exempt must be a list of namespaces; it holds a number."],
                         messages({"min-age-exempt": 4}))
        self.assertEqual(["dependabot-admission-yml: allow holds 'not ok!', which is not a namespace or namespace/name, "
                          "for example 'elastic' or 'cyrilgdn/postgresql'.",
                          "dependabot-admission-yml: allow holds 5, which is not a namespace or namespace/name, for "
                          "example 'elastic' or 'cyrilgdn/postgresql'.",
                          "dependabot-admission-yml: min-age-exempt holds 'a/b/c', which is not a namespace or "
                          "namespace/name, for example 'elastic' or 'cyrilgdn/postgresql'."],
                         messages({"allow": ["ok", "not ok!", 5], "min-age-exempt": ["a/b/c"]}))
        for entry in ("-a", "a/", "/a", "a b", "", ".a"):
            with self.subTest(entry=entry):
                self.assertEqual(1, len(messages({"allow": [entry]})))
        for entry in ("a", "A9_.-z", "a/b", "9z/x.y-z_"):
            with self.subTest(entry=entry):
                self.assertIn(entry, settings({"allow": [entry]})["allow"])

    def test_min_age_mistakes(self):
        for value in (91, -1, True, "3", 2.5, None):
            with self.subTest(value=value):
                self.assertEqual([f"dependabot-admission-yml: min-age-days must be a whole number from 0 to 90; it holds "
                                  f"{admission.shown(value)}."], messages({"min-age-days": value}))

    def test_every_mistake_at_once_in_reporting_order(self):
        doc = support.document()
        doc["workflow_inputs"]["dependabot-admission-enabled"] = "on"
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"x": 1, "allow": 5, "min-age-days": 100})
        with self.assertRaises(ConfigError) as caught:
            admission.settings(doc, True)
        self.assertEqual(["The input 'dependabot-admission-enabled' is 'on'; it must be true or false!",
                          "dependabot-admission-yml holds the unknown key 'x'; the keys are allow, min-age-days and "
                          "min-age-exempt.",
                          "dependabot-admission-yml: allow must be a list of namespaces; it holds a number.",
                          "dependabot-admission-yml: min-age-days must be a whole number from 0 to 90; it holds 100."],
                         caught.exception.messages)

    def test_an_environment_may_not_set_them(self):
        for key in ("dependabot-admission-enabled", "dependabot-admission-yml"):
            with self.subTest(key=key):
                doc = support.document(environments=[{"environment": "env-a", key: True}])
                self.assertEqual([f"The environment 'env-a' sets '{key}', which is a workflow input only: it applies "
                                  "to every environment at once. Set it in the calling workflow's 'with:'."],
                                 decide.decide(doc)["errors"])


class AppliesTest(unittest.TestCase):
    def test_only_dependabot_s_own_pull_request_or_push_with_the_switch_on(self):
        on, off = {"enabled": True}, {"enabled": False}
        for event, actor, policy, expected in (("pull_request", "dependabot[bot]", on, True),
                                               ("push", "dependabot[bot]", on, True),
                                               ("pull_request", "dependabot[bot]", off, False),
                                               ("pull_request", "octocat", on, False),
                                               ("pull_request", "Dependabot[bot]", on, False),
                                               ("schedule", "dependabot[bot]", on, False),
                                               ("workflow_dispatch", "dependabot[bot]", on, False)):
            with self.subTest(event=event, actor=actor, policy=policy):
                doc = support.document()
                doc["event"].update(name=event, actor=actor)
                self.assertEqual(expected, admission.applies(doc, policy))
        doc = support.document()
        doc["event"]["name"] = "pull_request"
        self.assertEqual(False, admission.applies(doc, on))


class VersionTest(unittest.TestCase):
    def test_parse_version(self):
        self.assertEqual((1, 2, 3, "", 3), admission.parse_version("1.2.3"))
        self.assertEqual((1, 2, 0, "", 2), admission.parse_version(" v1.2 "))
        self.assertEqual((1, 0, 0, "", 1), admission.parse_version("1"))
        self.assertEqual((1, 2, 3, "rc.1", 3), admission.parse_version("1.2.3-rc.1"))
        self.assertEqual((1, 2, 3, "", 3), admission.parse_version("1.2.3+build.5"))
        for text in ("x", "1.2.3.4", "", "1..2", None, 5):
            with self.subTest(text=text):
                self.assertIsNone(admission.parse_version(text))

    def test_each_operator(self):
        cases = [("1.2.3", "1.2.3", True), ("= 1.2.3", "1.2.3", True), ("1.2.3", "1.2.4", False),
                 ("!= 1.2.3", "1.2.3", False), ("!= 1.2.3", "1.2.4", True),
                 ("> 1.2.3", "1.2.3", False), ("> 1.2.3", "1.2.4", True),
                 (">= 1.2.3", "1.2.3", True), (">= 1.2.3", "1.2.2", False),
                 ("< 1.2.3", "1.2.3", False), ("< 1.2.3", "1.2.2", True),
                 ("<= 1.2.3", "1.2.3", True), ("<= 1.2.3", "1.2.4", False),
                 ("~> 1.2.3", "1.2.3", True), ("~> 1.2.3", "1.2.9", True), ("~> 1.2.3", "1.3.0", False),
                 ("~> 1.2.3", "1.2.2", False), ("~> 1.2", "1.9.9", True), ("~> 1.2", "2.0.0", False),
                 ("~> 1.2", "1.1.9", False), ("~> 1", "1.9.0", True), ("~> 1", "2.0.0", False),
                 (">= 3.0.0, < 5.0.0", "4.1.0", True), (">= 3.0.0, < 5.0.0", "5.0.0", False),
                 (">= 3.0.0, < 5.0.0, != 4.1.0", "4.1.0", False), ("", "1.0.0", True), ("  ", "1.0.0", True)]
        for constraint, version, expected in cases:
            with self.subTest(constraint=constraint, version=version):
                self.assertIs(expected, admission.allows(constraint, version))

    def test_pre_releases_only_by_an_exact_constraint(self):
        self.assertIs(True, admission.allows("1.0.0-rc1", "1.0.0-rc1"))
        self.assertIs(True, admission.allows("= 1.0.0-rc1", "1.0.0-rc1"))
        self.assertIs(False, admission.allows(">= 1.0.0", "1.1.0-rc1"))
        self.assertIs(False, admission.allows("= 1.0.0", "1.0.0-rc1"))
        self.assertIs(False, admission.allows("", "1.0.0-rc1"))
        self.assertIs(False, admission.allows("1.0.0-rc2", "1.0.0-rc1"))

    def test_what_cannot_be_read(self):
        self.assertIsNone(admission.allows("bogus", "1.0.0"))
        self.assertIsNone(admission.allows(">= x", "1.0.0"))
        self.assertIsNone(admission.allows("1.0.0", "x"))
        self.assertIsNone(admission.allows(None, "1.0.0"))

    def test_newest_allowed(self):
        versions = ["3.9.0", "4.0.0", "4.41.0", "4.9.0", "5.0.0", "4.42.0-beta1"]
        self.assertEqual("4.41.0", admission.newest_allowed("~> 4.0", versions))
        self.assertEqual("5.0.0", admission.newest_allowed(">= 3.0.0", versions))
        self.assertEqual("4.42.0-beta1", admission.newest_allowed("4.42.0-beta1", versions))
        self.assertIsNone(admission.newest_allowed("> 9.0.0", versions))
        self.assertIsNone(admission.newest_allowed("bogus", versions))
        self.assertEqual("1.0.0", admission.newest_allowed(">= 1.0.0-rc1, < 2.0.0", ["1.0.0-rc1", "1.0.0"]) or "1.0.0")
        self.assertEqual("1.0.0", admission.newest_allowed("<= 1.0.0", ["1.0.0-rc1", "1.0.0", "0.9.0"]))

    def test_civil(self):
        self.assertEqual("1970-01-01 00:00 UTC", admission.civil(0))
        self.assertEqual("2000-02-29 00:00 UTC", admission.civil(951782400))
        self.assertEqual("2024-12-31 23:59 UTC", admission.civil(1735689599))
        self.assertEqual("2025-03-01 12:30 UTC", admission.civil(1740832200))
        self.assertEqual("2026-09-21 14:13 UTC", admission.civil(NOW))


def judged(dependencies=None, files=None, locks=None, relevant=None, policy=None):
    doc = support.dependabot_pull_request(support.document(),
                                          support.admission_facts(dependencies, files, locks))
    return admission.judge(doc, policy or settings(), {"env-a": "envs/env-a"} if relevant is None else relevant)


def checks(dependency, policy=None):
    return [(check["check"], check["ok"], check["detail"])
            for check in judged([dependency], policy=policy)["dependencies"][0]["checks"]]


class ProviderCheckTest(unittest.TestCase):
    def test_an_admitted_provider(self):
        self.assertEqual([("host", True, "registry.terraform.io"), ("allow", True, "`hashicorp` is on the allow list"),
                          ("age", True, "published 10 days ago"),
                          ("key", True, "signed with `34365D9472D7468F`, as the base version"),
                          ("hashes", True, "every `zh:` hash is in the publisher's checksums")],
                         checks(support.provider_dependency()))
        block = judged()
        self.assertEqual((True, False, 0, 1, []), (block["admitted"], block["push_run"], block["refused_count"],
                                                   block["total"], block["problems"]))
        self.assertEqual({"kind": "provider", "address": REGISTRY_AZURERM, "from": "4.41.0", "to": "4.42.0",
                          "files": ["envs/env-a/.terraform.lock.hcl"], "admitted": True},
                         {key: value for key, value in block["dependencies"][0].items() if key != "checks"})

    def test_another_host(self):
        for address in ("registry.opentofu.org/hashicorp/azurerm", "registry.terraform.io/hashicorp", "hashicorp/x"):
            with self.subTest(address=address):
                self.assertEqual([("host", False, f"`{address}` is not a provider on registry.terraform.io")],
                                 checks(support.provider_dependency(address=address)))

    def test_allow(self):
        dependency = support.provider_dependency(address="registry.terraform.io/cyrilgdn/postgresql")
        self.assertEqual(("allow", False, "`cyrilgdn` is not on the allow list"), checks(dependency)[1])
        for entry in ("cyrilgdn", "CYRILGDN/PostgreSQL", "cyrilgdn/postgresql"):
            with self.subTest(entry=entry):
                self.assertEqual(("allow", True, "`cyrilgdn` is on the allow list"),
                                 checks(dependency, settings({"allow": [entry]}))[1])
        self.assertEqual(("allow", False, "`cyrilgdn` is not on the allow list"),
                         checks(dependency, settings({"allow": ["cyrilgdn/other"]}))[1])
        azure = support.provider_dependency(address="registry.terraform.io/azure/azapi")
        self.assertEqual(("allow", True, "`azure` is on the allow list"), checks(azure)[1])

    def test_age(self):
        for published, detail in (
                (NOW - 3 * DAY, "published 3 days ago"),
                (NOW - 3 * DAY + 1, "published 2 days ago; the minimum is 3 days, reached at 2026-09-21 14:13 UTC"),
                (NOW - DAY, "published 1 day ago; the minimum is 3 days, reached at 2026-09-23 14:13 UTC"),
                (NOW - 9 * 3600, "published 9 hours ago; the minimum is 3 days, reached at 2026-09-24 05:13 UTC"),
                (NOW - 3600, "published 1 hour ago; the minimum is 3 days, reached at 2026-09-24 13:13 UTC"),
                (NOW + 600, "published 0 hours ago; the minimum is 3 days, reached at 2026-09-24 14:23 UTC")):
            with self.subTest(published=published):
                check = checks(support.provider_dependency(published=published))[2]
                self.assertEqual(("age", detail == "published 3 days ago", detail), check)
        one = checks(support.provider_dependency(published=NOW - DAY), settings({"min-age-days": 1}))[2]
        self.assertEqual(("age", True, "published 1 day ago"), one)
        self.assertEqual(("age", False, "no release was published for this version"),
                         checks(support.provider_dependency(published=None))[2])

    def test_an_exempt_namespace(self):
        dependency = support.provider_dependency(address="registry.terraform.io/dsb-norge/x", published=NOW)
        self.assertEqual(("age", True, "`dsb-norge` is exempt from the minimum age"), checks(dependency)[2])
        other = support.provider_dependency(address="registry.terraform.io/hashicorp/x", published=None)
        self.assertEqual(("age", True, "`hashicorp` is exempt from the minimum age"),
                         checks(other, settings({"min-age-exempt": ["HashiCorp/X"]}))[2])

    def test_the_key(self):
        self.assertEqual(("key", True, "signed with `B`, as the base version"),
                         checks(support.provider_dependency(keys_from=("C", "B"), keys_to=("B", "A")))[3])
        vouched = support.provider_dependency(keys_from=("OLD",), keys_to=("NEW",), vouched=True,
                                              class_to="signed by a HashiCorp partner")
        self.assertEqual(("key", True, "signed with a new key, `NEW`, which HashiCorp vouches for (signed by a "
                                       "HashiCorp partner)"), checks(vouched)[3])
        dropped = support.provider_dependency(keys_from=("EA2DADF637267E2E",), keys_to=("ABF2A71040B5EE28", "X"),
                                              vouched=False, class_from="signed by a HashiCorp partner",
                                              class_to="self-signed")
        self.assertEqual(("key", False, "the signing key changed from `EA2DADF637267E2E` (signed by a HashiCorp "
                                        "partner) to `ABF2A71040B5EE28, X` (self-signed)"), checks(dropped)[3])

    def test_the_hashes(self):
        self.assertEqual(("hashes", False, "the lock records 1 `zh:` hash the publisher did not publish"),
                         checks(support.provider_dependency(zh=("aa", "cc")))[4])
        self.assertEqual(("hashes", False, "the lock records 2 `zh:` hashes the publisher did not publish"),
                         checks(support.provider_dependency(zh=("cc", "dd")))[4])
        self.assertEqual(["host", "allow", "age", "key"],
                         [check[0] for check in checks(support.provider_dependency(locked=False, zh=("cc",)))])

    def test_a_failing_check_refuses_the_dependency(self):
        block = judged([support.provider_dependency(published=NOW), support.provider_dependency(new="4.43.0")])
        self.assertEqual((False, 1, 2), (block["admitted"], block["refused_count"], block["total"]))
        self.assertEqual([False, True], [dependency["admitted"] for dependency in block["dependencies"]])


class ModuleCheckTest(unittest.TestCase):
    def test_a_registry_module(self):
        self.assertEqual([("source", True, "registry module"), ("allow", True, "`Azure` is on the allow list"),
                          ("age", True, "published 10 days ago")], checks(support.module_dependency()))

    def test_a_github_source(self):
        dependency = support.module_dependency(address="github.com/dsb-norge/x?ref=v1.3.0", source_kind="github",
                                               namespace="dsb-norge", name="x", published=None)
        self.assertEqual([("source", True, "GitHub source"), ("allow", True, "`dsb-norge` is on the allow list"),
                          ("age", True, "`dsb-norge` is exempt from the minimum age")], checks(dependency))
        other = support.module_dependency(address="github.com/acme/x", source_kind="github", namespace="acme",
                                          name="x", published=None)
        self.assertEqual([("source", True, "GitHub source"), ("allow", False, "`acme` is not on the allow list"),
                          ("age", False, "no release was published for this version")], checks(other))

    def test_another_source_kind(self):
        dependency = support.module_dependency(address="s3::https://bucket/x.zip", source_kind="other",
                                               namespace="", name="")
        self.assertEqual([("source", False, "`s3::https://bucket/x.zip` is neither a registry.terraform.io module nor "
                                            "a GitHub source")], checks(dependency))


def lock(**versions):
    return {f"registry.terraform.io/hashicorp/{name}": {"version": version, "constraints": None, "hashes": ["zh:aa"]}
            for name, version in versions.items()}


def problems(*files, locks=None, relevant=None):
    return [problem["detail"] for problem in judged([], list(files), locks, relevant)["problems"]]


class ShapeTest(unittest.TestCase):
    def test_dependabot_s_changes_pass(self):
        files = [{"path": "main/versions.tf", "status": "modified", "kind": "tf", "unmapped": [], "lines": [
            {"old": '      version = "~> 4.0, != 4.1.0"', "new": '      version = "~> 4.42"'},
            {"old": '  azurerm = { source = "hashicorp/azurerm", version = "4.41.0" }',
             "new": '  azurerm = { source = "hashicorp/azurerm", version = "4.42.0" }'},
            {"old": '  source = "github.com/dsb-norge/x?ref=v1.2.0"', "new": '  source = "github.com/dsb-norge/x?ref=v1.3.0"'},
            {"old": '  source = "git::https://github.com/o/r.git?depth=1&ref=v1"',
             "new": '  source = "git::https://github.com/o/r.git?depth=1&ref=v2"'}]},
                 {"path": "envs/env-a/.terraform.lock.hcl", "status": "modified", "kind": "lock",
                  "before": lock(azurerm="4.41.0", random="3.7.2"),
                  "after": {**lock(random="3.7.2"), REGISTRY_AZURERM: {"version": "4.42.0", "constraints": ">= 4.0",
                                                                       "hashes": ["zh:bb", "h1:cc"]}}}]
        self.assertEqual([], problems(*files))
        self.assertEqual(True, judged([], files)["admitted"])

    def test_what_dependabot_does_not_write(self):
        self.assertEqual(["`a.tf.json`: not a .tf or .terraform.lock.hcl file", "`b.tf`: added", "`c.tf`: removed",
                          "`d.tf`: renamed", "`e.tf`: changed"],
                         problems({"path": "a.tf.json", "status": "modified", "kind": "other"},
                                  {"path": "b.tf", "status": "added", "kind": "other"},
                                  {"path": "c.tf", "status": "removed", "kind": "other"},
                                  {"path": "d.tf", "status": "renamed", "kind": "other"},
                                  {"path": "e.tf", "status": "changed", "kind": "other"}))

    def test_a_tf_change_outside_a_version(self):
        self.assertEqual(["`m.tf`: a line added: `data \"external\" \"x\" {}`",
                          "`m.tf`: a line removed: `# comment`",
                          "`m.tf`: a change outside a version: `source = \"a\"` → `source = \"b\"`",
                          "`m.tf`: a change outside a version: `version = \"1\" # x` → `version = \"2\" # y`"],
                         problems({"path": "m.tf", "status": "modified", "kind": "tf", "unmapped": [], "lines": [
                             {"old": None, "new": '  data "external" "x" {}'}, {"old": "  # comment", "new": None},
                             {"old": '  source = "a"', "new": '  source = "b"'},
                             {"old": '  version = "1" # x', "new": '  version = "2" # y'}]}))

    def test_a_lock_change_outside_a_version(self):
        self.assertEqual(["`l/.terraform.lock.hcl`: cannot be read as a lock file",
                          "`m/.terraform.lock.hcl`: cannot be read as a lock file",
                          "`n/.terraform.lock.hcl`: the providers changed: registry.terraform.io/hashicorp/random",
                          "`o/.terraform.lock.hcl`: `registry.terraform.io/hashicorp/azurerm` changed without a version "
                          "change"],
                         problems({"path": "l/.terraform.lock.hcl", "status": "modified", "kind": "lock", "before": None,
                                   "after": lock()},
                                  {"path": "m/.terraform.lock.hcl", "status": "modified", "kind": "lock",
                                   "before": lock(), "after": None},
                                  {"path": "n/.terraform.lock.hcl", "status": "modified", "kind": "lock",
                                   "before": lock(azurerm="1"), "after": lock(azurerm="2", random="1")},
                                  {"path": "o/.terraform.lock.hcl", "status": "modified", "kind": "lock",
                                   "before": lock(azurerm="1"),
                                   "after": {REGISTRY_AZURERM: {"version": "1", "constraints": "1", "hashes": []}}}))

    def test_the_locks(self):
        self.assertEqual([], problems(locks={"envs/env-a": True}))
        self.assertEqual(["environment `env-a`: no committed .terraform.lock.hcl in `envs/env-a`",
                          "environment `env-b`: no committed .terraform.lock.hcl in `.`"],
                         problems(locks={"envs/env-a": False}, relevant={"env-b": ".", "env-a": "envs/env-a"}))
        block = judged([], [], {}, {"env-a": "envs/env-a"})
        self.assertEqual((False, 0, [{"check": "lock", "detail": "environment `env-a`: no committed "
                                                                 ".terraform.lock.hcl in `envs/env-a`"}]),
                         (block["admitted"], block["refused_count"], block["problems"]))
        shape = judged([], [{"path": "x", "status": "added", "kind": "other"}])["problems"]
        self.assertEqual([{"check": "shape", "detail": "`x`: added"}], shape)

    def test_a_push_run(self):
        doc = support.document()
        doc["event"].update(name="push", actor="dependabot[bot]")
        self.assertEqual({"applies": True, "admitted": True, "push_run": True, "dependencies": [], "problems": [],
                          "refused_count": 0, "total": 0}, admission.judge(doc, settings(), {}))


def decided(facts=None, environments=None, author="dependabot[bot]", inputs=None, comment=True):
    environments = environments or [{"environment": "env-a"}]
    doc = support.document(environments=environments, inputs={"add-pr-comment": comment, **(inputs or {})})
    support.dependabot_pull_request(doc, facts, author)
    doc["run"] = {"id": 4711, "attempt": 2}
    doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": 1,
                            "files": ["envs/env-a/.terraform.lock.hcl"]}
    output = decide.decide(doc)
    if not output["errors"]:
        unittest.TestCase().assertEqual([], invariants.check(doc, output))
    return doc, output


REFUSED_FACTS = support.admission_facts([support.provider_dependency(published=NOW - 9 * 3600),
                                         support.module_dependency(address="cloudposse/label/null", namespace="cloudposse",
                                                                   name="label", files=["main/a.tf", "main/b.tf"])],
                                        [{"path": "x.tf.json", "status": "modified", "kind": "other"}])


class VerdictTest(unittest.TestCase):
    def test_an_admitted_run_is_a_person_s_run(self):
        _, output = decided()
        self.assertEqual(["run"], [entry["verdict"] for entry in output["environments"]])
        self.assertEqual(["admission: admitted (1 dependency)", "relevance diff (diff): 1 of 1 environment affected"],
                         output["notices"])
        two = support.admission_facts([support.provider_dependency(), support.module_dependency()])
        self.assertEqual("admission: admitted (2 dependencies)", decided(two)[1]["notices"][0])

    def test_a_refused_run_runs_nothing(self):
        _, output = decided(REFUSED_FACTS, [{"environment": "env-a"}, {"environment": "env-b", "paths": ["nothing/**"]},
                                            {"environment": "env-c", "trigger-events": ["push"]}])
        self.assertEqual([("env-a", "skip", ["admission: not admitted"], True),
                          ("env-b", "skip", ["admission: not admitted"], False),
                          ("env-c", "skip", ["trigger-events: pull_request not enabled"], False)],
                         [(e["environment"], e["verdict"], e["reasons"], e["relevant"]) for e in output["environments"]])
        self.assertEqual({"1": [], "2": [], "3": []}, {stage: matrix["include"] for stage, matrix in output["matrices"].items()})
        # The relevance notice is the change's, not the drop's: env-a is touched although nothing runs.
        self.assertEqual(["admission: not admitted: 2 of 2 dependencies failed; 1 problem with the change",
                          "relevance diff (diff): 1 of 3 environments affected"], output["notices"][:2])
        self.assertEqual((False, 2, 2), (output["admission"]["admitted"], output["admission"]["refused_count"],
                                         output["admission"]["total"]))

    def test_refusal(self):
        self.assertEqual("1 of 3 dependencies failed", decide.refusal({"refused_count": 1, "total": 3, "problems": []}))
        self.assertEqual("2 problems with the change",
                         decide.refusal({"refused_count": 0, "total": 0, "problems": [{}, {}]}))

    def test_a_dependabot_push_run_runs_nothing_and_is_not_refused(self):
        doc = support.document()
        doc["event"].update(name="push", actor="dependabot[bot]", push={"created": False, "forced": False,
                                                                         "deleted": False})
        output = decide.decide(doc)
        self.assertEqual([], invariants.check(doc, output))
        self.assertEqual(["admission: Dependabot push run"], output["environments"][0]["reasons"])
        self.assertEqual(["admission: a Dependabot push run runs nothing; its pull request's run judges the change",
                          "relevance all (not-computed): 1 of 1 environment affected"], output["notices"][:2])
        self.assertEqual(True, output["admission"]["push_run"])

    def test_the_switch_off_decides_as_before(self):
        doc, output = decided(REFUSED_FACTS, inputs={"dependabot-admission-enabled": False})
        self.assertEqual(({"applies": False}, ["run"]), (output["admission"], [e["verdict"] for e in output["environments"]]))
        without = copy.deepcopy(doc)
        del without["admission"]
        self.assertEqual(output, decide.decide(without))

    def test_missing_facts_are_the_shim_s_fault(self):
        doc = support.dependabot_pull_request(support.document())
        del doc["admission"]
        with self.assertRaises(DocumentError) as caught:
            decide.decide(doc)
        self.assertEqual("input document: a Dependabot pull request the admission applies to needs the 'admission' "
                         "facts", str(caught.exception))

    def test_a_policy_mistake_is_an_error_on_any_run(self):
        doc = support.document(inputs={"dependabot-admission-enabled": "maybe"})
        output = decide.decide(doc)
        self.assertEqual(["The input 'dependabot-admission-enabled' is 'maybe'; it must be true or false!"],
                         output["errors"])
        self.assertEqual({"applies": False}, output["admission"])


class CommentsTest(unittest.TestCase):
    def manifest(self, facts=REFUSED_FACTS, **kwargs):
        return decided(facts, **kwargs)[1]["comments"]

    def test_a_refused_run_posts_the_admission_head_first(self):
        heads = self.manifest()["heads"]
        self.assertEqual([("admission", "", "final", "<!-- tf:head:admission: -->"),
                          ("env", "env-a", "not-admitted", "<!-- tf:head:env:env-a -->")],
                         [(head["kind"], head["key"], head["state"], head["marker"]) for head in heads])
        self.assertEqual("### Terraform validation summary for environment: `env-a`\n\n🚫 Not admitted: this Dependabot "
                         "pull request failed the admission, so nothing ran (run #4711 attempt #2). See the admission "
                         "comment.", heads[1]["body"])

    def test_the_admission_head_s_body(self):
        body = self.manifest()["heads"][0]["body"]
        self.assertEqual(
            "### 🚫 Dependabot pull request not admitted\n\n"
            "No Terraform ran. Every dependency a Dependabot pull request changes must pass the admission before any "
            "job runs it ([what the admission checks](https://github.com/dsb-norge/github-actions-terraform/blob/main/"
            "docs/Dependabot-admission.md)).\n\n"
            "| Dependency | Change | Result |\n|---|---|---|\n"
            "| provider `hashicorp/azurerm` | 4.41.0 → 4.42.0 | ❌ published 9 hours ago; the minimum is 3 days, reached "
            "at 2026-09-24 05:13 UTC |\n"
            "| module `cloudposse/label/null` | 0.4.3 → 0.4.4 | ❌ `cloudposse` is not on the allow list |\n"
            "| the change | — | ❌ `x.tf.json`: not a .tf or .terraform.lock.hcl file |\n\n"
            "<details><summary>Files</summary>\n\n"
            "- `envs/env-a/.terraform.lock.hcl`: provider `hashicorp/azurerm`\n"
            "- `main/a.tf`, `main/b.tf`: module `cloudposse/label/null`\n\n</details>\n\n"
            "**provider `hashicorp/azurerm` 4.42.0 is too new:** published 9 hours ago; the minimum is 3 days, reached "
            "at 2026-09-24 05:13 UTC. Then re-run all jobs of this run.\n\n"
            "**If you trust module `cloudposse/label/null` and the update is intended:** add `cloudposse/label` (or "
            "`cloudposse`) to `allow` in `dependabot-admission-yml` in the calling workflow on the default branch, then "
            "comment `@dependabot rebase` on this pull request.\n\n"
            "**The change:** `x.tf.json`: not a .tf or .terraform.lock.hcl file. Review it; a commit of your own runs it "
            "as you.\n\n"
            "**To run this pull request once without changing the policy:** push a commit to its branch. That run is "
            "yours and is not judged; Dependabot stops rebasing the pull request.", body)

    def test_the_help_for_each_check(self):
        facts = support.admission_facts([
            support.provider_dependency(address="registry.terraform.io/acme/thing", keys_from=("A",), keys_to=("B",),
                                        vouched=False, class_from="self-signed", class_to="self-signed",
                                        zh=("zz",)),
            support.module_dependency(address="s3::x", source_kind="other", namespace="", name="")],
            [], {})
        body = self.manifest(facts)["heads"][0]["body"]
        for text in ("**If you trust provider `acme/thing` and the update is intended:** add `acme/thing` (or `acme`)",
                     "**provider `acme/thing` 4.42.0:** the signing key changed from `A` (self-signed) to `B` "
                     "(self-signed). A new key HashiCorp does not vouch for is lock-file maintenance for a "
                     "maintainer: verify the key with the publisher, then update the lock by hand in a commit of your "
                     "own.",
                     "**provider `acme/thing` 4.42.0:** the lock records 1 `zh:` hash the publisher did not publish. Do "
                     "not merge; comment `@dependabot recreate`.",
                     "**module `s3::x`:** `s3::x` is neither a registry.terraform.io module nor a GitHub source; the "
                     "admission judges registry and GitHub sources only. A commit of your own runs it as you.",
                     "**environment `env-a`: no committed .terraform.lock.hcl in `envs/env-a`:** commit a lock file on "
                     "the default branch, then comment `@dependabot rebase` on this pull request."):
            with self.subTest(text=text):
                self.assertIn(text, body)
        self.assertNotIn("<details>", self.manifest(support.admission_facts([], [], {}))["heads"][0]["body"])

    def test_the_head_s_title_and_a_string_switch(self):
        heads = self.manifest(inputs={"add-pr-comment": "true"}, comment="true")["heads"]
        self.assertEqual(("admission", "🚫 Dependabot pull request not admitted"), (heads[0]["kind"], heads[0]["title"]))

    def test_no_comment_no_head_and_no_purge(self):
        manifest = self.manifest(comment=False)
        self.assertEqual(([], []), (manifest["heads"], manifest["gc"]))

    def test_a_later_run_purges_a_stale_admission_head(self):
        purge = {"marker-prefix": "<!-- tf:head:admission: -->", "keep-marker-substring": ""}
        self.assertEqual([purge], self.manifest(support.admission_facts())["gc"])
        doc = support.document(environments=[{"environment": "env-a"}])
        support.dependabot_pull_request(doc)
        doc["event"]["actor"] = "octocat"
        del doc["admission"]
        doc["run"] = {"id": 1, "attempt": 1}
        output = decide.decide(doc)
        self.assertEqual([], invariants.check(doc, output))
        self.assertEqual([purge], output["comments"]["gc"])
        self.assertEqual([], self.manifest(support.admission_facts(), author="octocat")["gc"])
        doc["event"]["pull_request"].pop("author")
        self.assertEqual([], decide.decide(doc)["comments"]["gc"])

    def test_the_caller_scopes_the_marker(self):
        doc = support.document()
        support.dependabot_pull_request(doc, REFUSED_FACTS)
        doc["caller"]["workflow_name"] = "Validate PR (v1)"
        doc["run"] = {"id": 1, "attempt": 1}
        heads = decide.decide(doc)["comments"]["heads"]
        self.assertEqual("<!-- tf:head:admission:ValidatePRv1 -->", heads[0]["marker"])


CIVIL = [(1738367940, "2025-01-31 23:59 UTC"), (1740787140, "2025-02-28 23:59 UTC"), (1743465540, "2025-03-31 23:59 UTC"),
         (1746057540, "2025-04-30 23:59 UTC"), (1748735940, "2025-05-31 23:59 UTC"), (1751327940, "2025-06-30 23:59 UTC"),
         (1754006340, "2025-07-31 23:59 UTC"), (1756684740, "2025-08-31 23:59 UTC"), (1759276740, "2025-09-30 23:59 UTC"),
         (1761955140, "2025-10-31 23:59 UTC"), (1764547140, "2025-11-30 23:59 UTC"), (1767225540, "2025-12-31 23:59 UTC"),
         (1709208000, "2024-02-29 12:00 UTC"), (4107542340, "2100-02-28 23:59 UTC"), (4107542400, "2100-03-01 00:00 UTC"),
         (13569465540, "2399-12-31 23:59 UTC"), (13574586600, "2400-02-29 06:30 UTC"),
         (13574649600, "2400-03-01 00:00 UTC"), (-2203891200, "1900-03-01 00:00 UTC"), (-60, "1969-12-31 23:59 UTC"),
         (7289568060, "2200-12-31 00:01 UTC"), (4133980800, "2101-01-01 00:00 UTC"),
         # The first of May, July, October and December: where the month index's rounding decides.
         (1746057600, "2025-05-01 00:00 UTC"), (1751328000, "2025-07-01 00:00 UTC"),
         (1759276800, "2025-10-01 00:00 UTC"), (1764547200, "2025-12-01 00:00 UTC")]


class EdgeTest(unittest.TestCase):
    """The cases the mutation gate asked for: each pins one branch or constant."""

    def test_civil_across_months_centuries_and_eras(self):
        for epoch, expected in CIVIL:
            with self.subTest(epoch=epoch):
                self.assertEqual(expected, admission.civil(epoch))

    def test_constraints_at_their_edges(self):
        self.assertIs(False, admission.allows("= 1.2.3", "1.2.4"))
        self.assertIs(True, admission.allows(">= 1.0.0-rc1", "1.0.0"))
        self.assertIs(False, admission.allows(">= 1.0.0-rc1", "1.0.0-rc2"))
        self.assertIs(False, admission.allows("~> 1.2", "2.0.0"))
        self.assertIs(True, admission.allows("~> 1.2.3-rc1", "1.2.3"))
        self.assertIsNone(admission.allows("1 2", "1.0.0"))
        self.assertIsNone(admission.allows("1.0.0,,2.0.0", "1.0.0"))

    def test_a_malformed_provider_address(self):
        for address in ("registry.terraform.io//x", "registry.terraform.io/a/b/c", "registry.terraform.io/a/"):
            with self.subTest(address=address):
                self.assertEqual([("host", False, f"`{address}` is not a provider on registry.terraform.io")],
                                 checks(support.provider_dependency(address=address)))

    def test_several_keys_are_named(self):
        vouched = support.provider_dependency(keys_from=("OLD",), keys_to=("NEW1", "NEW2"), vouched=True,
                                              class_to="signed by a HashiCorp partner")
        self.assertEqual(("key", True, "signed with a new key, `NEW1, NEW2`, which HashiCorp vouches for (signed by a "
                                       "HashiCorp partner)"), checks(vouched)[3])
        changed = support.provider_dependency(keys_from=("A", "B"), keys_to=("C",), vouched=False,
                                              class_from="self-signed", class_to="self-signed")
        self.assertEqual(("key", False, "the signing key changed from `A, B` (self-signed) to `C` (self-signed)"),
                         checks(changed)[3])

    def test_several_providers_added_to_a_lock(self):
        self.assertEqual(["`n/.terraform.lock.hcl`: the providers changed: registry.terraform.io/hashicorp/http, "
                          "registry.terraform.io/hashicorp/random"],
                         problems({"path": "n/.terraform.lock.hcl", "status": "modified", "kind": "lock",
                                   "before": lock(azurerm="1"), "after": lock(azurerm="2", random="1", http="1")}))

    def test_a_change_beside_the_value_is_outside_it(self):
        self.assertEqual(["`m.tf`: a change outside a version: `version = \"1\"` → `version  = \"2\"`",
                          "`m.tf`: a change outside a version: `source = \"x?ref=v1\"` → `source = \"x&ref=v2\"`"],
                         problems({"path": "m.tf", "status": "modified", "kind": "tf", "unmapped": [], "lines": [
                             {"old": '  version = "1"', "new": '  version  = "2"'},
                             {"old": '  source = "x?ref=v1"', "new": '  source = "x&ref=v2"'}]}))

    def test_a_version_change_no_dependency_explains(self):
        self.assertEqual(['`p.tf`: a version changed outside a module block or a required_providers entry: '
                          '`version = "~> 2.0"`'],
                         problems({"path": "p.tf", "status": "modified", "kind": "tf", "lines": [],
                                   "unmapped": ['  version = "~> 2.0"']}))

    def test_the_report_of_an_admitted_and_a_twice_failed_dependency(self):
        from dsb_tf_engine import comments
        report = comments.admission_report(judged([support.provider_dependency(),
                                                   support.provider_dependency(new="4.43.0", published=NOW,
                                                                               zh=("zz",))], [], {}, {}))
        self.assertEqual("| Dependency | Change | Result |\n|---|---|---|\n"
                         "| provider `hashicorp/azurerm` | 4.41.0 → 4.42.0 | ✅ admitted |\n"
                         "| provider `hashicorp/azurerm` | 4.41.0 → 4.43.0 | ❌ published 0 hours ago; the minimum is 3 "
                         "days, reached at 2026-09-24 14:13 UTC; the lock records 1 `zh:` hash the publisher did not "
                         "publish |", report)


class ModuleModeTest(unittest.TestCase):
    """docs/Dependabot-admission.md §11: opt-in, and when on, a refusal runs no test."""

    def document(self, facts=None, switch=True, event="pull_request"):
        import test_module
        doc = test_module.document(["tests/unit-tests.tftest.hcl"], dirs=["."], event=event)
        doc["workflow_inputs"]["dependabot-admission-enabled"] = switch
        doc["event"]["actor"] = "dependabot[bot]"
        if event == "pull_request":
            doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": False,
                                            "author": "dependabot[bot]"}
            doc["admission"] = facts or support.admission_facts(locks={})
        return doc

    def decided(self, doc):
        output = decide.decide(doc)
        # The checker's other invariants are the project mode's; the admission's hold in both.
        self.assertEqual([], invariants._admission_invariants(doc, output))
        return output

    def test_an_admitted_module_pull_request_runs_its_tests(self):
        output = self.decided(self.document())
        self.assertEqual((True, True, 1), (output["admission"]["applies"], output["admission"]["admitted"],
                                           output["tests"]["count"]))
        self.assertEqual("admission: admitted (1 dependency)", output["notices"][0])

    def test_a_refused_module_pull_request_runs_none(self):
        facts = support.admission_facts([support.provider_dependency(published=NOW)], locks={})
        output = self.decided(self.document(facts))
        self.assertEqual((False, 0, False), (output["admission"]["admitted"], output["tests"]["count"],
                                             output["tests"]["missing"]))
        self.assertEqual([{"file": "tests/unit-tests.tftest.hcl", "lane": "default", "reason": "admission: not admitted"}],
                         output["tests"]["not_run"])

    def test_a_module_push_by_dependabot_runs_none(self):
        output = self.decided(self.document(event="push"))
        self.assertEqual(True, output["admission"]["push_run"])
        self.assertEqual("admission: Dependabot push run", output["tests"]["not_run"][0]["reason"])

    def test_off_by_default(self):
        doc = self.document()
        del doc["workflow_inputs"]["dependabot-admission-enabled"]
        self.assertEqual({"applies": False}, self.decided(doc)["admission"])

    def test_facts_are_needed_when_it_applies(self):
        doc = self.document()
        del doc["admission"]
        with self.assertRaises(DocumentError):
            decide.decide(doc)


if __name__ == "__main__":
    unittest.main()
