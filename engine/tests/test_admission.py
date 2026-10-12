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
                          "exempt": ["dsb-norge"], "min_age_days": 3, "holds": []}, settings())
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
                self.assertEqual([f"dependabot-admission-yml must be a mapping with the keys allow, hold, min-age-days "
                                  f"and min-age-exempt; it holds {kind}."], messages(value))

    def test_unknown_keys_are_named_in_order(self):
        self.assertEqual(["dependabot-admission-yml holds the unknown key 5; the keys are allow, hold, min-age-days "
                          "and min-age-exempt.",
                          "dependabot-admission-yml holds the unknown key 'allows'; the keys are allow, hold, "
                          "min-age-days and min-age-exempt.",
                          "dependabot-admission-yml holds the unknown key 'zzz'; the keys are allow, hold, min-age-days "
                          "and min-age-exempt."],
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
                          "dependabot-admission-yml holds the unknown key 'x'; the keys are allow, hold, min-age-days "
                          "and min-age-exempt.",
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

    MARKER = "<!-- tf:head:admission:TerraformmoduleCI -->"

    def test_a_refused_module_pull_request_gets_the_admission_head(self):
        facts = support.admission_facts([support.provider_dependency(published=NOW)], locks={})
        comments = self.decided(self.document(facts))["comments"]
        self.assertEqual([], comments["gc"])
        self.assertEqual([("admission", "TerraformmoduleCI", "final", self.MARKER)],
                         [(head["kind"], head["key"], head["state"], head["marker"]) for head in comments["heads"]])
        self.assertTrue(comments["heads"][0]["body"].startswith("### 🚫 Dependabot pull request not admitted\n\n"))
        self.assertIn("| provider `hashicorp/azurerm` | 4.41.0 → 4.42.0 | ❌ published 0 hours ago",
                      comments["heads"][0]["body"])

    def test_a_later_module_run_purges_a_stale_head(self):
        purge = {"heads": [], "gc": [{"marker-prefix": self.MARKER, "keep-marker-substring": ""}]}
        self.assertEqual(purge, self.decided(self.document())["comments"])
        doc = self.document(switch=False)
        del doc["admission"]
        self.assertEqual(purge, self.decided(doc)["comments"])
        doc["event"]["pull_request"]["author"] = "octocat"
        self.assertEqual({"heads": [], "gc": []}, self.decided(doc)["comments"])

    def test_no_module_head_where_the_seed_does_not_run(self):
        facts = support.admission_facts([support.provider_dependency(published=NOW)], locks={})
        self.assertEqual({"heads": [], "gc": []}, self.decided(self.document(event="push"))["comments"])
        fork = self.document(facts)
        fork["event"]["pull_request"]["is_fork"] = True
        self.assertEqual({"heads": [], "gc": []}, decide.decide(fork)["comments"])
        quiet = self.document(facts)
        quiet["workflow_inputs"]["add-pr-comment"] = False
        self.assertEqual({"heads": [], "gc": []}, self.decided(quiet)["comments"])

    def test_facts_are_needed_when_it_applies(self):
        doc = self.document()
        del doc["admission"]
        with self.assertRaises(DocumentError):
            decide.decide(doc)



# Holds (docs/Dependabot-admission.md §4.6, Configuration-validation.md §3.9).

REASON = ("azurerm 3.117 stopped retrying a dropped connection to Azure Resource Manager, which fails the plan; "
          "4.12.0 retries again.")
AZURERM_HOLD = {"provider": "hashicorp/azurerm", "versions": "> 3.116.0, < 4.12.0", "reason": REASON}
HELD = {"name": "hashicorp/azurerm", "versions": "> 3.116.0, < 4.12.0", "reason": REASON}
PREFIX = "dependabot-admission-yml: "


def hold_policy(*holds):
    return settings({"hold": list(holds)})


def hold(name="hashicorp/azurerm", versions="> 3.116.0, < 4.12.0", reason=REASON, kind="provider"):
    return {kind: name, "versions": versions, "reason": reason}


class HoldSettingsTest(unittest.TestCase):
    def test_no_holds(self):
        self.assertEqual([], settings()["holds"])
        self.assertEqual([], settings({"hold": None})["holds"])
        self.assertEqual([], settings({"hold": []})["holds"])
        # An empty hold sets nothing, so the admission may be off.
        self.assertEqual([], settings({"hold": []}, switch=False)["holds"])
        self.assertEqual([], settings({"hold": None}, switch="false")["holds"])

    def test_a_provider_hold(self):
        self.assertEqual([{"kind": "provider", "name": "hashicorp/azurerm", "key": "hashicorp/azurerm",
                           "versions": "> 3.116.0, < 4.12.0",
                           "conditions": [(">", (3, 116, 0, "", 3)), ("<", (4, 12, 0, "", 3))], "reason": REASON}],
                         hold_policy(AZURERM_HOLD)["holds"])

    def test_the_names_a_hold_takes(self):
        cases = [("provider", "hashicorp/azurerm", "hashicorp/azurerm"),
                 ("provider", "registry.terraform.io/HashiCorp/AzureRM", "hashicorp/azurerm"),
                 ("provider", "cyrilgdn/postgresql", "cyrilgdn/postgresql"),
                 ("module", "Azure/naming/azurerm", "azure/naming/azurerm"),
                 ("module", "registry.terraform.io/Azure/naming/azurerm", "azure/naming/azurerm"),
                 ("module", "github.com/Example-Org/Network", "github.com/example-org/network"),
                 ("module", "github.com/example-org/network.git", "github.com/example-org/network"),
                 ("module", "github.com/example-org/net.work.GIT", "github.com/example-org/net.work"),
                 ("module", "git::https://github.com/example-org/network.git", "github.com/example-org/network"),
                 ("module", "git::https://github.com/example-org/network", "github.com/example-org/network"),
                 ("module", "git::ssh://git@github.com/example-org/network.git", "github.com/example-org/network"),
                 ("module", "git@github.com:example-org/network.git", "github.com/example-org/network")]
        for kind, name, key in cases:
            with self.subTest(name=name):
                held = hold_policy(hold(name, kind=kind))["holds"][0]
                self.assertEqual((kind, name, key), (held["kind"], held["name"], held["key"]))

    def test_the_conditions(self):
        cases = [("3.117.1", [("", (3, 117, 1, "", 3))]), ("= 3.117.1", [("=", (3, 117, 1, "", 3))]),
                 ("!=3.117.1", [("!=", (3, 117, 1, "", 3))]), (">= 4", [(">=", (4, 0, 0, "", 1))]),
                 ("  ~> 3.117 ", [("~>", (3, 117, 0, "", 2))]), ("<= 1.2.3", [("<=", (1, 2, 3, "", 3))]),
                 (">= 0", [(">=", (0, 0, 0, "", 1))])]
        for versions, conditions in cases:
            with self.subTest(versions=versions):
                self.assertEqual(conditions, hold_policy(hold(versions=versions))["holds"][0]["conditions"])

    def test_the_shape_of_hold(self):
        for value, kind in (({"provider": "x"}, "a mapping"), ("x", "a string"), (3, "a number"), (True, "a boolean")):
            with self.subTest(value=value):
                self.assertEqual([f"{PREFIX}hold must be a list of holds, each with provider or module, versions and "
                                  f"reason; it is {kind}."], messages({"hold": value}))
        self.assertEqual([f"{PREFIX}hold entry 1 must be a mapping with provider or module, versions and reason; it "
                          "is a string.",
                          f"{PREFIX}hold entry 3 must be a mapping with provider or module, versions and reason; it "
                          "is a list."], messages({"hold": ["x", AZURERM_HOLD, [1]]}))

    def test_unknown_keys(self):
        self.assertEqual([f"{PREFIX}hold entry 1 has the unknown key 5; a hold has provider or module, versions and "
                          "reason.",
                          f"{PREFIX}hold entry 1 has the unknown key 'version'; a hold has provider or module, versions "
                          "and reason."], messages({"hold": [{**AZURERM_HOLD, "version": "1", 5: 1}]}))

    def test_neither_or_both_kinds(self):
        neither = {"versions": "> 1.0.0", "reason": "r"}
        both = {"provider": "a/b", "module": "a/b/c", "versions": "> 1.0.0", "reason": "r"}
        for entry in (neither, both):
            with self.subTest(entry=entry):
                self.assertEqual([f"{PREFIX}hold entry 1 must name either a provider or a module."],
                                 messages({"hold": [entry]}))
        # Until its dependency reads, a hold is named by its position.
        self.assertEqual([f"{PREFIX}hold entry 1 must name either a provider or a module.",
                          f"{PREFIX}hold entry 1 has no versions; write the versions Dependabot may not bring in, for "
                          "example '> 3.116.0'.",
                          f"{PREFIX}hold entry 1 has no reason; say why the versions are held."],
                         messages({"hold": [{}]}))

    def test_a_provider_that_is_not_one(self):
        for name in ("Azure/naming/azurerm", "hashicorp", "registry.opentofu.org/hashicorp/azurerm", "a b/c", 5,
                     "hashicorp/", "/azurerm", "registry.terraform.io/x"):
            with self.subTest(name=name):
                self.assertEqual([f"{PREFIX}hold entry 1: provider {admission.shown(name)} is not a provider; a "
                                  "provider is '<namespace>/<type>', for example 'hashicorp/azurerm'."],
                                 messages({"hold": [hold(name)]}))

    def test_a_module_that_is_not_one(self):
        for name in ("Azure/naming", "s3::https://bucket/x.zip", "gitlab.com/a/b", "bitbucket.org/a/b", 7,
                     "Azure/naming/azurerm/x", "github.com/owner", "./modules/x", "app.terraform.io/a/b/c"):
            with self.subTest(name=name):
                self.assertEqual([f"{PREFIX}hold entry 1: module {admission.shown(name)} is not a module a hold can "
                                  "name; a registry module is '<namespace>/<name>/<provider>', for example "
                                  "'Azure/naming/azurerm', and a GitHub module 'github.com/<owner>/<repo>'."],
                                 messages({"hold": [hold(name, kind="module")]}))

    def test_a_module_with_a_subdirectory_or_a_ref(self):
        for name, package in (("github.com/example-org/network//subnets?ref=v1.2.0", "github.com/example-org/network"),
                              ("git::https://github.com/example-org/network.git?ref=v1", "github.com/example-org/network"),
                              ("Azure/naming/azurerm//modules/x", "Azure/naming/azurerm"),
                              ("registry.terraform.io/Azure/naming/azurerm//x", "Azure/naming/azurerm")):
            with self.subTest(name=name):
                self.assertEqual([f"{PREFIX}hold entry 1: module {admission.shown(name)} names a subdirectory or a "
                                  f"ref; a hold names the package, {admission.shown(package)}."],
                                 messages({"hold": [hold(name, kind="module")]}))

    def test_versions_mistakes(self):
        on = "the hold on provider 'hashicorp/azurerm'"
        self.assertEqual([f"{PREFIX}{on} has no versions; write the versions Dependabot may not bring in, for example "
                          "'> 3.116.0'."], messages({"hold": [{"provider": "hashicorp/azurerm", "reason": "r"}]}))
        for value in (3.117, [">= 3.117.0", "< 4.0.0"], True, None, {"a": 1}):
            with self.subTest(value=value):
                self.assertEqual([f"{PREFIX}{on} sets versions to {admission.shown(value)}, which is not a string; "
                                  "write one constraint in quotes, for example '> 3.116.0'."],
                                 messages({"hold": [hold(versions=value)]}))
        for value in ("", "   "):
            with self.subTest(value=value):
                self.assertEqual([f"{PREFIX}{on} sets versions to {admission.shown(value)}, which names no version; "
                                  "write the versions Dependabot may not bring in, for example '> 3.116.0'."],
                                 messages({"hold": [hold(versions=value)]}))
        for value in (">= v3.117.0", ">= 3.117.0-rc1", "3.117.0+b", ">> 1", "1.0.0,", ", 1.0.0", "1.2.3.4", "~>",
                      "abc", ">= 1.0.0,, < 2.0.0", "> 1.0.0 < 2.0.0", "=< 1.0.0", "1.x"):
            with self.subTest(value=value):
                self.assertEqual([f"{PREFIX}{on} sets versions to {admission.shown(value)}, which is not a Terraform "
                                  "version constraint of releases, for example '> 3.116.0, < 4.12.0'."],
                                 messages({"hold": [hold(versions=value)]}))
        for value in ("> 4.0.0, < 3.0.0", "> 1.0.0, < 1.0.1", "= 1.0.0, = 1.0.1", "< 0.0.0", "~> 1.2, >= 2.0.0",
                      "= 1.0.0, != 1.0.0", "> 1.2, < 1.2.1", "<= 0.0.0, != 0.0.0"):
            with self.subTest(value=value):
                self.assertEqual([f"{PREFIX}{on} sets versions to {admission.shown(value)}, which no release "
                                  "satisfies."], messages({"hold": [hold(versions=value)]}))

    def test_ranges_some_release_satisfies(self):
        for value in (">= 1.0.0, != 1.0.0, != 1.0.1, < 1.0.3", "!= 0.0.0", "> 1.9.9, < 2.0.0", "~> 1.2, != 1.2.0",
                      ">= 0", "> 1, < 2", "<= 0.0.0", "= 0.0.0", "~> 0.0.1", "> 1.2, < 1.2.2", "~> 2", "< 0.0.1",
                      "< 0.1, != 0.0.1"):
            with self.subTest(value=value):
                self.assertEqual(1, len(hold_policy(hold(versions=value))["holds"]))

    def test_reason_mistakes(self):
        for entry in ({"provider": "hashicorp/azurerm", "versions": "> 1.0.0"}, hold(reason=5), hold(reason=""),
                      hold(reason=" \n "), hold(reason=None)):
            with self.subTest(entry=entry):
                self.assertEqual([f"{PREFIX}the hold on provider 'hashicorp/azurerm' has no reason; say why the "
                                  "versions are held."], messages({"hold": [entry]}))

    def test_a_hold_needs_the_admission_on(self):
        message = (f"{PREFIX[:-2]} sets hold, but the Dependabot admission is off, so no hold is applied. Switch "
                   "dependabot-admission-enabled on, or remove hold.")
        for switch in (False, "false"):
            with self.subTest(switch=switch):
                self.assertEqual([message], messages({"hold": [AZURERM_HOLD]}, switch=switch))
        # Off by default in the module workflow.
        doc = support.document()
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"hold": [AZURERM_HOLD]})
        with self.assertRaises(ConfigError) as caught:
            admission.settings(doc, False)
        self.assertEqual([message], caught.exception.messages)
        # An invalid switch says so alone.
        self.assertEqual(["The input 'dependabot-admission-enabled' is 'yes'; it must be true or false!"],
                         messages({"hold": [AZURERM_HOLD]}, switch="yes"))
        # A hold that is not a list is set too.
        self.assertEqual(2, len(messages({"hold": "x"}, switch=False)))

    def test_every_hold_mistake_in_reporting_order(self):
        self.assertEqual(
            [f"{PREFIX}min-age-days must be a whole number from 0 to 90; it holds 100.",
             f"{PREFIX}hold entry 1 has the unknown key 'x'; a hold has provider or module, versions and reason.",
             f"{PREFIX}hold entry 1: module 'Azure/naming' is not a module a hold can name; a registry module is "
             "'<namespace>/<name>/<provider>', for example 'Azure/naming/azurerm', and a GitHub module "
             "'github.com/<owner>/<repo>'.",
             f"{PREFIX}hold entry 1 sets versions to '', which names no version; write the versions Dependabot may "
             "not bring in, for example '> 3.116.0'.",
             f"{PREFIX}hold entry 1 has no reason; say why the versions are held.",
             f"{PREFIX}the hold on provider 'cyrilgdn/postgresql' sets versions to '> 2, < 1', which no release "
             "satisfies.",
             f"{PREFIX[:-2]} sets hold, but the Dependabot admission is off, so no hold is applied. Switch "
             "dependabot-admission-enabled on, or remove hold."],
            messages({"min-age-days": 100, "hold": [{"module": "Azure/naming", "versions": "", "x": 1},
                                                     hold("cyrilgdn/postgresql", versions="> 2, < 1"),
                                                     AZURERM_HOLD]}, switch=False))

    def test_the_keys_name_hold(self):
        self.assertEqual(["dependabot-admission-yml holds the unknown key 'holds'; the keys are allow, hold, "
                          "min-age-days and min-age-exempt."], messages({"holds": []}))
        self.assertEqual(["dependabot-admission-yml must be a mapping with the keys allow, hold, min-age-days and "
                          "min-age-exempt; it holds a list."], messages([1]))


