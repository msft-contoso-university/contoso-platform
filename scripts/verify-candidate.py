"""Verify an independently approved App Service candidate without extracting it."""
import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

ENTRYPOINTS = {
    "contoso-web": "dotnet Contoso.Web.dll",
    "contoso-students": "dotnet Contoso.Students.Api.dll",
    "contoso-academics": "dotnet Contoso.Academics.dll",
}
REQUIRED_FILES = {
    "contoso-web": {"Contoso.Web.dll"},
    "contoso-students": {"Contoso.Students.Api.dll", "seed-students.sql"},
    "contoso-academics": {"Contoso.Academics.dll", "sql/academics.sql"},
}
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
MAX_FILES = 10000
MAX_TOTAL = 512 * 1024 * 1024
MAX_MANIFEST = 1024 * 1024


def valid_name(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name or name.startswith("/"):
        return False
    parts = name.split("/")
    return all(part not in ("", ".", "..") for part in parts) and str(PurePosixPath(name)) == name


def digest_stream(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate manifest key: {key}")
        result[key] = value
    return result


def verify(directory, service, commit, approved_digest):
    if service not in ENTRYPOINTS or not HEX40.fullmatch(commit) or not HEX64.fullmatch(approved_digest):
        raise ValueError("Expected an allowlisted service, exact source commit and approved SHA-256.")
    root = Path(directory)
    name = f"{service}-{commit}.zip"
    package = root / name
    if any(path.is_symlink() or not path.is_file() for path in (package, root / "SHA256SUMS", root / "candidate.json")):
        raise ValueError("Candidate artifact must contain regular files, not links.")
    if (root / "SHA256SUMS").read_text(encoding="utf-8").strip() != f"{approved_digest}  {name}":
        raise ValueError("Checksum file does not match the independently approved package.")
    with package.open("rb") as stream:
        if digest_stream(stream) != approved_digest:
            raise ValueError("Package SHA-256 does not match the approved digest.")
    manifest_path = root / "candidate.json"
    if manifest_path.stat().st_size > MAX_MANIFEST:
        raise ValueError("Candidate manifest exceeds size limit.")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes, object_pairs_hook=unique_object)
    if not isinstance(manifest, dict) or manifest.get("service") != service or manifest.get("sourceCommit") != commit:
        raise ValueError("Candidate provenance does not match the approved source.")
    if (manifest.get("runtime") != "net10.0" or manifest.get("frameworkDependent") is not True
            or manifest.get("entrypoint") != ENTRYPOINTS[service] or manifest.get("promotionOwner") != "contoso-platform"):
        raise ValueError("Candidate runtime or promotion metadata is invalid.")
    files = manifest.get("files")
    if (not isinstance(files, dict) or not REQUIRED_FILES[service].issubset(files)
            or "candidate.json" in files
            or any(not valid_name(path) or not isinstance(digest, str) or not HEX64.fullmatch(digest)
                   for path, digest in files.items())):
        raise ValueError("Candidate file manifest is invalid.")
    with zipfile.ZipFile(package) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if (len(entries) > MAX_FILES or sum(entry.file_size for entry in entries) > MAX_TOTAL
                or len({name.casefold() for name in names}) != len(names)
                or set(names) != set(files) | {"candidate.json"}
                or any(not valid_name(entry.filename) or entry.is_dir()
                       or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG) for entry in entries)):
            raise ValueError("Package contents are unsafe or differ from the manifest.")
        if archive.getinfo("candidate.json").file_size > MAX_MANIFEST or archive.read("candidate.json") != manifest_bytes:
            raise ValueError("Embedded and external candidate manifests differ.")
        for name, expected in files.items():
            with archive.open(name) as stream:
                if digest_stream(stream) != expected:
                    raise ValueError(f"Package file checksum mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--service", required=True, choices=ENTRYPOINTS)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--approved-sha256", required=True)
    args = parser.parse_args()
    try:
        verify(args.artifact_dir, args.service, args.source_commit, args.approved_sha256)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"Candidate verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified {args.service} candidate for source {args.source_commit}; no deployment performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
