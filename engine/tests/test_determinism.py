"""I12: the same input document yields byte-identical output under different hash seeds."""

import os
import subprocess
import sys
import tempfile
import unittest

import support

ENGINE_DIR = os.path.dirname(support.TESTS_DIR)


class DeterminismTest(unittest.TestCase):
    def decide_bytes(self, input_file, seed, work):
        output_file = os.path.join(work, f"output-{seed}.json")
        subprocess.run(
            [sys.executable, "-B", "-m", "dsb_tf_engine", "decide", "--input", input_file, "--output", output_file],
            # cwd as well as PYTHONPATH: `-m` finds the package in the working directory even
            # under an interpreter that is not handed PYTHONPATH, such as one `pipx run` starts.
            cwd=ENGINE_DIR, env={**os.environ, "PYTHONPATH": ENGINE_DIR, "PYTHONHASHSEED": str(seed)},
            capture_output=True, check=False,
        )
        with open(output_file, "rb") as handle:
            return handle.read()

    def test_every_port_case_is_byte_identical_across_hash_seeds(self):
        with tempfile.TemporaryDirectory() as work:
            for name in sorted(os.listdir(support.PORT_CASES_DIR)):
                input_file = os.path.join(support.PORT_CASES_DIR, name, "input.json")
                with self.subTest(case=name):
                    self.assertEqual(self.decide_bytes(input_file, 0, work), self.decide_bytes(input_file, 1, work))


if __name__ == "__main__":
    unittest.main()
