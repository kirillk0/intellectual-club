from __future__ import annotations

import runpy
import sys
import unittest
from pathlib import Path


class ShellOutletEntrypointTest(unittest.TestCase):
    def test_script_style_execution_can_import_outlets_package(self):
        script_path = Path(__file__).resolve().parents[1] / "shell" / "shell_outlet.py"
        project_root = script_path.parents[2]
        script_dir = script_path.parent

        original_path = list(sys.path)
        original_modules = {
            name: sys.modules.get(name)
            for name in ("outlets", "outlets.outlet_base", "outlets.shell", "outlets.shell.shell_outlet")
        }

        try:
            sys.path[:] = [str(script_dir), *[entry for entry in original_path if Path(entry or ".").resolve() != project_root]]
            for name in original_modules:
                sys.modules.pop(name, None)

            namespace = runpy.run_path(str(script_path), run_name="__test__")

            self.assertEqual(namespace["__name__"], "__test__")
            self.assertIn("main", namespace)
            self.assertIn(str(project_root), sys.path)
        finally:
            sys.path[:] = original_path
            for name in original_modules:
                sys.modules.pop(name, None)
            for name, module in original_modules.items():
                if module is not None:
                    sys.modules[name] = module
