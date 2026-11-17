import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone

REPOSITORY = "msft-contoso-university/contoso-platform"
STATE_BRANCH = "adlc-state"
NAME = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$")


class LockError(Exception):
    pass


def lock_path(tenant, subscription, environment, generation):
    tenant = str(uuid.UUID(tenant))
    subscription = str(uuid.UUID(subscription))
    if not NAME.fullmatch(environment) or not NAME.fullmatch(generation):
        raise ValueError("environment and generation must be lowercase alphanumeric or hyphen names")
    key = "|".join((tenant, subscription, environment))
    return "locks/" + hashlib.sha256(key.encode("utf-8")).hexdigest() + ".json"


def gh_api(method, path, payload=None):
    endpoint = f"repos/{REPOSITORY}/contents/{path}"
    if method == "GET":
        endpoint += f"?ref={STATE_BRANCH}"
    command = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        command.extend(["--input", "-"])
    try:
        result = subprocess.run(
            command, input=json.dumps(payload) if payload is not None else None,
            text=True, capture_output=True, check=False, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LockError(f"GitHub CLI did not complete: {error}") from error
    if result.returncode:
        raise LockError(f"GitHub API {method} failed: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise LockError("GitHub API returned invalid JSON") from error


def read_lock(path):
    response = gh_api("GET", path)
    if response.get("encoding") != "base64" or not isinstance(response.get("sha"), str):
        raise LockError("GitHub returned an invalid lock record")
    try:
        content = base64.b64decode("".join(response["content"].split()), validate=True)
        document = json.loads(content)
    except (ValueError, KeyError, TypeError, UnicodeDecodeError) as error:
        raise LockError("GitHub returned unreadable lock content") from error
    if not isinstance(document, dict):
        raise LockError("GitHub returned invalid lock content")
    return response["sha"], document


def acquire(path, operation_id, action, generation):
    owner = str(uuid.UUID(operation_id))
    document = {
        "version": 1,
        "operationId": owner,
        "action": action,
        "generation": generation,
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }
    payload = {
        "message": f"Acquire ADLC stack lock {owner}",
        "branch": STATE_BRANCH,
        "content": base64.b64encode(json.dumps(document, sort_keys=True).encode("utf-8")).decode("ascii"),
    }
    try:
        gh_api("PUT", path, payload)
    except LockError as error:
        try:
            _, current = read_lock(path)
        except LockError:
            raise LockError(f"Lock acquisition failed; ownership is unknown. {error}") from error
        if (current.get("operationId") == owner and current.get("action") == action
                and current.get("generation") == generation):
            return
        raise LockError("Stack is locked by another operation; no operation was started") from error


def release(path, operation_id):
    owner = str(uuid.UUID(operation_id))
    sha, current = read_lock(path)
    if current.get("operationId") != owner:
        raise LockError("Lock belongs to another operation; refusing to release it")
    gh_api("DELETE", path, {
        "message": f"Release ADLC stack lock {owner}",
        "branch": STATE_BRANCH,
        "sha": sha,
    })


def main():
    parser = argparse.ArgumentParser(description="Acquire or release a stack operation lock in GitHub.")
    parser.add_argument("command", choices=("acquire", "release"))
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--action", choices=("create", "update", "promote", "destroy"))
    args = parser.parse_args()
    try:
        if args.command == "acquire" and args.action is None:
            raise ValueError("--action is required to acquire a lock")
        path = lock_path(args.tenant, args.subscription, args.environment, args.generation)
        if args.command == "acquire":
            acquire(path, args.operation_id, args.action, args.generation)
        else:
            release(path, args.operation_id)
    except (ValueError, LockError) as error:
        print(f"Stack lock failed: {error}", file=sys.stderr)
        return 1
    print(f"Stack lock {args.command} succeeded for operation {args.operation_id}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
