"""decide-notifications' rules (docs/Notifications.md §4, §5, §9, §11): an environment's result, what it does
to its incident, who is named, the message, and the deliver rows.

Every message and line is compared as a literal.
"""

import copy
import hashlib
import json
import unittest

from dsb_tf_engine import notify_decide

TARGET = {"bot-url": "https://relay.example.net/api", "bot-audience": "api://relay", "alias": "tf-alerts"}
NOW = "2026-10-07T12:00:00Z"
RUN = {"id": 4711, "number": 42, "attempt": 1}
RUN_URL = "https://github.com/o/r/actions/runs/4711/attempts/1"


def sender(name, github_environment=None, identity=True):
    return {"github-environment": github_environment or name,
            "extra-envs": {"ARM_TENANT_ID": "tenant-1"} if identity else {},
            "extra-envs-from-secrets": {"ARM_CLIENT_ID": f"{name.upper()}_CLIENT_ID"} if identity else {}}


def row(name, goals=("init", "format", "validate", "lint", "plan", "apply"), notifications=None):
    return {"environment": name, "github-environment": name, "goals-granted": list(goals),
            "notifications": notifications}


def metadata(name, **outcomes):
    steps = {step: {"outcome": "success", "outputs": {}} for step in ("init", "fmt", "validate", "lint", "plan", "apply")}
    for step, outcome in outcomes.items():
        steps[step.replace("_", "-")] = {"outcome": outcome, "outputs": {}}
    return {"metadata": {"environment": name}, "steps": steps}


def facts(**overrides):
    base = {
        "repository": "o/r", "server_url": "https://github.com", "event": "push", "run": dict(RUN), "now": NOW,
        "target": dict(TARGET), "runs_on": "ubuntu-24.04", "senders": {"dev": sender("dev"), "prod": sender("prod")},
        "environments": [{"environment": "dev", "verdict": "run", "stage": 1},
                         {"environment": "prod", "verdict": "run", "stage": 1}],
        "rows": {"dev": row("dev"), "prod": row("prod")},
        "metadata": {"dev": metadata("dev"), "prod": metadata("prod")},
        "stage_results": {"1": "success", "2": "skipped", "3": "skipped"},
        "state": None,
        "people": {"available": True, "error": None, "pull_requests": [
            {"number": 7, "title": "Add a storage account", "author": "jdoe", "merged_by": "asmith"}], "pusher": "asmith"},
        "protection": {"dev": False, "prod": False},
        "identities": None, "people_domains": ["example.org"],
    }
    base.update(overrides)
    return base


def incident(status="open", kind="apply-failed", message_id="msg-1", alias="tf-alerts", sender_name="prod",
             opened_run=40, seen_run=40, people=("jdoe",), opened_at="2026-10-05T08:30:00Z"):
    return {"kind": kind, "status": status, "message_id": message_id, "alias": alias, "sender": sender_name,
            "opened_at": opened_at, "opened_run": opened_run, "seen_run": seen_run, "people": list(people),
            "resolved_at": None}


def state(**incidents):
    return {"schema_version": 1, "incidents": {key.replace("__", "/"): value for key, value in incidents.items()}}


def key(*parts):
    return hashlib.sha256("/".join(parts).encode("utf-8")).hexdigest()


