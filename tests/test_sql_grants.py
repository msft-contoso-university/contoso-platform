import importlib.util
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "infra" / "modules" / "sql-grants.py"
spec = importlib.util.spec_from_file_location("sql_grants", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
CLIENT = "11111111-1111-4111-8111-111111111111"
TARGET = {
    "database": "students",
    "runtime": "students-api",
    "runtimeClientId": "00112233-4455-6677-8899-aabbccddeeff",
    "migration": "students-migration",
    "migrationClientId": "01234567-89ab-cdef-0123-456789abcdef",
}


class SqlGrantTests(unittest.TestCase):
    def test_standalone_grant_runner_is_blocked(self):
        result = subprocess.run([sys.executable, str(PATH)], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("principal SIDs", result.stderr)

    def test_bundled_shell_script_has_linux_line_endings(self):
        script = (PATH.parents[2] / "scripts" / "grant-sql-access.sh").read_bytes()
        self.assertNotIn(b"\r\n", script)

    def test_requires_distinct_runtime_and_migration_identities(self):
        target = dict(TARGET, migration="STUDENTS-API")
        with self.assertRaisesRegex(ValueError, "distinct"):
            module.validate("school-sql", CLIENT, [target])

    def test_rejects_non_service_database_and_unsafe_identity(self):
        for target in (dict(TARGET, database="master"), dict(TARGET, runtime="api;DROP")):
            with self.subTest(target=target), self.assertRaises(ValueError):
                module.validate("school-sql", CLIENT, [target])

    def test_rejects_reused_or_invalid_client_ids(self):
        for value in (TARGET["runtimeClientId"], CLIENT, "00000000-0000-0000-0000-000000000000", "not-a-guid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.validate("school-sql", CLIENT, [dict(TARGET, migrationClientId=value)])
        other = dict(TARGET, database="academics", runtime="academics-api", migration="academics-migration")
        with self.assertRaisesRegex(ValueError, "distinct"):
            module.validate("school-sql", CLIENT, [TARGET, other])

    def test_runtime_never_gets_ddl_and_migration_uses_separate_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.json"
            with patch.object(module, "install_binary"), patch.object(module.subprocess, "run") as process:
                module.run("school-sql", CLIENT, [TARGET], str(output))
            command = process.call_args.args[0]
            query = command[command.index("-Q") + 1]
            self.assertIn("CREATE USER [students-api] WITH SID = 0x33221100554477668899aabbccddeeff, TYPE = E", query)
            self.assertIn("CREATE USER [students-migration] WITH SID = 0x67452301ab89efcd0123456789abcdef, TYPE = E", query)
            self.assertIn("Existing SQL principal does not match", query)
            self.assertIn("Runtime identity has unexpected explicit", query)
            self.assertNotIn("ALTER ROLE [db_ddladmin] ADD MEMBER [students-api]", query)
            self.assertIn("ALTER ROLE [db_ddladmin] ADD MEMBER [students-migration]", query)
            self.assertIn("-b", command)
            self.assertEqual(json.loads(output.read_text())["result"], "granted")

    def test_failed_grant_does_not_write_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.json"
            with patch.object(module, "install_binary"), \
                 patch.object(module.subprocess, "run", side_effect=module.subprocess.CalledProcessError(1, "sqlcmd")):
                with self.assertRaises(module.subprocess.CalledProcessError):
                    module.run("school-sql", CLIENT, [TARGET], str(output))
            self.assertFalse(output.exists())

    def test_binary_download_checks_digest_before_extracting(self):
        blob = io.BytesIO()
        with tarfile.open(fileobj=blob, mode="w:gz") as archive:
            data = b"executable"
            member = tarfile.TarInfo("tool")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        payload = blob.getvalue()
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(module.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
                module.install_binary(("https://example.test", hashlib.sha256(payload).hexdigest(), "tool"), Path(directory), "tool")
            self.assertEqual((Path(directory) / "tool").read_bytes(), b"executable")
            with patch.object(module.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    module.install_binary(("https://example.test", "0" * 64, "tool"), Path(directory), "other")
            self.assertFalse((Path(directory) / "other").exists())


if __name__ == "__main__":
    unittest.main()
