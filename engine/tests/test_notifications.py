"""Notifications in create-matrix (docs/Notifications.md §6, §7): notifications-yml validated globally and
per environment, its resolved value in every row, and the target a run notifies through.

Every message is compared as a literal, and every key and kind is written out here rather than read
from the module, so one added or dropped there fails here too.
"""

import unittest

import invariants
import support
from dsb_tf_engine import decide, model

TARGET = {"bot_url": "https://relay.example.net/api", "bot_audience": "api://11111111-2222-3333-4444-555555555555",
          "alias": "tf-alerts"}
PUBLISHED = {"bot-url": "https://relay.example.net/api", "bot-audience": "api://11111111-2222-3333-4444-555555555555",
             "alias": "tf-alerts"}
GLOBAL_KEYS = "defaults, deliver-as, enabled, kinds, runs-on"
ROUTE_KEYS = "alias, direct, mention, off, remind"
KINDS = "apply-cancelled, apply-failed, held-back"
ALIAS_RULE = "an alias is 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit"
OFF_PREFIX = "notifications are off: "
NO_TARGET = "no target: TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are not set"
NOT_THIS_EVENT = "only a push, a schedule or a dispatch on the default branch notifies"


def document(settings=None, env_settings=None, target=None, event="push", ref_name="main", ref_type="branch",
             names=("dev", "prod")):
    """Two environments; `settings` the parsed notifications-yml input, `env_settings` {index: parsed value}."""
    environments = [{"environment": name} for name in names]
    env_yaml = [{} for _ in environments]
    for index, value in (env_settings or {}).items():
        environments[index]["notifications-yml"] = "the text the parse result stands for"
        env_yaml[index]["notifications-yml"] = support.parsed(value)
    doc = support.document(environments=environments, env_yaml=env_yaml)
    if settings is not None:
        doc["workflow_inputs"]["notifications-yml"] = "the text the parse result stands for"
        doc["yaml"]["inputs"]["notifications-yml"] = support.parsed(settings)
    if target is not None:
        doc["notify_target"] = target
    doc["event"].update(name=event, ref_name=ref_name, ref_type=ref_type)
    return doc


def decided(doc):
    output = decide.decide(doc)
    assert invariants.check(doc, output) == [], invariants.check(doc, output)
    return output


def errors(settings=None, env_settings=None):
    return decided(document(settings, env_settings))["errors"]


def rows(output):
    return {row["environment"]: row["vars"] for stage in output["matrices"].values() for row in stage["include"]}