class ClassifyTest(unittest.TestCase):
    def result(self, **kwargs):
        decided = notify_decide.decide(facts(**kwargs))
        return {observation["environment"]: observation["result"] for observation in decided["observations"]
                if observation["slot"] == "apply"}

    def test_an_apply_that_succeeded_or_failed_or_was_cancelled(self):
        self.assertEqual({"dev": "applied", "prod": "failed"},
                         self.result(metadata={"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}))
        self.assertEqual({"dev": "cancelled", "prod": "applied"},
                         self.result(metadata={"dev": metadata("dev", apply="cancelled"), "prod": metadata("prod")}))

    def test_a_step_before_the_apply_that_failed_or_was_cancelled(self):
        self.assertEqual({"dev": "failed", "prod": "cancelled"},
                         self.result(metadata={"dev": metadata("dev", plan="failure", apply="skipped"),
                                               "prod": metadata("prod", validate="cancelled", plan="skipped",
                                                                apply="skipped")}))

    def test_a_tolerated_failure_is_a_failure(self):
        # allow-failing-terraform-operations: the step's outcome is failure, its conclusion success.
        self.assertEqual("failed", self.result(metadata={"dev": metadata("dev"),
                                                         "prod": metadata("prod", apply="failure")})["prod"])

    def test_an_apply_that_did_not_run_and_no_step_says_why_is_a_failure(self):
        self.assertEqual("failed", self.result(metadata={"dev": metadata("dev"),
                                                         "prod": metadata("prod", apply="skipped")})["prod"])

    def test_without_metadata_the_stage_result_decides(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1},
                        {"environment": "prod", "verdict": "run", "stage": 2}]
        self.assertEqual({"dev": "failed", "prod": "held-back"},
                         self.result(environments=environments, metadata={},
                                     stage_results={"1": "failure", "2": "skipped", "3": "skipped"}))
        self.assertEqual({"dev": "cancelled", "prod": "held-back"},
                         self.result(environments=environments, metadata={},
                                     stage_results={"1": "cancelled", "2": "skipped", "3": "skipped"}))

    def test_a_skipped_stage_with_no_earlier_failure_or_a_stage_that_succeeded_without_metadata_is_unknown(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1},
                        {"environment": "prod", "verdict": "run", "stage": 2}]
        self.assertEqual({"dev": "unknown", "prod": "unknown"},
                         self.result(environments=environments, metadata={},
                                     stage_results={"1": "success", "2": "skipped", "3": "skipped"}))

    def test_an_environment_not_due_to_apply(self):
        rows = {"dev": row("dev", goals=("init", "plan")), "prod": row("prod", goals=("init", "plan"))}
        plan = {"outcome": "success", "outputs": {"count-total": "0", "has-output-only-changes": "false",
                                                  "plan-complete": "true"}}
        clean = metadata("dev", apply="skipped")
        clean["steps"]["parse-plan"] = plan
        changed = metadata("prod", apply="skipped")
        changed["steps"]["parse-plan"] = {**plan, "outputs": {**plan["outputs"], "count-total": "2"}}
        for event, expected in (("schedule", {"dev": "clean", "prod": "none"}),
                                ("workflow_dispatch", {"dev": "clean", "prod": "none"}),
                                ("push", {"dev": "none", "prod": "none"})):
            with self.subTest(event=event):
                self.assertEqual(expected, self.result(event=event, rows=rows,
                                                       metadata={"dev": clean, "prod": changed}))

    def test_a_plan_that_changes_outputs_only_or_was_not_read_is_not_clean(self):
        rows = {"dev": row("dev", goals=("init", "plan")), "prod": row("prod", goals=("init", "plan"))}
        outputs_only = metadata("dev", apply="skipped")
        outputs_only["steps"]["parse-plan"] = {"outcome": "success", "outputs": {
            "count-total": "0", "has-output-only-changes": "true", "plan-complete": "true"}}
        unread = metadata("prod", apply="skipped")
        unread["steps"]["parse-plan"] = {"outcome": "success", "outputs": {
            "count-total": "?", "has-output-only-changes": "false", "plan-complete": "?"}}
        self.assertEqual({"dev": "none", "prod": "none"},
                         self.result(event="schedule", rows=rows, metadata={"dev": outputs_only, "prod": unread}))

    def test_an_environment_the_run_did_not_run_is_not_observed(self):
        environments = [{"environment": "dev", "verdict": "skip"}, {"environment": "prod", "verdict": "run", "stage": 1}]
        self.assertEqual({"prod": "applied"}, self.result(environments=environments, rows={"prod": row("prod")}))


class OpenTest(unittest.TestCase):
    def failing(self, **overrides):
        return facts(metadata={"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}, **overrides)

    def test_a_failed_apply_on_a_push_opens_an_incident(self):
        decided = notify_decide.decide(self.failing())
        self.assertEqual([{"id": "e1", "environment": "prod", "slot": "apply", "kind": "apply-failed", "action": "open",
                           "alias": "tf-alerts", "reply_to": None, "update": None, "sender": "prod",
                           "idempotency_key": key("o/r", "4711", "1", "prod", "apply", "open"), "message": "e1.md",
                           "mentions": []}],
                         decided["events"])
        self.assertEqual(["❌ **Apply failed** in `prod` · o/r",
                          "",
                          "The `apply` step failed, so the default branch is not applied in `prod`.",
                          "",
                          "Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by jdoe, merged by "
                          "asmith.",
                          "",
                          f"[Open the run]({RUN_URL})"],
                         decided["messages"]["e1.md"].split("\n")[:-1])
        self.assertTrue(decided["messages"]["e1.md"].endswith("\n"))

    def test_the_deliver_row_carries_the_senders_identity_and_nothing_of_the_message(self):
        decided = notify_decide.decide(self.failing())
        self.assertEqual([{"id": "e1", "sender": "prod", "github-environment": "prod", "runs-on": "ubuntu-24.04",
                           "alias": "tf-alerts", "reply-to": "", "update": "",
                           "idempotency-key": key("o/r", "4711", "1", "prod", "apply", "open"),
                           "extra-envs": {"ARM_TENANT_ID": "tenant-1"},
                           "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID"}}], decided["deliver"])

    def test_the_messages_of_each_kind(self):
        cases = (
            ({"plan": "failure", "apply": "skipped"}, "❌ **Apply failed** in `prod` · o/r",
             "The `plan` step failed, so `apply` did not run and the default branch is not applied in `prod`."),
            ({"apply": "cancelled"}, "🚫 **Apply cancelled** in `prod` · o/r",
             "The `apply` step was cancelled, so `prod` may be partly applied."),
            ({"lint": "cancelled", "plan": "skipped", "apply": "skipped"}, "🚫 **Apply cancelled** in `prod` · o/r",
             "The job was cancelled at the `lint` step, so `apply` did not run and the default branch is not applied "
             "in `prod`."),
            ({"apply": "skipped"}, "❌ **Apply failed** in `prod` · o/r",
             "`apply` did not run, and no step says why, so the default branch is not applied in `prod`."),
        )
        for outcomes, header, body in cases:
            with self.subTest(outcomes=outcomes):
                decided = notify_decide.decide(facts(metadata={"dev": metadata("dev"),
                                                               "prod": metadata("prod", **outcomes)}))
                lines = decided["messages"]["e1.md"].split("\n")
                self.assertEqual((header, body), (lines[0], lines[2]))

    def test_the_messages_without_metadata(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1},
                        {"environment": "prod", "verdict": "run", "stage": 2}]
        for result, dev_body, prod_body in (
                ("failure", "The job failed without reporting its steps, so the default branch may not be applied in "
                            "`dev`.",
                 "Stage 2 did not run because stage 1 failed, so the default branch is not applied in `prod`."),
                ("cancelled", "The job was cancelled before it reported its steps, so the default branch may not be "
                              "applied in `dev`.",
                 "Stage 2 did not run because stage 1 was cancelled, so the default branch is not applied in `prod`.")):
            with self.subTest(result=result):
                decided = notify_decide.decide(facts(environments=environments, metadata={},
                                                     stage_results={"1": result, "2": "skipped", "3": "skipped"}))
                self.assertEqual(["apply-failed" if result == "failure" else "apply-cancelled", "held-back"],
                                 [event["kind"] for event in decided["events"]])
                self.assertEqual(dev_body, decided["messages"]["e1.md"].split("\n")[2])
                self.assertEqual("⏸️ **Held back** in `prod` · o/r", decided["messages"]["e2.md"].split("\n")[0])
                self.assertEqual(prod_body, decided["messages"]["e2.md"].split("\n")[2])

    def test_a_schedule_opens_and_names_nobody(self):
        decided = notify_decide.decide(self.failing(event="schedule", people=None))
        self.assertEqual("open", decided["events"][0]["action"])
        self.assertEqual("Found by the scheduled run.", decided["messages"]["e1.md"].split("\n")[4])

    def test_a_dispatch_never_opens(self):
        decided = notify_decide.decide(self.failing(event="workflow_dispatch", people=None))
        self.assertEqual([], decided["events"])
        self.assertEqual([{"environment": "prod", "slot": "apply", "result": "failed", "kind": "apply-failed",
                           "action": "none", "event": None, "people": [], "alias": "tf-alerts", "sender": "prod",
                           "sending": False, "mentioned": [], "reminder_level": None,
                           "fingerprint": None, "checks": None}],
                         [o for o in decided["observations"] if o["environment"] == "prod"])

    def test_a_kind_switched_off_opens_nothing(self):
        rows = {"dev": row("dev"), "prod": row("prod", notifications={"kinds": {"apply-failed": {"off": True}}})}
        decided = notify_decide.decide(self.failing(rows=rows))
        self.assertEqual(([], "none"), (decided["events"], decided["observations"][1]["action"]))
        rows["prod"]["notifications"] = {"defaults": {"off": "true"}, "kinds": {"apply-failed": {"off": "false"}}}
        self.assertEqual(1, len(notify_decide.decide(self.failing(rows=rows))["events"]))

    def test_the_alias_and_the_sender_follow_the_routing(self):
        rows = {"dev": row("dev"), "prod": row("prod", notifications={
            "deliver-as": "dev", "defaults": {"alias": "tf-other"}, "kinds": {"apply-failed": {"alias": "tf-failed"}}})}
        decided = notify_decide.decide(self.failing(rows=rows))
        self.assertEqual(("tf-failed", "dev", "dev"), (decided["events"][0]["alias"], decided["events"][0]["sender"],
                                                       decided["deliver"][0]["github-environment"]))
        self.assertEqual({"ARM_CLIENT_ID": "DEV_CLIENT_ID"}, decided["deliver"][0]["extra-envs-from-secrets"])
        rows["prod"]["notifications"] = {"defaults": {"alias": "tf-other"}}
        self.assertEqual("tf-other", notify_decide.decide(self.failing(rows=rows))["events"][0]["alias"])


class PeopleTest(unittest.TestCase):
    def line(self, people, event="push"):
        decided = notify_decide.decide(facts(event=event, people=people, metadata={
            "dev": metadata("dev"), "prod": metadata("prod", apply="failure")}))
        return decided["messages"]["e1.md"].split("\n")[4], decided["observations"][1]["people"]

    def test_authors_then_mergers_who_are_not_authors(self):
        prs = [{"number": 7, "title": "A", "author": "jdoe", "merged_by": "asmith"},
               {"number": 8, "title": "B", "author": "asmith", "merged_by": "asmith"}]
        self.assertEqual(("Changes: [#7](https://github.com/o/r/pull/7) `A` by jdoe, merged by asmith; "
                          "[#8](https://github.com/o/r/pull/8) `B` by asmith.", ["jdoe", "asmith"]),
                         self.line({"available": True, "error": None, "pull_requests": prs, "pusher": "asmith"}))

    def test_bots_and_apps_are_never_named(self):
        prs = [{"number": 9, "title": "Bump azurerm", "author": "dependabot[bot]", "merged_by": "jdoe"},
               {"number": 10, "title": "C", "author": "kim", "merged_by": "my-merge-app[bot]"}]
        self.assertEqual(("Changes: [#9](https://github.com/o/r/pull/9) `Bump azurerm`, merged by jdoe; "
                          "[#10](https://github.com/o/r/pull/10) `C` by kim.", ["kim", "jdoe"]),
                         self.line({"available": True, "error": None, "pull_requests": prs, "pusher": None}))

    def test_a_direct_push(self):
        self.assertEqual(("Pushed by jdoe.", ["jdoe"]),
                         self.line({"available": True, "error": None, "pull_requests": [], "pusher": "jdoe"}))
        self.assertEqual(("Pushed by an app.", []),
                         self.line({"available": True, "error": None, "pull_requests": [], "pusher": None}))

    def test_people_that_could_not_be_read(self):
        self.assertEqual(("Who made the change could not be read.", []),
                         self.line({"available": False, "error": "gh api failed", "pull_requests": [], "pusher": None}))

    def test_a_title_is_a_code_span_that_cannot_carry_markup(self):
        prs = [{"number": 7, "title": "Fix `x` <at>boss</at>\nand [y](http://evil)" + "z" * 120, "author": "jdoe",
                "merged_by": "jdoe"}]
        line, _ = self.line({"available": True, "error": None, "pull_requests": prs, "pusher": None})
        self.assertEqual("Change: [#7](https://github.com/o/r/pull/7) `Fix 'x' ‹at›boss‹/at› and [y](http://evil)"
                         + "z" * 57 + "…` by jdoe.", line)

    def test_a_pull_request_without_a_title(self):
        prs = [{"number": 7, "title": "", "author": "jdoe", "merged_by": "jdoe"}]
        self.assertEqual("Change: [#7](https://github.com/o/r/pull/7) by jdoe.",
                         self.line({"available": True, "error": None, "pull_requests": prs, "pusher": None})[0])

    def test_many_pull_requests_are_cut_at_ten(self):
        prs = [{"number": n, "title": "", "author": f"u{n}", "merged_by": f"u{n}"} for n in range(1, 13)]
        line, people = self.line({"available": True, "error": None, "pull_requests": prs, "pusher": None})
        self.assertTrue(line.endswith("[#10](https://github.com/o/r/pull/10) by u10; and 2 more."), line)
        self.assertEqual([f"u{n}" for n in range(1, 13)], people)


class TransitionTest(unittest.TestCase):
    def failing(self, **overrides):
        return facts(metadata={"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}, **overrides)

    def test_an_open_incident_failing_again_on_a_push_is_a_reply(self):
        decided = notify_decide.decide(self.failing(state=state(prod__apply=incident(alias="tf-old"))))
        self.assertEqual([("reply", "msg-1", "tf-old", key("o/r", "4711", "1", "prod", "apply", "reply"))],
                         [(e["action"], e["reply_to"], e["alias"], e["idempotency_key"]) for e in decided["events"]])
        self.assertEqual(["❌ **Apply failed again** in `prod` · o/r", "",
                          "The `apply` step failed, so the default branch is not applied in `prod`. It has not been "
                          "applied since 2026-10-05 08:30 UTC."],
                         decided["messages"]["e1.md"].split("\n")[:3])

    def test_an_open_incident_failing_again_on_a_schedule_before_a_reminder_or_a_dispatch_sends_nothing(self):
        for event in ("schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                decided = notify_decide.decide(self.failing(event=event, now="2026-10-06T12:00:00Z",
                                                            state=state(prod__apply=incident())))
                self.assertEqual([], decided["events"])
                self.assertEqual("none", decided["observations"][1]["action"])

    def test_a_pending_incident_is_opened_again(self):
        decided = notify_decide.decide(self.failing(state=state(prod__apply=incident(status="pending",
                                                                                      message_id=None))))
        self.assertEqual(["open"], [e["action"] for e in decided["events"]])

    def test_a_resolved_incident_is_opened_anew(self):
        decided = notify_decide.decide(self.failing(state=state(prod__apply=incident(status="resolved"))))
        self.assertEqual([("open", None)], [(e["action"], e["reply_to"]) for e in decided["events"]])

    def test_an_apply_resolves_an_open_incident_on_any_event(self):
        for event in ("push", "schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                decided = notify_decide.decide(facts(event=event, state=state(prod__apply=incident(alias="tf-old"))))
                self.assertEqual([("resolve", "msg-1", "tf-old", "prod")],
                                 [(e["action"], e["reply_to"], e["alias"], e["sender"]) for e in decided["events"]])
                self.assertEqual(["✅ **Applied** in `prod` · o/r", "",
                                  "`prod` is applied again: the incident opened at 2026-10-05 08:30 UTC is resolved.",
                                  "", f"[Open the run]({RUN_URL})"],
                                 decided["messages"]["e1.md"].split("\n")[:-1])

    def test_a_clean_plan_resolves(self):
        rows = {"dev": row("dev"), "prod": row("prod", goals=("init", "plan"))}
        clean = metadata("prod", apply="skipped")
        clean["steps"]["parse-plan"] = {"outcome": "success", "outputs": {
            "count-total": "0", "has-output-only-changes": "false", "plan-complete": "true"}}
        decided = notify_decide.decide(facts(event="schedule", rows=rows, metadata={"dev": metadata("dev"), "prod": clean},
                                             state=state(prod__apply=incident())))
        self.assertEqual(["✅ **Applied** in `prod` · o/r", "",
                          "A plan of `prod` has no changes: the incident opened at 2026-10-05 08:30 UTC is resolved."],
                         decided["messages"]["e1.md"].split("\n")[:3])

    def test_an_open_incident_without_a_message_id_resolves_with_a_new_post(self):
        decided = notify_decide.decide(facts(state=state(prod__apply=incident(message_id=None))))
        self.assertEqual([("resolve", None)], [(e["action"], e["reply_to"]) for e in decided["events"]])
        self.assertEqual("", decided["deliver"][0]["reply-to"])

    def test_a_pending_incident_resolves_silently(self):
        decided = notify_decide.decide(facts(state=state(prod__apply=incident(status="pending", message_id=None))))
        self.assertEqual([], decided["events"])
        self.assertEqual("resolve", decided["observations"][1]["action"])

    def test_an_incident_of_a_removed_environment_is_closed(self):
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(sender_name="dev"))))
        self.assertEqual([("qa", "removed", "dev")], [(e["environment"], e["action"], e["sender"])
                                                      for e in decided["events"]])
        self.assertEqual(["✅ **No longer watched** `qa` · o/r", "",
                          "`qa` is no longer in environments-yml: the incident opened at 2026-10-05 08:30 UTC is "
                          "closed."], decided["messages"]["e1.md"].split("\n")[:3])

    def test_a_removed_environment_closes_the_incident_of_every_slot(self):
        drift = incident(kind="drift", sender_name="dev")
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(sender_name="dev"), qa__drift=drift)))
        self.assertEqual([("qa", "apply", "removed", key("o/r", "4711", "1", "qa", "apply", "removed")),
                          ("qa", "drift", "removed", key("o/r", "4711", "1", "qa", "drift", "removed"))],
                         [(e["environment"], e["slot"], e["action"], e["idempotency_key"]) for e in decided["events"]])
        self.assertEqual(["apply", "drift"], [o["slot"] for o in decided["observations"] if o["environment"] == "qa"])

    def test_a_removed_environment_says_so_in_every_slot(self):
        incidents = {f"qa__{slot}": incident(kind=kind, sender_name="dev")
                     for slot, kind in (("drift", "drift"), ("schedule", "scheduled-failed"))}
        decided = notify_decide.decide(facts(state=state(**incidents)))
        for event in decided["events"]:
            with self.subTest(slot=event["slot"]):
                self.assertEqual(["✅ **No longer watched** `qa` · o/r", "",
                                  "`qa` is no longer in environments-yml: the incident opened at 2026-10-05 08:30 UTC is "
                                  "closed."], decided["messages"][event["message"]].split("\n")[:3])
        self.assertEqual(["drift", "schedule"], [e["slot"] for e in decided["events"]])

    def test_a_removed_environment_whose_sender_is_gone_too_is_closed_quietly(self):
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(sender_name="qa"))))
        self.assertEqual([], decided["events"])
        self.assertEqual([{"environment": "qa", "slot": "apply", "result": "removed", "kind": None,
                           "action": "resolve", "event": None, "people": [], "alias": "tf-alerts", "sender": "qa",
                           "sending": False, "mentioned": [], "reminder_level": None,
                           "fingerprint": None, "checks": None}],
                         [o for o in decided["observations"] if o["environment"] == "qa"])
        self.assertIn("`qa`: removed from environments-yml, and its sender `qa` with it; closed without a message",
                      decided["summary"])

    def test_nothing_happens_to_an_incident_whose_environment_did_not_run(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1}, {"environment": "prod", "verdict": "skip"}]
        decided = notify_decide.decide(facts(environments=environments, rows={"dev": row("dev")},
                                             state=state(prod__apply=incident())))
        self.assertEqual([], decided["events"])
        self.assertEqual(["dev"], [o["environment"] for o in decided["observations"]])

    def test_the_state_key_is_the_environment_lowercased(self):
        decided = notify_decide.decide(facts(
            environments=[{"environment": "Prod", "verdict": "run", "stage": 1}], rows={"Prod": row("Prod")},
            metadata={"Prod": metadata("Prod")}, senders={"Prod": sender("Prod")},
            state=state(prod__apply=incident(sender_name="Prod"))))
        self.assertEqual(["resolve"], [e["action"] for e in decided["events"]])