def held_checks(dependency, *holds):
    return [(check["check"], check["ok"], check["detail"], check.get("holds"))
            for check in judged([dependency], policy=hold_policy(*holds))["dependencies"][0]["checks"]]


def hold_check(dependency, *holds):
    return next(check for check in held_checks(dependency, *holds) if check[0] == "hold")


class DependencyKeyTest(unittest.TestCase):
    def test_the_key_a_hold_names_a_dependency_by(self):
        cases = [(support.provider_dependency(), "hashicorp/azurerm"),
                 (support.provider_dependency(address="registry.terraform.io/Azure/AzAPI"), "azure/azapi"),
                 (support.provider_dependency(address="registry.example.com/hashicorp/azurerm"), None),
                 (support.provider_dependency(address="registry.terraform.io/hashicorp"), None),
                 (support.provider_dependency(address="registry.terraform.io/a/b/c"), None),
                 (support.module_dependency(), "azure/naming/azurerm"),
                 (support.module_dependency(provider="AWS"), "azure/naming/aws"),
                 (support.module_dependency(source_kind="github", namespace="O", name="R.Git"), "github.com/o/r"),
                 (support.module_dependency(source_kind="github", namespace="o", name="git"), "github.com/o/git"),
                 (support.module_dependency(source_kind="other", namespace="o", name="r"), None)]
        for dependency, key in cases:
            with self.subTest(address=dependency["address"], source_kind=dependency.get("source_kind")):
                self.assertEqual(key, admission.dependency_key(dependency))


