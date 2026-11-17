import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "get-azd-ancestor.ps1"


class AzdAncestorTests(unittest.TestCase):
    def test_direct_invocation_fails_closed(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(SCRIPT)], capture_output=True, text=True, timeout=30
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertFalse(result.stdout.strip())

    def test_hooks_share_identity_only_within_same_azd_process(self):
        if not shutil.which("azd"):
            if os.environ.get("ADLC_REQUIRE_AZD_SPIKE") == "1":
                self.fail("azd is required for the native hook identity spike")
            self.skipTest("azd not installed; native hook identity was not exercised")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "observed.jsonl"
            command = "& $env:ADLC_SPIKE_SCRIPT | Add-Content -Path $env:ADLC_SPIKE_OUTPUT -Encoding utf8"
            root.joinpath("azure.yaml").write_text(
                "name: adlc-identity-spike\nhooks:\n"
                f"  preprovision:\n    - shell: pwsh\n      run: {json.dumps(command)}\n"
                f"    - shell: pwsh\n      run: {json.dumps(command)}\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update({
                "ADLC_SPIKE_SCRIPT": str(SCRIPT),
                "ADLC_SPIKE_OUTPUT": str(output),
                "AZURE_ENV_NAME": "identity-spike",
                "AZD_DISABLE_TELEMETRY": "true",
            })
            for _ in range(2):
                result = subprocess.run(
                    ["azd", "-C", str(root), "hooks", "run", "preprovision", "--no-prompt"],
                    env=env, capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            identities = [json.loads(line) for line in output.read_text(encoding="utf-8-sig").splitlines()]
            self.assertEqual(4, len(identities))
            self.assertEqual(identities[0], identities[1])
            self.assertEqual(identities[2], identities[3])
            self.assertNotEqual(identities[0], identities[2])
            self.assertTrue(all(set(identity) == {"pid", "start"} and
                                re.fullmatch(r"(?:[0-9a-f-]{36}:[0-9]+:)?[0-9]+", identity["start"])
                                for identity in identities))
            if sys.platform.startswith("linux"):
                self.assertTrue(all(":" in identity["start"] for identity in identities))

    def test_simultaneous_hook_invocations_do_not_share_identity(self):
        if not shutil.which("azd"):
            if os.environ.get("ADLC_REQUIRE_AZD_SPIKE") == "1":
                self.fail("azd is required for the native hook identity spike")
            self.skipTest("azd not installed; concurrent native hooks were not exercised")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = (
                "$ErrorActionPreference = 'Stop'; "
                "& $env:ADLC_SPIKE_SCRIPT | Add-Content -Path $env:ADLC_SPIKE_OUTPUT -Encoding utf8; "
                "Set-Content -Path $env:ADLC_SPIKE_MARKER -Value ready; "
                "for ($i=0; $i -lt 200; $i++) { "
                "if ((Test-Path $env:ADLC_SPIKE_MARKER_A) -and (Test-Path $env:ADLC_SPIKE_MARKER_B)) { return }; "
                "Start-Sleep -Milliseconds 100 }; throw 'Concurrent hook barrier timed out'"
            )
            root.joinpath("azure.yaml").write_text(
                "name: adlc-identity-concurrency-spike\nhooks:\n"
                f"  preprovision:\n    - shell: pwsh\n      run: {json.dumps(command)}\n"
                f"    - shell: pwsh\n      run: {json.dumps(command)}\n",
                encoding="utf-8",
            )
            processes = []
            try:
                for name in ("a", "b"):
                    env = os.environ.copy()
                    env.update({
                        "ADLC_SPIKE_SCRIPT": str(SCRIPT),
                        "ADLC_SPIKE_OUTPUT": str(root / f"{name}.jsonl"),
                        "ADLC_SPIKE_MARKER": str(root / f"{name}.ready"),
                        "ADLC_SPIKE_MARKER_A": str(root / "a.ready"),
                        "ADLC_SPIKE_MARKER_B": str(root / "b.ready"),
                        "AZURE_ENV_NAME": "identity-spike",
                        "AZD_DISABLE_TELEMETRY": "true",
                    })
                    processes.append(subprocess.Popen(
                        ["azd", "-C", str(root), "hooks", "run", "preprovision", "--no-prompt"],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    ))
                for process in processes:
                    stdout, stderr = process.communicate(timeout=90)
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                groups = [
                    [json.loads(line) for line in (root / f"{name}.jsonl").read_text(encoding="utf-8-sig").splitlines()]
                    for name in ("a", "b")
                ]
                self.assertEqual(len(groups[0]), 2)
                self.assertEqual(len(groups[1]), 2)
                self.assertEqual(groups[0][0], groups[0][1])
                self.assertEqual(groups[1][0], groups[1][1])
                self.assertNotEqual(groups[0][0], groups[1][0])
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