class GlobalSettingsTest(unittest.TestCase):
    def test_every_setting_is_accepted(self):
        settings = {"enabled": True, "runs-on": "ubuntu-24.04", "deliver-as": "dev",
                    "defaults": {"mention": ["author", "merger"], "direct": [], "remind": True, "off": False,
                                 "alias": "tf-alerts"},
                    "kinds": {"apply-failed": {"direct": "author"}, "apply-cancelled": None,
                              "held-back": {"alias": "tf-held-back", "off": True, "remind": False, "mention": "merger"}}}
        self.assertEqual([], errors(settings))

    def test_absent_or_empty_means_the_defaults(self):
        for settings in (None, {}):
            with self.subTest(settings=settings):
                self.assertEqual([], errors(settings))

    def test_a_value_that_is_not_a_mapping(self):
        self.assertEqual(["notifications-yml is 'off'; it must be a mapping of settings (docs/Notifications.md §6.2)"],
                         errors("off"))
        self.assertEqual(['notifications-yml is ["enabled"]; it must be a mapping of settings (docs/Notifications.md '
                          "§6.2)"], errors(["enabled"]))

    def test_an_unknown_key_lists_the_known_ones_and_guesses_a_near_one(self):
        self.assertEqual([f"notifications-yml: unknown key 'alias'; known keys: {GLOBAL_KEYS}",
                          f"notifications-yml: unknown key 'kind' (did you mean 'kinds'?); known keys: {GLOBAL_KEYS}"],
                         errors({"kind": {}, "alias": "x"}))

    def test_enabled_runs_on_and_deliver_as(self):
        self.assertEqual(["notifications-yml: 'deliver-as' names 'dve', which is not an environment of environments-yml",
                          "notifications-yml: 'enabled' is 'yes'; it must be true or false",
                          "notifications-yml: 'runs-on' is 3; it must be a runner label"],
                         errors({"enabled": "yes", "runs-on": 3, "deliver-as": "dve"}))
        self.assertEqual(["notifications-yml: 'deliver-as' names [\"dev\"], which is not an environment of "
                          "environments-yml",
                          "notifications-yml: 'runs-on' is ''; it must be a runner label"],
                         errors({"runs-on": "", "deliver-as": ["dev"]}))

    def test_true_and_false_may_be_written_as_text(self):
        self.assertEqual([], errors({"enabled": "false", "defaults": {"off": "true", "remind": "false"}}))
        self.assertEqual([], errors({"enabled": "true", "kinds": {"held-back": {"off": "false", "remind": "true"}}}))

    def test_empty_defaults_and_kinds_mean_none(self):
        self.assertEqual([], errors({"defaults": None, "kinds": None}))

    def test_defaults_and_kinds_must_be_mappings(self):
        self.assertEqual([f"notifications-yml: 'defaults' is [\"author\"]; it must be a mapping of {ROUTE_KEYS}",
                          "notifications-yml: 'kinds' is 'held-back'; it must be a mapping from a kind to its settings"],
                         errors({"defaults": ["author"], "kinds": "held-back"}))

    def test_an_unknown_kind_and_a_kind_that_is_not_a_mapping(self):
        self.assertEqual([f"notifications-yml: kinds: unknown kind 'apply-fail' (did you mean 'apply-failed'?); kinds: "
                          f"{KINDS}",
                          f"notifications-yml: kinds: unknown kind 'drift'; kinds: {KINDS}",
                          f"notifications-yml: kinds.held-back is 'off'; it must be a mapping of {ROUTE_KEYS}"],
                         errors({"kinds": {"held-back": "off", "drift": {}, "apply-fail": {}}}))

    def test_the_routing_keys(self):
        self.assertEqual([f"notifications-yml: defaults.alias is 'TF Alerts'; {ALIAS_RULE}",
                          "notifications-yml: defaults.direct is 5; it must be a list of author and merger",
                          "notifications-yml: defaults.mention takes author and merger, not 'owner'",
                          f"notifications-yml: defaults: unknown key 'mentions' (did you mean 'mention'?); known keys: "
                          f"{ROUTE_KEYS}",
                          "notifications-yml: defaults.off is 'yes'; it must be true or false",
                          "notifications-yml: defaults.remind is 1; it must be true or false"],
                         errors({"defaults": {"alias": "TF Alerts", "direct": 5, "mention": ["author", "owner"],
                                              "off": "yes", "remind": 1, "mentions": []}}))

    def test_the_routing_keys_of_a_kind(self):
        self.assertEqual([f"notifications-yml: kinds.apply-failed.alias is 'a'; {ALIAS_RULE}",
                          "notifications-yml: kinds.apply-failed.direct takes author and merger, not 7",
                          "notifications-yml: kinds.apply-failed.mention is {\"a\": 1}; it must be a list of author and "
                          "merger"],
                         errors({"kinds": {"apply-failed": {"alias": "a", "direct": [7], "mention": {"a": 1}}}}))

    def test_an_alias_at_the_relays_limits(self):
        for alias in ("ab", "a" * 50, "tf-1-x", "0a"):
            with self.subTest(alias=alias):
                self.assertEqual([], errors({"defaults": {"alias": alias}}))
        for alias in ("a", "a" * 51, "-ab", "ab-", "a_b", "Ab", 12):
            with self.subTest(alias=alias):
                self.assertEqual(1, len(errors({"defaults": {"alias": alias}})))


