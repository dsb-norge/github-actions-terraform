"""GitHub Actions I/O: escaping, verbatim blocks, groups, annotations, step outputs."""

import io
import os
import tempfile
import unittest

from dsb_tf_engine import workflow


class EscapeTest(unittest.TestCase):
    def test_data_escapes_percent_first_then_cr_and_lf(self):
        self.assertEqual("100%25 a%0Db%0Ac %253A", workflow.escape_data("100% a\rb\nc %3A"))

    def test_properties_also_escape_colon_and_comma(self):
        self.assertEqual("a%3Ab%2Cc%25%0A", workflow.escape_property("a:b,c%\n"))

    def test_plain_text_is_unchanged(self):
        self.assertEqual("create-tf-vars-matrix", workflow.escape_property("create-tf-vars-matrix"))


class LogTest(unittest.TestCase):
    def setUp(self):
        self.stream = io.StringIO()
        self.log = workflow.Log(self.stream, "my: title")

    def lines(self):
        return self.stream.getvalue().splitlines()

    def test_verbatim_wraps_every_line_between_matching_markers(self):
        self.log.verbatim("::warning::x\nsecond\n")
        lines = self.lines()
        self.assertTrue(lines[0].startswith("::stop-commands::"))
        token = lines[0][len("::stop-commands::"):]
        self.assertEqual(32, len(token))
        self.assertEqual(["::warning::x", "second", f"::{token}::"], lines[1:])

    def test_verbatim_tokens_differ(self):
        self.log.verbatim("a")
        self.log.verbatim("b")
        starts = [line for line in self.lines() if line.startswith("::stop-commands::")]
        self.assertNotEqual(starts[0], starts[1])

    def test_verbatim_of_nothing_is_an_empty_block(self):
        self.log.verbatim("")
        self.assertEqual(2, len(self.lines()))

    def test_a_group_holds_its_text_verbatim(self):
        self.log.group("name", "body")
        lines = self.lines()
        self.assertEqual("::group::my: title: name", lines[0])
        self.assertTrue(lines[1].startswith("::stop-commands::"))
        self.assertEqual(["body", lines[3], "::endgroup::"], lines[2:])
        self.assertEqual(f"::{lines[1][len('::stop-commands::'):]}::", lines[3])

    def test_an_error_is_one_line_with_escaped_title_and_message(self):
        self.log.error("a\nb%")
        self.assertEqual(["::error title=my%3A title::a%0Ab%25"], self.lines())

    def test_a_notice_is_one_line_with_its_own_escaped_title_and_message(self):
        self.log.notice("Terraform CI, again", "a\nb%: c")
        self.assertEqual(["::notice title=Terraform CI%2C again::a%0Ab%25: c"], self.lines())

    def test_a_line(self):
        self.log.line("x")
        self.log.line()
        self.assertEqual("x\n\n", self.stream.getvalue())


class AppendOutputTest(unittest.TestCase):
    def test_outputs_append_under_distinct_random_delimiters(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "output")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("earlier=1\n")
            workflow.append_output(path, "a", "one\ntwo")
            workflow.append_output(path, "b", "")
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        self.assertEqual("earlier=1", lines[0])
        name, delimiter = lines[1].split("<<")
        self.assertEqual("a", name)
        self.assertRegex(delimiter, r"^EOF_[0-9a-f]{32}$")
        self.assertEqual(["one", "two", delimiter], lines[2:5])
        second_name, second = lines[5].split("<<")
        self.assertEqual(("b", "", second), (second_name, lines[6], lines[7]))
        self.assertNotEqual(delimiter, second)
        self.assertEqual(8, len(lines))


if __name__ == "__main__":
    unittest.main()
