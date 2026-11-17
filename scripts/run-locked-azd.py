"""Fail-closed prototype for process-scoped stack lifecycle serialization."""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("stack_lock", Path(__file__).with_name("stack-lock.py"))
stack_lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stack_lock)


def verify_context(environment, tenant, subscription, generation):
    uuid.UUID(tenant)
    uuid.UUID(subscription)
    azure_cli = shutil.which("az")
    if not azure_cli:
        raise FileNotFoundError("Azure CLI executable was not found on PATH.")
    result = subprocess.run(
        ["azd", "env", "get-values", "--environment", environment, "--no-prompt"],
        text=True, capture_output=True, check=True, timeout=60,
    )
    values = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in values:
            raise ValueError("Invalid azd environment values.")
        values[key] = json.loads(value) if value.startswith('"') else value
    expected = {
        "AZURE_ENV_NAME": environment,
        "AZURE_TENANT_ID": tenant,
        "AZURE_SUBSCRIPTION_ID": subscription,
        "ADLC_STACK_GENERATION": generation,
    }
    if any(values.get(key, "").lower() != value.lower() for key, value in expected.items()):
        raise ValueError("azd environment does not match the requested stack identity.")
    account = subprocess.run(
        [azure_cli, "account", "show", "--subscription", subscription, "--output", "json", "--only-show-errors"],
        text=True, capture_output=True, check=True, timeout=60,
    )
    account = json.loads(account.stdout)
    if (account.get("id", "").lower() != subscription.lower()
            or account.get("tenantId", "").lower() != tenant.lower()
            or account.get("state") != "Enabled"):
        raise ValueError("Azure caller context does not match the requested stack.")


def run_locked(environment, tenant, subscription, generation, action):
    if action not in ("create", "update"):
        raise ValueError("Destroy is blocked until an explicit, verified confirmation flow is integrated.")
    path = stack_lock.lock_path(tenant, subscription, environment, generation)
    verify_context(environment, tenant, subscription, generation)
    owner = str(uuid.uuid4())
    stack_lock.acquire(path, owner, action, generation)
    child_env = os.environ.copy()
    child_env.update({
        "ADLC_OPERATION_ID": owner,
        "ADLC_OPERATION_ACTION": action,
        "ADLC_OPERATION_ENVIRONMENT": environment,
        "ADLC_OPERATION_GENERATION": generation,
    })
    try:
        completed = subprocess.run(["azd", "up", "--environment", environment], env=child_env, check=False)
    except (OSError, KeyboardInterrupt):
        print(f"Operation {owner} did not complete; the stack lock is retained for review.", file=sys.stderr)
        raise
    if completed.returncode != 0:
        print(f"Operation {owner} failed; the stack lock is retained for review.", file=sys.stderr)
        return completed.returncode
    stack_lock.release(path, owner, action, generation)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--action", required=True, choices=("create", "update", "destroy"))
    parser.parse_args()
    print("Stack lifecycle is incomplete; the locked azd wrapper cannot execute yet.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
