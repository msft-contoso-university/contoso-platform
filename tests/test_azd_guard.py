import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AzdGuardTests(unittest.TestCase):
    def test_incomplete_lifecycle_hooks_reference_guard(self):
        project = (ROOT / "azure.yaml").read_text(encoding="utf-8")
        for hook in ("preup", "preprovision", "predeploy", "predown"):
            with self.subTest(hook=hook):
                self.assertRegex(
                    project,
                    re.compile(
                        rf"(?m)^  {hook}:\s*\n"
                        r"    shell: pwsh\s*\n"
                        r"    run: \./scripts/guard-incomplete\.ps1\s*$"
                    ),
                )

    def test_guard_rejects_lifecycle(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ROOT / "scripts" / "guard-incomplete.ps1")],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ADLC stack is incomplete", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
