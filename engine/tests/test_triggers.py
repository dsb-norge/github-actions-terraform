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
        doc["event"]["dispatch"] = {"block": True, "environment": "", "goal": "", "reason": "", **dispatch}
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
        doc["event"]["dispatch"] = {"block": False, "environment": "", "goal": "", "reason": ""}
        output = decided(doc)
        self.assertEqual({"prod": WITH_APPLY + ["destroy-plan"], "staging": WITH_APPLY,
                          "sandbox": ["init", "format", "validate", "lint"],
                          "scratch": ["init", "plan", "apply", "destroy-plan", "destroy"]}, granted(output))
        line = ("dispatched by octocat: the calling workflow declares no dispatch inputs, so every environment runs "
                "with its goals; copy the standard block from docs/Dispatch-and-triggers.md §3.1 to choose one "
                "environment and a goal")
        self.assertEqual({"event": "workflow_dispatch", "lines": [line]}, output["trigger"])
        self.assertEqual(line, output["notices"][0])

    def test_a_schedule_runs_only_the_environments_that_opted_in(self):
        output = decided(document(event="schedule"))
        self.assertEqual({"staging": WITH_APPLY}, granted(output))
        self.assertEqual({name: ["trigger-events: schedule not enabled"] for name in ("prod", "sandbox", "scratch")},
                         skipped(output))
        self.assertEqual([], output["trigger"]["lines"])

    def test_destroy_is_never_granted_on_a_schedule(self):
        environments = SPEC[:3] + [{**SPEC[3], "trigger-events": ["schedule"]}]
        output = decided(document(environments, event="schedule"))
        self.assertEqual({"staging": WITH_APPLY, "scratch": ["init", "plan", "apply", "destroy-plan"]},
                         granted(output))

    def test_a_schedule_no_environment_opted_into_is_green_with_a_notice(self):
        output = decided(document(SPEC[:1] + SPEC[2:], event="schedule"))
        self.assertEqual(([], {"affected": 0, "unaffected": 3}), (output["errors"], output["counts"]))
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
        doc["event"]["dispatch"] = {"block": True, "environment": "staging", "goal": "plan", "reason": ""}
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
        environments = [{"environment": "a", "goals-yml": ["apply"]}, {"environment": "b", "goals-yml": ["all"]},
                        {"environment": "c", "goals-yml": ["plan", "apply-on-pr"]},
                        {"environment": "d", "goals-yml": ["init"]}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "apply"}))
        self.assertEqual(["dispatch: environment 'c' does not hold the goal 'apply' (goals: plan, apply-on-pr)",
                          "dispatch: environment 'd' does not hold the goal 'apply' (goals: init)"], output["errors"])
        output = decided(document(environments[:2], event="workflow_dispatch", dispatch={"goal": "apply"}))
        self.assertEqual({"a": ["apply"], "b": WITH_APPLY}, granted(output))

    def test_apply_off_the_default_branch_is_refused_before_any_environment(self):
        output = decided(document([{"environment": "d", "goals-yml": ["init"]}], event="workflow_dispatch",
                                  ref="feature/x", dispatch={"goal": "apply"}))
        self.assertEqual(["dispatch: apply is only allowed from the default branch 'main'; this run is on "
                          "'feature/x'"], output["errors"])

    def test_destroy_plan_needs_the_goal_itself(self):
        environments = [{"environment": "a", "goals-yml": ["all", "lint"]}, {"environment": "b", "goals-yml": ["destroy"]},
                        {"environment": "c", "goals-yml": ["init", "destroy-plan"]}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "destroy-plan"}))
        self.assertEqual(["dispatch: environment 'a' does not hold the goal 'destroy-plan' (goals: all, lint)",
                          "dispatch: environment 'b' does not hold the goal 'destroy-plan' (goals: destroy)"],
                         output["errors"])
        output = decided(document(environments[2:], event="workflow_dispatch", dispatch={"goal": "destroy-plan"}))
        self.assertEqual({"c": ["init", "destroy-plan"]}, granted(output))

    def test_a_single_goal_written_alone_is_listed_as_one(self):
        environments = [{"environment": "a", "goals-yml": "plan"}]
        output = decided(document(environments, event="workflow_dispatch", dispatch={"goal": "apply"}))
        self.assertEqual(["dispatch: environment 'a' does not hold the goal 'apply' (goals: plan)"], output["errors"])

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
        goals = ["apply", "destroy"]
        for event, expected in (("push", ["apply", "destroy"]), ("workflow_dispatch", ["apply", "destroy"]),
                                ("schedule", ["apply"]), ("pull_request", [])):
            with self.subTest(event=event):
                environments = [{"environment": "a", "goals-yml": goals, "trigger-events": [event]}]
                output = decided(document(environments, event=event, base_ref="main"))
                self.assertEqual(expected, output["environments"][0]["goals"])
        self.assertEqual([], self.goals(goals, ref="feature/x"))

    def test_the_on_pr_goals_need_a_pull_request_against_the_default_branch(self):
        goals = ["apply-on-pr", "destroy-on-pr"]
        pull = dict(event="pull_request", base_ref="main")
        self.assertEqual(["apply", "destroy"], self.goals(goals, **pull))
        self.assertEqual(["apply", "destroy"], self.goals(goals, ref="87/merge", action="synchronize", **pull))
        for kwargs in (dict(action="closed"), dict(action="converted_to_draft")):
            with self.subTest(kwargs=kwargs):
                self.assertEqual([], self.goals(goals, **pull, **kwargs))
        self.assertEqual([], self.goals(goals, event="pull_request", base_ref="develop"))
        self.assertEqual([], self.goals(goals, event="pull_request"))
        self.assertEqual([], self.goals(goals, event="push", base_ref="main"))

    def test_destroy_plan_is_granted_on_every_event(self):
        for event in ("pull_request", "push", "workflow_dispatch", "schedule"):
            with self.subTest(event=event):
                environments = [{"environment": "a", "goals-yml": ["destroy-plan"], "trigger-events": [event]}]
                output = decided(document(environments, event=event, ref="feature/x"))
                self.assertEqual(["destroy-plan"], output["environments"][0]["goals"])

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


