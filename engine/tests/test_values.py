"""The jq-compatible value helpers, including the cases the bash builder's helper tests held."""

import unittest

from dsb_tf_engine import values

ALL_GOAL_KEYS = ["apply", "destroy", "destroy-plan", "format", "init", "lint", "plan", "validate"]


class RenderTest(unittest.TestCase):
    def test_scalars_render_as_jq_prints_them(self):
        self.assertEqual("null", values.render(None))
        self.assertEqual("true", values.render(True))
        self.assertEqual("false", values.render(False))
        self.assertEqual("5", values.render(5))
        self.assertEqual("1.5", values.render(1.5))
        self.assertEqual("text", values.render("text"))

    def test_containers_render_as_indented_json(self):
        self.assertEqual('[\n  1,\n  "a"\n]', values.render([1, "a"]))
        self.assertEqual('{\n  "å": {}\n}', values.render({"å": {}}))

    def test_trailing_newlines_are_stripped_like_command_substitution(self):
        self.assertEqual("KEY", values.render("KEY\n\n"))
        self.assertEqual("", values.render("\n"))
        self.assertEqual("a\nb", values.render("a\nb\n"))

    def test_get_val_reads_null_as_empty(self):
        self.assertEqual("", values.get_val(None))
        self.assertEqual("false", values.get_val(False))
        self.assertEqual("x", values.get_val("x\n"))


class MergeTest(unittest.TestCase):
    def test_arrays_concatenate(self):
        self.assertEqual(["a", "b"], values.merge(["a"], ["b"]))

    def test_arrays_keep_duplicates(self):
        self.assertEqual(["a", "a", "b"], values.merge(["a"], ["a", "b"]))

    def test_null_global_yields_the_environment_value(self):
        self.assertEqual(["b"], values.merge(None, ["b"]))

    def test_null_environment_yields_the_global_value(self):
        self.assertEqual({"A": 1}, values.merge({"A": 1}, None))

    def test_flat_objects_override_per_key(self):
        self.assertEqual({"A": 1, "B": 3}, values.merge({"A": 1, "B": 2}, {"B": 3}))

    def test_nested_objects_deep_merge_and_siblings_survive(self):
        self.assertEqual({"plan": {"GOGC": 25, "GOMEMLIMIT": "24GiB"}},
                         values.merge({"plan": {"GOGC": 25, "GOMEMLIMIT": "12GiB"}}, {"plan": {"GOMEMLIMIT": "24GiB"}}))

    def test_nested_objects_keep_untouched_sibling_goals(self):
        self.assertEqual({"lint": {"GOGC": 400}, "plan": {"GOGC": 25}},
                         values.merge({"plan": {"GOGC": 25}, "lint": {"GOGC": 400}}, {"plan": {"GOGC": 25}}))

    def test_a_null_leaf_survives(self):
        self.assertEqual({"plan": {"GOMEMLIMIT": None}},
                         values.merge({"plan": {"GOMEMLIMIT": "6GiB"}}, {"plan": {"GOMEMLIMIT": None}}))

    def test_an_environment_scalar_replaces_a_global_object(self):
        self.assertEqual({"A": "env"}, values.merge({"A": {"nested": 1}}, {"A": "env"}))

    def test_mismatched_shapes_are_refused(self):
        for global_value, env_value in [({"A": 1}, "s"), ({"A": 1}, ["a"]), (["a"], {"a": 1}),
                                        ("a", "b"), (5, 3), ("ab", 2), (True, {"a": 1})]:
            with self.subTest(global_value=global_value, env_value=env_value):
                with self.assertRaises(values.MergeError):
                    values.merge(global_value, env_value)


class NormalizeGoalKeysTest(unittest.TestCase):
    def test_empty_object_gains_all_eight_goal_keys_as_empty_objects(self):
        normalized = values.normalize_goal_keys({})
        self.assertEqual(ALL_GOAL_KEYS, sorted(normalized))
        self.assertTrue(all(value == {} for value in normalized.values()))

    def test_null_and_false_become_the_full_key_set(self):
        self.assertEqual(ALL_GOAL_KEYS, sorted(values.normalize_goal_keys(None)))
        self.assertEqual(ALL_GOAL_KEYS, sorted(values.normalize_goal_keys(False)))

    def test_existing_values_and_null_leaves_are_preserved(self):
        normalized = values.normalize_goal_keys({"plan": {"GOGC": 25}, "apply": {"GOMEMLIMIT": None}})
        self.assertEqual({"GOGC": 25}, normalized["plan"])
        self.assertEqual({"GOMEMLIMIT": None}, normalized["apply"])
        self.assertEqual({}, normalized["lint"])

    def test_an_unknown_key_passes_through_and_the_eight_are_still_added(self):
        normalized = values.normalize_goal_keys({"all": {"NOPE": 1}})
        self.assertEqual({"NOPE": 1}, normalized["all"])
        self.assertEqual(9, len(normalized))

    def test_non_objects_pass_through_untouched(self):
        self.assertEqual([1, 2], values.normalize_goal_keys([1, 2]))
        self.assertEqual("nope", values.normalize_goal_keys("nope"))
        self.assertEqual(True, values.normalize_goal_keys(True))

    def test_the_input_is_not_mutated(self):
        original = {"plan": {}}
        values.normalize_goal_keys(original)
        self.assertEqual({"plan": {}}, original)


if __name__ == "__main__":
    unittest.main()
