"""Trigger events, the dispatch filter and the granted goals: docs/Dispatch-and-triggers.md §4 and §6.

Every row of the spec's §6 table and every error of §4.3 is a case here, with the expected output
written out as literals.
"""

import unittest

import invariants
import support
from dsb_tf_engine import decide

STANDARD = ["init", "format", "validate", "lint", "plan"]
WITH_APPLY = STANDARD + ["apply"]
DEFAULT_EVENTS = ["pull_request", "push", "workflow_dispatch"]
# The configuration of the spec's §6 table.
SPEC = [
    {"environment": "prod", "goals-yml": ["all", "destroy-plan"]},
    {"environment": "staging", "goals-yml": ["all"],
     "trigger-events": ["pull_request", "push", "workflow_dispatch", "schedule"]},
    {"environment": "sandbox", "goals-yml": ["init", "format", "validate", "lint"]},
    {"environment": "scratch", "goals-yml": ["init", "plan", "apply", "destroy-plan", "destroy"]},
]


def document(environments=None, event="push", ref="main", dispatch=None, trigger_events=None, action=None,
             base_ref=None, actor=None, triggering_actor=None, pull_request=False):
    environments = [dict(e) for e in (SPEC if environments is None else environments)]
    env_yaml = [{key: support.parsed(value) for key, value in e.items() if key.endswith("-yml")} for e in environments]
    doc = support.document(environments=environments, env_yaml=env_yaml, ref_name=ref)
    doc["event"]["name"] = event
    if dispatch is not None:
        doc["event"]["dispatch"] = {"block": True, "environment": "", "goal": "", "reason": "", "inputs": [], **dispatch}
    if trigger_events is not None:
        doc["yaml"]["inputs"]["trigger-events-yml"] = support.parsed(trigger_events)
    for key, value in (("action", action), ("base_ref", base_ref), ("actor", actor),
                       ("triggering_actor", triggering_actor)):
        if value is not None:
            doc["event"][key] = value
    if pull_request:
        doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": False}
        doc["run"] = {"id": 4711, "attempt": 1}
    return doc


def decided(doc):
    output = decide.decide(doc)
    assert invariants.check(doc, output) == [], invariants.check(doc, output)
    return output


def granted(output):
    """The running environments and their granted goals, in declaration order."""
    return {e["environment"]: e["goals"] for e in output["environments"] if e["verdict"] == "run"}


def skipped(output):
    return {e["environment"]: e["reasons"] for e in output["environments"] if e["verdict"] == "skip"}


class SpecTableTest(unittest.TestCase):
    """docs/Dispatch-and-triggers.md §6, row by row."""

    def test_the_recovery_case(self):
        output = decided(document(event="workflow_dispatch",
                                  dispatch={"environment": "staging", "goal": "apply", "reason": "rebuild"}))
        self.assertEqual({"staging": WITH_APPLY}, granted(output))
        self.assertEqual({"prod": ["dispatch: not the requested environment"],
                          "sandbox": ["dispatch: not the requested environment"],
                          "scratch": ["dispatch: not the requested environment"]}, skipped(output))

    def test_a_default_goal_is_a_push_for_one_environment(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "staging", "goal": "default"}))
        self.assertEqual({"staging": WITH_APPLY}, granted(output))

    def test_a_fleet_wide_plan_removes_apply_and_destroy_and_never_adds_plan(self):
        output = decided(document(event="workflow_dispatch", dispatch={"goal": "plan"}))
        self.assertEqual({"prod": STANDARD, "staging": STANDARD, "sandbox": ["init", "format", "validate", "lint"],
                          "scratch": ["init", "plan"]}, granted(output))

    def test_apply_off_the_default_branch_is_an_error(self):
        output = decided(document(event="workflow_dispatch", ref="feature/x",
                                  dispatch={"environment": "staging", "goal": "apply"}))
        self.assertEqual(["dispatch: apply is only allowed from the default branch 'main'; this run is on "
                          "'feature/x'"], output["errors"])

    def test_apply_for_an_environment_without_the_goal_is_an_error(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "sandbox", "goal": "apply"}))
        self.assertEqual(["dispatch: environment 'sandbox' does not hold the goal 'apply' (goals: init, format, "
                          "validate, lint)"], output["errors"])

    def test_a_destroy_plan_is_read_only(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "prod", "goal": "destroy-plan"}))
        self.assertEqual({"prod": ["init", "destroy-plan"]}, granted(output))

    def test_a_default_dispatch_destroys_only_what_goals_yml_holds(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "scratch"}))
        self.assertEqual({"scratch": ["init", "plan", "apply", "destroy-plan", "destroy"]}, granted(output))

    def test_the_destroy_plan_cap_removes_apply_and_destroy(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "scratch", "goal": "destroy-plan"}))
        self.assertEqual({"scratch": ["init", "destroy-plan"]}, granted(output))

    def test_a_named_environment_that_takes_no_part_is_an_error(self):
        environments = [{**SPEC[0], "trigger-events": ["pull_request", "push"]}] + SPEC[1:]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"environment": "prod"}))
        self.assertEqual(["dispatch: environment 'prod' does not take part in workflow_dispatch (trigger-events: "
                          "pull_request, push)"], output["errors"])

    def test_a_dispatch_without_an_inputs_block_runs_every_environment_with_its_goals(self):
        doc = document(event="workflow_dispatch", actor="octocat")
        doc["event"]["dispatch"] = {"block": False, "environment": "", "goal": "", "reason": "", "inputs": []}
        output = decided(doc)
        self.assertEqual({"prod": WITH_APPLY + ["destroy-plan"], "staging": WITH_APPLY,
                          "sandbox": ["init", "format", "validate", "lint"],
                          "scratch": ["init", "plan", "apply", "destroy-plan", "destroy"]}, granted(output))
        line = ("dispatched by octocat: the calling workflow declares no dispatch inputs, so every environment runs "
                "with its goals; copy the standard block from docs/Dispatch-and-triggers.md §3.1 to choose one "
                "environment and a goal")
        self.assertEqual({"event": "workflow_dispatch", "lines": [line]}, output["trigger"])
        self.assertEqual(line, output["notices"][0])

    def test_a_schedule_runs_only_the_environments_that_opted_in_and_plans_them(self):
        output = decided(document(event="schedule"))
        self.assertEqual({"staging": STANDARD}, granted(output))
        self.assertEqual({name: ["trigger-events: schedule not enabled"] for name in ("prod", "sandbox", "scratch")},
                         skipped(output))
        self.assertEqual(["schedule: goal plan for staging (schedule-goal, plan where an environment sets none)"],
                         output["trigger"]["lines"])

    def test_a_reconcile_applies_and_destroy_is_never_granted_on_a_schedule(self):
        environments = [SPEC[0], {**SPEC[1], "schedule-goal": "default"}, SPEC[2],
                        {**SPEC[3], "trigger-events": ["schedule"], "schedule-goal": "default"}]
        output = decided(document(environments, event="schedule"))
        self.assertEqual({"staging": WITH_APPLY, "scratch": ["init", "plan", "apply", "destroy-plan"]},
                         granted(output))

    def test_a_schedule_no_environment_opted_into_is_green_with_a_notice(self):
        output = decided(document(SPEC[:1] + SPEC[2:], event="schedule"))
        self.assertEqual(([], {"affected": 0, "unaffected": 3, "by_stage": {"1": 0, "2": 0, "3": 0}}),
                         (output["errors"], output["counts"]))
        line = ("schedule: no environment takes part in scheduled runs; add 'schedule' to the trigger-events of the "
                "environment the schedule is for")
        self.assertEqual({"event": "schedule", "lines": [line]}, output["trigger"])
        self.assertEqual(line, output["notices"][0])

    def test_a_push_is_unchanged(self):
        output = decided(document())
        self.assertEqual({"prod": WITH_APPLY + ["destroy-plan"], "staging": WITH_APPLY,
                          "sandbox": ["init", "format", "validate", "lint"],
                          "scratch": ["init", "plan", "apply", "destroy-plan", "destroy"]}, granted(output))
        self.assertEqual({"event": "push", "lines": []}, output["trigger"])


