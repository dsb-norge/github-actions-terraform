"""The one glob matcher: the grammar of docs/Terraform-tests.md §4.4, used by relevance and tests.

`*` matches within one segment, `?` one character of a segment, `**` any number of whole segments
including none, a pattern without `/` matches the basename; no negation, classes or braces.
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

    def test_a_leading_dot_slash_in_a_pattern_is_ignored(self):
        self.assertMatches("./envs/prod/**", "envs/prod/main.tf")
        self.assertEqual("envs/prod/**", globs.compile_glob("./envs/prod/**").pattern)

    def test_matching_is_case_sensitive(self):
        self.assertMatches("README.md", "readme.md", False)


class ValidationTest(unittest.TestCase):
    def test_unsupported_syntax_is_refused_with_the_reason(self):
        for pattern, reason in (("!envs/**", "negation"), ("envs/[ab]/**", "character classes"),
                                ("envs/{a,b}/**", "braces"), ("envs/a]/x", "character classes"),
                                ("envs/a}/x", "braces"), ("", "it is empty"), ("./", "it is empty"), ("/envs/**", "absolute"),
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
