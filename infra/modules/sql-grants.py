import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import uuid
from pathlib import Path

AZD = (
    "https://github.com/Azure/azure-dev/releases/download/azure-dev-cli_1.38.0/azd-linux-amd64.tar.gz",
    "a975ff5f74bead27dad97ea4d7396d4802a0cb573a908b643af1f47a8f13d98c",
    "azd-linux-amd64",
)
SQLCMD = (
    "https://github.com/microsoft/go-sqlcmd/releases/download/v1.10.0/sqlcmd-linux-amd64.tar.bz2",
    "92516d98c63d99b0994de5b61350c91f6915f9b76f139a59039fbcb225c2e987",
    "sqlcmd",
)
IDENTITY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,58}[A-Za-z0-9]$")
SERVER_NAME = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
DATABASES = {"students", "academics", "enrollments"}


def validate(server, client_id, targets):
    if not isinstance(server, str) or not SERVER_NAME.fullmatch(server):
        raise ValueError("invalid SQL server name")
    uuid.UUID(client_id)
    if not isinstance(targets, list) or not 1 <= len(targets) <= len(DATABASES):
        raise ValueError("one to three database grants are required")
    databases = set()
    runtime_names = set()
    migration_names = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"database", "runtime", "migration"}:
            raise ValueError("each grant must specify exactly database, runtime and migration")
        database, runtime, migration = target["database"], target["runtime"], target["migration"]
        if not isinstance(database, str) or database not in DATABASES or database in databases:
            raise ValueError("database must be a unique, allowlisted service database")
        if any(not isinstance(value, str) or not IDENTITY_NAME.fullmatch(value) for value in (runtime, migration)):
            raise ValueError("invalid managed identity name")
        databases.add(database)
        runtime_names.add(runtime.lower())
        migration_names.add(migration.lower())
    if (runtime_names & migration_names or len(runtime_names) != len(targets)
            or len(migration_names) != len(targets)):
        raise ValueError("runtime and migration identities must be distinct per database")


def install_binary(spec, directory, name):
    url, expected_digest, member_name = spec
    archive_path = directory / f"{name}.archive"
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url, timeout=60) as response, archive_path.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > 40 * 1024 * 1024:
                raise ValueError(f"{name} download exceeds size limit")
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != expected_digest:
        raise ValueError(f"{name} archive digest mismatch")
    with tarfile.open(archive_path) as archive:
        matches = [member for member in archive.getmembers() if member.name == member_name]
        if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 100 * 1024 * 1024:
            raise ValueError(f"{name} archive has an invalid executable")
        source = archive.extractfile(matches[0])
        if source is None:
            raise ValueError(f"{name} executable cannot be read")
        with source, (directory / name).open("wb") as output:
            shutil.copyfileobj(source, output)
    (directory / name).chmod(0o700)


def run(server, client_id, targets, grant_script, output_path):
    validate(server, client_id, targets)
    with tempfile.TemporaryDirectory(prefix="adlc-sql-grants-") as temporary:
        directory = Path(temporary)
        install_binary(AZD, directory, "azd")
        install_binary(SQLCMD, directory, "sqlcmd")
        (directory / "azure.yaml").write_text("name: contoso-sql-grants\n", encoding="utf-8")
        (directory / "grant-sql-access.sh").write_bytes(grant_script)
        env = os.environ.copy()
        env["HOME"] = str(directory)
        env["AZURE_CLIENT_ID"] = client_id
        env["PATH"] = str(directory) + os.pathsep + env.get("PATH", "")
        env.pop("SERVICE_WEB_NAME", None)
        subprocess.run(["azd", "env", "new", "grant", "--no-prompt"], cwd=directory, env=env, check=True)
        for target in targets:
            for identity, ddl in ((target["runtime"], "false"), (target["migration"], "true")):
                subprocess.run([
                    "azd", "env", "set", f"SQL_SERVER={server}",
                    f"SQL_DATABASE={target['database']}", f"SERVICE_API_NAME={identity}",
                    f"SQL_GRANT_DDLADMIN={ddl}", "--no-prompt",
                ], cwd=directory, env=env, check=True)
                subprocess.run(["bash", "grant-sql-access.sh"], cwd=directory, env=env, check=True)
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump({"result": "granted", "databaseCount": len(targets)}, output)


if __name__ == "__main__":
    try:
        run(
            os.environ["SQL_SERVER"], os.environ["BOOTSTRAP_CLIENT_ID"],
            json.loads(os.environ["GRANT_TARGETS"]),
            base64.b64decode(os.environ["GRANT_SCRIPT"], validate=True),
            os.environ["AZ_SCRIPTS_OUTPUT_PATH"],
        )
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"Private SQL grants failed: {error}", file=sys.stderr)
        sys.exit(1)
