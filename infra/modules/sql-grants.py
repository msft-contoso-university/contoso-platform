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
    bootstrap_id = uuid.UUID(client_id)
    if bootstrap_id.int == 0:
        raise ValueError("bootstrap client ID must not be empty")
    if not isinstance(targets, list) or not 1 <= len(targets) <= len(DATABASES):
        raise ValueError("one to three database grants are required")
    databases = set()
    runtime_names = set()
    migration_names = set()
    identity_client_ids = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {
            "database", "runtime", "runtimeClientId", "migration", "migrationClientId"
        }:
            raise ValueError("each grant must specify database and both identity names and client IDs")
        database, runtime, migration = target["database"], target["runtime"], target["migration"]
        if not isinstance(database, str) or database not in DATABASES or database in databases:
            raise ValueError("database must be a unique, allowlisted service database")
        if any(not isinstance(value, str) or not IDENTITY_NAME.fullmatch(value) for value in (runtime, migration)):
            raise ValueError("invalid managed identity name")
        for key in ("runtimeClientId", "migrationClientId"):
            if not isinstance(target[key], str):
                raise ValueError("identity client ID must be a GUID")
            identity_id = uuid.UUID(target[key])
            if identity_id.int == 0 or identity_id == bootstrap_id or identity_id in identity_client_ids:
                raise ValueError("bootstrap, runtime and migration client IDs must be distinct")
            identity_client_ids.add(identity_id)
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


def grant_sql(target):
    """Create or verify exact Entra application SIDs before assigning roles."""
    statements = ["SET XACT_ABORT ON;", "BEGIN TRANSACTION;"]
    for kind in ("runtime", "migration"):
        name = target[kind]
        client_id = str(uuid.UUID(target[f"{kind}ClientId"]))
        sid = "0x" + uuid.UUID(client_id).bytes_le.hex()
        statements.extend([
            f"IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'{name}' AND (type <> 'E' OR sid <> {sid}))",
            "    THROW 51010, 'Existing SQL principal does not match the managed identity client ID.', 1;",
            f"IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'{name}')",
            f"    CREATE USER [{name}] WITH SID = {sid}, TYPE = E;",
        ])
        if kind == "runtime":
            statements.extend([
                "IF EXISTS (SELECT 1 FROM sys.database_role_members rm",
                "    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id",
                "    JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id",
                f"    WHERE m.name = N'{name}' AND r.name NOT IN (N'db_datareader', N'db_datawriter'))",
                "    THROW 51011, 'Runtime identity has an unexpected database role.', 1;",
                "IF EXISTS (SELECT 1 FROM sys.database_permissions p",
                "    JOIN sys.database_principals m ON m.principal_id = p.grantee_principal_id",
                f"    WHERE m.name = N'{name}' AND p.state IN ('G', 'W') AND p.permission_name <> N'CONNECT')",
                "    THROW 51012, 'Runtime identity has unexpected explicit database permissions.', 1;",
            ])
        roles = ["db_datareader", "db_datawriter"]
        if kind == "migration":
            roles.append("db_ddladmin")
        for role in roles:
            statements.extend([
                "IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm",
                "    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id",
                "    JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id",
                f"    WHERE r.name = N'{role}' AND m.name = N'{name}')",
                f"    ALTER ROLE [{role}] ADD MEMBER [{name}];",
            ])
    statements.append("COMMIT TRANSACTION;")
    return "\n".join(statements)


def run(server, client_id, targets, output_path):
    validate(server, client_id, targets)
    with tempfile.TemporaryDirectory(prefix="adlc-sql-grants-") as temporary:
        directory = Path(temporary)
        install_binary(SQLCMD, directory, "sqlcmd")
        env = os.environ.copy()
        env["AZURE_CLIENT_ID"] = client_id
        env["PATH"] = str(directory) + os.pathsep + env.get("PATH", "")
        for target in targets:
            subprocess.run([
                str(directory / "sqlcmd"), "-S", f"{server}.database.windows.net",
                "-d", target["database"], "--authentication-method", "ActiveDirectoryDefault",
                "-x", "-b", "-Q", grant_sql(target),
            ], cwd=directory, env=env, check=True)
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump({"result": "granted", "databaseCount": len(targets)}, output)


if __name__ == "__main__":
    print(
        "Private SQL grants are blocked until database principal SIDs are verified against managed identity client IDs.",
        file=sys.stderr,
    )
    sys.exit(1)
