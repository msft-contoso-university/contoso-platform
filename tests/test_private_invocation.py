import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class PrivateInvocationTests(unittest.TestCase):
    def test_owner_store_refuses_duplicates_mismatches_and_broad_permissions(self):
        test = Path(__file__).with_name("test-private-invocation.ps1")
        with tempfile.TemporaryDirectory() as parent:
            env = os.environ.copy()
            env["ADLC_TEST_PARENT"] = parent
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(test)],
                env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_owner_creation_is_exclusive_under_race(self):
        test = Path(__file__).with_name("test-private-race.ps1")
        with tempfile.TemporaryDirectory() as parent:
            env = os.environ.copy()
            env["ADLC_TEST_PARENT"] = parent
            processes = [
                subprocess.Popen(["pwsh", "-NoProfile", "-File", str(test)], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                for _ in range(2)
            ]
            try:
                outputs = [process.communicate(timeout=60) for process in processes]
                self.assertEqual(1, sum(process.returncode == 0 for process in processes), outputs)
                self.assertEqual(1, len(list((Path(parent) / "race-owner").glob("*.json"))))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