class TriggerEventsTest(unittest.TestCase):
    def test_the_default_is_pull_request_push_and_dispatch(self):
        output = decided(document([{"environment": "prod"}], event="schedule"))
        self.assertEqual(DEFAULT_EVENTS, output["environments"][0]["trigger-events"])
        self.assertEqual(["trigger-events: schedule not enabled"], output["environments"][0]["reasons"])

    def test_an_explicit_null_global_is_the_default(self):
        output = decided(document([{"environment": "prod"}], trigger_events=None))
        self.assertEqual(DEFAULT_EVENTS, output["environments"][0]["trigger-events"])
        doc = document([{"environment": "prod"}])
        doc["yaml"]["inputs"]["trigger-events-yml"] = support.parsed(None)
        self.assertEqual(DEFAULT_EVENTS, decided(doc)["environments"][0]["trigger-events"])

    def test_the_global_list_applies_where_an_environment_says_nothing(self):
        environments = [{"environment": "prod"}, {"environment": "staging", "trigger-events": ["push", "schedule"]}]
        output = decided(document(environments, event="pull_request", trigger_events=["push"]))
        self.assertEqual([["push"], ["push", "schedule"]], [e["trigger-events"] for e in output["environments"]])
        self.assertEqual({"prod": ["trigger-events: pull_request not enabled"],
                          "staging": ["trigger-events: pull_request not enabled"]}, skipped(output))

    def test_every_supported_event_takes_part_by_its_own_name(self):
        for event in ("pull_request", "push", "workflow_dispatch", "schedule"):
            with self.subTest(event=event):
                output = decided(document([{"environment": "prod", "trigger-events": [event]}], event=event))
                self.assertEqual("run", output["environments"][0]["verdict"])

    def test_the_trigger_events_are_not_a_row_variable(self):
        output = decided(document([{"environment": "prod", "trigger-events": ["push"]}]))
        self.assertNotIn("trigger-events", output["matrices"]["1"]["include"][0]["vars"])
        self.assertNotIn("trigger-events-yml", output["matrices"]["1"]["include"][0]["vars"])

    def test_invalid_lists_are_errors_whatever_the_event(self):
        cases = [
            (dict(environments=[{"environment": "prod", "trigger-events": ["push", "merge"]}]),
             ["environments-yml: environment 'prod': unknown trigger event 'merge'"]),
            (dict(environments=[{"environment": "prod", "trigger-events": [3]}]),
             ["environments-yml: environment 'prod': unknown trigger event 3"]),
            (dict(environments=[{"environment": "prod", "trigger-events": "push"}]),
             ["environments-yml: environment 'prod': 'trigger-events' must be a non-empty list of events, not 'push'"]),
            (dict(environments=[{"environment": "prod", "trigger-events": []}]),
             ["environments-yml: environment 'prod': 'trigger-events' must be a non-empty list of events, not []"]),
            (dict(environments=[{"environment": "prod", "trigger-events": None}]),
             ["environments-yml: environment 'prod': 'trigger-events' must be a non-empty list of events, not null"]),
            (dict(environments=[{"environment": "prod"}], trigger_events=["push", "merge_group"]),
             ["trigger-events-yml: unknown trigger event 'merge_group'"]),
            (dict(environments=[{"environment": "prod"}], trigger_events=["push", "schedule"]),
             ["trigger-events-yml: 'schedule' is per environment only; add it to the trigger-events of the "
              "environment the schedule is for"]),
            (dict(environments=[{"environment": "prod"}], trigger_events="push"),
             ["trigger-events-yml: the list must be a non-empty list of events, not 'push'"]),
            (dict(environments=[{"environment": "prod"}], trigger_events=[]),
             ["trigger-events-yml: the list must be a non-empty list of events, not []"]),
            (dict(environments=[{"environment": "a", "trigger-events": ["x"]}, {"environment": "b",
                                                                                 "trigger-events": ["y"]}],
                  trigger_events=["z"]),
             ["trigger-events-yml: unknown trigger event 'z'", "environments-yml: environment 'a': unknown trigger "
              "event 'x'", "environments-yml: environment 'b': unknown trigger event 'y'"]),
        ]
        for kwargs, errors in cases:
            for event in ("push", "schedule"):
                with self.subTest(kwargs=kwargs, event=event):
                    self.assertEqual(errors, decided(document(event=event, **kwargs))["errors"])

    def test_schedule_is_accepted_in_an_environments_own_list(self):
        output = decided(document([{"environment": "prod", "trigger-events": ["schedule"]}], event="schedule"))
        self.assertEqual(([], "run"), (output["errors"], output["environments"][0]["verdict"]))

    def test_an_unsupported_run_event_is_an_error(self):
        for event in ("merge_group", "pull_request_target", "release", "workflow_call"):
            with self.subTest(event=event):
                self.assertEqual([f"event '{event}' is not supported by this workflow; supported: pull_request, push, "
                                  "workflow_dispatch, schedule"], decided(document(event=event))["errors"])

    def test_the_lists_are_validated_before_the_event(self):
        output = decided(document([{"environment": "prod", "trigger-events": ["merge"]}], event="merge_group"))
        self.assertEqual(["environments-yml: environment 'prod': unknown trigger event 'merge'"], output["errors"])