class HoldCheckTest(unittest.TestCase):
    def test_a_held_provider(self):
        block = judged([support.provider_dependency(old="3.116.0", new="3.117.1")], policy=hold_policy(AZURERM_HOLD))
        self.assertEqual((False, 1, 1), (block["admitted"], block["refused_count"], block["total"]))
        self.assertEqual([("host", True), ("hold", False), ("allow", True), ("age", True), ("key", True),
                          ("hashes", True)], [(check["check"], check["ok"]) for check in block["dependencies"][0]["checks"]])
        self.assertEqual({"check": "hold", "ok": False, "detail": "held by this repository: `> 3.116.0, < 4.12.0`",
                          "holds": [HELD]}, block["dependencies"][0]["checks"][1])

    def test_a_version_outside_the_hold_passes(self):
        for version in ("3.116.0", "4.12.0", "4.81.0", "3.0.0"):
            with self.subTest(version=version):
                self.assertEqual(("hold", True, f"no hold covers {version}", []),
                                 hold_check(support.provider_dependency(new=version), AZURERM_HOLD))

    def test_another_dependency_passes(self):
        dependency = support.provider_dependency(address="registry.terraform.io/hashicorp/azuread", new="3.117.1")
        self.assertEqual(("hold", True, "no hold names it", []), hold_check(dependency, AZURERM_HOLD))
        module = support.module_dependency(new="3.117.1")
        self.assertEqual([("source", True, "registry module", None), ("hold", True, "no hold names it", []),
                          ("allow", True, "`Azure` is on the allow list", None),
                          ("age", True, "published 10 days ago", None)], held_checks(module, AZURERM_HOLD))

    def test_names_compare_without_case_and_host(self):
        dependency = support.provider_dependency(new="3.117.1")
        for name in ("HashiCorp/AzureRM", "registry.terraform.io/hashicorp/azurerm"):
            with self.subTest(name=name):
                self.assertEqual(False, hold_check(dependency, hold(name))[1])

    def test_a_held_registry_module_through_a_subdirectory(self):
        dependency = support.module_dependency(address="Azure/naming/azurerm//modules/x", new="0.5.0")
        self.assertEqual(("hold", False, "held by this repository: `>= 0.5.0`",
                          [{"name": "azure/naming/azurerm", "versions": ">= 0.5.0", "reason": "r"}]),
                         hold_check(dependency, hold("azure/naming/azurerm", ">= 0.5.0", "r", "module")))
        self.assertEqual(("hold", True, "no hold names it", []),
                         hold_check(dependency, hold("Azure/naming/aws", ">= 0.5.0", "r", "module")))
        other = support.module_dependency(address="registry.terraform.io/Azure/naming/azurerm", new="0.5.0")
        self.assertEqual(False, hold_check(other, hold("Azure/naming/azurerm", ">= 0.5.0", "r", "module"))[1])

    def test_a_held_github_module(self):
        dependency = support.module_dependency(address="git::https://github.com/Example-Org/Network.GIT?ref=v2.0.0",
                                               source_kind="github", namespace="Example-Org", name="Network.GIT",
                                               old="v1.4.0", new="v2.0.0")
        self.assertEqual(("hold", False, "held by this repository: `>= 2.0.0`",
                          [{"name": "github.com/example-org/network", "versions": ">= 2.0.0", "reason": "r"}]),
                         hold_check(dependency, hold("github.com/example-org/network", ">= 2.0.0", "r", "module")))
        self.assertEqual(("hold", True, "no hold covers v1.9.0", []),
                         hold_check({**dependency, "to": "v1.9.0"},
                                    hold("github.com/example-org/network", ">= 2.0.0", "r", "module")))

    def test_a_version_that_cannot_be_read_is_held(self):
        github = support.module_dependency(address="github.com/o/r?ref=v2", source_kind="github", namespace="o",
                                           name="r", old="v1", new="v2")
        for to in ("v2", "release-1.2.3", "main", "1.2", "0123abc"):
            with self.subTest(to=to):
                self.assertEqual(("hold", False, f"held by this repository: `{to}` is not a version a hold can compare",
                                  [{"name": "github.com/o/r", "versions": ">= 9.0.0", "reason": "r"}]),
                                 hold_check({**github, "to": to}, hold("github.com/o/r", ">= 9.0.0", "r", "module")))
        provider = support.provider_dependency(new="~> 4.0", locked=False, zh=())
        self.assertEqual(False, hold_check(provider, AZURERM_HOLD)[1])

    def test_a_pre_release_is_held_through_its_release_or_its_order(self):
        for version, versions, held in (("4.0.0-beta1", ">= 4.0.0", True), ("4.12.0-rc1", "> 3.116.0, < 4.12.0", True),
                                        ("4.12.1-rc1", "> 3.116.0, < 4.12.0", False),
                                        ("3.116.0-rc1", "> 3.116.0, < 4.12.0", False),
                                        ("v4.0.0-rc.1", "= 4.0.0", True), ("4.0.0+build.5", ">= 4.0.0", True),
                                        ("4.0.0-beta1", "!= 4.0.0", True)):
            with self.subTest(version=version, versions=versions):
                self.assertEqual(not held, hold_check(support.provider_dependency(new=version),
                                                      hold(versions=versions))[1])

    def test_every_hold_that_covers_the_version(self):
        holds = (hold(versions="= 3.117.1", reason="a"), hold(versions=">= 3.117.0, < 4.0.0", reason="b"),
                 hold(versions=">= 5.0.0", reason="c"))
        self.assertEqual(("hold", False, "held by this repository: `= 3.117.1` and `>= 3.117.0, < 4.0.0`",
                          [{"name": "hashicorp/azurerm", "versions": "= 3.117.1", "reason": "a"},
                           {"name": "hashicorp/azurerm", "versions": ">= 3.117.0, < 4.0.0", "reason": "b"}]),
                         hold_check(support.provider_dependency(new="3.117.1"), *holds))

    def test_a_pessimistic_constraint_is_shown_as_read(self):
        for versions, reading in (("~> 3.117", "`~> 3.117` (`>= 3.117.0, < 4.0.0`)"),
                                  ("~> 3.117.1", "`~> 3.117.1` (`>= 3.117.1, < 3.118.0`)"),
                                  ("~> 3", "`~> 3` (`>= 3.0.0, < 4.0.0`)"),
                                  (">= 3.0, ~> 3.117", "`>= 3.0, ~> 3.117` (`>= 3.0, >= 3.117.0, < 4.0.0`)")):
            with self.subTest(versions=versions):
                self.assertEqual(f"held by this repository: {reading}",
                                 hold_check(support.provider_dependency(new="3.117.1"), hold(versions=versions))[2])

    def test_a_held_dependency_refuses_a_grouped_pull_request(self):
        block = judged([support.provider_dependency(new="3.117.1"),
                        support.provider_dependency(address="registry.terraform.io/hashicorp/azuread")],
                       policy=hold_policy(AZURERM_HOLD))
        self.assertEqual((False, 1, 2, [False, True]),
                         (block["admitted"], block["refused_count"], block["total"],
                          [dependency["admitted"] for dependency in block["dependencies"]]))

    def test_a_held_run_is_not_admitted(self):
        doc, output = decided(support.admission_facts([support.provider_dependency(old="3.116.0", new="3.117.1")]),
                              inputs={})
        self.assertEqual(True, output["admission"]["admitted"])
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"hold": [AZURERM_HOLD]})
        output = decide.decide(doc)
        self.assertEqual([], invariants.check(doc, output))
        self.assertEqual((False, ["admission: not admitted"]),
                         (output["admission"]["admitted"], output["environments"][0]["reasons"]))
        self.assertEqual("admission: not admitted: 1 of 1 dependencies failed", output["notices"][0])


