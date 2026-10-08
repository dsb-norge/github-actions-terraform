"""The incident state the record job keeps (docs/Notifications.md §9): one document per repository, merged
from a run's observations and the relay's answers, a newer run never overwritten by an older one."""

import copy
import unittest

from dsb_tf_engine import notify_state

NOW = "2026-10-07T12:00:00Z"
CUTOFF = "2026-09-07T12:00:00Z"


def observation(action="open", environment="prod", result="failed", kind="apply-failed", event="e1", people=("jdoe",),
                alias="tf-alerts", sender="prod", mentioned=("jdoe",), reminder_level=None):
    return {"environment": environment, "slot": "apply", "result": result, "kind": kind, "action": action,
            "event": event, "people": list(people), "alias": alias, "sender": sender, "mentioned": list(mentioned),
            "reminder_level": reminder_level}


def incident(status="open", message_id="msg-1", seen_run=40, opened_run=40, kind="apply-failed", resolved_at=None):
    return {"kind": kind, "status": status, "message_id": message_id, "alias": "tf-alerts", "sender": "prod",
            "opened_at": "2026-10-05T08:30:00Z", "opened_run": opened_run, "seen_run": seen_run, "people": ["jdoe"],
            "resolved_at": resolved_at}


def accepted(message_id="msg-9"):
    return {"e1": {"accepted": True, "message_id": message_id}}


def merge(state, observations, results=None, run=42):
    return notify_state.merge(state, observations, results or {}, run, NOW, CUTOFF)


class OpenTest(unittest.TestCase):
    def test_an_accepted_open_is_an_open_incident_with_its_thread(self):
        state, changed = merge(None, [observation()], accepted())
        self.assertEqual({"schema_version": 1, "incidents": {"prod/apply": {
            "kind": "apply-failed", "status": "open", "message_id": "msg-9", "alias": "tf-alerts", "sender": "prod",
            "opened_at": NOW, "opened_run": 42, "seen_run": 42, "people": ["jdoe"], "resolved_at": None,
            "mentioned": ["jdoe"], "reminder_level": 0, "reminded_at": None}}}, state)
        self.assertTrue(changed)

    def test_an_open_the_relay_did_not_accept_is_pending(self):
        for results in ({}, {"e1": {"accepted": False, "message_id": None}}):
            with self.subTest(results=results):
                state, _ = merge(None, [observation()], results)
                self.assertEqual(("pending", None), (state["incidents"]["prod/apply"]["status"],
                                                     state["incidents"]["prod/apply"]["message_id"]))

    def test_an_open_without_a_message_is_pending(self):
        state, _ = merge(None, [observation(event=None)], accepted())
        self.assertEqual("pending", state["incidents"]["prod/apply"]["status"])

    def test_the_key_is_the_environment_lowercased(self):
        state, _ = merge(None, [observation(environment="Prod")], accepted())
        self.assertEqual(["prod/apply"], list(state["incidents"]))

    def test_an_open_incident_an_overlapping_run_opened_first_keeps_its_thread(self):
        state, _ = merge({"schema_version": 1, "incidents": {"prod/apply": incident(seen_run=41)}},
                         [observation()], accepted())
        self.assertEqual(("msg-1", 40, 42), (state["incidents"]["prod/apply"]["message_id"],
                                             state["incidents"]["prod/apply"]["opened_run"],
                                             state["incidents"]["prod/apply"]["seen_run"]))

    def test_a_pending_or_resolved_incident_is_replaced(self):
        for status in ("pending", "resolved"):
            with self.subTest(status=status):
                state, _ = merge({"schema_version": 1, "incidents": {"prod/apply": incident(status=status)}},
                                 [observation()], accepted())
                self.assertEqual(("open", "msg-9", 42), (state["incidents"]["prod/apply"]["status"],
                                                         state["incidents"]["prod/apply"]["message_id"],
                                                         state["incidents"]["prod/apply"]["opened_run"]))