class DispatchFilterTest(unittest.TestCase):
    def test_no_environment_by_that_name_is_an_error_listing_the_names(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "stagin"}))
        self.assertEqual(["dispatch: no environment named 'stagin'. Environments: prod, staging, sandbox, scratch"],
                         output["errors"])

    def test_an_earlier_rules_reason_is_the_one_recorded(self):
        environments = SPEC[:2] + [{**SPEC[2], "trigger-events": ["push"]}] + SPEC[3:]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"environment": "staging"}))
        self.assertEqual({"prod": ["dispatch: not the requested environment"],
                          "sandbox": ["trigger-events: workflow_dispatch not enabled"],
                          "scratch": ["dispatch: not the requested environment"]}, skipped(output))

    def test_an_empty_environment_input_runs_every_environment_that_takes_part(self):
        environments = SPEC[:2] + [{**SPEC[2], "trigger-events": ["push"]}] + SPEC[3:]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "plan"}))
        self.assertEqual(["prod", "staging", "scratch"], list(granted(output)))

    def test_a_dispatch_document_without_inputs_is_a_dispatch_without_a_block(self):
        doc = document(event="workflow_dispatch")
        self.assertNotIn("dispatch", doc["event"])
        output = decided(doc)
        self.assertEqual(4, output["counts"]["affected"])
        self.assertIn("declares no dispatch inputs", output["trigger"]["lines"][0])

    def test_the_dispatch_filter_and_cap_apply_only_to_a_dispatch(self):
        doc = document(event="push")
        doc["event"]["dispatch"] = {"block": True, "environment": "staging", "goal": "plan", "reason": "", "inputs": []}
        output = decided(doc)
        self.assertEqual(4, output["counts"]["affected"])
        self.assertEqual(WITH_APPLY + ["destroy-plan"], granted(output)["prod"])
        self.assertEqual([], output["trigger"]["lines"])