class DeliveryTest(unittest.TestCase):
    def failing_both(self, **overrides):
        return facts(metadata={"dev": metadata("dev", apply="failure"), "prod": metadata("prod", apply="failure")},
                     **overrides)

    def test_a_protected_sender_is_not_used(self):
        decided = notify_decide.decide(self.failing_both(protection={"dev": False, "prod": True}))
        self.assertEqual(["dev"], [row["sender"] for row in decided["deliver"]])
        self.assertEqual(["dev", "prod"], [e["environment"] for e in decided["events"]])
        self.assertIn("| `prod` | apply failed | not sent: its sender `prod` has protection rules; set deliver-as to an "
                      "environment without them |", decided["summary"])

    def test_a_sender_whose_protection_is_unknown_is_not_used(self):
        decided = notify_decide.decide(self.failing_both(protection={"dev": False, "prod": None}))
        self.assertEqual(["dev"], [row["sender"] for row in decided["deliver"]])
        self.assertIn("| `prod` | apply failed | not sent: whether its sender `prod` has protection rules could not be "
                      "read |", decided["summary"])

    def test_a_sender_without_an_identity_is_not_used(self):
        senders = {"dev": sender("dev"), "prod": sender("prod", identity=False)}
        decided = notify_decide.decide(self.failing_both(senders=senders))
        self.assertEqual(["dev"], [row["sender"] for row in decided["deliver"]])
        self.assertIn("| `prod` | apply failed | not sent: its sender `prod` has no ARM_TENANT_ID and ARM_CLIENT_ID |",
                      decided["summary"])

    def test_the_protection_is_read_by_github_environment(self):
        senders = {"dev": sender("dev"), "prod": sender("prod", "production")}
        decided = notify_decide.decide(self.failing_both(senders=senders, protection={"dev": False,
                                                                                       "production": False}))
        self.assertEqual(["dev", "production"], [row["github-environment"] for row in decided["deliver"]])

    def test_the_summary_lists_what_is_sent(self):
        decided = notify_decide.decide(self.failing_both())
        self.assertEqual("\n".join([
            "### 📣 Teams notifications", "",
            "| Environment | What | Sent |", "|---|---|---|",
            "| `dev` | apply failed | to `tf-alerts` as `dev` |",
            "| `prod` | apply failed | to `tf-alerts` as `prod` |", ""]), decided["summary"])

    def test_nothing_to_send(self):
        self.assertEqual("### 📣 Teams notifications\n\nNothing to tell Teams.\n",
                         notify_decide.decide(facts())["summary"])


class RulesTest(unittest.TestCase):
    """The edges of the rules: each one a test, so a rule that changes fails one."""

    def body(self, decided, message="e1.md"):
        return decided["messages"][message].split("\n")[2]

    def test_the_first_step_before_the_apply_that_failed_is_named(self):
        for step in ("init", "verify-lock", "fmt", "validate", "lint", "plan"):
            with self.subTest(step=step):
                outcomes = {step.replace("-", "_"): "failure", "apply": "skipped"}
                decided = notify_decide.decide(facts(metadata={"dev": metadata("dev"),
                                                               "prod": metadata("prod", **outcomes)}))
                self.assertEqual(f"The `{step}` step failed, so `apply` did not run and the default branch is not "
                                 "applied in `prod`.", self.body(decided))
        decided = notify_decide.decide(facts(metadata={"dev": metadata("dev"), "prod": metadata(
            "prod", fmt="cancelled", plan="failure", apply="skipped")}))
        self.assertEqual("The job was cancelled at the `fmt` step, so `apply` did not run and the default branch is "
                         "not applied in `prod`.", self.body(decided))

    def test_stages_are_numbered_from_one(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 2}]
        decided = notify_decide.decide(facts(environments=environments, rows={"dev": row("dev")}, metadata={},
                                             stage_results={"0": "failure", "1": "success", "2": "skipped"}))
        self.assertEqual("unknown", decided["observations"][0]["result"])

    def test_a_stage_that_ran_and_failed_is_failed_whatever_came_before(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 2}]
        decided = notify_decide.decide(facts(environments=environments, rows={"dev": row("dev")}, metadata={},
                                             stage_results={"1": "failure", "2": "failure", "3": "skipped"}))
        self.assertEqual("failed", decided["observations"][0]["result"])

    def test_an_environment_not_due_to_apply_without_metadata_is_nothing(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1}]
        decided = notify_decide.decide(facts(environments=environments, rows={"dev": row("dev", goals=("plan",))},
                                             metadata={}, stage_results={"1": "failure"}))
        self.assertEqual("none", decided["observations"][0]["result"])

    def test_a_failed_plan_is_never_clean(self):
        content = metadata("dev", plan="failure", apply="skipped")
        content["steps"]["parse-plan"] = {"outcome": "success", "outputs": {"count-total": "0",
                                                                            "has-output-only-changes": "false"}}
        decided = notify_decide.decide(facts(event="schedule", environments=[{"environment": "dev", "verdict": "run",
                                                                              "stage": 1}],
                                             rows={"dev": row("dev", goals=("plan",))}, metadata={"dev": content}))
        self.assertEqual("none", decided["observations"][0]["result"])

    def test_off_may_be_written_as_text(self):
        rows = {"dev": row("dev"), "prod": row("prod", notifications={"kinds": {"apply-failed": {"off": "true"}}})}
        self.assertEqual([], notify_decide.decide(facts(rows=rows, metadata={
            "dev": metadata("dev"), "prod": metadata("prod", apply="failure")}))["events"])

    def test_people_that_could_not_be_read_name_nobody(self):
        self.assertEqual([], notify_decide.named({"available": False, "error": "x", "pull_requests": [
            {"number": 1, "title": "", "author": "jdoe", "merged_by": "kim"}], "pusher": "jdoe"}))
        self.assertEqual([], notify_decide.named(None))

    def test_ten_pull_requests_are_all_listed_and_a_hundred_characters_are_kept(self):
        prs = [{"number": n, "title": "t" * 100 if n == 1 else "", "author": "jdoe", "merged_by": "jdoe"}
               for n in range(1, 11)]
        decided = notify_decide.decide(facts(people={"available": True, "error": None, "pull_requests": prs,
                                                     "pusher": None},
                                             metadata={"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}))
        line = decided["messages"]["e1.md"].split("\n")[4]
        self.assertTrue(line.endswith("[#10](https://github.com/o/r/pull/10) by jdoe."), line)
        self.assertIn("`" + "t" * 100 + "`", line)

    def test_the_summary_says_what_of_every_kind(self):
        environments = [{"environment": "dev", "verdict": "run", "stage": 1},
                        {"environment": "prod", "verdict": "run", "stage": 2}]
        decided = notify_decide.decide(facts(environments=environments, metadata={},
                                             stage_results={"1": "cancelled", "2": "skipped", "3": "skipped"}))
        self.assertIn("| `dev` | apply cancelled | to `tf-alerts` as `dev` |", decided["summary"])
        self.assertIn("| `prod` | held back | to `tf-alerts` as `prod` |", decided["summary"])
        decided = notify_decide.decide(facts(state=state(prod__apply=incident(), qa__apply=incident(sender_name="dev"))))
        self.assertIn("| `prod` | resolved | to `tf-alerts` as `prod` |", decided["summary"])
        self.assertIn("| `qa` | resolved | to `tf-alerts` as `dev` |", decided["summary"])

    def test_notes_are_one_line_each(self):
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(sender_name="qa"),
                                                         uat__apply=incident(sender_name="uat"))))
        self.assertEqual("\n".join(["### 📣 Teams notifications", "",
                                    "- `qa`: removed from environments-yml, and its sender `qa` with it; closed without "
                                    "a message",
                                    "- `uat`: removed from environments-yml, and its sender `uat` with it; closed without "
                                    "a message", ""]), decided["summary"])

    def test_a_summary_with_a_table_and_a_note(self):
        decided = notify_decide.decide(facts(state=state(prod__apply=incident(), qa__apply=incident(sender_name="qa"))))
        self.assertEqual("\n".join(["### 📣 Teams notifications", "",
                                    "| Environment | What | Sent |", "|---|---|---|",
                                    "| `prod` | resolved | to `tf-alerts` as `prod` |", "",
                                    "- `qa`: removed from environments-yml, and its sender `qa` with it; closed without "
                                    "a message", ""]), decided["summary"])

    def test_later_messages_go_where_the_first_went_as_its_sender(self):
        failing = {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}
        for metadata_, action in ((failing, "reply"), (None, "resolve")):
            with self.subTest(action=action):
                decided = notify_decide.decide(facts(**({"metadata": metadata_} if metadata_ else {}),
                                                     state=state(prod__apply=incident(sender_name="dev",
                                                                                      alias="tf-old"))))
                self.assertEqual([(action, "dev", "tf-old")],
                                 [(e["action"], e["sender"], e["alias"]) for e in decided["events"]])
                self.assertEqual("dev", decided["deliver"][0]["sender"])

    def test_a_removed_environments_pending_incident_closes_quietly(self):
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(status="pending", message_id=None))))
        self.assertEqual([], decided["events"])
        self.assertEqual("resolve", [o for o in decided["observations"] if o["environment"] == "qa"][0]["action"])
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(status="resolved"))))
        self.assertEqual([], [o for o in decided["observations"] if o["environment"] == "qa"])

    def test_a_sent_message_is_sending_and_one_not_sent_is_not(self):
        decided = notify_decide.decide(facts(metadata={"dev": metadata("dev", apply="failure"),
                                                       "prod": metadata("prod", apply="failure")},
                                             protection={"dev": False, "prod": True}))
        self.assertEqual([True, False], [o["sending"] for o in decided["observations"]])

    def test_a_reply_names_the_pushs_people(self):
        decided = notify_decide.decide(facts(metadata={"dev": metadata("dev"), "prod": metadata("prod", apply="failure")},
                                             state=state(prod__apply=incident())))
        self.assertEqual(["jdoe", "asmith"], decided["observations"][1]["people"])

    def test_an_environment_the_run_skipped_is_not_observed_though_it_has_a_row(self):
        environments = [{"environment": "dev", "verdict": "skip"}, {"environment": "prod", "verdict": "run", "stage": 1}]
        self.assertEqual(["prod"], [o["environment"] for o in notify_decide.decide(facts(environments=environments))[
            "observations"]])


