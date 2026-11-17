import gzip
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "scripts" / "verify-oci-candidate.py"
spec = importlib.util.spec_from_file_location("verify_oci_candidate", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
COMMIT = "a" * 40


def digest(content):
    return hashlib.sha256(content).hexdigest()


def fixture(root, *, bad_diff=False, user="1654", revision=COMMIT, extra=None, duplicate=False, link=False):
    contents = {}

    def descriptor(content, media_type):
        value = digest(content)
        contents["blobs/sha256/" + value] = content
        return {"mediaType": media_type, "digest": "sha256:" + value, "size": len(content)}

    def encoded(value):
        return json.dumps(value, separators=(",", ":")).encode()

    layer_data = b"example test layer"
    layer = descriptor(gzip.compress(layer_data, mtime=0), module.LAYER_TYPE)
    config = descriptor(encoded({
        "os": "linux", "architecture": "amd64",
        "config": {"User": user, "Entrypoint": ["dotnet", "Contoso.Enrollments.Api.dll"],
                   "Labels": {"org.opencontainers.image.revision": revision}},
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + ("0" * 64 if bad_diff else digest(layer_data))]},
    }), module.CONFIG_TYPE)
    manifest = descriptor(encoded({
        "schemaVersion": 2, "mediaType": module.MANIFEST_TYPE, "config": config, "layers": [layer],
    }), module.MANIFEST_TYPE)
    contents["oci-layout"] = encoded({"imageLayoutVersion": "1.0.0"})
    contents["index.json"] = encoded({"schemaVersion": 2, "manifests": [manifest]})
    if extra:
        contents[extra] = b"unreferenced"
    archive_name = f"contoso-enrollments-{COMMIT}.oci.tar"
    archive = root / archive_name
    with tarfile.open(archive, "w") as tar:
        for name, value in contents.items():
            member = tarfile.TarInfo(name)
            member.size = len(value)
            tar.addfile(member, io.BytesIO(value))
        if duplicate:
            member = tarfile.TarInfo("index.json")
            tar.addfile(member, io.BytesIO())
        if link:
            member = tarfile.TarInfo("link")
            member.type = tarfile.SYMTYPE
            member.linkname = "index.json"
            tar.addfile(member)
    (root / "sql").mkdir()
    (root / "sql" / "migrations.sql").write_bytes(b"SELECT 1;\n")
    archive_hash = digest(archive.read_bytes())
    sql_hash = digest((root / "sql" / "migrations.sql").read_bytes())
    files = {archive_name: archive_hash, "sql/migrations.sql": sql_hash}
    metadata = {
        "service": "contoso-enrollments", "sourceCommit": COMMIT, "promotionOwner": "contoso-platform",
        "entrypoint": "dotnet Contoso.Enrollments.Api.dll", "files": files,
        "image": {"format": "oci-archive", "archive": archive_name, "manifestDigest": manifest["digest"],
                  "configDigest": config["digest"], "os": "linux", "architecture": "amd64"},
    }
    (root / "candidate.json").write_text(json.dumps(metadata), encoding="utf-8")
    (root / "SHA256SUMS").write_text(
        "".join(f"{value}  {name}\n" for name, value in sorted(files.items())), encoding="utf-8", newline="\n"
    )
    return archive_hash, sql_hash


class VerifyOciTests(unittest.TestCase):
    def test_valid_candidate_and_separately_approved_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_hash, sql_hash = fixture(root)
            module.verify(root, COMMIT, archive_hash, sql_hash)
            with self.assertRaisesRegex(ValueError, "Checksum list"):
                module.verify(root, COMMIT, archive_hash, "0" * 64)
            (root / "sql" / "migrations.sql").write_bytes(b"ALTER TABLE sensitive;")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                module.verify(root, COMMIT, archive_hash, sql_hash)

    def test_rejects_recomputed_archive_with_bad_diffid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hashes = fixture(root, bad_diff=True)
            with self.assertRaisesRegex(ValueError, "DiffID mismatch"):
                module.verify(root, COMMIT, *hashes)

    def test_rejects_root_and_wrong_source_label(self):
        for options in ({"user": "0:0"}, {"user": "root"}, {"revision": "b" * 40}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                hashes = fixture(root, **options)
                with self.assertRaisesRegex(ValueError, "runtime identity"):
                    module.verify(root, COMMIT, *hashes)

    def test_rejects_unsafe_and_unreferenced_archive_entries(self):
        for extra in ("../escape", "unreferenced"):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                hashes = fixture(root, extra=extra)
                with self.assertRaisesRegex(ValueError, "Unsafe|unreferenced"):
                    module.verify(root, COMMIT, *hashes)

    def test_rejects_duplicate_and_link_entries(self):
        for options in ({"duplicate": True}, {"link": True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                hashes = fixture(root, **options)
                with self.assertRaisesRegex(ValueError, "duplicate|ordinary"):
                    module.verify(root, COMMIT, *hashes)

    def test_rejects_untrusted_metadata_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hashes = fixture(root)
            path = root / "candidate.json"
            metadata = json.loads(path.read_text(encoding="utf-8"))
            metadata["image"]["manifestDigest"] = "sha256:" + "0" * 64
            path.write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "manifest digest"):
                module.verify(root, COMMIT, *hashes)


if __name__ == "__main__":
    unittest.main()
