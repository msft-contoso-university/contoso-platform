import base64
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "scripts" / "stack-lock.py"
spec = importlib.util.spec_from_file_location("stack_lock", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
OWNER = "ebca89ce-a010-423d-9eac-de5eb37e3029"
OTHER = "c1581e17-f82c-4aeb-8e97-10c6d6c6d387"
PATHNAME = "locks/123.json"


def record(owner=OWNER, action="create", generation="one"):
    return {
        "encoding": "base64",
        "sha": "abc123",
        "content": base64.b64encode(json.dumps({"operationId": owner, "action": action, "generation": generation}).encode()).decode(),
    }


class StackLockTests(unittest.TestCase):
    def test_stack_identity_is_stable_and_not_exposed_in_path(self):
        tenant = "11111111-1111-4111-8111-111111111111"
        subscription = "22222222-2222-4222-8222-222222222222"
        path = module.lock_path(tenant, subscription, "demo", "one")
        self.assertEqual(path, module.lock_path(tenant.upper(), subscription.upper(), "demo", "one"))
        self.assertNotIn(subscription, path)
        self.assertEqual(path, module.lock_path(tenant, subscription, "demo", "two"))
        self.assertNotEqual(path, module.lock_path(tenant, subscription, "other", "one"))

    def test_existing_other_owner_fails_closed(self):
        with patch.object(module, "gh_api", side_effect=[module.LockError("conflict"), record(OTHER)]):
            with self.assertRaisesRegex(module.LockError, "locked by another"):
                module.acquire(PATHNAME, OWNER, "create", "one")

    def test_ambiguous_acquire_checks_exact_owner(self):
        with patch.object(module, "gh_api", side_effect=[module.LockError("lost response"), record()]):
            module.acquire(PATHNAME, OWNER, "create", "one")

    def test_unverifiable_acquire_fails_closed(self):
        with patch.object(module, "gh_api", side_effect=module.LockError("unavailable")):
            with self.assertRaisesRegex(module.LockError, "ownership is unknown"):
                module.acquire(PATHNAME, OWNER, "create", "one")

    def test_release_requires_owner_and_current_blob_sha(self):
        with patch.object(module, "gh_api", side_effect=[record(), {}]) as api:
            module.release(PATHNAME, OWNER, "create", "one")
        self.assertEqual(api.call_args_list[1].args[2]["sha"], "abc123")
        with patch.object(module, "gh_api", return_value=record(OTHER)) as api:
            with self.assertRaisesRegex(module.LockError, "another operation"):
                module.release(PATHNAME, OWNER, "create", "one")
            self.assertEqual(api.call_count, 1)
        for action, generation in (("update", "one"), ("create", "two")):
            with patch.object(module, "gh_api", return_value=record()) as api:
                with self.assertRaisesRegex(module.LockError, "action or generation"):
                    module.release(PATHNAME, OWNER, action, generation)
                self.assertEqual(api.call_count, 1)

    def test_verify_requires_exact_owner_action_and_generation(self):
        with patch.object(module, "gh_api", return_value=record()):
            module.verify(PATHNAME, OWNER, "create", "one")
            for owner, action, generation in (
                (OTHER, "create", "one"), (OWNER, "destroy", "one"), (OWNER, "create", "two")
            ):
                with self.assertRaisesRegex(module.LockError, "does not belong"):
                    module.verify(PATHNAME, owner, action, generation)


if __name__ == "__main__":
    unittest.main()
