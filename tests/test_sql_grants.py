import importlib.util
import hashlib
import io
import json
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
TARGET = {"database": "students", "runtime": "students-api", "migration": "students-migration"}


class SqlGrantTests(unittest.TestCase):
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

    def test_runtime_never_gets_ddl_and_migration_uses_separate_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.json"
            with patch.object(module, "install_binary"), patch.object(module.subprocess, "run") as process:
                module.run("school-sql", CLIENT, [TARGET], b"grant script", str(output))
            commands = [call.args[0] for call in process.call_args_list]
            self.assertIn("SERVICE_API_NAME=students-api", commands[1])
            self.assertIn("SQL_GRANT_DDLADMIN=false", commands[1])
            self.assertIn("SERVICE_API_NAME=students-migration", commands[3])
            self.assertIn("SQL_GRANT_DDLADMIN=true", commands[3])
            self.assertEqual(json.loads(output.read_text())["result"], "granted")

    def test_failed_grant_does_not_write_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.json"
            with patch.object(module, "install_binary"), \
                 patch.object(module.subprocess, "run", side_effect=module.subprocess.CalledProcessError(1, "azd")):
                with self.assertRaises(module.subprocess.CalledProcessError):
                    module.run("school-sql", CLIENT, [TARGET], b"grant script", str(output))
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