class GoalsRuleTest(unittest.TestCase):
    """The goals an environment names are a list of known names; a plain string is one goal."""

    VOCABULARY = ("init, format, validate, lint, plan, apply, destroy-plan, destroy, all, apply-on-pr, destroy-on-pr, "
                  "one per list item ('- plan' on its own line, or [init, plan])!")

    def output(self, goals, **kwargs):
        return decided(document([{"environment": "a", "goals-yml": goals}], **kwargs))

    def test_a_plain_string_is_one_goal_never_a_substring(self):
        # The workflow's contains() read 'destroy-plan' as holding plan and destroy too.
        self.assertEqual({"a": ["destroy-plan"]}, granted(self.output("destroy-plan")))
        self.assertEqual({"a": WITH_APPLY}, granted(self.output("all")))
        self.assertEqual(["destroy-plan"], self.output("destroy-plan")["matrices"]["1"]["include"][0]["vars"]["goals"])

    def test_a_list_written_without_its_dashes_is_an_error_not_a_destroy(self):
        # 'goals-yml: |' with the goals on separate lines and no dashes parses as one string.
        for text in ("init plan destroy-plan", "init, plan, destroy-plan", "init plan apply-on-pr"):
            with self.subTest(text=text):
                self.assertEqual([f"The environment 'a' has the unknown goal {text!r}; a goal is one of "
                                  + self.VOCABULARY], self.output(text)["errors"])

    def test_a_misspelt_or_unknown_goal_is_an_error(self):
        self.assertEqual(["The environment 'a' has the unknown goal 'aply', 'destroy-plan-on-pr'; a goal is one of "
                          + self.VOCABULARY],
                         self.output(["init", "plan", "aply", "destroy-plan-on-pr"])["errors"])
        self.assertEqual(["The environment 'a' has the unknown goal 'ALL'; a goal is one of " + self.VOCABULARY],
                         self.output(["ALL"])["errors"])
        self.assertEqual(["The environment 'a' has the unknown goal 1, null, [\"plan\"]; a goal is one of "
                          + self.VOCABULARY], self.output([1, None, ["plan"]])["errors"])

    def test_other_shapes_are_an_error(self):
        for goals, shown in ((3, "3"), (True, "true"), ({"all": True}, '{"all": true}')):
            with self.subTest(goals=goals):
                self.assertEqual([f"The environment 'a' has the goals {shown}; they must be a list of goals!"],
                                 self.output(goals)["errors"])

    def test_no_goals_is_an_empty_list(self):
        self.assertEqual({"a": []}, granted(self.output(None)))
        self.assertEqual({"a": []}, granted(self.output([])))

    def test_the_global_goals_are_held_to_the_same_rule(self):
        doc = document([{"environment": "a"}])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed("init plan destroy-plan")
        self.assertEqual(["The environment 'a' has the unknown goal 'init plan destroy-plan'; a goal is one of "
                          + self.VOCABULARY], decided(doc)["errors"])
        doc["yaml"]["inputs"]["goals-yml"] = support.parsed("plan")
        self.assertEqual({"a": ["plan"]}, granted(decided(doc)))


class LinesTest(unittest.TestCase):
    def line(self, **kwargs):
        dispatch = {key: kwargs.pop(key) for key in ("environment", "goal", "reason") if key in kwargs}
        return decided(document(event="workflow_dispatch", dispatch=dispatch, **kwargs))["trigger"]["lines"]

    def test_the_dispatch_line(self):
        self.assertEqual(['dispatched by octocat: environment staging, goal apply, reason "rebuild after incident 42"'],
                         self.line(environment="staging", goal="apply", reason="rebuild after incident 42",
                                   actor="octocat"))

    def test_a_re_run_names_both_actors_and_the_same_actor_once(self):
        self.assertEqual(["dispatched by octocat (re-run by hubot): environment (all), goal default, no reason given"],
                         self.line(actor="octocat", triggering_actor="hubot"))
        self.assertEqual(["dispatched by octocat: environment (all), goal default, no reason given"],
                         self.line(actor="octocat", triggering_actor="octocat"))

    def test_an_unknown_actor(self):
        self.assertEqual(["dispatched by an unknown actor: environment (all), goal plan, no reason given"],
                         self.line(goal="plan"))

    def test_a_reason_is_one_line(self):
        self.assertEqual(['dispatched by a: environment (all), goal default, reason "two lines ::error::x"'],
                         self.line(actor="a", reason="  two\nlines\r\n\t::error::x  "))
        self.assertEqual(["dispatched by a: environment (all), goal default, no reason given"],
                         self.line(actor="a", reason=" \n "))

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