def identity(name, object_id, upn):
    return {"name": name, "object_id": object_id, "upn": upn}


IDENTITIES = {"available": True, "error": None, "people": {
    "jdoe": identity("Jane Doe", "oid-jdoe", "100001@example.org"),
    "asmith": identity("Ola Nordmann", "oid-asmith", "100002@EXAMPLE.ORG"),
    "kim": identity("Kim Admin", "oid-kim", "kim@admin.example.net"),
    "lee": None}}


class IdentityTest(unittest.TestCase):
    """People named by their SAML identity, and mentioned once the relay can (§5, D11, D21)."""

    def decide(self, people=None, notifications=None, **overrides):
        rows = {"dev": row("dev"), "prod": row("prod", notifications=notifications)}
        given = {"identities": IDENTITIES, "rows": rows,
                 "metadata": {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}, **overrides}
        if people is not None:
            given["people"] = people
        return notify_decide.decide(facts(**given))

    def line(self, decided):
        return decided["messages"]["e1.md"].split("\n")[4]

    def test_people_are_named_by_their_identity(self):
        self.assertEqual("Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by Jane Doe, merged by "
                         "Ola Nordmann.", self.line(self.decide()))

    def test_an_identity_outside_the_people_domains_or_none_is_named_by_login(self):
        prs = [{"number": 7, "title": "", "author": "kim", "merged_by": "lee"}]
        decided = self.decide(people={"available": True, "error": None, "pull_requests": prs, "pusher": None})
        self.assertEqual("Change: [#7](https://github.com/o/r/pull/7) by kim, merged by lee.", self.line(decided))
        self.assertEqual([], decided["events"][0]["mentions"])

    def test_a_name_that_is_empty_or_could_carry_markup_is_the_login(self):
        people = {"available": True, "error": None, "pusher": None, "pull_requests": [
            {"number": 7, "title": "", "author": "jdoe", "merged_by": "asmith"}]}
        for name, shown in (("", "jdoe"), ("<b>J</b>", "jdoe"), ("J*o*", "jdoe"), ("[J](x)", "jdoe"),
                            ("Åse O'Brien-Ødegård Jr.", "Åse O'Brien-Ødegård Jr.")):
            identities = {"available": True, "error": None, "people": {
                "jdoe": identity(name, "oid-jdoe", "100001@example.org"), "asmith": None}}
            decided = self.decide(people=people, identities=identities)
            self.assertEqual(f"Change: [#7](https://github.com/o/r/pull/7) by {shown}, merged by asmith.",
                             self.line(decided))
            self.assertEqual([{"login": "jdoe", "object_id": "oid-jdoe", "name": shown}],
                             decided["events"][0]["mentions"])

    def test_identities_that_could_not_be_read_name_logins(self):
        decided = self.decide(identities={"available": False, "error": "x", "people": {}})
        self.assertEqual("Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by jdoe, merged by asmith.",
                         self.line(decided))
        self.assertEqual([], decided["events"][0]["mentions"])
        decided = self.decide(identities=None)
        self.assertEqual([], decided["events"][0]["mentions"])

    def test_the_author_is_mentioned_by_default(self):
        self.assertEqual([{"login": "jdoe", "object_id": "oid-jdoe", "name": "Jane Doe"}],
                         self.decide()["events"][0]["mentions"])

    def test_the_routing_chooses_who_is_mentioned(self):
        both = self.decide(notifications={"defaults": {"mention": ["author", "merger"]}})["events"][0]["mentions"]
        self.assertEqual(["jdoe", "asmith"], [m["login"] for m in both])
        merger = self.decide(notifications={"kinds": {"apply-failed": {"mention": "merger"}}})["events"][0]["mentions"]
        self.assertEqual(["asmith"], [m["login"] for m in merger])
        nobody = self.decide(notifications={"defaults": {"mention": []}})["events"][0]["mentions"]
        self.assertEqual([], nobody)

    def test_a_merger_who_is_an_author_is_mentioned_once(self):
        prs = [{"number": 7, "title": "", "author": "jdoe", "merged_by": "asmith"},
               {"number": 8, "title": "", "author": "asmith", "merged_by": "jdoe"}]
        decided = self.decide(people={"available": True, "error": None, "pull_requests": prs, "pusher": None},
                              notifications={"defaults": {"mention": ["author", "merger"]}})
        self.assertEqual(["jdoe", "asmith"], [m["login"] for m in decided["events"][0]["mentions"]])

    def test_people_of_several_pull_requests_are_named_and_mentioned_once(self):
        prs = [{"number": 7, "title": "", "author": "jdoe", "merged_by": "asmith"},
               {"number": 8, "title": "", "author": "jdoe", "merged_by": "asmith"}]
        people = {"available": True, "error": None, "pull_requests": prs, "pusher": None}
        decided = self.decide(people=people, notifications={"defaults": {"mention": ["author", "merger"]}})
        self.assertEqual(["jdoe", "asmith"], [m["login"] for m in decided["events"][0]["mentions"]])
        self.assertEqual(["jdoe", "asmith"], notify_decide.named(people))

    def test_a_direct_push_mentions_its_pusher_as_its_author(self):
        decided = self.decide(people={"available": True, "error": None, "pull_requests": [], "pusher": "jdoe"})
        self.assertEqual("Pushed by Jane Doe.", self.line(decided))
        self.assertEqual(["jdoe"], [m["login"] for m in decided["events"][0]["mentions"]])
        decided = self.decide(people={"available": True, "error": None, "pull_requests": [], "pusher": "jdoe"},
                              notifications={"defaults": {"mention": "merger"}})
        self.assertEqual([], decided["events"][0]["mentions"])

    def test_a_reply_mentions_too_and_a_resolution_or_a_schedule_never(self):
        reply = self.decide(state=state(prod__apply=incident()))
        self.assertEqual(("reply", ["jdoe"]), (reply["events"][0]["action"],
                                               [m["login"] for m in reply["events"][0]["mentions"]]))
        resolve = notify_decide.decide(facts(identities=IDENTITIES, state=state(prod__apply=incident())))
        self.assertEqual(("resolve", []), (resolve["events"][0]["action"], resolve["events"][0]["mentions"]))
        scheduled = self.decide(event="schedule", people=None)
        self.assertEqual([], scheduled["events"][0]["mentions"])