def audited(holds, inventory, document=None):
    doc = document or support.document()
    if inventory is not None:
        doc["dependency_inventory"] = inventory
    return admission.audit(doc, hold_policy(*holds) if holds else settings(), _applying(doc))


def _applying(doc):
    return {"applies": True, "push_run": False} if "admission" in doc else admission.NOT_APPLYING


AUDIT = "dependabot-admission-yml: the hold on "


class AuditTest(unittest.TestCase):
    def test_nothing_without_holds_or_an_inventory(self):
        self.assertEqual([], audited([], support.inventory()))
        self.assertEqual([], audited([AZURERM_HOLD], None))

    def test_a_hold_that_matches_nothing(self):
        self.assertEqual([f"{AUDIT}provider 'hashicorp/azurem' matches nothing in the repository: no committed lock "
                          "file, required_providers entry or module block names it."],
                         audited([hold("hashicorp/azurem")], support.inventory()))
        self.assertEqual([f"{AUDIT}module 'github.com/o/r' matches nothing in the repository: no committed lock "
                          "file, required_providers entry or module block names it."],
                         audited([hold("github.com/o/r", kind="module")], support.inventory()))

    def test_what_a_hold_matches(self):
        through_a_lock = support.inventory(providers=[])
        through_an_entry = support.inventory(locks=[])
        for inventory in (through_a_lock, through_an_entry):
            with self.subTest(inventory=inventory):
                self.assertEqual([], audited([AZURERM_HOLD], inventory))
        modules = support.inventory(modules=[
            support.inventory_module(),
            support.inventory_module(path="main/net.tf", source_kind="github", namespace="Example-Org",
                                     name="network.git", provider="", version="v1.0.0")])
        self.assertEqual([], audited([hold("azure/naming/azurerm", ">= 0.5.0", "r", "module"),
                                      hold("github.com/example-org/network", ">= 2.0.0", "r", "module")], modules))

    def test_a_module_of_another_source_kind_matches_no_hold(self):
        other = support.inventory(modules=[support.inventory_module(source_kind="other", namespace="", name="",
                                                                    provider="", version="")])
        self.assertEqual([f"{AUDIT}module 'Azure/naming/azurerm' matches nothing in the repository: no committed "
                          "lock file, required_providers entry or module block names it."],
                         audited([hold("Azure/naming/azurerm", ">= 0.5.0", "r", "module")], other))

    def test_another_host_or_source_kind_matches_no_hold(self):
        elsewhere = support.inventory(locks=[{"path": "a/.terraform.lock.hcl",
                                              "providers": {"registry.example.com/hashicorp/azurerm": "3.117.1"}}],
                                      providers=[{"path": "a/v.tf", "address": "registry.example.com/hashicorp/azurerm"}])
        self.assertEqual([f"{AUDIT}provider 'hashicorp/azurerm' matches nothing in the repository: no committed lock "
                          "file, required_providers entry or module block names it."],
                         audited([AZURERM_HOLD], elsewhere))
        other = support.inventory(modules=[support.inventory_module(source_kind="other", namespace="o", name="r",
                                                                    provider="", version="v1.0.0")])
        self.assertEqual([f"{AUDIT}module 'github.com/o/r' matches nothing in the repository: no committed lock file, "
                          "required_providers entry or module block names it."],
                         audited([hold("github.com/o/r", ">= 1.0.0", "r", "module")], other))

    def test_a_lock_that_records_a_held_version(self):
        locks = [{"path": f"envs/{env}/.terraform.lock.hcl",
                  "providers": {"registry.terraform.io/hashicorp/azurerm": version}}
                 for env, version in (("dev", "3.117.1"), ("prod", "3.117.1"), ("test", "3.117.0"), ("x", "4.81.0"))]
        self.assertEqual(
            [f"{AUDIT}provider 'hashicorp/azurerm' covers 3.117.1, which envs/dev/.terraform.lock.hcl and "
             "envs/prod/.terraform.lock.hcl record; a hold names the versions Dependabot may not bring in.",
             f"{AUDIT}provider 'hashicorp/azurerm' covers 3.117.0, which envs/test/.terraform.lock.hcl records; a hold "
             "names the versions Dependabot may not bring in."],
            audited([AZURERM_HOLD], support.inventory(locks=locks)))
        three = [{"path": f"{name}/.terraform.lock.hcl", "providers": {"registry.terraform.io/hashicorp/azurerm": "3.117.1"}}
                 for name in ("a", "b", "c")]
        self.assertEqual([f"{AUDIT}provider 'hashicorp/azurerm' covers 3.117.1, which a/.terraform.lock.hcl, "
                          "b/.terraform.lock.hcl and c/.terraform.lock.hcl record; a hold names the versions Dependabot "
                          "may not bring in."], audited([AZURERM_HOLD], support.inventory(locks=three)))

    def test_an_inverted_range(self):
        self.assertEqual([f"{AUDIT}provider 'hashicorp/azurerm' covers 3.116.0, which envs/prod/.terraform.lock.hcl "
                          "records; a hold names the versions Dependabot may not bring in."],
                         audited([hold(versions="3.116.0")], support.inventory()))

    def test_a_module_pin_that_records_a_held_version(self):
        modules = [support.inventory_module(path="a.tf", version="0.5.0"),
                   support.inventory_module(path="b.tf", version="0.5.0"),
                   support.inventory_module(path="c.tf", version="~> 0.5"),
                   support.inventory_module(path="d.tf", source_kind="github", namespace="o", name="r", provider="",
                                            version="v3"),
                   support.inventory_module(path="e.tf", source_kind="github", namespace="o", name="r", provider="",
                                            version="v3.1.0")]
        self.assertEqual([f"{AUDIT}module 'Azure/naming/azurerm' covers 0.5.0, which a.tf and b.tf pin; a hold names "
                          "the versions Dependabot may not bring in.",
                          f"{AUDIT}module 'github.com/o/r' covers v3.1.0, which e.tf pins; a hold names the versions "
                          "Dependabot may not bring in."],
                         audited([hold("Azure/naming/azurerm", ">= 0.5.0", "r", "module"),
                                  hold("github.com/o/r", ">= 3.0.0", "r", "module")],
                                 support.inventory(modules=modules)))

    def test_a_judged_pull_request_s_own_dependencies_are_left_out(self):
        doc = support.dependabot_pull_request(support.document(), support.admission_facts(
            [support.provider_dependency(old="3.116.0", new="3.117.1")]))
        locks = [{"path": "envs/prod/.terraform.lock.hcl",
                  "providers": {"registry.terraform.io/hashicorp/azurerm": "3.117.1",
                                "registry.terraform.io/hashicorp/random": "3.9.1"}}]
        self.assertEqual([f"{AUDIT}provider 'hashicorp/random' covers 3.9.1, which envs/prod/.terraform.lock.hcl "
                          "records; a hold names the versions Dependabot may not bring in."],
                         audited([AZURERM_HOLD, hold("hashicorp/random", ">= 3.9.0")],
                                 support.inventory(locks=locks), doc))

    def test_files_that_cannot_be_read(self):
        self.assertEqual(["dependabot-admission-yml: the holds were not audited against 'main/broken.tf', which "
                          "cannot be read."],
                         audited([AZURERM_HOLD], support.inventory(unreadable=["main/broken.tf"])))
        self.assertEqual(["dependabot-admission-yml: the holds were not audited: the repository's committed files "
                          "could not be listed."],
                         audited([hold("hashicorp/azurem")], support.inventory(locks=[], providers=[],
                                                                                available=False)))

    def test_the_audit_warns_in_both_modes(self):
        doc = support.document()
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"hold": [hold("hashicorp/azurem")]})
        doc["dependency_inventory"] = support.inventory()
        output = decide.decide(doc)
        self.assertEqual([], invariants.check(doc, output))
        self.assertEqual(f"{AUDIT}provider 'hashicorp/azurem' matches nothing in the repository: no committed lock "
                         "file, required_providers entry or module block names it.", output["warnings"][-1])
        module = ModuleModeTest().document()
        module["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"hold": [hold("hashicorp/azurem")]})
        module["dependency_inventory"] = support.inventory()
        self.assertEqual(output["warnings"][-1], decide.decide(module)["warnings"][-1])


HELD_FACTS = support.admission_facts([support.provider_dependency(old="3.116.0", new="3.117.1")])


class ReasonTest(unittest.TestCase):
    def test_the_reason_as_the_comment_shows_it(self):
        from dsb_tf_engine import comments
        for text, shown in (("Done!", "Done!"), ("Why?", "Why?"), ("It is.", "It is."), ("x", "x."),
                            (" a\n  < b ", "a &lt; b.")):
            with self.subTest(text=text):
                self.assertEqual(shown, comments._reason(text))


class HoldCommentTest(unittest.TestCase):
    def body(self, facts=HELD_FACTS, *holds):
        doc = support.document(inputs={"add-pr-comment": True})
        support.dependabot_pull_request(doc, facts)
        doc["yaml"]["inputs"]["dependabot-admission-yml"] = support.parsed({"hold": list(holds or [AZURERM_HOLD])})
        doc["run"] = {"id": 4711, "attempt": 2}
        output = decide.decide(doc)
        self.assertEqual([], output["errors"])
        return output["comments"]["heads"][0]["body"]

    def test_the_held_head(self):
        self.assertEqual(
            "### 🚫 Dependabot pull request not admitted\n\n"
            "No Terraform ran. Every dependency a Dependabot pull request changes must pass the admission before any "
            "job runs it ([what the admission checks](https://github.com/dsb-norge/github-actions-terraform/blob/main/"
            "docs/Dependabot-admission.md)).\n\n"
            "| Dependency | Change | Result |\n|---|---|---|\n"
            "| provider `hashicorp/azurerm` | 3.116.0 → 3.117.1 | ❌ held by this repository: `> 3.116.0, < 4.12.0` |\n\n"
            "<details><summary>Files</summary>\n\n"
            "- `envs/env-a/.terraform.lock.hcl`: provider `hashicorp/azurerm`\n\n</details>\n\n"
            "**provider `hashicorp/azurerm` 3.117.1 is held by this repository.** Reason: " + REASON + " When that no "
            "longer applies, remove or narrow the hold on `hashicorp/azurerm` in `dependabot-admission-yml` in the "
            "calling workflow on the default branch, then comment `@dependabot rebase` on this pull request. Until then "
            "leave this pull request open: closing it makes Dependabot skip 3.117.1 even after the hold is lifted. It "
            "counts towards Dependabot's limit of open pull requests (5 by default).", self.body())

    def test_several_holds_give_each_reason(self):
        body = self.body(HELD_FACTS, hold(versions="= 3.117.1", reason="first"),
                         hold("HashiCorp/AzureRM", ">= 3.117.0, < 4.0.0", "second\n  line <!-- x -->"))
        self.assertIn("**provider `hashicorp/azurerm` 3.117.1 is held by this repository.** Reason for `= 3.117.1`: "
                      "first. Reason for `>= 3.117.0, < 4.0.0`: second line &lt;!-- x -->. When that no longer applies, "
                      "remove or narrow the holds on `hashicorp/azurerm` in", body)

    def test_the_last_paragraph_stays_when_another_check_fails(self):
        self.assertNotIn("To run this pull request once", self.body())
        refused = support.admission_facts([support.provider_dependency(old="3.116.0", new="3.117.1", published=NOW)])
        self.assertIn("**To run this pull request once without changing the policy:**", self.body(refused))
        problem = support.admission_facts([support.provider_dependency(old="3.116.0", new="3.117.1")],
                                          [{"path": "x.tf.json", "status": "modified", "kind": "other"}])
        self.assertIn("**To run this pull request once without changing the policy:**", self.body(problem))

    def test_a_version_that_cannot_be_read(self):
        facts = support.admission_facts([support.module_dependency(address="github.com/dsb-norge/r?ref=v2",
                                                                   source_kind="github", namespace="dsb-norge",
                                                                   name="r", old="v1", new="v2")])
        body = self.body(facts, hold("github.com/dsb-norge/r", ">= 2.0.0", "r", "module"))
        self.assertIn("| module `github.com/dsb-norge/r?ref=v2` | v1 → v2 | ❌ held by this repository: `v2` is not a "
                      "version a hold can compare |", body)
        self.assertIn("**module `github.com/dsb-norge/r?ref=v2` v2 is held by this repository.** Reason: r. When that "
                      "no longer applies, remove or narrow the hold on `github.com/dsb-norge/r` in", body)
        self.assertNotIn("To run this pull request once", body)

if __name__ == "__main__":
    unittest.main()