class EnvironmentSettingsTest(unittest.TestCase):
    PREFIX = "environments-yml: environment 'prod': notifications-yml"

    def test_routing_and_deliver_as_are_accepted(self):
        self.assertEqual([], errors(env_settings={1: {"deliver-as": "dev", "defaults": {"mention": ["merger"]},
                                                      "kinds": {"held-back": {"alias": "tf-held"}}}}))

    def test_enabled_and_runs_on_are_workflow_wide(self):
        self.assertEqual([f"{self.PREFIX}: 'enabled' is workflow-wide; set it in the notifications-yml input",
                          f"{self.PREFIX}: 'runs-on' is workflow-wide; set it in the notifications-yml input"],
                         errors(env_settings={1: {"runs-on": "x", "enabled": False}}))

    def test_the_same_rules_name_the_environment(self):
        self.assertEqual([f"{self.PREFIX} is 'x'; it must be a mapping of settings (docs/Notifications.md §6.2)"],
                         errors(env_settings={1: "x"}))
        self.assertEqual([f"{self.PREFIX}: unknown key 'alias'; known keys: defaults, deliver-as, kinds",
                          f"{self.PREFIX}: 'deliver-as' names 'qa', which is not an environment of environments-yml",
                          f"{self.PREFIX}: kinds: unknown kind 'held-bak' (did you mean 'held-back'?); kinds: {KINDS}"],
                         errors(env_settings={1: {"deliver-as": "qa", "kinds": {"held-bak": {}}, "alias": "x"}}))

    def test_the_global_value_is_reported_once_before_the_environments(self):
        self.assertEqual(["notifications-yml: 'enabled' is 1; it must be true or false",
                          f"{self.PREFIX}: 'enabled' is workflow-wide; set it in the notifications-yml input"],
                         errors({"enabled": 1}, env_settings={1: {"enabled": True}}))

    def test_the_unsuffixed_name_per_environment_names_its_spelling(self):
        doc = support.document(environments=[{"environment": "prod", "notifications": {}}])
        self.assertEqual(["The environment 'prod' sets 'notifications', which is not a setting: per environment it is "
                          "'notifications-yml'. Written like this it would have been ignored, and the environment "
                          "would have run with the global value."], decided(doc)["errors"])


class RowTest(unittest.TestCase):
    def test_without_settings_every_row_holds_null(self):
        self.assertEqual({"dev": None, "prod": None},
                         {name: row["notifications"] for name, row in rows(decided(document())).items()})

    def test_the_environment_merges_over_the_global_value_key_by_key_and_a_list_replaces(self):
        settings = {"deliver-as": "dev", "defaults": {"mention": ["author"]}, "kinds": {"held-back": {"alias": "tf-a"}}}
        output = decided(document(settings, {1: {"defaults": {"mention": ["merger"]},
                                                 "kinds": {"held-back": {"off": True}}}}))
        self.assertEqual({"dev": settings,
                          "prod": {"deliver-as": "dev", "defaults": {"mention": ["merger"]},
                                   "kinds": {"held-back": {"alias": "tf-a", "off": True}}}},
                         {name: row["notifications"] for name, row in rows(output).items()})

    def test_an_environment_without_a_global_value_has_its_own(self):
        output = decided(document(env_settings={0: {"deliver-as": "prod"}}))
        self.assertEqual({"dev": {"deliver-as": "prod"}, "prod": None},
                         {name: row["notifications"] for name, row in rows(output).items()})

    def test_the_yaml_spelling_is_not_a_row_field(self):
        output = decided(document({"enabled": True}, {1: {"deliver-as": "dev"}}))
        self.assertEqual([False, False], ["notifications-yml" in row for row in rows(output).values()])


