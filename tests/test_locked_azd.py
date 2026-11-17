import importlib.util
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "scripts" / "run-locked-azd.py"
spec = importlib.util.spec_from_file_location("locked_azd", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TENANT = "11111111-1111-4111-8111-111111111111"
SUBSCRIPTION = "22222222-2222-4222-8222-222222222222"
ARGS = ("demo", TENANT, SUBSCRIPTION, "one")


class LockedAzdTests(unittest.TestCase):
    def test_context_must_match_environment_and_enabled_account(self):
        values = {
            "AZURE_ENV_NAME": "demo", "AZURE_TENANT_ID": TENANT,
            "AZURE_SUBSCRIPTION_ID": SUBSCRIPTION, "ADLC_STACK_GENERATION": "one",
        }
        env_output = "\n".join(f"{key}={json.dumps(value)}" for key, value in values.items())
        account = {"id": SUBSCRIPTION, "tenantId": TENANT, "state": "Enabled"}
        responses = [
            subprocess.CompletedProcess([], 0, stdout=env_output),
            subprocess.CompletedProcess([], 0, stdout=json.dumps(account)),
        ]
        with patch.object(module.subprocess, "run", side_effect=responses):
            module.verify_context(*ARGS)
        account["tenantId"] = "33333333-3333-4333-8333-333333333333"
        responses = [
            subprocess.CompletedProcess([], 0, stdout=env_output),
            subprocess.CompletedProcess([], 0, stdout=json.dumps(account)),
        ]
        with patch.object(module.subprocess, "run", side_effect=responses):
            with self.assertRaisesRegex(ValueError, "caller context"):
                module.verify_context(*ARGS)

    def test_success_inherits_fresh_owner_and_releases_only_that_owner(self):
        with patch.object(module, "verify_context"), \
             patch.object(module.stack_lock, "acquire") as acquire, \
             patch.object(module.stack_lock, "release") as release, \
             patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(0, module.run_locked(*ARGS, "update"))
            owner = acquire.call_args.args[1]
            self.assertEqual(owner, run.call_args.kwargs["env"]["ADLC_OPERATION_ID"])
            self.assertEqual("update", run.call_args.kwargs["env"]["ADLC_OPERATION_ACTION"])
            self.assertNotIn(owner, os.environ.values())
            self.assertEqual(owner, release.call_args.args[1])
            self.assertEqual(["azd", "up", "--environment", "demo"], run.call_args.args[0])
            self.assertEqual(0, module.run_locked(*ARGS, "update"))
            self.assertNotEqual(owner, acquire.call_args.args[1])

    def test_failure_retains_lock(self):
        with patch.object(module, "verify_context"), \
             patch.object(module.stack_lock, "acquire"), \
             patch.object(module.stack_lock, "release") as release, \
             patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run:
            self.assertEqual(1, module.run_locked(*ARGS, "update"))
            release.assert_not_called()
            self.assertEqual(["azd", "up", "--environment", "demo"], run.call_args.args[0])

    def test_destroy_is_blocked_before_lock_or_azd(self):
        with patch.object(module, "verify_context") as context, \
             patch.object(module.stack_lock, "acquire") as acquire:
            with self.assertRaisesRegex(ValueError, "Destroy is blocked"):
                module.run_locked(*ARGS, "destroy")
            context.assert_not_called()
            acquire.assert_not_called()

    def test_process_start_failure_retains_lock(self):
        with patch.object(module, "verify_context"), \
             patch.object(module.stack_lock, "acquire"), \
             patch.object(module.stack_lock, "release") as release, \
             patch.object(module.subprocess, "run", side_effect=OSError("cannot start")):
            with self.assertRaises(OSError):
                module.run_locked(*ARGS, "create")
            release.assert_not_called()

    def test_preflight_failure_never_acquires_lock(self):
        with patch.object(module, "verify_context", side_effect=ValueError("wrong account")), \
             patch.object(module.stack_lock, "acquire") as acquire:
            with self.assertRaises(ValueError):
                module.run_locked(*ARGS, "create")
            acquire.assert_not_called()

    def test_cli_is_blocked_without_invoking_azd_or_lock(self):
        args = ["run-locked-azd.py", "--environment", "demo", "--tenant", TENANT,
                "--subscription", SUBSCRIPTION, "--generation", "one", "--action", "create"]
        with patch.object(sys, "argv", args), patch.object(module, "run_locked") as run:
            self.assertEqual(1, module.main())
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
