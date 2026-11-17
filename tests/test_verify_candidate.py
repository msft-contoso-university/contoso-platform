import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "scripts" / "verify-candidate.py"
spec = importlib.util.spec_from_file_location("verify_candidate", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
COMMIT = "a" * 40
SERVICE = "contoso-students"


def create_candidate(root, *, content=b"assembly", file_digest=None, extra_name=None, external=None):
    files = {
        "Contoso.Students.Api.dll": hashlib.sha256(content).hexdigest(),
        "seed-students.sql": hashlib.sha256(b"seed").hexdigest(),
    }
    if file_digest:
        files["Contoso.Students.Api.dll"] = file_digest
    manifest = {
        "service": SERVICE, "sourceCommit": COMMIT, "runtime": "net10.0",
        "frameworkDependent": True, "entrypoint": "dotnet Contoso.Students.Api.dll",
        "promotionOwner": "contoso-platform", "files": files,
    }
    manifest_bytes = json.dumps(manifest).encode()
    (root / "candidate.json").write_bytes(external or manifest_bytes)
    name = f"{SERVICE}-{COMMIT}.zip"
    with zipfile.ZipFile(root / name, "w") as archive:
        archive.writestr("Contoso.Students.Api.dll", content)
        archive.writestr("seed-students.sql", b"seed")
        archive.writestr("candidate.json", manifest_bytes)
        if extra_name:
            archive.writestr(extra_name, b"unexpected")
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    (root / "SHA256SUMS").write_text(f"{digest}  {name}\n")
    return digest


class CandidateVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_valid_candidate(self):
        digest = create_candidate(self.root)
        module.verify(self.root, SERVICE, COMMIT, digest)

    def test_requires_independently_approved_digest(self):
        create_candidate(self.root)
        with self.assertRaisesRegex(ValueError, "approved package"):
            module.verify(self.root, SERVICE, COMMIT, "b" * 64)

    def test_rejects_mismatched_file_hash_and_embedded_manifest(self):
        digest = create_candidate(self.root, file_digest="b" * 64)
        with self.assertRaisesRegex(ValueError, "file checksum mismatch"):
            module.verify(self.root, SERVICE, COMMIT, digest)
        digest = create_candidate(self.root, external=b'{"service":"different"}')
        with self.assertRaisesRegex(ValueError, "provenance"):
            module.verify(self.root, SERVICE, COMMIT, digest)
        digest = create_candidate(self.root)
        manifest_path = self.root / "candidate.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["extra"] = "different"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "Embedded and external"):
            module.verify(self.root, SERVICE, COMMIT, digest)

    def test_rejects_unexpected_and_unsafe_archive_paths(self):
        digest = create_candidate(self.root, extra_name="../outside")
        with self.assertRaisesRegex(ValueError, "unsafe"):
            module.verify(self.root, SERVICE, COMMIT, digest)

    def test_rejects_mutable_source_identifiers(self):
        digest = create_candidate(self.root)
        with self.assertRaisesRegex(ValueError, "exact source"):
            module.verify(self.root, SERVICE, "main", digest)


if __name__ == "__main__":
    unittest.main()