class RemindTest(unittest.TestCase):
    """Reminders on scheduled runs (§10): an open incident in the apply slot, by working days open."""

    def decide(self, now, opened_at="2026-10-05T08:30:00Z", level=None, plan_only=False, notifications=None,
               status="open", **overrides):
        opened = incident(status=status, opened_at=opened_at, people=("jdoe", "asmith"))
        if level is not None:
            opened["reminder_level"] = level
        goals = ("init", "plan") if plan_only else ("init", "plan", "apply")
        rows = {"dev": row("dev"), "prod": row("prod", goals=goals, notifications=notifications)}
        prod = metadata("prod", **({} if plan_only else {"apply": "failure"}))
        given = {"event": "schedule", "now": now, "people": None, "rows": rows,
                 "metadata": {"dev": metadata("dev"), "prod": prod}, "state": state(prod__apply=opened), **overrides}
        return notify_decide.decide(facts(**given))

    def actions(self, decided):
        return [(o["environment"], o["action"], o["reminder_level"]) for o in decided["observations"]
                if o["environment"] == "prod"]

    def test_a_working_day_open_is_the_first_reminder(self):
        # Opened Monday; Tuesday passed whole by Wednesday.
        decided = self.decide("2026-10-07T01:00:00Z")
        self.assertEqual([("prod", "remind", 1)], self.actions(decided))
        self.assertEqual([("remind", "msg-1", "tf-alerts", "prod", key("o/r", "4711", "1", "prod", "apply", "remind"))],
                         [(e["action"], e["reply_to"], e["alias"], e["sender"], e["idempotency_key"])
                          for e in decided["events"]])
        self.assertEqual(["⏰ **Still not applied** in `prod` · o/r", "",
                          "`prod` has not been applied for 1 working day, since the apply failed at 2026-10-05 08:30 "
                          "UTC.", "",
                          "The change was by jdoe and asmith.", "",
                          f"[Open the run]({RUN_URL})", ""],
                         decided["messages"]["e1.md"].split("\n"))
        self.assertIn("| `prod` | reminder 1 | to `tf-alerts` as `prod` |", decided["summary"])

    def test_the_day_it_opened_and_the_next_are_not_a_working_day_yet(self):
        for now in ("2026-10-05T23:00:00Z", "2026-10-06T23:59:59Z"):
            with self.subTest(now=now):
                self.assertEqual([("prod", "none", None)], self.actions(self.decide(now)))

    def test_a_weekend_is_no_working_day(self):
        friday = "2026-10-09T15:00:00Z"
        self.assertEqual([("prod", "none", None)], self.actions(self.decide("2026-10-12T01:00:00Z", opened_at=friday)))
        self.assertEqual([("prod", "remind", 1)], self.actions(self.decide("2026-10-13T01:00:00Z", opened_at=friday)))
        saturday = "2026-10-10T10:00:00Z"
        self.assertEqual([("prod", "remind", 1)], self.actions(self.decide("2026-10-13T01:00:00Z",
                                                                          opened_at=saturday)))

    def test_the_levels_come_after_one_three_and_every_five_more_working_days(self):
        # Opened Monday 2026-10-05: three working days have passed by Friday 10-09, eight by Friday 10-16,
        # thirteen by Friday 10-23.
        for level, now, expected in ((1, "2026-10-08T01:00:00Z", ("none", None)),
                                     (1, "2026-10-09T01:00:00Z", ("remind", 2)),
                                     (2, "2026-10-15T01:00:00Z", ("none", None)),
                                     (2, "2026-10-16T01:00:00Z", ("remind", 3)),
                                     (3, "2026-10-22T01:00:00Z", ("none", None)),
                                     (3, "2026-10-23T01:00:00Z", ("remind", 4)),
                                     (4, "2026-10-23T01:00:00Z", ("none", None))):
            with self.subTest(level=level, now=now):
                self.assertEqual([("prod", *expected)], self.actions(self.decide(now, level=level)))

    def test_a_late_first_schedule_reminds_once_at_the_level_due(self):
        decided = self.decide("2026-10-19T01:00:00Z")
        self.assertEqual([("prod", "remind", 3)], self.actions(decided))
        self.assertEqual("`prod` has not been applied for 9 working days, since the apply failed at 2026-10-05 08:30 "
                         "UTC.", decided["messages"]["e1.md"].split("\n")[2])

    def test_each_kind_says_what_happened(self):
        for kind, what in (("apply-cancelled", "the apply was cancelled"), ("held-back", "its stage was held back")):
            with self.subTest(kind=kind):
                opened = incident(kind=kind)
                decided = self.decide("2026-10-07T01:00:00Z", state=state(prod__apply=opened), plan_only=True)
                self.assertEqual(f"`prod` has not been applied for 1 working day, since {what} at 2026-10-05 08:30 "
                                 "UTC.", decided["messages"]["e1.md"].split("\n")[2])

    def test_a_scheduled_plan_that_does_not_apply_reminds_too(self):
        self.assertEqual([("prod", "remind", 1)], self.actions(self.decide("2026-10-07T01:00:00Z", plan_only=True)))

    def test_a_clean_scheduled_plan_resolves_instead(self):
        decided = self.decide("2026-10-07T01:00:00Z", plan_only=True,
                              metadata={"dev": metadata("dev"), "prod": dict(metadata("prod"), steps={
                                  "plan": {"outcome": "success", "outputs": {}},
                                  "parse-plan": {"outcome": "success", "outputs": {
                                      "count-total": "0", "has-output-only-changes": "false"}}})})
        self.assertEqual([("prod", "resolve", None)], self.actions(decided))

    def test_only_a_schedule_reminds(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertNotIn("remind", [a for _, a, _ in self.actions(self.decide("2026-10-07T01:00:00Z",
                                                                                       event=event))])

    def test_a_pending_incident_or_one_with_reminders_off_is_not_reminded(self):
        self.assertEqual([("prod", "none", None)],
                         self.actions(self.decide("2026-10-07T01:00:00Z", status="pending", plan_only=True)))
        for off in (False, "false"):
            with self.subTest(off=off):
                decided = self.decide("2026-10-07T01:00:00Z", notifications={"kinds": {"apply-failed": {"remind": off}}})
                self.assertEqual([("prod", "none", None)], self.actions(decided))
        decided = self.decide("2026-10-07T01:00:00Z", notifications={"kinds": {"held-back": {"remind": False}}})
        self.assertEqual([("prod", "remind", 1)], self.actions(decided))

    def test_an_environment_the_schedule_does_not_run_is_not_reminded(self):
        decided = self.decide("2026-10-07T01:00:00Z", environments=[{"environment": "dev", "verdict": "run", "stage": 1},
                                                                     {"environment": "prod", "verdict": "skip",
                                                                      "stage": 1}])
        self.assertEqual([], decided["events"])

    def test_the_first_reminder_mentions_whom_the_incident_opened_mentioning_the_second_everyone_named(self):
        identities = {"available": True, "error": None, "people": {
            "jdoe": identity("Jane Doe", "oid-jdoe", "1@example.org"),
            "asmith": identity("Ola Nordmann", "oid-asmith", "2@example.org")}}
        opened = incident(people=("jdoe", "asmith"))
        opened["mentioned"] = ["jdoe"]
        for level, now, mentioned in ((None, "2026-10-07T01:00:00Z", ["jdoe"]),
                                      (1, "2026-10-09T01:00:00Z", ["jdoe", "asmith"]),
                                      (2, "2026-10-16T01:00:00Z", [])):
            with self.subTest(level=level):
                given = dict(opened, **({} if level is None else {"reminder_level": level}))
                decided = self.decide(now, state=state(prod__apply=given), identities=identities)
                self.assertEqual(mentioned, [m["login"] for m in decided["events"][0]["mentions"]])
                self.assertEqual("The change was by Jane Doe and Ola Nordmann.",
                                 decided["messages"]["e1.md"].split("\n")[4])

    def test_a_state_from_before_reminders_mentions_everyone_named_first(self):
        identities = {"available": True, "error": None, "people": {
            "jdoe": identity("Jane Doe", "oid-jdoe", "1@example.org"), "asmith": None}}
        decided = self.decide("2026-10-07T01:00:00Z", identities=identities)
        self.assertEqual(["jdoe"], [m["login"] for m in decided["events"][0]["mentions"]])

    def test_a_reminder_goes_where_the_incident_went_as_its_sender(self):
        opened = incident(alias="tf-old", sender_name="dev")
        decided = self.decide("2026-10-07T01:00:00Z", state=state(prod__apply=opened))
        self.assertEqual([("remind", "tf-old", "dev")], [(e["action"], e["alias"], e["sender"]) for e in decided["events"]])

    def test_an_opening_remembers_whom_it_meant_to_mention_and_nothing_else_does(self):
        failing = {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}
        opened = notify_decide.decide(facts(metadata=failing))
        self.assertEqual(["jdoe"], [o for o in opened["observations"] if o["environment"] == "prod"][0]["mentioned"])
        replied = notify_decide.decide(facts(metadata=failing, state=state(prod__apply=incident())))
        self.assertEqual(("reply", []), [(o["action"], o["mentioned"]) for o in replied["observations"]
                                         if o["environment"] == "prod"][0])

    def test_working_days_across_a_leap_day_a_new_year_and_a_month(self):
        for since, now, days in (("2028-02-28T09:00:00Z", "2028-03-02T01:00:00Z", 2),
                                 ("2026-12-31T09:00:00Z", "2027-01-05T01:00:00Z", 2),
                                 ("2026-01-30T09:00:00Z", "2026-02-03T01:00:00Z", 1),
                                 ("2100-02-26T09:00:00Z", "2100-03-03T01:00:00Z", 2),
                                 # Across the 400-year eras of the arithmetic, and inside the years 2000 to 2004,
                                 # where an era of 401 years would read the same as one of 400.
                                 ("2000-02-25T09:00:00Z", "2000-03-02T01:00:00Z", 3),
                                 ("1999-12-30T09:00:00Z", "2000-01-04T01:00:00Z", 2),
                                 ("2004-02-27T09:00:00Z", "2004-03-03T01:00:00Z", 2),
                                 ("2001-06-01T09:00:00Z", "2001-06-06T01:00:00Z", 2),
                                 ("2026-10-07T09:00:00Z", "2026-10-07T23:00:00Z", 0),
                                 ("2026-10-07T09:00:00Z", "2026-10-06T23:00:00Z", 0)):
            with self.subTest(since=since, now=now):
                self.assertEqual(days, notify_decide.working_days(since, now))

    def test_the_level_due_after_each_age(self):
        self.assertEqual([0, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 4],
                         [notify_decide.reminder_due(age) for age in range(14)])

    def test_people_are_named_as_a_list(self):
        for people, line in (((), None), (("jdoe",), "The change was by jdoe."),
                             (("a", "b", "c"), "The change was by a, b and c.")):
            with self.subTest(people=people):
                decided = self.decide("2026-10-07T01:00:00Z", state=state(prod__apply=incident(people=people)))
                lines = decided["messages"]["e1.md"].split("\n")
                self.assertEqual(line, lines[4] if len(lines) == 8 else None)


PLAN_ONLY = ("init", "format", "validate", "lint", "plan")
DRIFTED = ["azurerm_storage_account.logs", 'module.net.azurerm_subnet.app["web"]']


def planned(name, plan_class, pending=False, fingerprint="f1", drift=0, addresses=(), add=0, change=0, destroy=0,
            outputs_only=False):
    """The metadata of a plan-only job whose plan succeeded and was classified (Drift-detection.md §4)."""
    content = metadata(name, apply="skipped")
    content["steps"]["parse-plan"] = {"outcome": "success", "outputs": {
        "count-total": str(add + change + destroy), "count-add": str(add), "count-change": str(change),
        "count-destroy": str(destroy), "count-import": "0", "count-move": "0", "count-remove": "0",
        "has-output-only-changes": "true" if outputs_only else "false", "plan-complete": "true",
        "plan-class": plan_class, "count-drift": str(drift), "has-pending-changes": "true" if pending else "false",
        "drift-addresses": json.dumps(list(addresses)), "plan-fingerprint": fingerprint}}
    return content


def drifted(fingerprint="f1", pending=False, addresses=DRIFTED, drift=None, **counts):
    return planned("prod", "drift", pending=pending, fingerprint=fingerprint,
                   drift=len(addresses) if drift is None else drift, addresses=addresses, **({"change": 2} | counts))


class ScheduledFindingTest(unittest.TestCase):
    """What a scheduled plan-only run finds (Drift-detection.md §4, §5): drift in the drift slot, a default branch
    not applied in the apply slot."""

    def decide(self, prod, event="schedule", now=NOW, notifications=None, goals=PLAN_ONLY, **overrides):
        rows = {"dev": row("dev"), "prod": row("prod", goals=goals, notifications=notifications)}
        given = {"event": event, "now": now, "people": None, "rows": rows,
                 "metadata": {"dev": metadata("dev"), "prod": prod}, **overrides}
        return notify_decide.decide(facts(**given))

    def prod(self, decided):
        return [(o["slot"], o["action"]) for o in decided["observations"] if o["environment"] == "prod"]

    def test_drift_opens_an_incident_in_the_drift_slot(self):
        decided = self.decide(drifted())
        self.assertEqual([("apply", "none"), ("drift", "open")], self.prod(decided))
        self.assertEqual([("drift", "drift", "open", key("o/r", "4711", "1", "prod", "drift", "open"), [])],
                         [(e["slot"], e["kind"], e["action"], e["idempotency_key"], e["mentions"])
                          for e in decided["events"]])
        self.assertEqual(["🌀 **Drift** in `prod` · o/r", "",
                          "2 resources in `prod` changed outside Terraform, and the next apply would change them back:",
                          "",
                          "- `azurerm_storage_account.logs`",
                          "- `module.net.azurerm_subnet.app[\"web\"]`", "",
                          "Found by the scheduled run.", "",
                          f"[Open the run]({RUN_URL})", ""],
                         decided["messages"]["e1.md"].split("\n"))
        self.assertEqual(("drift", "f1"), [(o["result"], o["fingerprint"]) for o in decided["observations"]
                                           if o["slot"] == "drift"][0])
        self.assertIn("| `prod` | drift | to `tf-alerts` as `prod` |", decided["summary"])

    def test_one_drifted_resource_reads_in_the_singular(self):
        decided = self.decide(drifted(addresses=["a.b"]))
        self.assertEqual("1 resource in `prod` changed outside Terraform, and the next apply would change it back:",
                         decided["messages"]["e1.md"].split("\n")[2])

    def test_at_most_twenty_addresses_are_listed_and_each_is_a_safe_code_span(self):
        addresses = [f"a.r{i:02d}" for i in range(25)]
        decided = self.decide(drifted(addresses=addresses[:22], drift=60))
        lines = decided["messages"]["e1.md"].split("\n")
        self.assertEqual("60 resources in `prod` changed outside Terraform, and the next apply would change them back:",
                         lines[2])
        self.assertEqual([f"- `a.r{i:02d}`" for i in range(20)] + ["- and 40 more"], lines[4:25])
        decided = self.decide(drifted(addresses=["a.b[\"x`y <z>\"]"]))
        self.assertEqual("- `a.b[\"x'y ‹z›\"]`", decided["messages"]["e1.md"].split("\n")[4])

    def test_addresses_that_cannot_be_read_are_left_out(self):
        for broken in ("not json", json.dumps({"a": 1}), json.dumps([1, "a.b"])):
            with self.subTest(broken=broken):
                prod = drifted(drift=3)
                prod["steps"]["parse-plan"]["outputs"]["drift-addresses"] = broken
                lines = self.decide(prod)["messages"]["e1.md"].split("\n")
                self.assertEqual(["3 resources in `prod` changed outside Terraform, and the next apply would change them "
                                  "back.", "", "Found by the scheduled run."], lines[2:5])

    def test_the_same_drift_again_sends_nothing_until_a_weekly_reminder(self):
        opened = incident(kind="drift", people=())
        opened.update(fingerprint="f1", mentioned=[], reminder_level=0)
        for now, expected in (("2026-10-09T01:00:00Z", ("drift", "none")),   # 3 working days
                              ("2026-10-13T01:00:00Z", ("drift", "remind"))):  # 5 working days
            with self.subTest(now=now):
                decided = self.decide(drifted(), now=now, state=state(prod__drift=opened))
                self.assertEqual([("apply", "none"), expected], self.prod(decided))
        self.assertEqual(["⏰ **Still drifted** in `prod` · o/r", "",
                          "`prod` has drifted for 5 working days, since the scheduled plan found it at 2026-10-05 08:30 "
                          "UTC.", "", f"[Open the run]({RUN_URL})", ""], decided["messages"]["e1.md"].split("\n"))
        self.assertEqual([], decided["events"][0]["mentions"])
        opened["reminder_level"] = 1
        self.assertEqual([("apply", "none"), ("drift", "none")],
                         self.prod(self.decide(drifted(), now="2026-10-16T01:00:00Z", state=state(prod__drift=opened))))
        self.assertEqual([("apply", "none"), ("drift", "remind")],
                         self.prod(self.decide(drifted(), now="2026-10-20T01:00:00Z", state=state(prod__drift=opened))))
        off = {"kinds": {"drift": {"remind": False}}}
        opened["reminder_level"] = 0
        self.assertEqual([("apply", "none"), ("drift", "none")],
                         self.prod(self.decide(drifted(), now="2026-10-13T01:00:00Z", notifications=off,
                                               state=state(prod__drift=opened))))

    def test_a_reminder_or_a_resolution_of_drift_goes_where_the_incident_went(self):
        opened = incident(kind="drift", people=(), alias="tf-old", sender_name="dev")
        opened["fingerprint"] = "f1"
        for prod, now, action in ((drifted(), "2026-10-13T01:00:00Z", "remind"),
                                  (planned("prod", "clean", fingerprint=""), NOW, "resolve")):
            with self.subTest(action=action):
                decided = self.decide(prod, now=now, state=state(prod__drift=opened))
                self.assertEqual([(action, "tf-old", "dev")], [(e["action"], e["alias"], e["sender"])
                                                              for e in decided["events"] if e["slot"] == "drift"])

    def test_a_drift_incident_from_before_reminders_and_reminders_off_as_text(self):
        opened = incident(kind="drift", people=())
        opened["fingerprint"] = "f1"
        self.assertIn(("drift", "remind"), self.prod(self.decide(drifted(), now="2026-10-13T01:00:00Z",
                                                                 state=state(prod__drift=opened))))
        off = {"kinds": {"drift": {"remind": "false"}}}
        self.assertIn(("drift", "none"), self.prod(self.decide(drifted(), now="2026-10-13T01:00:00Z", notifications=off,
                                                               state=state(prod__drift=opened))))

    def test_drift_after_a_resolved_or_pending_incident_opens_anew(self):
        for status in ("resolved", "pending"):
            with self.subTest(status=status):
                opened = incident(kind="drift", people=(), status=status)
                opened["fingerprint"] = "f0"
                self.assertIn(("drift", "open"), self.prod(self.decide(drifted(), state=state(prod__drift=opened))))

    def test_drift_routes_to_its_alias_and_turns_off_as_text(self):
        decided = self.decide(drifted(), notifications={"kinds": {"drift": {"alias": "tf-drift"}}})
        self.assertEqual([("open", "tf-drift")], [(e["action"], e["alias"]) for e in decided["events"]])
        decided = self.decide(drifted(), notifications={"kinds": {"drift": {"off": "true"}}})
        self.assertEqual([], decided["events"])

    def test_a_drift_count_that_is_not_a_number_counts_the_addresses(self):
        prod = drifted(addresses=["a.b", "c.d"])
        prod["steps"]["parse-plan"]["outputs"]["count-drift"] = "?"
        self.assertEqual("2 resources in `prod` changed outside Terraform, and the next apply would change them back:",
                         self.decide(prod)["messages"]["e1.md"].split("\n")[2])
        prod["steps"]["parse-plan"]["outputs"]["drift-addresses"] = "x"
        self.assertEqual("0 resources in `prod` changed outside Terraform, and the next apply would change them back.",
                         self.decide(prod)["messages"]["e1.md"].split("\n")[2])

    def test_an_apply_resolves_a_pending_drift_incident_quietly(self):
        opened = incident(kind="drift", people=(), status="pending", message_id=None)
        decided = notify_decide.decide(facts(event="push", now=NOW, state=state(prod__drift=opened)))
        self.assertEqual(([], [("drift", "resolve", "applied")]),
                         (decided["events"], [(o["slot"], o["action"], o["result"]) for o in decided["observations"]
                                              if o["slot"] == "drift"]))

    def test_other_drift_is_a_reply(self):
        opened = incident(kind="drift", alias="tf-old", people=())
        opened["fingerprint"] = "f1"
        decided = self.decide(drifted(fingerprint="f2", addresses=["a.b"]), state=state(prod__drift=opened))
        self.assertEqual([("reply", "msg-1", "tf-old")], [(e["action"], e["reply_to"], e["alias"])
                                                          for e in decided["events"]])
        self.assertEqual(["🌀 **Drift changed** in `prod` · o/r", "",
                          "1 resource in `prod` changed outside Terraform, and the next apply would change it back:"],
                         decided["messages"]["e1.md"].split("\n")[:3])
        self.assertEqual("f2", [o for o in decided["observations"] if o["slot"] == "drift"][0]["fingerprint"])
        self.assertIn("| `prod` | drift changed | to `tf-old` as `prod` |", decided["summary"])

    def test_no_drift_resolves_and_a_pending_drift_incident_quietly(self):
        opened = incident(kind="drift", people=())
        opened["fingerprint"] = "f1"
        for prod in (planned("prod", "clean", fingerprint=""), planned("prod", "pending", pending=True, add=1)):
            with self.subTest(plan_class=prod["steps"]["parse-plan"]["outputs"]["plan-class"]):
                decided = self.decide(prod, state=state(prod__drift=opened))
                drift = [e for e in decided["events"] if e["slot"] == "drift"]
                self.assertEqual([("resolve", "msg-1")], [(e["action"], e["reply_to"]) for e in drift])
                self.assertEqual(["✅ **No drift** in `prod` · o/r", "",
                                  "The scheduled plan of `prod` finds no drift: the drift found at 2026-10-05 08:30 UTC "
                                  "is gone."], decided["messages"][drift[0]["message"]].split("\n")[:3])
                self.assertEqual(["no-drift"], [o["result"] for o in decided["observations"] if o["slot"] == "drift"])
        decided = self.decide(planned("prod", "clean", fingerprint=""),
                              state=state(prod__drift=dict(opened, status="pending", message_id=None)))
        self.assertEqual(([], [("apply", "clean"), ("drift", "resolve")]),
                         (decided["events"], [(o["slot"], o["result"]) if o["slot"] == "apply" else
                                              (o["slot"], o["action"]) for o in decided["observations"]
                                              if o["environment"] == "prod"]))

    def test_an_apply_changes_drift_back_and_resolves_it_on_any_event(self):
        opened = incident(kind="drift", people=())
        opened["fingerprint"] = "f1"
        for event in ("push", "schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                decided = notify_decide.decide(facts(event=event, now=NOW, state=state(prod__drift=opened)))
                self.assertEqual([("drift", "resolve")], [(e["slot"], e["action"]) for e in decided["events"]])
                self.assertEqual(["✅ **No drift** in `prod` · o/r", "",
                                  "`prod` is applied, which changed back the drift found at 2026-10-05 08:30 UTC."],
                                 decided["messages"]["e1.md"].split("\n")[:3])

    def test_drift_is_found_by_a_scheduled_plan_only_run_alone(self):
        for event, goals in (("push", PLAN_ONLY), ("workflow_dispatch", PLAN_ONLY), ("schedule", None)):
            with self.subTest(event=event, goals=goals):
                given = {} if goals else {"goals": ("init", "plan", "apply")}
                decided = self.decide(drifted(), event=event, **({"goals": goals} if goals else given))
                self.assertEqual([], [e for e in decided["events"] if e["slot"] == "drift"])

    def test_unknown_or_failed_plans_say_nothing_about_drift(self):
        opened = incident(kind="drift", people=())
        opened["fingerprint"] = "f1"
        for prod in (planned("prod", "unknown", fingerprint=""), metadata("prod", plan="failure", apply="skipped"),
                     planned("prod", "", fingerprint="")):
            with self.subTest(prod=prod["steps"].get("parse-plan")):
                drift_and_apply = [each for each in self.prod(self.decide(prod, state=state(prod__drift=opened)))
                                   if each[0] != "schedule"]
                self.assertEqual([("apply", "none"), ("drift", "none")], drift_and_apply)
                self.assertEqual([("apply", "none")], [each for each in self.prod(self.decide(prod))
                                                       if each[0] != "schedule"])

    def test_drift_switched_off_opens_nothing(self):
        decided = self.decide(drifted(), notifications={"kinds": {"drift": {"off": True}}})
        self.assertEqual(([], [("apply", "none")]), (decided["events"], self.prod(decided)))

    def test_pending_changes_open_a_default_branch_not_applied(self):
        decided = self.decide(planned("prod", "pending", pending=True, add=2, change=1))
        self.assertEqual([("apply", "open")], self.prod(decided))
        self.assertEqual([("apply", "pending-change", "open")], [(e["slot"], e["kind"], e["action"])
                                                                 for e in decided["events"]])
        self.assertEqual(["⏳ **Not applied** in `prod` · o/r", "",
                          "The scheduled plan of `prod` has 3 changes (2 to add, 1 to change), so the default branch "
                          "is not applied in `prod`.", "",
                          "Found by the scheduled run.", "",
                          f"[Open the run]({RUN_URL})", ""], decided["messages"]["e1.md"].split("\n"))
        self.assertIn("| `prod` | not applied | to `tf-alerts` as `prod` |", decided["summary"])

    def test_the_pending_reason_names_each_count_and_output_changes(self):
        for prod, reason in ((planned("prod", "pending", pending=True, destroy=1),
                              "The scheduled plan of `prod` has 1 change (1 to destroy), so the default branch is not "
                              "applied in `prod`."),
                             (planned("prod", "pending", pending=True, outputs_only=True),
                              "The scheduled plan of `prod` changes only outputs, so the default branch is not applied "
                              "in `prod`.")):
            with self.subTest(reason=reason):
                self.assertEqual(reason, self.decide(prod)["messages"]["e1.md"].split("\n")[2])

    def test_drift_beside_changes_of_its_own_opens_both(self):
        decided = self.decide(drifted(pending=True, add=1))
        self.assertEqual([("apply", "open"), ("drift", "open")], self.prod(decided))
        self.assertEqual(["pending-change", "drift"], [e["kind"] for e in decided["events"]])

    def test_drift_alone_or_no_changes_resolve_the_apply_slot(self):
        for prod in (drifted(), planned("prod", "clean", fingerprint="")):
            with self.subTest(plan_class=prod["steps"]["parse-plan"]["outputs"]["plan-class"]):
                decided = self.decide(prod, state=state(prod__apply=incident()))
                self.assertEqual(("apply", "resolve"), self.prod(decided)[0])

    def test_pending_changes_with_an_apply_incident_open_are_its_reminder(self):
        decided = self.decide(planned("prod", "pending", pending=True, add=1), now="2026-10-07T01:00:00Z",
                              state=state(prod__apply=incident(kind="pending-change", people=())))
        self.assertEqual([("apply", "remind")], self.prod(decided))
        self.assertEqual("`prod` has not been applied for 1 working day, since the scheduled plan found changes at "
                         "2026-10-05 08:30 UTC.", decided["messages"]["e1.md"].split("\n")[2])

    def test_the_pending_reason_counts_every_kind_and_skips_what_is_not_a_number(self):
        prod = planned("prod", "pending", pending=True)
        prod["steps"]["parse-plan"]["outputs"].update({"count-import": "1", "count-move": "2", "count-remove": "1",
                                                       "count-add": "x"})
        self.assertEqual("The scheduled plan of `prod` has 4 changes (1 to import, 2 to move, 1 to remove), so the "
                         "default branch is not applied in `prod`.", self.decide(prod)["messages"]["e1.md"].split("\n")[2])

    def test_pending_changes_on_a_dispatch_or_switched_off_open_nothing(self):
        prod = planned("prod", "pending", pending=True, add=1)
        self.assertEqual([("apply", "none")], self.prod(self.decide(prod, event="workflow_dispatch")))
        self.assertEqual([("apply", "none")],
                         self.prod(self.decide(prod, notifications={"kinds": {"pending-change": {"off": True}}})))


class ScheduleSlotTest(unittest.TestCase):
    """A scheduled plan that fails or cannot be read (Drift-detection.md D6): the schedule slot."""

    def decide(self, prod, checks=None, incidents=None, now=NOW, notifications=None, **overrides):
        rows = {"dev": row("dev"), "prod": row("prod", goals=PLAN_ONLY, notifications=notifications)}
        stored = {"schema_version": 1, "incidents": incidents or {}}
        if checks is not None:
            stored["checks"] = {"prod": checks}
        given = {"event": "schedule", "now": now, "people": None, "rows": rows, "state": stored,
                 "metadata": {"dev": metadata("dev"), "prod": prod}, **overrides}
        return notify_decide.decide(facts(**given))

    def schedule(self, decided):
        return [(o["action"], o["kind"], o["checks"]) for o in decided["observations"]
                if o["environment"] == "prod" and o["slot"] == "schedule"]

    def failed(self, step="plan"):
        return metadata("prod", **{step: "failure"}, apply="skipped")

    def test_the_first_failed_scheduled_plan_is_counted_and_the_second_opens_an_incident(self):
        self.assertEqual([("none", None, {"failed": 1, "unread": 0})], self.schedule(self.decide(self.failed())))
        decided = self.decide(self.failed(), checks={"failed": 1, "unread": 0, "seen_run": 41})
        self.assertEqual([("open", "scheduled-failed", {"failed": 2, "unread": 0})], self.schedule(decided))
        self.assertEqual([("schedule", "scheduled-failed", "open", key("o/r", "4711", "1", "prod", "schedule", "open"))],
                         [(e["slot"], e["kind"], e["action"], e["idempotency_key"]) for e in decided["events"]])
        self.assertEqual(["❌ **Scheduled plan failed** in `prod` · o/r", "",
                          "The scheduled plan of `prod` failed 2 times in a row, the last at the `plan` step: drift "
                          "and a default branch that is not applied go unseen.", "",
                          "Found by the scheduled run.", "",
                          f"[Open the run]({RUN_URL})", ""], decided["messages"]["e1.md"].split("\n"))
        self.assertIn("| `prod` | scheduled plan failed | to `tf-alerts` as `prod` |", decided["summary"])

    def test_a_job_that_reported_nothing_fails_too(self):
        decided = self.decide(None, checks={"failed": 1, "unread": 0, "seen_run": 41},
                              stage_results={"1": "failure", "2": "skipped", "3": "skipped"})
        self.assertEqual("The scheduled plan of `prod` failed 2 times in a row, the last without reporting its steps: "
                         "drift and a default branch that is not applied go unseen.",
                         decided["messages"]["e1.md"].split("\n")[2])

    def test_the_third_plan_in_a_row_that_cannot_be_read_opens_an_incident(self):
        unread = planned("prod", "unknown", fingerprint="")
        self.assertEqual([("none", None, {"failed": 0, "unread": 2})],
                         self.schedule(self.decide(unread, checks={"failed": 0, "unread": 1, "seen_run": 41})))
        decided = self.decide(unread, checks={"failed": 0, "unread": 2, "seen_run": 41})
        self.assertEqual([("open", "drift-check-failing", {"failed": 0, "unread": 3})], self.schedule(decided))
        self.assertEqual(["⚠️ **Drift check failing** in `prod` · o/r", "",
                          "The scheduled plan of `prod` could not be read 3 times in a row: drift and a default branch "
                          "that is not applied go unseen.", "", "Found by the scheduled run.", "",
                          f"[Open the run]({RUN_URL})", ""], decided["messages"]["e1.md"].split("\n"))
        old = planned("prod", "", fingerprint="")
        old["steps"]["parse-plan"]["outputs"]["count-total"] = "?"
        self.assertEqual([("none", None, {"failed": 0, "unread": 1})], self.schedule(self.decide(old)))

    def test_a_failure_breaks_a_row_of_unread_plans_and_a_read_plan_a_row_of_failures(self):
        self.assertEqual([("none", None, {"failed": 1, "unread": 0})],
                         self.schedule(self.decide(self.failed(), checks={"failed": 0, "unread": 2, "seen_run": 41})))
        self.assertEqual([("none", None, {"failed": 0, "unread": 1})],
                         self.schedule(self.decide(planned("prod", "unknown", fingerprint=""),
                                                   checks={"failed": 1, "unread": 0, "seen_run": 41})))

    def test_a_readable_plan_resets_the_counts_and_resolves(self):
        clean = planned("prod", "clean", fingerprint="")
        self.assertEqual([("none", None, {"failed": 0, "unread": 0})],
                         self.schedule(self.decide(clean, checks={"failed": 1, "unread": 0, "seen_run": 41})))
        self.assertEqual([], self.schedule(self.decide(clean)))
        self.assertEqual([], self.schedule(self.decide(clean, checks={"failed": 0, "unread": 0, "seen_run": 41})))
        opened = incident(kind="scheduled-failed", people=())
        decided = self.decide(clean, checks={"failed": 2, "unread": 0, "seen_run": 41},
                              incidents={"prod/schedule": opened})
        self.assertEqual([("resolve", None, {"failed": 0, "unread": 0})], self.schedule(decided))
        self.assertEqual(["✅ **Scheduled plan works** in `prod` · o/r", "",
                          "The scheduled plan of `prod` ran and was read: the incident opened at 2026-10-05 08:30 UTC "
                          "is resolved."], decided["messages"]["e1.md"].split("\n")[:3])

    def test_an_open_incident_is_not_opened_again_and_reminds_weekly(self):
        opened = incident(kind="scheduled-failed", people=())
        incidents = {"prod/schedule": opened}
        self.assertEqual([("none", None, {"failed": 3, "unread": 0})],
                         self.schedule(self.decide(self.failed(), checks={"failed": 2, "unread": 0, "seen_run": 41},
                                                   incidents=incidents)))
        decided = self.decide(self.failed(), checks={"failed": 2, "unread": 0, "seen_run": 41}, incidents=incidents,
                              now="2026-10-13T01:00:00Z")
        self.assertEqual([("remind", None, {"failed": 3, "unread": 0})], self.schedule(decided))
        self.assertEqual(["⏰ **Scheduled plan still failing** in `prod` · o/r", "",
                          "The scheduled plan of `prod` has not worked for 5 working days, since 2026-10-05 08:30 UTC."],
                         decided["messages"]["e1.md"].split("\n")[:3])

    def test_the_summary_names_a_failing_drift_check(self):
        decided = self.decide(planned("prod", "unknown", fingerprint=""), checks={"failed": 0, "unread": 2, "seen_run": 41})
        self.assertIn("| `prod` | drift check failing | to `tf-alerts` as `prod` |", decided["summary"])

    def test_a_pending_incident_opens_again(self):
        pending = incident(kind="scheduled-failed", people=(), status="pending", message_id=None)
        decided = self.decide(self.failed(), checks={"failed": 1, "unread": 0, "seen_run": 41},
                              incidents={"prod/schedule": pending})
        self.assertEqual([("open", "scheduled-failed", {"failed": 2, "unread": 0})], self.schedule(decided))

    def test_reminders_go_where_the_incident_went_and_respect_its_kinds_routing(self):
        opened = incident(kind="scheduled-failed", people=(), alias="tf-old", sender_name="dev")
        checks = {"failed": 2, "unread": 0, "seen_run": 41}
        decided = self.decide(self.failed(), checks=checks, incidents={"prod/schedule": opened},
                              now="2026-10-13T01:00:00Z")
        self.assertEqual([("remind", "tf-old", "dev")], [(e["action"], e["alias"], e["sender"])
                                                        for e in decided["events"]])
        for off in (False, "false"):
            with self.subTest(off=off):
                decided = self.decide(self.failed(), checks=checks, incidents={"prod/schedule": opened},
                                      now="2026-10-13T01:00:00Z",
                                      notifications={"kinds": {"scheduled-failed": {"remind": off}}})
                self.assertEqual([("none", None, {"failed": 3, "unread": 0})], self.schedule(decided))
        decided = self.decide(planned("prod", "clean", fingerprint=""), checks=checks,
                              incidents={"prod/schedule": opened})
        self.assertEqual([("resolve", "tf-old", "dev")], [(e["action"], e["alias"], e["sender"])
                                                         for e in decided["events"]])

    def test_a_resolved_incident_opens_anew_and_a_pending_one_resolves_quietly(self):
        resolved = incident(kind="scheduled-failed", people=(), status="resolved")
        self.assertEqual([("open", "scheduled-failed", {"failed": 2, "unread": 0})],
                         self.schedule(self.decide(self.failed(), checks={"failed": 1, "unread": 0, "seen_run": 41},
                                                   incidents={"prod/schedule": resolved})))
        pending = incident(kind="scheduled-failed", people=(), status="pending", message_id=None)
        decided = self.decide(planned("prod", "clean", fingerprint=""), checks={"failed": 2, "unread": 0, "seen_run": 41},
                              incidents={"prod/schedule": pending})
        self.assertEqual(([], [("resolve", None, {"failed": 0, "unread": 0})]), (decided["events"], self.schedule(decided)))

    def test_routing_to_an_alias_and_off_as_text(self):
        checks = {"failed": 1, "unread": 0, "seen_run": 41}
        decided = self.decide(self.failed(), checks=checks,
                              notifications={"kinds": {"scheduled-failed": {"alias": "tf-health"}}})
        self.assertEqual([("open", "tf-health")], [(e["action"], e["alias"]) for e in decided["events"]])
        decided = self.decide(self.failed(), checks=checks, notifications={"kinds": {"scheduled-failed": {"off": "true"}}})
        self.assertEqual([], decided["events"])

    def test_an_incident_reminded_at_the_level_due_is_not_reminded_again(self):
        opened = incident(kind="scheduled-failed", people=())
        opened["reminder_level"] = 1
        decided = self.decide(self.failed(), checks={"failed": 2, "unread": 0, "seen_run": 41},
                              incidents={"prod/schedule": opened}, now="2026-10-13T01:00:00Z")
        self.assertEqual([("none", None, {"failed": 3, "unread": 0})], self.schedule(decided))

    def test_an_incident_from_before_reminders_is_reminded(self):
        opened = incident(kind="drift-check-failing", people=())
        decided = self.decide(planned("prod", "unknown", fingerprint=""), checks={"failed": 0, "unread": 3, "seen_run": 41},
                              incidents={"prod/schedule": opened}, now="2026-10-13T01:00:00Z")
        self.assertEqual([("remind", None, {"failed": 0, "unread": 4})], self.schedule(decided))

    def test_a_reconcile_or_a_job_that_did_not_report_and_did_not_fail_counts_nothing(self):
        rows = {"dev": row("dev"), "prod": row("prod")}
        self.assertEqual([], self.schedule(self.decide(self.failed(), rows=rows)))
        self.assertEqual([], self.schedule(self.decide(None, checks={"failed": 1, "unread": 0, "seen_run": 41},
                                                       stage_results={"1": "success", "2": "skipped",
                                                                      "3": "skipped"})))

    def test_a_cancelled_plan_counts_nothing(self):
        cancelled = metadata("prod", plan="cancelled", apply="skipped")
        self.assertEqual([], self.schedule(self.decide(cancelled)))
        self.assertEqual([], self.schedule(self.decide(cancelled, checks={"failed": 1, "unread": 0, "seen_run": 41})))

    def test_only_a_scheduled_plan_only_run_counts(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual([], self.schedule(self.decide(self.failed(), event=event)))

    def test_switched_off_counts_but_opens_nothing(self):
        decided = self.decide(self.failed(), checks={"failed": 1, "unread": 0, "seen_run": 41},
                              notifications={"kinds": {"scheduled-failed": {"off": True}}})
        self.assertEqual(([], [("none", None, {"failed": 2, "unread": 0})]), (decided["events"], self.schedule(decided)))


class WantedTest(unittest.TestCase):
    def test_people_only_for_a_push_that_opens_or_repeats(self):
        failing = {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}
        self.assertEqual({"people": True, "protection": ["prod"], "reminded": []},
                         notify_decide.wanted(facts(metadata=failing, people=None, protection=None)))
        self.assertEqual({"people": False, "protection": ["prod"], "reminded": []},
                         notify_decide.wanted(facts(event="schedule", metadata=failing, people=None, protection=None)))
        self.assertEqual({"people": False, "protection": [], "reminded": []},
                         notify_decide.wanted(facts(people=None, protection=None)))
        self.assertEqual({"people": False, "protection": ["prod"], "reminded": []},
                         notify_decide.wanted(facts(people=None, protection=None,
                                                    state=state(prod__apply=incident()))))
        self.assertEqual({"people": True, "protection": ["prod"], "reminded": []},
                         notify_decide.wanted(facts(metadata=failing, people=None, protection=None,
                                                    state=state(prod__apply=incident()))))

    def test_the_people_a_reminder_names_are_looked_up(self):
        failing = {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}
        opened = incident(people=("jdoe", "asmith"))
        self.assertEqual({"people": False, "protection": ["prod"], "reminded": ["jdoe", "asmith"]},
                         notify_decide.wanted(facts(event="schedule", now="2026-10-07T01:00:00Z", metadata=failing,
                                                    people=None, protection=None, state=state(prod__apply=opened))))
        opened["mentioned"] = ["asmith"]
        self.assertEqual(["jdoe", "asmith"], notify_decide.wanted(facts(
            event="schedule", now="2026-10-07T01:00:00Z", metadata=failing, people=None, protection=None,
            state=state(prod__apply=opened)))["reminded"])

    def test_wanted_does_not_change_the_facts(self):
        given = facts(people=None, protection=None)
        before = copy.deepcopy(given)
        notify_decide.wanted(given)
        notify_decide.decide(given)
        self.assertEqual(before, given)


if __name__ == "__main__":
    unittest.main()