class TargetTest(unittest.TestCase):
    def notify(self, **kwargs):
        output = decided(document(**kwargs))
        notify = {key: value for key, value in output["notify"].items() if key not in ("senders", "runs-on")}
        return notify, [warning for warning in output["warnings"] if warning.startswith(OFF_PREFIX)]

    def test_a_complete_target_on_a_push_to_the_default_branch_notifies(self):
        self.assertEqual(({"active": True, "reason": "on", "target": PUBLISHED}, []), self.notify(target=TARGET))

    def test_a_schedule_and_a_dispatch_on_the_default_branch_notify(self):
        for event in ("schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual(({"active": True, "reason": "on", "target": PUBLISHED}, []),
                                 self.notify(target=TARGET, event=event))

    def test_no_other_run_notifies(self):
        for event, ref_name, ref_type in (("pull_request", "feature/x", "branch"), ("push", "feature/x", "branch"),
                                          ("push", "main", "tag"), ("schedule", "release", "branch"),
                                          ("workflow_dispatch", "feature/x", "branch")):
            with self.subTest(event=event, ref_name=ref_name, ref_type=ref_type):
                self.assertEqual(({"active": False, "reason": NOT_THIS_EVENT, "target": PUBLISHED}, []),
                                 self.notify(target=TARGET, event=event, ref_name=ref_name, ref_type=ref_type))

    def test_without_a_target_nothing_notifies_and_nothing_warns(self):
        self.assertEqual(({"active": False, "reason": NO_TARGET, "target": None}, []), self.notify())
        self.assertEqual(({"active": False, "reason": NO_TARGET, "target": None}, []),
                         self.notify(target={"bot_url": "", "bot_audience": "", "alias": ""}))

    def test_a_partial_target_warns_on_every_run(self):
        for event in ("push", "pull_request"):
            with self.subTest(event=event):
                self.assertEqual(({"active": False, "reason": "the target is incomplete", "target": None},
                                  [f"{OFF_PREFIX}TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are set "
                                   "together or not at all; missing: TF_NOTIFY_ALIAS"]),
                                 self.notify(target={**TARGET, "alias": ""}, event=event))
        self.assertEqual([f"{OFF_PREFIX}TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are set together "
                          "or not at all; missing: TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE"],
                         self.notify(target={"bot_url": "", "bot_audience": "", "alias": "tf-alerts"})[1])

    def test_an_invalid_value_warns_and_names_the_rule(self):
        notify, warnings = self.notify(target={"bot_url": "http://relay.example.net/api", "bot_audience": "11111111",
                                               "alias": "TF Alerts"})
        self.assertEqual({"active": False, "reason": "the target is invalid", "target": None}, notify)
        self.assertEqual([f"{OFF_PREFIX}TF_NOTIFY_BOT_URL is 'http://relay.example.net/api'; it must start with "
                          "https:// and end with /api",
                          f"{OFF_PREFIX}TF_NOTIFY_BOT_AUDIENCE is '11111111'; it must start with api://",
                          f"{OFF_PREFIX}TF_NOTIFY_ALIAS is 'TF Alerts'; {ALIAS_RULE}"], warnings)

    def test_the_url_forms(self):
        for url in ("https://relay.example.net/api", "https://relay.example.net/api/", "https://h/x/api"):
            with self.subTest(url=url):
                self.assertEqual(True, self.notify(target={**TARGET, "bot_url": url})[0]["active"])
        for url in ("https://relay.example.net", "https:///api", "https://relay.example.net/apis", "https://a b/api",
                    "ftp://relay/api", " https://relay.example.net/api"):
            with self.subTest(url=url):
                self.assertEqual(False, self.notify(target={**TARGET, "bot_url": url})[0]["active"])

    def test_the_audience_forms(self):
        self.assertEqual(True, self.notify(target={**TARGET, "bot_audience": "api://relay"})[0]["active"])
        for audience in ("api://", "API://x", "api://a b"):
            with self.subTest(audience=audience):
                self.assertEqual(False, self.notify(target={**TARGET, "bot_audience": audience})[0]["active"])

    def test_enabled_false_turns_it_off_without_a_warning(self):
        for enabled in (False, "false"):
            with self.subTest(enabled=enabled):
                self.assertEqual(({"active": False, "reason": "switched off: notifications-yml sets enabled: false",
                                   "target": PUBLISHED}, []),
                                 self.notify(settings={"enabled": enabled}, target=TARGET))
        self.assertEqual(True, self.notify(settings={"enabled": True}, target=TARGET)[0]["active"])

    def test_a_module_decides_no_notifications(self):
        doc = support.document(environments=[])
        doc["mode"] = "module"
        doc["notify_target"] = TARGET
        self.assertNotIn("notify", decide.decide(doc))


