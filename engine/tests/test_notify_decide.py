"""decide-notifications' rules (docs/Notifications.md §4, §5, §9, §11): an environment's result, what it does
to its incident, who is named, the message, and the deliver rows.

Every message and line is compared as a literal.
"""

import copy
import hashlib
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
        return {observation["environment"]: observation["result"] for observation in decided["observations"]}

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
                           "idempotency_key": key("o/r", "4711", "1", "prod", "apply", "open"), "message": "e1.md"}],
                         decided["events"])
        self.assertEqual(["❌ **Apply failed** in `prod` · `o/r`",
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
            ({"plan": "failure", "apply": "skipped"}, "❌ **Apply failed** in `prod` · `o/r`",
             "The `plan` step failed, so `apply` did not run and the default branch is not applied in `prod`."),
            ({"apply": "cancelled"}, "🚫 **Apply cancelled** in `prod` · `o/r`",
             "The `apply` step was cancelled, so `prod` may be partly applied."),
            ({"lint": "cancelled", "plan": "skipped", "apply": "skipped"}, "🚫 **Apply cancelled** in `prod` · `o/r`",
             "The job was cancelled at the `lint` step, so `apply` did not run and the default branch is not applied "
             "in `prod`."),
            ({"apply": "skipped"}, "❌ **Apply failed** in `prod` · `o/r`",
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
                self.assertEqual("⏸️ **Held back** in `prod` · `o/r`", decided["messages"]["e2.md"].split("\n")[0])
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
                           "sending": False}],
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
        self.assertEqual(["❌ **Apply failed again** in `prod` · `o/r`", "",
                          "The `apply` step failed, so the default branch is not applied in `prod`. It has not been "
                          "applied since 2026-10-05 08:30 UTC."],
                         decided["messages"]["e1.md"].split("\n")[:3])

    def test_an_open_incident_failing_again_on_a_schedule_or_a_dispatch_sends_nothing(self):
        for event in ("schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                decided = notify_decide.decide(self.failing(event=event, state=state(prod__apply=incident())))
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
                self.assertEqual(["✅ **Applied** `prod` · `o/r`", "",
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
        self.assertEqual("A plan of `prod` has no changes: the incident opened at 2026-10-05 08:30 UTC is resolved.",
                         decided["messages"]["e1.md"].split("\n")[2])

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
        self.assertEqual(["✅ **No longer watched** `qa` · `o/r`", "",
                          "`qa` is no longer in environments-yml: the incident opened at 2026-10-05 08:30 UTC is "
                          "closed."], decided["messages"]["e1.md"].split("\n")[:3])

    def test_a_removed_environment_whose_sender_is_gone_too_is_closed_quietly(self):
        decided = notify_decide.decide(facts(state=state(qa__apply=incident(sender_name="qa"))))
        self.assertEqual([], decided["events"])
        self.assertEqual([{"environment": "qa", "slot": "apply", "result": "removed", "kind": None,
                           "action": "resolve", "event": None, "people": [], "alias": "tf-alerts", "sender": "qa",
                           "sending": False}],
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


class WantedTest(unittest.TestCase):
    def test_people_only_for_a_push_that_opens_or_repeats(self):
        failing = {"dev": metadata("dev"), "prod": metadata("prod", apply="failure")}
        self.assertEqual({"people": True, "protection": ["prod"]},
                         notify_decide.wanted(facts(metadata=failing, people=None, protection=None)))
        self.assertEqual({"people": False, "protection": ["prod"]},
                         notify_decide.wanted(facts(event="schedule", metadata=failing, people=None, protection=None)))
        self.assertEqual({"people": False, "protection": []},
                         notify_decide.wanted(facts(people=None, protection=None)))
        self.assertEqual({"people": False, "protection": ["prod"]},
                         notify_decide.wanted(facts(people=None, protection=None,
                                                    state=state(prod__apply=incident()))))
        self.assertEqual({"people": True, "protection": ["prod"]},
                         notify_decide.wanted(facts(metadata=failing, people=None, protection=None,
                                                    state=state(prod__apply=incident()))))

    def test_wanted_does_not_change_the_facts(self):
        given = facts(people=None, protection=None)
        before = copy.deepcopy(given)
        notify_decide.wanted(given)
        notify_decide.decide(given)
        self.assertEqual(before, given)


if __name__ == "__main__":
    unittest.main()