class GoalInputTest(unittest.TestCase):
    def test_an_unknown_goal_is_an_error(self):
        for goal in ("destroy", "all", "apply-on-pr", "Plan"):
            with self.subTest(goal=goal):
                output = decided(document(event="workflow_dispatch", dispatch={"environment": "scratch", "goal": goal}))
                self.assertEqual([f"dispatch: unknown goal '{goal}'; the goal input is one of default, plan, apply, "
                                  "destroy-plan"], output["errors"])

    def test_an_empty_goal_is_the_default(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "scratch", "goal": ""}))
        self.assertEqual({"scratch": ["init", "plan", "apply", "destroy-plan", "destroy"]}, granted(output))

    def test_apply_needs_apply_or_all_and_apply_on_pr_does_not_count(self):
        environments = [{"environment": "a", "goals-yml": ["init", "plan", "apply"]},
                        {"environment": "b", "goals-yml": ["all"]},
                        {"environment": "c", "goals-yml": ["init", "plan", "apply-on-pr"]},
                        {"environment": "d", "goals-yml": ["init"]}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "apply"}))
        self.assertEqual(["dispatch: environment 'c' does not hold the goal 'apply' (goals: init, plan, apply-on-pr)",
                          "dispatch: environment 'd' does not hold the goal 'apply' (goals: init)"], output["errors"])
        output = decided(document(environments[:2], event="workflow_dispatch", dispatch={"goal": "apply"}))
        self.assertEqual({"a": ["init", "plan", "apply"], "b": WITH_APPLY}, granted(output))

    def test_apply_never_brings_a_destroy_with_it(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "scratch", "goal": "apply"}))
        self.assertEqual({"scratch": ["init", "plan", "apply"]}, granted(output))
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "prod", "goal": "apply"}))
        self.assertEqual({"prod": WITH_APPLY}, granted(output))

    def test_apply_off_the_default_branch_is_refused_before_any_environment(self):
        output = decided(document([{"environment": "d", "goals-yml": ["init"]}], event="workflow_dispatch",
                                  ref="feature/x", dispatch={"goal": "apply"}))
        self.assertEqual(["dispatch: apply is only allowed from the default branch 'main'; this run is on "
                          "'feature/x'"], output["errors"])

    def test_destroy_plan_needs_the_goal_itself(self):
        environments = [{"environment": "a", "goals-yml": ["all", "lint"]}, {"environment": "b", "goals-yml": ["init"]},
                        {"environment": "c", "goals-yml": ["init", "destroy-plan"]}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "destroy-plan"}))
        self.assertEqual(["dispatch: environment 'a' does not hold the goal 'destroy-plan' (goals: all, lint)",
                          "dispatch: environment 'b' does not hold the goal 'destroy-plan' (goals: init)"],
                         output["errors"])
        output = decided(document(environments[2:], event="workflow_dispatch", dispatch={"goal": "destroy-plan"}))
        self.assertEqual({"c": ["init", "destroy-plan"]}, granted(output))

    def test_a_single_goal_written_alone_is_listed_as_one(self):
        environments = [{"environment": "a", "goals-yml": "all"}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "destroy-plan"}))
        self.assertEqual(["dispatch: environment 'a' does not hold the goal 'destroy-plan' (goals: all)"], output["errors"])

    def test_a_goal_off_the_default_branch_caps_a_branch_run(self):
        output = decided(document(event="workflow_dispatch", ref="feature/x", dispatch={"goal": "plan"}))
        self.assertEqual({"prod": STANDARD, "staging": STANDARD, "sandbox": ["init", "format", "validate", "lint"],
                          "scratch": ["init", "plan"]}, granted(output))
        output = decided(document(event="workflow_dispatch", ref="feature/x", dispatch={"environment": "scratch"}))
        self.assertEqual({"scratch": ["init", "plan", "destroy-plan"]}, granted(output))


class ExpansionTest(unittest.TestCase):
    """The expansion is what the workflow's gates would let through for the goals named."""

    def goals(self, goals, **kwargs):
        output = decided(document([{"environment": "a", "goals-yml": goals}], **kwargs))
        return output["environments"][0]["goals"]

    def test_all_is_the_standard_goals_and_apply_not_the_destroy_goals(self):
        self.assertEqual(WITH_APPLY, self.goals(["all"]))
        self.assertEqual(STANDARD, self.goals(["all"], ref="feature/x"))

    def test_apply_and_destroy_need_the_default_branch_and_their_events(self):
        goals = ["init", "plan", "apply", "destroy-plan", "destroy"]
        always = ["init", "plan"]
        for event, expected in (("push", always + ["apply", "destroy-plan", "destroy"]),
                                ("workflow_dispatch", always + ["apply", "destroy-plan", "destroy"]),
                                ("schedule", always + ["apply", "destroy-plan"]),
                                ("pull_request", always + ["destroy-plan"])):
            with self.subTest(event=event):
                # The expansion is the gates'; a schedule is uncapped only with schedule-goal: default.
                environments = [{"environment": "a", "goals-yml": goals, "trigger-events": [event],
                                 "schedule-goal": "default"}]
                output = decided(document(environments, event=event, base_ref="main"))
                self.assertEqual(expected, output["environments"][0]["goals"])
        self.assertEqual(always + ["destroy-plan"], self.goals(goals, ref="feature/x"))

    def test_the_on_pr_goals_need_a_pull_request_against_the_default_branch(self):
        goals = ["init", "plan", "apply-on-pr", "destroy-plan", "destroy-on-pr"]
        planned = ["init", "plan", "destroy-plan"]
        pull = dict(event="pull_request", base_ref="main")
        both = ["init", "plan", "apply", "destroy-plan", "destroy"]
        self.assertEqual(both, self.goals(goals, **pull))
        self.assertEqual(both, self.goals(goals, ref="87/merge", action="synchronize", **pull))
        for kwargs in (dict(action="closed"), dict(action="converted_to_draft")):
            with self.subTest(kwargs=kwargs):
                self.assertEqual(planned, self.goals(goals, **pull, **kwargs))
        self.assertEqual(planned, self.goals(goals, event="pull_request", base_ref="develop"))
        self.assertEqual(planned, self.goals(goals, event="pull_request"))
        self.assertEqual(planned, self.goals(goals, event="push", base_ref="main"))

    def test_destroy_plan_is_granted_on_every_event(self):
        for event in ("pull_request", "push", "workflow_dispatch", "schedule"):
            with self.subTest(event=event):
                environments = [{"environment": "a", "goals-yml": ["init", "destroy-plan"], "trigger-events": [event],
                                 "schedule-goal": "destroy-plan"}]
                output = decided(document(environments, event=event, ref="feature/x"))
                self.assertEqual(["init", "destroy-plan"], output["environments"][0]["goals"])

    def test_no_goals_run_with_none(self):
        output = decided(document([{"environment": "a"}]))
        self.assertEqual(([], ["relevance: all:not-computed", "goals: none"]),
                         (output["environments"][0]["goals"], output["environments"][0]["reasons"]))

    def test_the_row_carries_the_granted_goals_and_the_raw_ones_stay(self):
        output = decided(document([{"environment": "a", "goals-yml": ["all", "destroy-plan"]}]))
        row = output["matrices"]["1"]["include"][0]["vars"]
        self.assertEqual((WITH_APPLY + ["destroy-plan"], ["all", "destroy-plan"]), (row["goals-granted"], row["goals"]))
        self.assertEqual(["a: run — relevance: all:not-computed; goals: init, format, validate, lint, plan, apply, "
                          "destroy-plan"], output["record"])

    def test_a_skipped_environment_is_granted_nothing(self):
        output = decided(document(event="schedule"))
        entry = output["environments"][0]
        self.assertEqual(("skip", False), (entry["verdict"], "goals" in entry))