class SendersTest(unittest.TestCase):
    """Every environment's identity, the deliver job's to sign in with (docs/Notifications.md §12): its
    github-environment and its two identity variables from the job-wide maps, and nothing else."""

    def test_every_environment_is_a_sender_with_its_identity_variables_only(self):
        environments = [{"environment": "dev"},
                        {"environment": "prod", "github-environment": "production",
                         "extra-envs-from-secrets-yml": "the text the parse result stands for"}]
        doc = support.document(environments=environments, env_yaml=[{}, {"extra-envs-from-secrets-yml": support.parsed(
            {"ARM_CLIENT_ID": "PROD_CLIENT_ID", "ARM_TENANT_ID": "PROD_TENANT_ID"})}])
        doc["yaml"]["inputs"]["extra-envs-yml"] = support.parsed(
            {"ARM_TENANT_ID": "tenant-1", "ARM_SUBSCRIPTION_ID": "sub-1", "TF_VAR_x": "y"})
        doc["yaml"]["inputs"]["extra-envs-from-secrets-yml"] = support.parsed(
            {"ARM_CLIENT_ID": "DEV_CLIENT_ID", "ARM_CLIENT_SECRET": "NEVER"})
        self.assertEqual({"dev": {"github-environment": "dev", "extra-envs": {"ARM_TENANT_ID": "tenant-1"},
                                  "extra-envs-from-secrets": {"ARM_CLIENT_ID": "DEV_CLIENT_ID"}},
                          "prod": {"github-environment": "production", "extra-envs": {"ARM_TENANT_ID": "tenant-1"},
                                   "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID",
                                                               "ARM_TENANT_ID": "PROD_TENANT_ID"}}},
                         decided(doc)["notify"]["senders"])

    def test_an_environment_without_the_variables_has_empty_maps(self):
        self.assertEqual({"github-environment": "dev", "extra-envs": {}, "extra-envs-from-secrets": {}},
                         decided(document())["notify"]["senders"]["dev"])

    def test_a_run_that_does_not_notify_still_lists_them(self):
        self.assertEqual(["dev", "prod"], sorted(decided(document(event="pull_request"))["notify"]["senders"]))


class RunsOnTest(unittest.TestCase):
    def test_the_deliver_jobs_runner_is_the_settings_or_ubuntu_latest(self):
        self.assertEqual("ubuntu-latest", decided(document(target=TARGET))["notify"]["runs-on"])
        self.assertEqual("ubuntu-24.04", decided(document({"runs-on": "ubuntu-24.04"}, target=TARGET))["notify"]["runs-on"])
        self.assertEqual("ubuntu-latest", decided(document({"enabled": True}, target=TARGET))["notify"]["runs-on"])


class DocumentTest(unittest.TestCase):
    def test_the_target_holds_exactly_three_strings(self):
        message = "input document: 'notify_target' needs exactly the strings 'bot_url', 'bot_audience' and 'alias'"
        for target in ("x", {**TARGET, "extra": ""}, {"bot_url": "", "bot_audience": ""}, {**TARGET, "alias": None}):
            with self.subTest(target=target):
                doc = document()
                doc["notify_target"] = target
                with self.assertRaises(model.DocumentError) as raised:
                    decide.decide(doc)
                self.assertEqual(message, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
