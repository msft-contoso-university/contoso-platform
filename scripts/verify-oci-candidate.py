"""Verify an independently approved Enrollments OCI candidate without extraction."""
import argparse
import gzip
import hashlib
import json
import re
import sys
import tarfile
import zlib
from pathlib import Path, PurePosixPath

HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json"
CONFIG_TYPE = "application/vnd.oci.image.config.v1+json"
LAYER_TYPE = "application/vnd.oci.image.layer.v1.tar+gzip"
MAX_ARCHIVE = 2 * 1024**3
MAX_SQL = 64 * 1024**2
MAX_METADATA = 2 * 1024**2
MAX_EXPANDED = 4 * 1024**3


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def sha256(stream, limit):
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            return digest.hexdigest(), total
        total += len(chunk)
        if total > limit:
            raise ValueError("Content exceeds verification size limit.")
        digest.update(chunk)


def regular_file(root, parts, limit):
    path = root
    for part in parts:
        path /= part
        if path.is_symlink():
            raise ValueError("Candidate files must not be links.")
    if not path.is_file() or path.stat().st_size > limit:
        raise ValueError("Candidate file is missing or exceeds its size limit.")
    return path


def read_json(stream):
    content = stream.read(MAX_METADATA + 1)
    if len(content) > MAX_METADATA:
        raise ValueError("OCI metadata exceeds size limit.")
    return json.loads(content, object_pairs_hook=unique_object)