class ScheduleGoalTest(unittest.TestCase):
    """On a schedule each environment's schedule-goal caps its goals as a dispatch's goal input does, plan where
    it sets none (docs/Dispatch-and-triggers.md §4.4, D12)."""

    ALL = ["all", "destroy-plan"]

    def scheduled(self, schedule_goal=None, goals=None, event="schedule", **kwargs):
        environment = {"environment": "a", "goals-yml": self.ALL if goals is None else goals,
                       "trigger-events": ["pull_request", "push", "workflow_dispatch", "schedule"]}
        if schedule_goal is not None:
            environment["schedule-goal"] = schedule_goal
        return decided(document([environment], event=event, base_ref="main", **kwargs))

    def test_each_value_caps_what_a_push_to_the_default_branch_would_grant(self):
        for schedule_goal, expected in ((None, STANDARD), ("plan", STANDARD), ("default", WITH_APPLY + ["destroy-plan"]),
                                        ("apply", WITH_APPLY), ("destroy-plan", ["init", "destroy-plan"])):
            with self.subTest(schedule_goal=schedule_goal):
                self.assertEqual({"a": expected}, granted(self.scheduled(schedule_goal)))

    def test_the_plan_cap_only_removes(self):
        self.assertEqual({"a": ["init", "format", "validate", "lint"]},
                         granted(self.scheduled(goals=["init", "format", "validate", "lint"])))
        self.assertEqual({"a": ["init", "plan"]},
                         granted(self.scheduled(goals=["init", "plan", "apply", "destroy-plan", "destroy"])))

    def test_destroy_is_never_granted_whatever_the_schedule_goal(self):
        for schedule_goal in ("default", "plan", "apply", "destroy-plan"):
            with self.subTest(schedule_goal=schedule_goal):
                goals = ["init", "plan", "apply", "destroy-plan", "destroy"]
                self.assertNotIn("destroy", granted(self.scheduled(schedule_goal, goals=goals))["a"])

    def test_the_record_names_the_cap_before_the_goals(self):
        output = self.scheduled()
        self.assertEqual(["a: run — relevance: all:event; schedule-goal: plan; goals: init, format, validate, lint, plan"],
                         output["record"])
        self.assertEqual(["a: run — relevance: all:event; schedule-goal: default; goals: init, format, validate, lint, "
                          "plan, apply, destroy-plan"], self.scheduled("default")["record"])

    def test_the_trigger_line_groups_the_running_environments_by_their_cap(self):
        environments = [
            {"environment": "prod", "goals-yml": ["all"], "trigger-events": ["push", "schedule"]},
            {"environment": "nightly", "goals-yml": ["all"], "trigger-events": ["schedule"], "schedule-goal": "default"},
            {"environment": "scratch", "goals-yml": ["all"], "trigger-events": ["schedule"], "schedule-goal": "plan"},
            {"environment": "check", "goals-yml": ["init", "destroy-plan"], "trigger-events": ["schedule"],
             "schedule-goal": "destroy-plan"},
            {"environment": "quiet", "goals-yml": ["all"], "schedule-goal": "apply"},
        ]
        output = decided(document(environments, event="schedule"))
        line = ("schedule: goal default for nightly; goal plan for prod, scratch; goal destroy-plan for check "
                "(schedule-goal, plan where an environment sets none)")
        self.assertEqual({"event": "schedule", "lines": [line]}, output["trigger"])
        self.assertEqual(line, output["notices"][0])
        self.assertEqual({"quiet": ["trigger-events: schedule not enabled"]}, skipped(output))

    def test_other_events_ignore_it(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                output = self.scheduled("plan", event=event)
                self.assertEqual({"a": WITH_APPLY + ["destroy-plan"]}, granted(output))
                self.assertNotIn("schedule-goal: plan", output["environments"][0]["reasons"])
        self.assertEqual({"a": STANDARD + ["destroy-plan"]}, granted(self.scheduled("plan", event="pull_request")))

    def test_a_dispatch_is_capped_by_its_goal_input_not_by_schedule_goal(self):
        output = self.scheduled("plan", event="workflow_dispatch", dispatch={"goal": "apply"})
        self.assertEqual({"a": WITH_APPLY}, granted(output))

    def test_a_planned_schedule_needs_no_ordering(self):
        environments = [{"environment": "a", "goals-yml": ["all"], "trigger-events": ["schedule"]},
                        {"environment": "b", "goals-yml": ["all"], "trigger-events": ["schedule"], "depends-on": ["a"]}]
        output = decided(document(environments, event="schedule"))
        self.assertEqual(({"a": STANDARD, "b": STANDARD}, 1), (granted(output), output["ordering"]["stages_used"]))
        environments[0]["schedule-goal"] = environments[1]["schedule-goal"] = "default"
        output = decided(document(environments, event="schedule"))
        self.assertEqual(({"a": WITH_APPLY, "b": WITH_APPLY}, 2), (granted(output), output["ordering"]["stages_used"]))

    def test_mistakes_are_errors_on_every_event(self):
        where = "environments-yml: environment 'a'"
        cases = (
            ("aply", ["all"], f"{where}: 'schedule-goal' is one of default, plan, apply, destroy-plan, not 'aply'"),
            (None, ["all"], None),
            (["plan"], ["all"], f"{where}: 'schedule-goal' is one of default, plan, apply, destroy-plan, not [\"plan\"]"),
            ("destroy", ["all"], f"{where}: 'schedule-goal' is one of default, plan, apply, destroy-plan, not 'destroy'"),
            ("apply", ["init", "plan"], f"{where}: 'schedule-goal: apply' needs the goal 'apply' or 'all' "
                                        "(goals: init, plan)"),
            ("apply", ["init", "plan", "apply-on-pr"], f"{where}: 'schedule-goal: apply' needs the goal 'apply' or "
                                                       "'all' (goals: init, plan, apply-on-pr)"),
            ("destroy-plan", ["all"], f"{where}: 'schedule-goal: destroy-plan' needs the goal 'destroy-plan' "
                                      "(goals: all)"),
            ("destroy-plan", ["init", "plan", "apply"], f"{where}: 'schedule-goal: destroy-plan' needs the goal "
                                                        "'destroy-plan' (goals: init, plan, apply)"),
            ("destroy-plan", ["init", "destroy-plan", "destroy"], None),
            ("apply", ["init", "plan", "apply"], None),
        )
        for value, goals, message in cases:
            for event in ("pull_request", "push", "workflow_dispatch", "schedule"):
                with self.subTest(value=value, goals=goals, event=event):
                    environment = {"environment": "a", "goals-yml": goals, "trigger-events": ["push", "schedule"],
                                   "schedule-goal": value}
                    if message is None and value is None:
                        del environment["schedule-goal"]
                    output = decided(document([environment], event=event, base_ref="main"))
                    self.assertEqual([] if message is None else [message], output["errors"])

    def test_an_explicit_null_is_an_error(self):
        environment = {"environment": "a", "goals-yml": ["all"], "trigger-events": ["schedule"], "schedule-goal": None}
        self.assertEqual(["environments-yml: environment 'a': 'schedule-goal' is one of default, plan, apply, "
                          "destroy-plan, not null"], decided(document([environment]))["errors"])

    def test_every_mistaken_environment_is_reported_at_once(self):
        environments = [{"environment": "a", "goals-yml": ["all"], "schedule-goal": "x"},
                        {"environment": "b", "goals-yml": ["init", "plan"], "schedule-goal": "apply"}]
        self.assertEqual(["environments-yml: environment 'a': 'schedule-goal' is one of default, plan, apply, "
                          "destroy-plan, not 'x'",
                          "environments-yml: environment 'b': 'schedule-goal: apply' needs the goal 'apply' or 'all' "
                          "(goals: init, plan)"], decided(document(environments))["errors"])

    def test_a_schedule_goal_without_schedule_is_a_warning(self):
        environments = [{"environment": "a", "schedule-goal": "plan"},
                        {"environment": "b", "trigger-events": ["push"], "schedule-goal": "default"},
                        {"environment": "c", "trigger-events": ["push", "schedule"], "schedule-goal": "default"},
                        {"environment": "d", "trigger-events": ["schedule"]}]
        for event in ("push", "schedule"):
            with self.subTest(event=event):
                output = decided(document(environments, event=event))
                self.assertEqual(["The environment 'a' sets schedule-goal: plan, but its trigger-events do not hold "
                                  "schedule, so it has no effect.",
                                  "The environment 'b' sets schedule-goal: default, but its trigger-events do not hold "
                                  "schedule, so it has no effect."], output["warnings"])

    def test_it_is_a_rule_field_never_a_row_variable(self):
        output = self.scheduled("default")
        self.assertNotIn("schedule-goal", output["matrices"]["1"]["include"][0]["vars"])


class GoalsRuleTest(unittest.TestCase):
    """The goals an environment names: a list of known names with their prerequisites; a plain string is
    one goal (docs/Configuration-validation.md §3.2)."""

    VOCABULARY = ("A goal is one of init, format, validate, lint, plan, apply, destroy-plan, destroy, all, "
                  "apply-on-pr, destroy-on-pr.")

    def output(self, goals, **kwargs):
        return decided(document([{"environment": "a", "goals-yml": goals}], **kwargs))

    def test_a_plain_string_is_one_goal_never_a_substring(self):
        # The old gates read 'destroy-plan' as holding plan and destroy too; as one goal it lacks init.
        self.assertEqual(["The environment 'a' has the goal 'destroy-plan' without 'init': a destroy plan needs an "
                          "initialised directory, so it could never run. Add 'init', or use 'all'."],
                         self.output("destroy-plan")["errors"])
        self.assertEqual({"a": WITH_APPLY}, granted(self.output("all")))
        self.assertEqual(["init"], self.output("init")["matrices"]["1"]["include"][0]["vars"]["goals"])

    def test_a_list_written_without_its_dashes_is_an_error_not_a_destroy(self):
        # 'goals-yml: |' with the goals on separate lines and no dashes parses as one string.
        for text, listed in (("init plan destroy-plan", "init, plan, destroy-plan"),
                             ("init, plan, destroy-plan", "init, plan, destroy-plan"),
                             ("init\tplan apply-on-pr", "init, plan, apply-on-pr")):
            with self.subTest(text=text):
                self.assertEqual([f"The environment 'a' has the goal {text!r}, which is not a goal. It looks like a "
                                  "list written without its dashes: YAML reads the lines as one piece of text. Write "
                                  f"one goal per line starting with '- ', or [{listed}]."], self.output(text)["errors"])

    def test_two_goals_and_a_block_s_trailing_newline_are_a_list_without_dashes_too(self):
        for text, listed in (("init plan", "init, plan"), ("init\nplan\n", "init, plan")):
            with self.subTest(text=text):
                self.assertEqual([f"The environment 'a' has the goal {text!r}, which is not a goal. It looks like a "
                                  "list written without its dashes: YAML reads the lines as one piece of text. Write "
                                  f"one goal per line starting with '- ', or [{listed}]."], self.output(text)["errors"])

    def test_one_goal_with_a_stray_separator_is_a_near_miss(self):
        self.assertEqual([f"The environment 'a' has the goal 'plan ', which is not a goal; did you mean 'plan'? "
                          f"{self.VOCABULARY}"], self.output(["init", "plan "])["errors"])

    def test_all_holds_the_prerequisites_of_plan_apply_and_destroy_plan(self):
        for goals in (["all", "plan"], ["all", "apply"], ["all", "destroy-plan"], ["all", "apply-on-pr"]):
            with self.subTest(goals=goals):
                self.assertEqual([], self.output(goals)["errors"])

    def test_text_that_only_looks_like_a_list_is_an_unknown_goal(self):
        # A misspelt part means it is not a list of goals without its dashes.
        self.assertEqual([f"The environment 'a' has the goal 'init plna', which is not a goal. {self.VOCABULARY}"],
                         self.output(["init plna"])["errors"])

    def test_a_misspelt_unknown_or_other_cased_goal_is_an_error(self):
        self.assertEqual(["The environment 'a' has the goal 'aply', which is not a goal; did you mean 'apply'? "
                          + self.VOCABULARY,
                          "The environment 'a' has the goal 'destroy-plan-on-pr', which is not a goal. " + self.VOCABULARY],
                         self.output(["init", "plan", "aply", "destroy-plan-on-pr"])["errors"])
        self.assertEqual(["The environment 'a' has the goal 'ALL'; goals are written in lower case: 'all'."],
                         self.output(["ALL"])["errors"])
        self.assertEqual(["The environment 'a' has the goal 1, which is not a goal. " + self.VOCABULARY,
                          "The environment 'a' has the goal null, which is not a goal. " + self.VOCABULARY,
                          'The environment \'a\' has the goal ["plan"], which is not a goal. ' + self.VOCABULARY],
                         self.output([1, None, ["plan"]])["errors"])

    def test_a_goal_whose_prerequisite_is_missing_is_an_error(self):
        cases = [
            (["plan"], "The environment 'a' has the goal 'plan' without 'init': a plan needs an initialised directory, "
                       "so it could never run. Add 'init', or use 'all'."),
            (["init", "apply"], "The environment 'a' has the goal 'apply' without 'plan': an apply deploys the plan, so "
                                "it could never run. Add 'plan', or use 'all'."),
            (["init", "apply-on-pr"], "The environment 'a' has the goal 'apply-on-pr' without 'plan': an apply on a pull "
                                      "request deploys the plan, so it could never run. Add 'plan', or use 'all'."),
            (["all", "destroy"], "The environment 'a' has the goal 'destroy' without 'destroy-plan': a destroy deploys "
                                 "the destroy plan, so it could never run. Add 'destroy-plan'."),
            (["all", "destroy-on-pr"], "The environment 'a' has the goal 'destroy-on-pr' without 'destroy-plan': a "
                                       "destroy on a pull request deploys the destroy plan, so it could never run. Add "
                                       "'destroy-plan'."),
        ]
        for goals, message in cases:
            with self.subTest(goals=goals):
                self.assertEqual([message], self.output(goals)["errors"])

    def test_the_prerequisites_are_met_by_all_or_by_the_goal(self):
        for goals in (["all", "apply-on-pr"], ["init", "plan", "apply"], ["all", "destroy-plan", "destroy"],
                      ["init", "destroy-plan", "destroy-on-pr"], ["format", "validate", "lint"]):
            with self.subTest(goals=goals):
                self.assertEqual([], self.output(goals)["errors"])

    def test_every_prerequisite_problem_is_reported(self):
        self.assertEqual(["The environment 'a' has the goal 'plan' without 'init': a plan needs an initialised "
                          "directory, so it could never run. Add 'init', or use 'all'.",
                          "The environment 'a' has the goal 'destroy' without 'destroy-plan': a destroy deploys the "
                          "destroy plan, so it could never run. Add 'destroy-plan'."],
                         self.output(["plan", "destroy"])["errors"])

    def test_other_shapes_are_an_error(self):
        for goals, shown in ((3, "3"), (True, "true"), ({"all": True}, '{"all": true}')):
            with self.subTest(goals=goals):
                self.assertEqual([f"The environment 'a' has the goals {shown}; they must be a list of goal names."],
                                 self.output(goals)["errors"])

    def test_no_goals_is_an_empty_list(self):
        self.assertEqual({"a": []}, granted(self.output(None)))
        self.assertEqual({"a": []}, granted(self.output([])))

    def test_the_global_goals_are_reported_once_naming_the_input(self):
        doc = document([{"environment": "a"}, {"environment": "b"}])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed("init plan destroy-plan")
        self.assertEqual(["goals-yml has the goal 'init plan destroy-plan', which is not a goal. It looks like a list "
                          "written without its dashes: YAML reads the lines as one piece of text. Write one goal per "
                          "line starting with '- ', or [init, plan, destroy-plan]."], decided(doc)["errors"])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed("all")
        self.assertEqual({"a": WITH_APPLY, "b": WITH_APPLY}, granted(decided(doc)))

    def test_the_global_goals_are_validated_when_every_environment_sets_its_own(self):
        doc = document([{"environment": "a", "goals-yml": ["all"]}])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed(["aply"])
        self.assertEqual(["goals-yml has the goal 'aply', which is not a goal; did you mean 'apply'? " + self.VOCABULARY],
                         decided(doc)["errors"])

    def test_the_global_and_every_environment_are_reported_together(self):
        doc = document([{"environment": "a", "goals-yml": ["plan"]}, {"environment": "b", "goals-yml": ["ALL"]}])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed(["init", "apply"])
        self.assertEqual(["goals-yml has the goal 'apply' without 'plan': an apply deploys the plan, so it could never "
                          "run. Add 'plan', or use 'all'.",
                          "The environment 'a' has the goal 'plan' without 'init': a plan needs an initialised "
                          "directory, so it could never run. Add 'init', or use 'all'.",
                          "The environment 'b' has the goal 'ALL'; goals are written in lower case: 'all'."],
                         decided(doc)["errors"])


class RefTypeTest(unittest.TestCase):
    """The default branch is a branch: a tag of its name is not it (docs/Configuration-validation.md §3.8)."""

    def run_on(self, ref_type, **kwargs):
        doc = document([{"environment": "prod", "goals-yml": ["all", "destroy-plan", "destroy"]}], **kwargs)
        doc["event"]["ref_type"] = ref_type
        return decided(doc)

    def test_a_tag_named_like_the_default_branch_applies_nothing(self):
        on_branch, on_tag = self.run_on("branch"), self.run_on("tag")
        self.assertEqual({"prod": WITH_APPLY + ["destroy-plan", "destroy"]}, granted(on_branch))
        self.assertEqual({"prod": STANDARD + ["destroy-plan"]}, granted(on_tag))
        self.assertEqual(["true", "false"], [output["matrices"]["1"]["include"][0]["vars"]["caller-repo-is-on-default-branch"]
                                             for output in (on_branch, on_tag)])

    def test_a_dispatched_apply_on_a_tag_names_the_tag(self):
        self.assertEqual(["dispatch: apply is only allowed from the default branch 'main'; this run is on the tag "
                          "'main'"],
                         self.run_on("tag", event="workflow_dispatch", dispatch={"goal": "apply"})["errors"])


class LinesTest(unittest.TestCase):
    def line(self, **kwargs):
        dispatch = {key: kwargs.pop(key) for key in ("environment", "goal", "reason", "inputs") if key in kwargs}
        return decided(document(event="workflow_dispatch", dispatch=dispatch, **kwargs))["trigger"]["lines"]

    def test_the_dispatch_line(self):
        self.assertEqual(['dispatched by octocat: environment staging, goal apply, reason "rebuild after incident 42"'],
                         self.line(environment="staging", goal="apply", reason="rebuild after incident 42",
                                   actor="octocat"))

    def test_a_re_run_names_both_actors_and_the_same_actor_once(self):
        self.assertEqual(["dispatched by octocat (re-run by hubot): environment (all), goal default, no reason given"],
                         self.line(goal="default", actor="octocat", triggering_actor="hubot"))
        self.assertEqual(["dispatched by octocat: environment (all), goal default, no reason given"],
                         self.line(goal="default", actor="octocat", triggering_actor="octocat"))

    def test_an_unknown_actor(self):
        self.assertEqual(["dispatched by an unknown actor: environment (all), goal plan, no reason given"],
                         self.line(goal="plan"))

    def test_a_reason_is_one_line(self):
        self.assertEqual(['dispatched by a: environment (all), goal default, reason "two lines ::error::x"'],
                         self.line(goal="default", actor="a", reason="  two\nlines\r\n\t::error::x  "))
        self.assertEqual(["dispatched by a: environment (all), goal default, no reason given"],
                         self.line(goal="default", actor="a", reason=" \n "))

    def test_a_block_without_the_standard_inputs_says_so(self):
        self.assertEqual(["dispatched by a: this dispatch delivered the inputs mode, target but neither 'environment' "
                          "nor 'goal', so every environment runs with its goals; the standard block is in "
                          "docs/Dispatch-and-triggers.md §3.1"],
                         self.line(actor="a", inputs=["mode", "target"]))
        self.assertEqual(["dispatched by a: this dispatch delivered no inputs, so every environment runs with its "
                          "goals; the standard block is in docs/Dispatch-and-triggers.md §3.1"], self.line(actor="a"))
        output = decided(document(event="workflow_dispatch", dispatch={"inputs": ["mode"]}))
        self.assertEqual(["run"] * 4, [entry["verdict"] for entry in output["environments"]])

    def test_the_lines_come_first_among_the_notices(self):
        output = decided(document(event="workflow_dispatch", dispatch={"environment": "staging"}, actor="a"))
        self.assertEqual(["dispatched by a: environment staging, goal default, no reason given",
                          "relevance all (event): 1 of 4 environments affected"], output["notices"])


class PullRequestHeadTest(unittest.TestCase):
    def test_an_environment_that_takes_no_part_in_pull_requests_says_so(self):
        environments = [{"environment": "prod"}, {"environment": "nightly", "trigger-events": ["schedule"]},
                        {"environment": "grouped", "trigger-events": ["push"], "pr-comment-group": "g"}]
        output = decided(document(environments, event="pull_request", pull_request=True))
        heads = {head["key"]: head for head in output["comments"]["heads"]}
        self.assertEqual("not-taking-part", heads["nightly"]["state"])
        self.assertEqual("### Terraform validation summary for environment: `nightly`\n\n➖ Does not take part in pull "
                         "requests: this environment's trigger-events are schedule (run #4711 attempt #1).",
                         heads["nightly"]["body"])
        self.assertEqual("placeholder", heads["prod"]["state"])
        self.assertEqual(["g", "prod", "nightly"], [head["key"] for head in output["comments"]["heads"]])
        self.assertEqual(["nightly", "grouped"], output["comments"]["purge_tags_for"])
        environments = [{"environment": "nightly", "trigger-events": ["push", "schedule"]}]
        output = decided(document(environments, event="pull_request", pull_request=True))
        self.assertIn("this environment's trigger-events are push, schedule (run #4711",
                      output["comments"]["heads"][0]["body"])


if __name__ == "__main__":
    unittest.main()
