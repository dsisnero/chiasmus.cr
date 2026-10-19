#!/usr/bin/env python3
"""Create and verify a self-contained Chiasmus toolchain archive manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys


MANIFEST_NAME = "toolchain-manifest.json"
MANIFEST_VERSION = 1
REQUIRED_TOOLS = (
    "chiasmus-discover",
    "chiasmus-facts",
    "chiasmus-parity",
    "chiasmus-plan",
    "chiasmus-complete",
)
REQUIRED_GRAMMARS = ("java", "go", "crystal")
EXTENSIONS = {"linux": "so", "darwin": "dylib", "macos": "dylib", "windows": "dll"}


class ManifestError(Exception):
    pass


def platform_parts(platform: str) -> tuple[str, str, str]:
    match = re.fullmatch(r"(linux|darwin|macos|windows)-(x86_64|aarch64)", platform)
    if not match:
        raise ManifestError(f"unsupported platform: {platform}")
    system, _architecture = match.groups()
    return system, ".exe" if system == "windows" else "", EXTENSIONS[system]


def archive_files(root: Path) -> dict[str, Path]:
    if not root.is_dir() or root.is_symlink():
        raise ManifestError(f"archive root is missing or a symlink: {root}")
    files = {}
    for current, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(current) / name
            if path.is_symlink():
                raise ManifestError(f"symlink in archive: {path.relative_to(root)}")
        for name in names:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            if relative != MANIFEST_NAME:
                files[relative] = path
    return files


def required_paths(platform: str) -> set[str]:
    system, executable, grammar = platform_parts(platform)
    required = {f"{name}{executable}" for name in REQUIRED_TOOLS} | {
        f"grammars/libtree-sitter-{language}.{grammar}"
        for language in REQUIRED_GRAMMARS
    }
    if system == "windows":
        required.add("sqlite3.dll")
    return required


def check_required(files: dict[str, Path], platform: str) -> None:
    missing = required_paths(platform) - files.keys()
    if missing:
        raise ManifestError("missing required archive file: " + ", ".join(sorted(missing)))
    system, executable, _grammar = platform_parts(platform)
    # Windows does not preserve POSIX execute bits when inspecting a Unix
    # fixture; native Unix archive verification checks the actual file mode.
    if system != "windows" and os.name != "nt":
        for name in REQUIRED_TOOLS:
            path = files[f"{name}{executable}"]
            if not path.stat().st_mode & 0o111:
                raise ManifestError(f"Unix CLI is not executable: {name}")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def parse_object(raw: str, label: str) -> dict:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ManifestError(f"invalid {label} JSON: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must be a JSON object")
    return value


def create(args: argparse.Namespace) -> None:
    root = Path(args.root)
    files = archive_files(root)
    check_required(files, args.platform)
    if not re.fullmatch(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?", args.source_commit):
        raise ManifestError("source commit must be a full hexadecimal Git commit ID")
    if not args.build_id.strip():
        raise ManifestError("build ID must not be empty")
    capabilities = parse_object(args.capabilities_json, "capabilities")
    schemas = parse_object(args.schemas_json, "schemas")
    if not all(
        isinstance(names, list) and all(isinstance(name, str) for name in names)
        for names in capabilities.values()
    ):
        raise ManifestError("capabilities must map tools to string arrays")
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "platform": args.platform,
        "source_commit": args.source_commit.lower(),
        "build_id": args.build_id,
        "capabilities": capabilities,
        "schema_versions": schemas,
        "files": {
            name: {"sha256": digest(path), "size": path.stat().st_size}
            for name, path in sorted(files.items())
        },
    }
    output = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    temporary = root / (MANIFEST_NAME + ".tmp")
    temporary.write_text(output, encoding="utf-8")
    temporary.replace(root / MANIFEST_NAME)
    sys.stdout.write(output)


def verify(args: argparse.Namespace) -> None:
    root = Path(args.root)
    manifest_path = root / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ManifestError(f"missing or symlinked manifest: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"invalid manifest: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("manifest_version") != MANIFEST_VERSION:
        raise ManifestError("unsupported manifest version")
    if manifest.get("platform") != args.platform:
        raise ManifestError(f"platform mismatch: expected {args.platform}, got {manifest.get('platform')}")
    build_id = manifest.get("build_id")
    if not isinstance(build_id, str) or not build_id.strip():
        raise ManifestError("build ID must not be empty")
    actual = archive_files(root)
    check_required(actual, args.platform)
    entries = manifest.get("files")
    if not isinstance(entries, dict):
        raise ManifestError("manifest files must be an object")
    for name in entries:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or name != path.as_posix():
            raise ManifestError(f"invalid manifest path: {name}")
    missing = entries.keys() - actual.keys()
    unmanifested = actual.keys() - entries.keys()
    if missing:
        raise ManifestError("missing archive file: " + ", ".join(sorted(missing)))
    if unmanifested:
        raise ManifestError("unmanifested archive file: " + ", ".join(sorted(unmanifested)))
    for name, path in actual.items():
        record = entries[name]
        if not isinstance(record, dict) or record.get("sha256") != digest(path):
            raise ManifestError(f"checksum mismatch: {name}")
        if record.get("size") != path.stat().st_size:
            raise ManifestError(f"size mismatch: {name}")
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, dict):
        raise ManifestError("capabilities must be an object")
    for capability in args.require_capability:
        tool, separator, name = capability.partition(".")
        if not separator or name not in capabilities.get(tool, []):
            raise ManifestError(f"missing capability: {capability}")
    print(f"Verified {args.platform} toolchain ({manifest['build_id']})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create_parser = commands.add_parser("create")
    create_parser.add_argument("--root", required=True)
    create_parser.add_argument("--platform", required=True)
    create_parser.add_argument("--source-commit", required=True)
    create_parser.add_argument("--build-id", required=True)
    create_parser.add_argument("--capabilities-json", required=True)
    create_parser.add_argument("--schemas-json", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--root", required=True)
    verify_parser.add_argument("--platform", required=True)
    verify_parser.add_argument("--require-capability", action="append", default=[])
    args = parser.parse_args()
    try:
        if args.command == "create":
            create(args)
        else:
            verify(args)
    except (ManifestError, OSError) as error:
        print(f"release manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