def verify(directory, commit, approved_archive_sha256, approved_sql_sha256):
    if not HEX40.fullmatch(commit) or not all(HEX64.fullmatch(value) for value in (approved_archive_sha256, approved_sql_sha256)):
        raise ValueError("Expected an exact commit and independently approved archive and SQL SHA-256 values.")
    root = Path(directory)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Candidate directory must be an ordinary directory.")
    archive_name = f"contoso-enrollments-{commit}.oci.tar"
    archive_path = regular_file(root, [archive_name], MAX_ARCHIVE)
    sql_path = regular_file(root, ["sql", "migrations.sql"], MAX_SQL)
    manifest_path = regular_file(root, ["candidate.json"], MAX_METADATA)
    sums_path = regular_file(root, ["SHA256SUMS"], 1024)
    expected_files = {archive_name: approved_archive_sha256, "sql/migrations.sql": approved_sql_sha256}
    expected_sums = "".join(f"{digest}  {name}\n" for name, digest in sorted(expected_files.items()))
    if sums_path.read_text(encoding="utf-8") != expected_sums:
        raise ValueError("Checksum list does not match the independently approved files.")
    for path, digest, limit in ((archive_path, approved_archive_sha256, MAX_ARCHIVE), (sql_path, approved_sql_sha256, MAX_SQL)):
        with path.open("rb") as stream:
            actual, _ = sha256(stream, limit)
        if actual != digest:
            raise ValueError(f"Approved checksum mismatch: {path.name}")
    with manifest_path.open("rb") as stream:
        metadata = read_json(stream)
    if (not isinstance(metadata, dict) or metadata.get("service") != "contoso-enrollments"
            or metadata.get("sourceCommit") != commit or metadata.get("promotionOwner") != "contoso-platform"
            or metadata.get("entrypoint") != "dotnet Contoso.Enrollments.Api.dll"
            or metadata.get("files") != expected_files):
        raise ValueError("Candidate metadata does not match approved files and source.")
    image = metadata.get("image")
    if (not isinstance(image, dict) or image.get("format") != "oci-archive" or image.get("archive") != archive_name
            or image.get("os") != "linux" or image.get("architecture") != "amd64"
            or not isinstance(image.get("manifestDigest"), str) or not DIGEST.fullmatch(image["manifestDigest"])
            or not isinstance(image.get("configDigest"), str) or not DIGEST.fullmatch(image["configDigest"])):
        raise ValueError("Invalid OCI image metadata.")

    with tarfile.open(archive_path, "r:") as archive:
        members = {}
        directories = set()
        for member in archive:
            name = member.name
            parts = PurePosixPath(name)
            if (not name or "\\" in name or ":" in name or parts.is_absolute()
                    or any(part in ("", ".", "..") for part in name.split("/"))
                    or str(parts) != name or name in members or name in directories
                    or len(members) + len(directories) >= 1024):
                raise ValueError("Unsafe or duplicate OCI archive entry.")
            if member.isdir():
                if name not in ("blobs", "blobs/sha256"):
                    raise ValueError("Unexpected OCI directory.")
                directories.add(name)
            elif member.isfile():
                members[name] = member
            else:
                raise ValueError("Only ordinary OCI files and directories are allowed.")

        def metadata_file(name):
            member = members.get(name)
            if member is None or member.size > MAX_METADATA:
                raise ValueError("Missing or oversized OCI metadata.")
            with archive.extractfile(member) as stream:
                return read_json(stream)

        referenced = {"oci-layout", "index.json"}

        def blob(descriptor, media_type):
            if not isinstance(descriptor, dict):
                raise ValueError("Invalid OCI descriptor.")
            digest = descriptor.get("digest")
            size = descriptor.get("size")
            if (descriptor.get("mediaType") != media_type or not isinstance(digest, str)
                    or not DIGEST.fullmatch(digest) or type(size) is not int or size < 0):
                raise ValueError("Invalid OCI blob descriptor.")
            name = "blobs/sha256/" + digest[7:]
            member = members.get(name)
            if member is None or member.size != size:
                raise ValueError("Missing OCI blob or descriptor size mismatch.")
            with archive.extractfile(member) as stream:
                actual, _ = sha256(stream, MAX_ARCHIVE)
            if actual != digest[7:]:
                raise ValueError("OCI blob checksum mismatch.")
            referenced.add(name)
            return name

        if metadata_file("oci-layout") != {"imageLayoutVersion": "1.0.0"}:
            raise ValueError("Unsupported OCI layout.")
        index = metadata_file("index.json")
        manifests = index.get("manifests") if isinstance(index, dict) else None
        if not isinstance(index, dict) or index.get("schemaVersion") != 2 or not isinstance(manifests, list) or len(manifests) != 1:
            raise ValueError("Expected one OCI image manifest.")
        if not isinstance(manifests[0], dict) or manifests[0].get("digest") != image["manifestDigest"]:
            raise ValueError("OCI manifest digest does not match candidate metadata.")
        manifest = metadata_file(blob(manifests[0], MANIFEST_TYPE))
        if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 2 or manifest.get("mediaType") != MANIFEST_TYPE:
            raise ValueError("Invalid OCI image manifest.")
        config_descriptor = manifest.get("config")
        if not isinstance(config_descriptor, dict) or config_descriptor.get("digest") != image["configDigest"]:
            raise ValueError("OCI config digest does not match candidate metadata.")
        config = metadata_file(blob(config_descriptor, CONFIG_TYPE))
        settings = config.get("config") if isinstance(config, dict) else None
        if not isinstance(settings, dict) or config.get("os") != "linux" or config.get("architecture") != "amd64":
            raise ValueError("OCI config is not Linux AMD64.")
        user = settings.get("User")
        labels = settings.get("Labels")
        if (not isinstance(user, str) or not user or user.split(":")[0] == "root"
                or (user.split(":")[0].isdecimal() and int(user.split(":")[0]) == 0)
                or not isinstance(labels, dict) or labels.get("org.opencontainers.image.revision") != commit
                or settings.get("Entrypoint") != ["dotnet", "Contoso.Enrollments.Api.dll"]):
            raise ValueError("OCI runtime identity, entrypoint or source label is invalid.")
        layers = manifest.get("layers")
        rootfs = config.get("rootfs")
        diff_ids = rootfs.get("diff_ids") if isinstance(rootfs, dict) else None
        if (not isinstance(layers, list) or not layers or not isinstance(diff_ids, list)
                or rootfs.get("type") != "layers" or len(layers) != len(diff_ids)):
            raise ValueError("OCI root filesystem is invalid.")
        expanded = 0
        for layer, diff_id in zip(layers, diff_ids):
            if not isinstance(diff_id, str) or not DIGEST.fullmatch(diff_id):
                raise ValueError("Invalid OCI layer DiffID.")
            name = blob(layer, LAYER_TYPE)
            with archive.extractfile(members[name]) as compressed, gzip.GzipFile(fileobj=compressed) as stream:
                actual, size = sha256(stream, MAX_EXPANDED - expanded)
            expanded += size
            if actual != diff_id[7:]:
                raise ValueError("OCI layer DiffID mismatch.")
        if set(members) != referenced:
            raise ValueError("OCI archive contains unreferenced files.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--approved-archive-sha256", required=True)
    parser.add_argument("--approved-sql-sha256", required=True)
    args = parser.parse_args()
    try:
        verify(args.artifact_dir, args.source_commit, args.approved_archive_sha256, args.approved_sql_sha256)
    except (OSError, EOFError, ValueError, KeyError, TypeError, tarfile.TarError, zlib.error) as error:
        print(f"OCI candidate verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified Enrollments candidate for source {args.source_commit}; no deployment performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
