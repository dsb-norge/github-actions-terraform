"""The admission's facts as the adapter gathers them (docs/Dependabot-admission.md §8).

git, curl, gh and gpg answer from a table; one test runs the real gpg over recorded partner keys, because how
the trust signature is verified is the pitfall P18 records.
"""

import json
import os
import shutil
import subprocess
import unittest

import support
from dsb_tf_engine import admission_facts as facts

REGISTRY = "https://registry.terraform.io/v1"
CURL = ("curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "20", "--retry", "1")
KEYS = json.load(open(os.path.join(support.TESTS_DIR, "admission_keys.json"), encoding="utf-8"))
HC = {"key_id": "34365D9472D7468F", "ascii_armor": "", "trust_signature": ""}


class Tools:
    """Answers {argv: (code, stdout, stderr)}; a prefix tuple ending in '*' matches any longer argv."""

    def __init__(self, answers=None, gpg_verify=0, missing=()):
        self.answers = answers or {}
        self.gpg_verify = gpg_verify
        self.missing = missing
        self.calls = []

    def run(self, argv, stdin=""):
        argv = tuple(argv)
        self.calls.append(argv)
        if argv[0] in self.missing:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        if argv[0] == "gpg":
            return (0, "", "") if "--import" in argv else (self.gpg_verify, "", "")
        if argv in self.answers:
            answer = self.answers[argv]
            return answer if isinstance(answer, tuple) else (0, answer if isinstance(answer, str) else
                                                              json.dumps(answer), "")
        return 1, "", f"unexpected call {argv}"


def curl(path):
    return (*CURL, f"{REGISTRY}/{path}")


def show(revision, path):
    return ("git", "show", f"{revision}:{path}")


DIFF = ("git", "diff", "--raw", "-z", "-M", "HEAD^1", "HEAD")
LS = ("git", "ls-files", "-z", "--", "*.terraform.lock.hcl", ".terraform.lock.hcl")
SHA = "0" * 40


def raw(*entries):
    """git diff --raw -z output: (old mode, new mode, status, path[, new path])."""
    out = ""
    for entry in entries:
        old_mode, new_mode, status, *paths = entry
        out += f":{old_mode} {new_mode} {SHA} {SHA} {status}\0" + "".join(f"{path}\0" for path in paths)
    return out


class RunTest(unittest.TestCase):
    def test_failures_name_the_fact(self):
        with self.assertRaises(facts.FactError) as caught:
            facts._run(Tools(missing=("git",)), ("git", "x"), "the thing")
        self.assertEqual("the thing: 'git' cannot be run on this runner: [Errno 2] No such file or directory: 'git'",
                         str(caught.exception))
        with self.assertRaises(facts.FactError) as caught:
            facts._run(Tools({("git", "x"): (1, "out", "")}), ("git", "x"), "the thing")
        self.assertEqual("the thing: out", str(caught.exception))
        with self.assertRaises(facts.FactError) as caught:
            facts._run(Tools({("git", "x"): (2, "out", " the error " + "x" * 400)}), ("git", "x"), "the thing")
        self.assertEqual("the thing: the error " + "x" * 290, str(caught.exception))
        self.assertEqual("fine", facts._run(Tools({("git", "x"): (0, "fine", "noise")}), ("git", "x"), "it"))

    def test_answers(self):
        with self.assertRaises(facts.FactError) as caught:
            facts._json("nope", "the answer")
        self.assertEqual("the answer: the answer is not JSON", str(caught.exception))
        self.assertEqual("x", facts._field({"k": "x"}, "k", str, "it"))
        for answer in ({}, {"k": 5}, {"k": True}, [], None):
            with self.subTest(answer=answer):
                with self.assertRaises(facts.FactError) as caught:
                    facts._field(answer, "k", str, "it")
                self.assertEqual("it: the answer has no 'k'", str(caught.exception))
        self.assertEqual(5, facts._field({"k": 5}, "k", int, "it"))
        self.assertEqual(support.NOW, facts._epoch("2026-09-21T14:13:20Z", "it"))
        self.assertEqual(support.NOW, facts._epoch("2026-09-21T16:13:20+02:00", "it"))
        with self.assertRaises(facts.FactError) as caught:
            facts._epoch("yesterday", "it")
        self.assertEqual("it: 'yesterday' is not a time", str(caught.exception))


class ChangeTest(unittest.TestCase):
    def test_the_statuses(self):
        tools = Tools({DIFF: raw(("100644", "100644", "M", "a.tf"), ("000000", "100644", "A", "b.tf"),
                                 ("100644", "000000", "D", "c.tf"), ("100644", "100644", "R087", "d.tf", "e.tf"),
                                 ("100644", "100644", "C100", "f.tf", "g.tf"), ("100644", "120000", "T", "h"),
                                 ("100644", "100755", "M", "i.tf"), ("100644", "100644", "U", "j.tf"))})
        self.assertEqual([("a.tf", "modified", "a.tf"), ("b.tf", "added", "b.tf"), ("c.tf", "removed", "c.tf"),
                          ("e.tf", "renamed", "d.tf"), ("g.tf", "added", "f.tf"), ("h", "changed", "h"),
                          ("i.tf", "changed", "i.tf"), ("j.tf", "changed", "j.tf")], facts.changed_files(tools))
        self.assertEqual([], facts.changed_files(Tools({DIFF: ""})))

    def test_lock_blocks(self):
        text = ('# This file is maintained automatically by "terraform init".\n\n'
                'provider "registry.terraform.io/hashicorp/azurerm" {\n  version     = "4.42.0"\n'
                '  constraints = ">= 4.0.0"\n  hashes = [\n    "h1:abc=",\n    "zh:def",\n  ]\n}\n\n'
                'provider "registry.terraform.io/hashicorp/random" {\n  version = "3.7.2"\n  hashes = []\n}\n')
        self.assertEqual({"registry.terraform.io/hashicorp/azurerm": {"version": "4.42.0", "constraints": ">= 4.0.0",
                                                                      "hashes": ["h1:abc=", "zh:def"]},
                          "registry.terraform.io/hashicorp/random": {"version": "3.7.2", "constraints": None,
                                                                     "hashes": []}},
                         facts.parse_lock_blocks(text))
        self.assertEqual({}, facts.parse_lock_blocks("  \n"))
        self.assertIsNone(facts.parse_lock_blocks("not a lock"))
        self.assertIsNone(facts.parse_lock_blocks('provider "x" {\n  constraints = "1"\n}\n'))

    def test_line_changes(self):
        self.assertEqual([{"old": "b", "new": "B"}, {"old": None, "new": "x"}, {"old": "d", "new": None}],
                         facts.line_changes("a\nb\nc\nd\ne\n", "a\nB\nc\nx\ne\n")[:1]
                         + facts.line_changes("a\nc\n", "a\nx\nc\n") + facts.line_changes("a\nd\nc\n", "a\nc\n"))
        self.assertEqual([{"old": "b", "new": "X"}, {"old": "c", "new": None}],
                         facts.line_changes("a\nb\nc\nz\n", "a\nX\nz\n"))
        self.assertEqual([{"old": "b", "new": "X"}, {"old": None, "new": "Y"}],
                         facts.line_changes("a\nb\nz\n", "a\nX\nY\nz\n"))
        self.assertEqual([], facts.line_changes("a\n", "a\n"))


TF = '''terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = { source = "hashicorp/random", version = "3.7.2" }
    tags = { name = "x" }
  }
}

# a { brace in a comment
/* and
   another } in a block comment */
locals {
  text = "a { brace } in a string"
  doc  = <<-EOT
    { not a block
  EOT
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.3"
}

module "local" {
  source = "./modules/x"
}

module "git" {
  source = "github.com/dsb-norge/x?ref=v1.2.0"
}
'''


class LinesTest(unittest.TestCase):
    def test_every_version_and_source_line_names_its_dependency(self):
        self.assertEqual({4: ("provider", "azurerm", "hashicorp/azurerm", "~> 4.0"),
                          5: ("provider", "azurerm", "hashicorp/azurerm", "~> 4.0"),
                          7: ("provider", "random", "hashicorp/random", "3.7.2"),
                          23: ("module", "naming", "Azure/naming/azurerm", "0.4.3"),
                          24: ("module", "naming", "Azure/naming/azurerm", "0.4.3"),
                          28: ("module", "local", "./modules/x", ""),
                          32: ("module", "git", "github.com/dsb-norge/x?ref=v1.2.0", "")},
                         facts.dependency_lines(TF))

    def test_an_unbalanced_brace_closes_nothing(self):
        self.assertEqual({}, facts.dependency_lines("}\n}\n"))
        self.assertEqual({2: ("module", "m", "", "1")}, facts.dependency_lines('module "m" {\n  version = "1"\n}\n'))

    def test_sources(self):
        cases = {"github.com/dsb-norge/x?ref=v1.2.0": ("github", "dsb-norge", "x", "v1.2.0"),
                 "github.com/dsb-norge/x.git//sub?ref=v1": ("github", "dsb-norge", "x", "v1"),
                 "git::https://github.com/o/r.git?depth=1&ref=v2": ("github", "o", "r", "v2"),
                 "git::ssh://git@github.com/o/r.git?ref=v3": ("github", "o", "r", "v3"),
                 "git@github.com:o/r.git": ("github", "o", "r", ""),
                 "Azure/naming/azurerm": ("registry", "Azure", "naming", ""),
                 "registry.terraform.io/Azure/naming/azurerm": ("registry", "Azure", "naming", ""),
                 "Azure/avm-res-network-firewallpolicy/azurerm//modules/rule_collection_groups":
                     ("registry", "Azure", "avm-res-network-firewallpolicy", ""),
                 "registry.terraform.io/Azure/naming/azurerm//modules/x": ("registry", "Azure", "naming", ""),
                 "Azure/naming/azurerm//modules/x?ref=v1": ("other", "", "", ""),
                 "./modules/x": ("other", "", "", ""),
                 "s3::https://bucket/x.zip": ("other", "", "", ""),
                 "app.terraform.io/o/x/aws": ("other", "", "", "")}
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(expected, facts.classify_source(source))

    def test_provider_addresses(self):
        self.assertEqual("registry.terraform.io/hashicorp/azurerm", facts.provider_address("hashicorp/azurerm"))
        self.assertEqual("registry.example.com/o/x", facts.provider_address("registry.example.com/o/x"))
        self.assertEqual("azurerm", facts.provider_address("azurerm"))


class RegistryTest(unittest.TestCase):
    def test_provider_versions(self):
        tools = Tools({curl("providers/hashicorp/azurerm/versions"):
                       {"versions": [{"version": "4.0.0"}, {"version": 5}, "x", {"version": "4.1.0"}]}})
        self.assertEqual(["4.0.0", "4.1.0"], facts.provider_versions(tools, "registry.terraform.io/hashicorp/azurerm"))
        for answer in ({}, {"versions": "x"}, []):
            with self.subTest(answer=answer):
                with self.assertRaises(facts.FactError) as caught:
                    facts.provider_versions(Tools({curl("providers/hashicorp/azurerm/versions"): answer}),
                                            "registry.terraform.io/hashicorp/azurerm")
                self.assertEqual("the versions of provider hashicorp/azurerm: the answer has no 'versions'",
                                 str(caught.exception))

    def test_module_versions(self):
        path = "modules/Azure/naming/azurerm/versions"
        tools = Tools({curl(path): {"modules": [{"versions": [{"version": "0.4.3"}, {}, 7, {"version": "0.4.4"}]}]}})
        self.assertEqual(["0.4.3", "0.4.4"], facts.module_versions(tools, "Azure", "naming", "azurerm"))
        self.assertEqual([], facts.module_versions(Tools({curl(path): {"modules": [{}]}}), "Azure", "naming", "azurerm"))
        for answer in ({}, {"modules": []}, {"modules": "x"}, {"modules": ["x"]}, []):
            with self.subTest(answer=answer):
                with self.assertRaises(facts.FactError) as caught:
                    facts.module_versions(Tools({curl(path): answer}), "Azure", "naming", "azurerm")
                self.assertEqual("the versions of module Azure/naming/azurerm: the answer has no 'modules'",
                                 str(caught.exception))


def download(keys, shasums_url="https://releases.example/SHA256SUMS"):
    return {"signing_keys": {"gpg_public_keys": keys}, "shasums_url": shasums_url}


class SigningTest(unittest.TestCase):
    def test_hashicorp_s_own_key(self):
        self.assertEqual((True, "signed by HashiCorp"), facts._vouched(Tools(), HC))

    def test_a_key_without_a_trust_signature_is_self_signed(self):
        for key in ({"key_id": "X"}, {"key_id": "X", "trust_signature": ""}, {"key_id": "X", "trust_signature": None}):
            with self.subTest(key=key):
                self.assertEqual((False, "self-signed"), facts._vouched(Tools(), key))

    def test_a_partner_key_is_verified_with_gpg(self):
        key = KEYS["power-platform-4.1.0"]
        tools = Tools(gpg_verify=0)
        self.assertEqual((True, "signed by a HashiCorp partner"), facts._vouched(tools, key))
        self.assertEqual([("gpg", "--import"), ("gpg", "--verify")],
                         [(call[0], "--import" if "--import" in call else "--verify") for call in tools.calls])
        self.assertEqual((False, "self-signed (a trust signature that does not verify)"),
                         facts._vouched(Tools(gpg_verify=1), key))
        self.assertEqual((False, "self-signed (an unreadable key)"),
                         facts._vouched(Tools(), {"key_id": "X", "trust_signature": "sig",
                                                  "ascii_armor": "-----BEGIN-----\n\nnot*base64\n-----END-----"}))

    def test_a_partner_key_that_gpg_cannot_import(self):
        class Refusing(Tools):
            def run(self, argv, stdin=""):
                return (2, "", "gpg: no valid OpenPGP data found") if "--import" in argv else super().run(argv, stdin)
        with self.assertRaises(facts.FactError) as caught:
            facts._vouched(Refusing(), KEYS["azapi-2.13.0"])
        self.assertEqual("HashiCorp's partner key: gpg: no valid OpenPGP data found", str(caught.exception))

    @unittest.skipUnless(shutil.which("gpg"), "gpg is not installed")
    def test_the_real_gpg_verifies_the_de_armoured_key(self):
        class Real:
            def run(self, argv, stdin=""):
                done = subprocess.run(argv, input=stdin, capture_output=True, text=True, check=False)
                return done.returncode, done.stdout, done.stderr
        for name in ("power-platform-4.1.0", "azapi-2.13.0"):
            with self.subTest(key=name):
                self.assertEqual((True, "signed by a HashiCorp partner"), facts._vouched(Real(), KEYS[name]))
        swapped = {**KEYS["power-platform-4.1.0"], "trust_signature": KEYS["azapi-2.13.0"]["trust_signature"]}
        self.assertEqual((False, "self-signed (a trust signature that does not verify)"), facts._vouched(Real(), swapped))

    def test_the_download_answer(self):
        path = "providers/hashicorp/azurerm/4.42.0/download/linux/amd64"
        keys, url = facts._signing(Tools({curl(path): download([HC])}), "hashicorp", "azurerm", "4.42.0")
        self.assertEqual(([HC], "https://releases.example/SHA256SUMS"), (keys, url))
        for answer in ({}, {"signing_keys": {}}, download([]), download(["x"]), download([{"key_id": 5}]),
                       {"signing_keys": "x"}, []):
            with self.subTest(answer=answer):
                with self.assertRaises(facts.FactError) as caught:
                    facts._signing(Tools({curl(path): answer}), "hashicorp", "azurerm", "4.42.0")
                self.assertEqual("the signing keys of provider hashicorp/azurerm 4.42.0: the answer has no "
                                 "'signing_keys'", str(caught.exception))
        with self.assertRaises(facts.FactError) as caught:
            facts._signing(Tools({curl(path): download([HC], None)}), "hashicorp", "azurerm", "4.42.0")
        self.assertEqual("the signing keys of provider hashicorp/azurerm 4.42.0: the answer has no 'shasums_url'",
                         str(caught.exception))


def provider_answers(new_key=HC, old_key=HC, published="2026-09-11T14:13:20Z", sums="aa  x.zip\n\nbb  y.zip\n"):
    base = "providers/hashicorp/azurerm"
    return {curl(f"{base}/4.42.0"): {"published_at": published},
            curl(f"{base}/4.41.0/download/linux/amd64"): download([old_key]),
            curl(f"{base}/4.42.0/download/linux/amd64"): download([new_key]),
            (*CURL, "https://releases.example/SHA256SUMS"): sums}


class ProviderFactsTest(unittest.TestCase):
    def test_the_facts(self):
        tools = Tools(provider_answers())
        self.assertEqual({"published": support.NOW - 10 * support.DAY, "keys_from": ["34365D9472D7468F"],
                          "keys_to": ["34365D9472D7468F"], "vouched": True,
                          "class_from": "signed by HashiCorp", "class_to": "signed by HashiCorp", "zh": ["aa"],
                          "shasums": ["aa", "bb"]},
                         facts.provider_facts(tools, "registry.terraform.io/hashicorp/azurerm", "4.41.0", "4.42.0",
                                              ["aa"]))

    def test_no_hashes_no_checksums(self):
        tools = Tools(provider_answers(new_key={"key_id": "NEW"}, old_key={"key_id": "OLD", "trust_signature": "s",
                                                                             "ascii_armor": KEYS["azapi-2.13.0"]["ascii_armor"]}))
        result = facts.provider_facts(tools, "registry.terraform.io/hashicorp/azurerm", "4.41.0", "4.42.0", [])
        self.assertEqual((["OLD"], ["NEW"], False, "signed by a HashiCorp partner", "self-signed", [], []),
                         (result["keys_from"], result["keys_to"], result["vouched"], result["class_from"],
                          result["class_to"], result["zh"], result["shasums"]))
        self.assertNotIn((*CURL, "https://releases.example/SHA256SUMS"), tools.calls)


class ModuleFactsTest(unittest.TestCase):
    def test_a_registry_module(self):
        tools = Tools({curl("modules/Azure/naming/azurerm/0.4.4"): {"published_at": "2026-09-20T14:13:20Z"}})
        self.assertEqual({"published": support.NOW - support.DAY},
                         facts.module_facts(tools, "registry", "Azure", "naming", "azurerm", "0.4.4"))

    def test_a_github_release(self):
        release = ("gh", "api", "repos/dsb-norge/x/releases/tags/v1.3.0")
        tools = Tools({release: {"published_at": "2026-09-21T14:13:20Z"}})
        self.assertEqual({"published": support.NOW}, facts.module_facts(tools, "github", "dsb-norge", "x", "", "v1.3.0"))
        tools = Tools({release: (1, "", "gh: Not Found (HTTP 404)")})
        self.assertEqual({"published": None}, facts.module_facts(tools, "github", "dsb-norge", "x", "", "v1.3.0"))
        with self.assertRaises(facts.FactError) as caught:
            facts.module_facts(Tools({release: (1, "", "gh: Bad credentials (HTTP 401)")}), "github", "dsb-norge", "x",
                               "", "v1.3.0")
        self.assertEqual("the release of dsb-norge/x v1.3.0: gh: Bad credentials (HTTP 401)", str(caught.exception))
        with self.assertRaises(facts.FactError) as caught:
            facts.module_facts(Tools(missing=("gh",)), "github", "dsb-norge", "x", "", "v1.3.0")
        self.assertEqual("the release of dsb-norge/x v1.3.0: 'gh' cannot be run on this runner: [Errno 2] No such "
                         "file or directory: 'gh'", str(caught.exception))

    def test_another_kind_has_no_publication(self):
        self.assertEqual({"published": None}, facts.module_facts(Tools(), "other", "", "", "", "x"))

    def test_the_exact_version_a_module_selects(self):
        path = curl("modules/Azure/naming/azurerm/versions")
        tools = Tools({path: {"modules": [{"versions": [{"version": "0.4.3"}, {"version": "0.4.9"}]}]}})
        self.assertEqual("0.4.3", facts._module_version(tools, "registry", "Azure", "naming", "azurerm", "0.4.3"))
        self.assertEqual("1.2.3", facts._module_version(tools, "registry", "Azure", "naming", "azurerm", "= v1.2.3"))
        self.assertEqual("0.4.9", facts._module_version(tools, "registry", "Azure", "naming", "azurerm", "~> 0.4"))
        self.assertEqual("> 9.0", facts._module_version(tools, "registry", "Azure", "naming", "azurerm", "> 9.0"))
        self.assertEqual("~> 1", facts._module_version(Tools(), "github", "o", "r", "", "~> 1"))


LOCK_OLD = ('provider "registry.terraform.io/hashicorp/azurerm" {\n  version = "4.41.0"\n  hashes = ["zh:aa"]\n}\n'
            'provider "registry.terraform.io/hashicorp/random" {\n  version = "3.7.2"\n  hashes = []\n}\n')
LOCK_NEW = ('provider "registry.terraform.io/hashicorp/azurerm" {\n  version = "4.42.0"\n  hashes = ["h1:x", "zh:aa"]\n}\n'
            'provider "registry.terraform.io/hashicorp/random" {\n  version = "3.7.2"\n  hashes = []\n}\n')
MODULES_OLD = 'module "naming" {\n  source  = "Azure/naming/azurerm"\n  version = "0.4.3"\n}\n' \
              'module "git" {\n  source = "github.com/dsb-norge/x?ref=v1.2.0"\n}\n'
MODULES_NEW = MODULES_OLD.replace('"0.4.3"', '"0.4.4"').replace("v1.2.0", "v1.3.0")
VERSIONS_OLD = 'terraform {\n  required_providers {\n    azapi = { source = "azure/azapi", version = "~> 2.6.0" }\n  }\n}\n'
VERSIONS_NEW = VERSIONS_OLD.replace("~> 2.6.0", "~> 2.12")


def gather_answers():
    answers = {LS: "envs/env-a/.terraform.lock.hcl\0",
               DIFF: raw(("100644", "100644", "M", "envs/env-a/.terraform.lock.hcl"),
                         ("100644", "100644", "M", "main/modules.tf"), ("100644", "100644", "M", "main/versions.tf"),
                         ("100644", "100644", "M", "envs/env-a/versions.tf"), ("100644", "100644", "M", "README.md"),
                         ("000000", "100644", "A", "main/new.tf")),
               show("HEAD^1", "envs/env-a/.terraform.lock.hcl"): LOCK_OLD,
               show("HEAD", "envs/env-a/.terraform.lock.hcl"): LOCK_NEW,
               show("HEAD^1", "main/modules.tf"): MODULES_OLD, show("HEAD", "main/modules.tf"): MODULES_NEW,
               show("HEAD^1", "main/versions.tf"): VERSIONS_OLD, show("HEAD", "main/versions.tf"): VERSIONS_NEW,
               show("HEAD^1", "envs/env-a/versions.tf"): VERSIONS_OLD.replace("azapi", "azurerm").replace(
                   "azure/azurerm", "hashicorp/azurerm"),
               show("HEAD", "envs/env-a/versions.tf"): VERSIONS_NEW.replace("azapi", "azurerm").replace(
                   "azure/azurerm", "hashicorp/azurerm"),
               curl("providers/azure/azapi/versions"): {"versions": [{"version": v} for v in
                                                                     ("2.6.1", "2.12.0", "2.13.0", "3.0.0")]},
               curl("providers/azure/azapi/2.13.0"): {"published_at": "2026-09-11T14:13:20Z"},
               curl("providers/azure/azapi/2.6.1/download/linux/amd64"): download([{"key_id": "AZ"}]),
               curl("providers/azure/azapi/2.13.0/download/linux/amd64"): download([{"key_id": "AZ"}]),
               curl("modules/Azure/naming/azurerm/0.4.4"): {"published_at": "2026-09-11T14:13:20Z"},
               ("gh", "api", "repos/dsb-norge/x/releases/tags/v1.3.0"): (1, "", "HTTP 404"),
               **provider_answers()}
    return answers


class GatherTest(unittest.TestCase):
    def test_everything_a_dependabot_pull_request_changes(self):
        tools = Tools(gather_answers())
        gathered = facts.gather(tools, now=support.NOW)
        self.assertEqual(support.NOW, gathered["now"])
        self.assertEqual({"envs/env-a": True}, gathered["locks"])
        self.assertEqual([("envs/env-a/.terraform.lock.hcl", "modified", "lock"), ("main/modules.tf", "modified", "tf"),
                          ("main/versions.tf", "modified", "tf"), ("envs/env-a/versions.tf", "modified", "tf"),
                          ("README.md", "modified", "other"), ("main/new.tf", "added", "other")],
                         [(item["path"], item["status"], item["kind"]) for item in gathered["files"]])
        self.assertEqual([{"old": '  version = "0.4.3"', "new": '  version = "0.4.4"'},
                          {"old": '  source = "github.com/dsb-norge/x?ref=v1.2.0"',
                           "new": '  source = "github.com/dsb-norge/x?ref=v1.3.0"'}], gathered["files"][1]["lines"])
        self.assertEqual("4.42.0", gathered["files"][0]["after"]["registry.terraform.io/hashicorp/azurerm"]["version"])
        self.assertEqual([("module", "Azure/naming/azurerm", "0.4.3", "0.4.4", ["main/modules.tf"]),
                          ("module", "github.com/dsb-norge/x?ref=v1.3.0", "v1.2.0", "v1.3.0", ["main/modules.tf"]),
                          ("provider", "registry.terraform.io/azure/azapi", "2.6.1", "2.13.0", ["main/versions.tf"]),
                          ("provider", "registry.terraform.io/hashicorp/azurerm", "4.41.0", "4.42.0",
                           ["envs/env-a/.terraform.lock.hcl"])],
                         [(d["kind"], d["address"], d["from"], d["to"], d["files"]) for d in gathered["dependencies"]])
        naming, git, azapi, azurerm = gathered["dependencies"]
        self.assertEqual(("registry", "Azure", "naming", {"published": support.NOW - 10 * support.DAY}),
                         (naming["source_kind"], naming["namespace"], naming["name"], naming["facts"]))
        self.assertEqual(("github", "dsb-norge", "x", {"published": None}),
                         (git["source_kind"], git["namespace"], git["name"], git["facts"]))
        self.assertEqual((False, [], []), (azapi["locked"], azapi["facts"]["zh"], azapi["facts"]["shasums"]))
        self.assertEqual((True, ["aa"], ["aa", "bb"]), (azurerm["locked"], azurerm["facts"]["zh"],
                                                         azurerm["facts"]["shasums"]))
        document = support.dependabot_pull_request(support.document(), gathered)
        from dsb_tf_engine import model
        model.check(document)

    def test_the_same_dependency_in_several_files_is_one(self):
        answers = {LS: "a/.terraform.lock.hcl\0b/.terraform.lock.hcl\0",
                   DIFF: raw(("100644", "100644", "M", "a/.terraform.lock.hcl"),
                             ("100644", "100644", "M", "b/.terraform.lock.hcl")),
                   **{show(rev, f"{d}/.terraform.lock.hcl"): text for d in "ab"
                      for rev, text in (("HEAD^1", LOCK_OLD), ("HEAD", LOCK_NEW))}, **provider_answers()}
        gathered = facts.gather(Tools(answers), now=1)
        self.assertEqual([["a/.terraform.lock.hcl", "b/.terraform.lock.hcl"]],
                         [d["files"] for d in gathered["dependencies"]])

    def test_a_registry_module_with_a_subdirectory_is_its_package(self):
        old = 'module "rules" {\n  source  = "Azure/naming/azurerm//modules/rules"\n  version = "0.4.3"\n}\n'
        answers = {LS: "", DIFF: raw(("100644", "100644", "M", "main/rules.tf")),
                   show("HEAD^1", "main/rules.tf"): old, show("HEAD", "main/rules.tf"): old.replace("0.4.3", "0.4.4"),
                   curl("modules/Azure/naming/azurerm/0.4.4"): {"published_at": "2026-09-11T14:13:20Z"}}
        gathered = facts.gather(Tools(answers), now=support.NOW)
        self.assertEqual([{"kind": "module", "address": "Azure/naming/azurerm//modules/rules", "from": "0.4.3",
                           "to": "0.4.4", "files": ["main/rules.tf"], "source_kind": "registry",
                           "namespace": "Azure", "name": "naming",
                           "facts": {"published": support.NOW - 10 * support.DAY}}], gathered["dependencies"])

    def test_a_provider_on_another_host_asks_nothing(self):
        old, new = ('provider "registry.example.com/o/x" {\n  version = "1.0.0"\n  hashes = []\n}\n',
                    'provider "registry.example.com/o/x" {\n  version = "1.1.0"\n  hashes = []\n}\n')
        answers = {LS: ".terraform.lock.hcl\0", DIFF: raw(("100644", "100644", "M", ".terraform.lock.hcl")),
                   show("HEAD^1", ".terraform.lock.hcl"): old, show("HEAD", ".terraform.lock.hcl"): new}
        gathered = facts.gather(Tools(answers), now=1)
        self.assertEqual({"published": None, "keys_from": [], "keys_to": [], "vouched": False, "class_from": "",
                          "class_to": "", "zh": [], "shasums": []}, gathered["dependencies"][0]["facts"])
        self.assertEqual({".": True}, gathered["locks"])

    def test_unreadable_locks_and_unrelated_lines_gather_no_dependency(self):
        answers = {LS: "", DIFF: raw(("100644", "100644", "M", "l/.terraform.lock.hcl"), ("100644", "100644", "M", "m.tf")),
                   show("HEAD^1", "l/.terraform.lock.hcl"): "garbage", show("HEAD", "l/.terraform.lock.hcl"): LOCK_NEW,
                   show("HEAD^1", "m.tf"): 'module "a" {\n  source = "x/y/z"\n  version = "1"\n}\nlocals { a = 1 }\n',
                   show("HEAD", "m.tf"): 'module "b" {\n  source = "x/y/z"\n  version = "2"\n}\nlocals { a = 2 }\n'
                                         '# added\n'}
        gathered = facts.gather(Tools(answers), now=1)
        self.assertEqual(([], None), (gathered["dependencies"], gathered["files"][0]["before"]))
        self.assertEqual({}, gathered["locks"])

    def test_the_time_of_the_run(self):
        gathered = facts.gather(Tools({LS: "", DIFF: ""}))
        self.assertGreater(gathered["now"], support.NOW - 1)

    def test_a_fact_that_cannot_be_gathered(self):
        answers = gather_answers()
        del answers[curl("providers/azure/azapi/versions")]
        with self.assertRaises(facts.FactError) as caught:
            facts.gather(Tools(answers), now=1)
        self.assertEqual("the versions of provider azure/azapi: unexpected call "
                         f"{curl('providers/azure/azapi/versions')}", str(caught.exception))



class UnchangedResolutionTest(unittest.TestCase):
    def test_a_constraint_that_resolves_to_the_same_version_is_no_dependency(self):
        old = 'terraform {\n  required_providers {\n    azapi = { source = "azure/azapi", version = "~> 2.6" }\n  }\n}\n'
        answers = {LS: "", DIFF: raw(("100644", "100644", "M", "v.tf")), show("HEAD^1", "v.tf"): old,
                   show("HEAD", "v.tf"): old.replace("~> 2.6", "~> 2.12"),
                   curl("providers/azure/azapi/versions"): {"versions": [{"version": "2.6.1"}, {"version": "2.13.0"}]}}
        self.assertEqual([], facts.gather(Tools(answers), now=1)["dependencies"])


class EdgeTest(unittest.TestCase):
    """The cases the mutation gate asked for."""

    def test_a_header_after_a_comment_or_heredoc_on_its_line(self):
        text = ('/* a\n   b */ module "m" {\n  version = "1"\n}\n'
                'locals { x = <<EOT\n{ text\nEOT\n}\nmodule "n" {\n  version = "2"\n}\n'
                'module "o" { # trailing } comment\n  version = "3"\n}\n')
        self.assertEqual({3: ("module", "m", "", "1"), 10: ("module", "n", "", "2"), 13: ("module", "o", "", "3")},
                         facts.dependency_lines(text))

    def test_two_adjacent_changed_lines_each_name_their_dependency(self):
        old = ('terraform {\n  required_providers {\n    a = { source = "x/a", version = "~> 1.0.0" }\n'
               '    b = { source = "x/b", version = "~> 2.0.0" }\n  }\n}\n')
        new = old.replace("~> 1.0.0", "~> 1.1.0").replace("~> 2.0.0", "~> 2.1.0")
        tools = Tools({curl("providers/x/a/versions"): {"versions": [{"version": "1.0.5"}, {"version": "1.1.2"}]},
                       curl("providers/x/b/versions"): {"versions": [{"version": "2.0.9"}, {"version": "2.1.0"}]}})
        dependencies = {}
        self.assertEqual([], facts._tf_dependencies(tools, "v.tf", old, new, set(), dependencies))
        self.assertEqual([("registry.terraform.io/x/a", "1.0.5", "1.1.2"), ("registry.terraform.io/x/b", "2.0.9", "2.1.0")],
                         [(d["address"], d["from"], d["to"]) for d in dependencies.values()])

    def test_a_version_no_dependency_explains_is_reported(self):
        old = 'provider "azurerm" {\n  version = "~> 2.0"\n}\nhelm_release {\n  version = "1"\n}\n'
        new = old.replace("~> 2.0", "~> 3.0").replace('"1"', '"2"')
        dependencies = {}
        self.assertEqual(['  version = "~> 3.0"', '  version = "2"'],
                         facts._tf_dependencies(Tools(), "p.tf", old, new, set(), dependencies))
        self.assertEqual({}, dependencies)
        self.assertEqual([], facts._tf_dependencies(Tools(), "p.tf", "a = 1\n", "a = 2\n", set(), {}))

    def test_a_github_error_is_shortened(self):
        release = ("gh", "api", "repos/o/r/releases/tags/v1")
        with self.assertRaises(facts.FactError) as caught:
            facts.module_facts(Tools({release: (1, "", " " + "e" * 400)}), "github", "o", "r", "", "v1")
        self.assertEqual("the release of o/r v1: " + "e" * 300, str(caught.exception))

    def test_the_committed_locks_that_cannot_be_listed(self):
        with self.assertRaises(facts.FactError) as caught:
            facts.gather(Tools({LS: (128, "", "fatal: not a git repository")}), now=1)
        self.assertEqual("the committed lock files: fatal: not a git repository", str(caught.exception))

    def test_the_kind_of_a_changed_file_reaches_the_facts(self):
        answers = {LS: "", DIFF: raw(("100644", "100644", "M", "a/.terraform.lock.hcl"),
                                     ("100644", "100644", "M", "b.tf")),
                   show("HEAD^1", "a/.terraform.lock.hcl"): LOCK_OLD, show("HEAD", "a/.terraform.lock.hcl"): LOCK_OLD,
                   show("HEAD^1", "b.tf"): "x = 1\n", show("HEAD", "b.tf"): "x = 1\n", **provider_answers()}
        self.assertEqual([("lock", None), ("tf", [])],
                         [(item["kind"], item.get("unmapped")) for item in facts.gather(Tools(answers), now=1)["files"]])


class LargeFileTest(unittest.TestCase):
    """difflib's autojunk treats a line frequent in a file of 200 lines or more as junk, which would pair every
    closing brace around a change; both comparisons turn it off."""

    OLD = "\n".join(["}"] * 150 + ['module "m" {', '  source  = "x/m/azurerm"', '  version = "1.0.0"', '}']
                    + ["}"] * 150) + "\n"

    def test_one_change_is_one_pair(self):
        self.assertEqual([{"old": '  version = "1.0.0"', "new": '  version = "1.1.0"'}],
                         facts.line_changes(self.OLD, self.OLD.replace('"1.0.0"', '"1.1.0"')))

    def test_nothing_is_unmapped(self):
        path = curl("modules/x/m/azurerm/versions")
        self.assertEqual([], facts._tf_dependencies(Tools({path: {"modules": [{"versions": []}]}}), "m.tf", self.OLD,
                                                    self.OLD.replace('"1.0.0"', '"1.1.0"'), set(), {}))


class FallbackTest(unittest.TestCase):
    def test_adjacent_unmapped_lines(self):
        # After a first line, so each changed line is found by its own offset into the change.
        old = '# legacy providers\nprovider "a" { version = "1" }\nprovider "b" { version = "2" }\n'
        new = old.replace('"1"', '"1.1"').replace('"2"', '"2.1"')
        self.assertEqual(['provider "a" { version = "1.1" }', 'provider "b" { version = "2.1" }'],
                         facts._tf_dependencies(Tools(), "p.tf", old, new, set(), {}))

    def test_a_constraint_nothing_satisfies_is_kept_as_written(self):
        old = 'terraform {\n  required_providers {\n    a = { source = "x/a", version = "> 9.0" }\n  }\n}\n'
        new = old.replace("> 9.0", "~> 1.0")
        tools = Tools({curl("providers/x/a/versions"): {"versions": [{"version": "1.0.4"}]}})
        dependencies = {}
        facts._tf_dependencies(tools, "v.tf", old, new, set(), dependencies)
        self.assertEqual([("> 9.0", "1.0.4")], [(d["from"], d["to"]) for d in dependencies.values()])
        dependencies = {}
        facts._tf_dependencies(tools, "v.tf", new, old, set(), dependencies)
        self.assertEqual([("1.0.4", "> 9.0")], [(d["from"], d["to"]) for d in dependencies.values()])

    def test_a_github_source_without_a_ref_falls_back_to_its_version(self):
        old = 'module "g" {\n  source  = "github.com/o/r"\n  version = "1"\n}\n'
        new = old.replace('"1"', '"2"')
        dependencies = {}
        facts._tf_dependencies(Tools(), "g.tf", old, new, set(), dependencies)
        self.assertEqual([("github.com/o/r", "1", "2")],
                         [(d["address"], d["from"], d["to"]) for d in dependencies.values()])

    def test_an_argument_does_not_span_lines(self):
        self.assertEqual({}, facts.dependency_lines('module "m" {\n  version =\n    "1"\n}\n'))


class ZoneAndRootTest(unittest.TestCase):
    """The cases CI's shards asked for, where the runner's zone is UTC."""

    def test_a_time_without_a_zone_is_refused(self):
        with self.assertRaises(facts.FactError) as caught:
            facts._epoch("2026-09-21T14:13:20", "it")
        self.assertEqual("it: '2026-09-21T14:13:20' has no time zone", str(caught.exception))
        self.assertEqual(support.NOW, facts._epoch("2026-09-21T14:13:20Z", "it"))

    def test_a_change_git_cannot_list(self):
        with self.assertRaises(facts.FactError) as caught:
            facts.changed_files(Tools({DIFF: (128, "", "fatal: bad revision 'HEAD^1'")}))
        self.assertEqual("the pull request's change: fatal: bad revision 'HEAD^1'", str(caught.exception))

    def test_an_entry_with_a_version_but_no_source_names_nothing(self):
        self.assertEqual({}, facts.dependency_lines('terraform {\n  required_providers {\n    a = {\n'
                                                    '      version = "1"\n    }\n  }\n}\n'))

    def test_a_root_level_file_beside_a_root_lock(self):
        old = 'terraform {\n  required_providers {\n    a = { source = "x/a", version = "~> 1.0.0" }\n  }\n}\n'
        dependencies = {}
        self.assertEqual([], facts._tf_dependencies(Tools(), "versions.tf", old, old.replace("1.0.0", "1.1.0"), {"."},
                                                    dependencies))
        self.assertEqual({}, dependencies)


if __name__ == "__main__":
    unittest.main()