class LaterTest(unittest.TestCase):
    def given(self, **kwargs):
        return {"schema_version": 1, "incidents": {"prod/apply": incident(**kwargs)}}

    def test_a_reply_moves_the_incident_on_and_keeps_its_thread_and_people(self):
        state, changed = merge(self.given(), [observation("reply", kind="held-back", people=("kim",))], accepted())
        self.assertEqual({**incident(), "kind": "held-back", "seen_run": 42}, state["incidents"]["prod/apply"])
        self.assertTrue(changed)

    def test_a_resolve_leaves_a_tombstone(self):
        state, _ = merge(self.given(), [observation("resolve", result="applied", kind="apply-failed")], accepted())
        self.assertEqual({**incident(), "status": "resolved", "resolved_at": NOW, "seen_run": 42},
                         state["incidents"]["prod/apply"])

    def test_a_pending_incident_resolves_too(self):
        state, _ = merge(self.given(status="pending", message_id=None),
                         [observation("resolve", result="applied", event=None)])
        self.assertEqual("resolved", state["incidents"]["prod/apply"]["status"])

    def test_still_failing_without_a_message_only_moves_the_run_on(self):
        state, changed = merge(self.given(), [observation("none", event=None, kind="held-back")])
        self.assertEqual({**incident(), "seen_run": 42}, state["incidents"]["prod/apply"])
        self.assertTrue(changed)

    def test_an_observation_with_nothing_to_do_changes_nothing(self):
        given = {"schema_version": 1, "incidents": {}}
        for obs in (observation("none", result="applied", kind=None, event=None),
                    observation("resolve", result="applied", event=None),
                    observation("reply", event=None)):
            with self.subTest(obs=obs):
                self.assertEqual((given, False), merge(copy.deepcopy(given), [obs]))

    def test_a_resolved_incident_is_not_moved_on(self):
        given = self.given(status="resolved", resolved_at="2026-10-06T00:00:00Z")
        self.assertEqual((given, False), merge(copy.deepcopy(given), [observation("none", event=None)]))

    def test_an_older_run_never_overwrites_a_newer_one(self):
        given = self.given(seen_run=43)
        for obs in (observation("resolve", result="applied"), observation("open"), observation("reply")):
            with self.subTest(action=obs["action"]):
                self.assertEqual((given, False), merge(copy.deepcopy(given), [obs], accepted(), run=42))

    def test_the_same_run_again_is_applied(self):
        state, _ = merge(self.given(seen_run=42), [observation("resolve", result="applied")], run=42)
        self.assertEqual("resolved", state["incidents"]["prod/apply"]["status"])


class RemindTest(unittest.TestCase):
    def given(self, **kwargs):
        return {"schema_version": 1, "incidents": {"prod/apply": incident(**kwargs)}}

    def test_an_accepted_reminder_moves_the_level_on(self):
        state, changed = merge(self.given(), [observation("remind", reminder_level=2)], accepted())
        self.assertEqual({**incident(), "reminder_level": 2, "reminded_at": NOW, "seen_run": 42},
                         state["incidents"]["prod/apply"])
        self.assertTrue(changed)

    def test_a_reminder_the_relay_did_not_accept_is_due_again(self):
        for results in ({}, {"e1": {"accepted": False, "message_id": None}}):
            with self.subTest(results=results):
                state, _ = merge(self.given(), [observation("remind", reminder_level=1)], results)
                self.assertEqual({**incident(), "seen_run": 42}, state["incidents"]["prod/apply"])


class TombstoneTest(unittest.TestCase):
    def test_a_tombstone_older_than_the_cutoff_is_dropped_and_a_newer_one_kept(self):
        given = {"schema_version": 1, "incidents": {
            "old/apply": incident(status="resolved", resolved_at="2026-09-01T00:00:00Z"),
            "new/apply": incident(status="resolved", resolved_at="2026-09-08T00:00:00Z"),
            "open/apply": incident()}}
        state, changed = merge(copy.deepcopy(given), [])
        self.assertEqual(["new/apply", "open/apply"], sorted(state["incidents"]))
        self.assertTrue(changed)


class ReadTest(unittest.TestCase):
    def test_a_state_of_another_shape_is_none(self):
        for given in (None, [], {"schema_version": 2, "incidents": {}}, {"schema_version": 1, "incidents": []},
                      {"schema_version": 1}, {"schema_version": 1, "incidents": {"prod/apply": "x"}}):
            with self.subTest(given=given):
                self.assertIsNone(notify_state.valid(given))
        self.assertEqual({"schema_version": 1, "incidents": {}}, notify_state.valid({"schema_version": 1,
                                                                                      "incidents": {}}))

    def test_merging_into_none_starts_empty(self):
        self.assertEqual(({"schema_version": 1, "incidents": {}}, False), merge(None, []))

    def test_merge_does_not_change_its_inputs(self):
        given = {"schema_version": 1, "incidents": {"prod/apply": incident()}}
        before = copy.deepcopy(given)
        merge(given, [observation("resolve", result="applied")])
        self.assertEqual(before, given)


if __name__ == "__main__":
    unittest.main()
