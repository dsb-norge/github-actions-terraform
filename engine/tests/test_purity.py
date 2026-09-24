"""The decision core is pure: it imports nothing that reads the environment, the filesystem, the
network or the clock (only json and re from the standard library), and nothing from the adapter
side. docs/Decision-engine.md D2."""

import ast
import os
import unittest

import support

PACKAGE_DIR = os.path.join(os.path.dirname(support.TESTS_DIR), "dsb_tf_engine")
CORE = ("__init__.py", "decide.py", "environments.py", "globs.py", "model.py", "record.py", "relevance.py", "values.py")
ADAPTER_SIDE = ("__main__.py", "adapter.py", "workflow.py")
CORE_MAY_IMPORT = {"json", "re", "dsb_tf_engine"}


def imports(name):
    with open(os.path.join(PACKAGE_DIR, name), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom):
            found.add("dsb_tf_engine" if node.level else node.module.split(".")[0])
            if node.level:
                found |= {f"dsb_tf_engine.{alias.name}" for alias in node.names}
    return found


class PurityTest(unittest.TestCase):
    def test_every_module_is_classified(self):
        modules = {name for name in os.listdir(PACKAGE_DIR) if name.endswith(".py")}
        self.assertEqual(modules, set(CORE) | set(ADAPTER_SIDE))

    def test_the_core_imports_only_json_re_and_itself(self):
        for name in CORE:
            with self.subTest(module=name):
                external = {module for module in imports(name) if not module.startswith("dsb_tf_engine")}
                self.assertLessEqual(external, CORE_MAY_IMPORT)

    def test_the_core_never_imports_the_adapter_side(self):
        adapter_modules = {f"dsb_tf_engine.{name[:-3]}" for name in ADAPTER_SIDE}
        for name in CORE:
            with self.subTest(module=name):
                self.assertEqual(set(), imports(name) & adapter_modules)

    def test_the_scan_sees_imports(self):
        self.assertIn("subprocess", imports("adapter.py"))
        self.assertIn("dsb_tf_engine.values", imports("environments.py"))


if __name__ == "__main__":
    unittest.main()
