"""The one glob matcher: the grammar of docs/Terraform-tests.md §4.4, used by relevance and tests.

`*` matches within one segment, `?` one character of a segment, `**` any number of whole segments
including none, a pattern without `/` matches the basename unless a leading `/` or `./` anchors it
at the root; no negation, classes or braces.
"""

import unittest

from dsb_tf_engine import globs


class MatchTest(unittest.TestCase):
    def assertMatches(self, pattern, path, expected=True):
        self.assertEqual(expected, globs.compile_glob(pattern).matches(path), f"{pattern!r} vs {path!r}")

    def test_star_matches_within_one_segment(self):
        self.assertMatches("envs/*/main.tf", "envs/prod/main.tf")
        self.assertMatches("envs/*/main.tf", "envs/prod/sub/main.tf", False)
        self.assertMatches("envs/p*d/main.tf", "envs/prod/main.tf")
        self.assertMatches("envs/*.tf", "envs/.tf")

    def test_question_mark_matches_one_character_of_a_segment(self):
        self.assertMatches("env?.tf", "env1.tf")
        self.assertMatches("env?.tf", "env.tf", False)
        self.assertMatches("a?b/c.tf", "a/b/c.tf", False)

    def test_double_star_matches_any_number_of_segments_including_none(self):
        self.assertMatches("envs/prod/**", "envs/prod/main.tf")
        self.assertMatches("envs/prod/**", "envs/prod/a/b/c.tf")
        self.assertMatches("envs/prod/**", "envs/prod", False)
        self.assertMatches("envs/prod/**", "envs/production/main.tf", False)
        self.assertMatches("**/unit-*.tftest.hcl", "unit-a.tftest.hcl")
        self.assertMatches("**/unit-*.tftest.hcl", "modules/x/tests/unit-a.tftest.hcl")
        self.assertMatches("modules/**/main.tf", "modules/main.tf")
        self.assertMatches("modules/**/main.tf", "modules/a/b/main.tf")
        self.assertMatches("**/main.tf", "envs/xmain.tf", False)
        self.assertMatches("**/main.tf", "xmain.tf", False)
        self.assertMatches("modules/**/main.tf", "modules/amain.tf", False)
        self.assertMatches("**", "anything/at/all.md")
        self.assertMatches("**", "top.md")

    def test_a_pattern_without_a_slash_matches_the_basename(self):
        self.assertMatches("*.md", "README.md")
        self.assertMatches("*.md", "docs/deep/guide.md")
        self.assertMatches(".tflint.hcl", "envs/prod/.tflint.hcl")
        self.assertMatches("main.tf", "envs/prod/main.tf")
        self.assertMatches("main.tf", "envs/prod/main.tf.bak", False)

    def test_a_pattern_with_a_slash_is_anchored_at_the_root(self):
        self.assertMatches("main/**", "main/x.tf")
        self.assertMatches("main/**", "envs/main/x.tf", False)
        self.assertMatches(".tflint.hcl", ".tflint.hcl")
        self.assertMatches("envs/prod/.tflint.hcl", "envs/prod/.tflint.hcl")

    def test_regex_characters_are_literal(self):
        self.assertMatches("a.b+c(d)$^|.tf", "a.b+c(d)$^|.tf")
        self.assertMatches("a.tf", "aXtf", False)
        self.assertMatches("dir.with.dots/**", "dir.with.dots/x")

    def test_a_leading_slash_or_dot_slash_anchors_a_name_at_the_root(self):
        for pattern in ("/.tflint.hcl", "./.tflint.hcl"):
            with self.subTest(pattern=pattern):
                self.assertMatches(pattern, ".tflint.hcl")
                self.assertMatches(pattern, "envs/prod/.tflint.hcl", False)
                self.assertMatches(pattern, "x.tflint.hcl", False)
                self.assertEqual("/.tflint.hcl", globs.compile_glob(pattern).pattern)
        self.assertMatches("/*.md", "README.md")
        self.assertMatches("/*.md", "docs/guide.md", False)
        self.assertMatches("/?.tf", "a.tf")
        self.assertMatches("/?.tf", "x/a.tf", False)

    def test_an_anchor_changes_nothing_where_a_slash_already_anchors(self):
        for pattern, normalised in (("./envs/prod/**", "envs/prod/**"), ("/envs/prod/**", "envs/prod/**"),
                                    ("/**", "**"), ("./**/main.tf", "**/main.tf"), ("/main/**", "main/**")):
            with self.subTest(pattern=pattern):
                self.assertEqual(normalised, globs.compile_glob(pattern).pattern)
        self.assertMatches("/envs/prod/**", "envs/prod/main.tf")
        self.assertMatches("/envs/prod/**", "x/envs/prod/main.tf", False)
        self.assertMatches("/**", "any/where.md")
        self.assertMatches("./**/main.tf", "main.tf")
        self.assertMatches("./**/main.tf", "a/b/main.tf")

    def test_the_basename_rule_still_holds_without_an_anchor(self):
        self.assertEqual(".tflint.hcl", globs.compile_glob(".tflint.hcl").pattern)
        self.assertMatches(".tflint.hcl", "envs/prod/.tflint.hcl")

    def test_matching_is_case_sensitive(self):
        self.assertMatches("README.md", "readme.md", False)


class ValidationTest(unittest.TestCase):
    def test_unsupported_syntax_is_refused_with_the_reason(self):
        for pattern, reason in (("!envs/**", "negation"), ("envs/[ab]/**", "character classes"),
                                ("envs/{a,b}/**", "braces"), ("envs/a]/x", "character classes"),
                                ("envs/a}/x", "braces"), ("", "it is empty"), ("./", "it is empty"), ("/", "it is empty"),
                                ("//x", "an empty segment"), ("/./x", "'.' or '..' segments"), ("./../x", "'.' or '..' segments"),
                                ("/!x", "negation"),
                                ("envs/a**/x", "'**' must be a whole segment"), ("**b", "'**' must be a whole segment"),
                                ("envs//x", "an empty segment"), ("envs/../x", "'.' or '..' segments"),
                                ("envs/./x", "'.' or '..' segments"), ("envs/x/", "an empty segment")):
            with self.subTest(pattern=pattern):
                with self.assertRaises(globs.GlobError) as raised:
                    globs.compile_glob(pattern)
                self.assertIn(reason, str(raised.exception))
                self.assertIn(repr(pattern), str(raised.exception))

    def test_a_non_string_is_refused(self):
        for value in (None, 5, ["a"]):
            with self.subTest(value=value):
                with self.assertRaises(globs.GlobError) as raised:
                    globs.compile_glob(value)
                self.assertIn("not a string", str(raised.exception))

    def test_the_first_matching_pattern_is_named(self):
        patterns = [globs.compile_glob(p) for p in ("docs/**", "*.tf", "envs/**")]
        self.assertEqual("*.tf", globs.first_match(patterns, "envs/prod/main.tf"))
        self.assertIsNone(globs.first_match(patterns, "scripts/run.sh"))
        self.assertIsNone(globs.first_match([], "anything"))


if __name__ == "__main__":
    unittest.main()
