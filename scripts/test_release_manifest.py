"""Contract tests for the platform toolchain archive manifest.

These tests intentionally use tiny placeholder binaries and grammar files. They
exercise packaging metadata without compiling Crystal or loading tree-sitter.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release_manifest.py")
PLATFORM = "linux-x86_64"
TOOLS = (
    "chiasmus-discover",
    "chiasmus-facts",
    "chiasmus-parity",
    "chiasmus-plan",
    "chiasmus-complete",
)
GRAMMARS = (
    "libtree-sitter-java.so",
    "libtree-sitter-go.so",
    "libtree-sitter-crystal.so",
)
CAPABILITIES = {
    "discover": ["symbols", "relationships"],
    "facts": ["inventory", "source-parity"],
    "parity": ["bundle"],
    "plan": ["plan"],
    "complete": ["completion"],
}
SCHEMA_VERSIONS = {
    "extraction": 1,
    "portdom": 1,
    "report": 1,
    "grammar_abi": 15,
}


class ReleaseManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "chiasmus"
        grammar_dir = self.root / "grammars"
        grammar_dir.mkdir(parents=True)
        for name in TOOLS:
            executable = self.root / name
            executable.write_bytes(f"placeholder:{name}".encode())
            executable.chmod(0o755)
        for name in GRAMMARS:
            (grammar_dir / name).write_bytes(f"grammar:{name}".encode())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_manifest(self, *args: str, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            check=False,
            capture_output=True,
            text=True,
        )
        if succeeds and result.returncode != 0:
            self.fail(f"manifest command failed ({result.returncode}): {result.stderr}")
        if not succeeds and result.returncode == 0:
            self.fail("manifest command unexpectedly succeeded")
        return result

    def create_manifest(self) -> dict:
        result = self.run_manifest(
            "create",
            "--root",
            str(self.root),
            "--platform",
            PLATFORM,
            "--source-commit",
            "a" * 40,
            "--build-id",
            "build-2026-10-15.1",
            "--capabilities-json",
            json.dumps(CAPABILITIES),
            "--schemas-json",
            json.dumps(SCHEMA_VERSIONS),
        )
        return json.loads(result.stdout)

    def test_manifest_records_platform_source_build_capabilities_schemas_and_all_file_hashes(self) -> None:
        manifest = self.create_manifest()

        self.assertEqual(manifest["platform"], PLATFORM)
        self.assertEqual(manifest["source_commit"], "a" * 40)
        self.assertEqual(manifest["build_id"], "build-2026-10-15.1")
        self.assertEqual(manifest["capabilities"], CAPABILITIES)
        self.assertEqual(manifest["schema_versions"], SCHEMA_VERSIONS)

        expected_paths = set(TOOLS) | {f"grammars/{name}" for name in GRAMMARS}
        self.assertEqual(set(manifest["files"]), expected_paths)
        for relative_path in expected_paths:
            expected_hash = hashlib.sha256((self.root / relative_path).read_bytes()).hexdigest()
            self.assertEqual(manifest["files"][relative_path]["sha256"], expected_hash)

        self.run_manifest("verify", "--root", str(self.root), "--platform", PLATFORM)

    def test_verifier_rejects_tampered_file(self) -> None:
        self.create_manifest()
        (self.root / "chiasmus-facts").write_bytes(b"modified after packaging")

        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("checksum", result.stderr.lower())

    @unittest.skipIf(os.name == "nt", "Windows does not preserve Unix executable bits")
    def test_verifier_rejects_non_executable_unix_cli(self) -> None:
        self.create_manifest()
        (self.root / "chiasmus-discover").chmod(0o644)

        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("executable", result.stderr.lower())

    def test_verifier_rejects_empty_build_id(self) -> None:
        manifest = self.create_manifest()
        manifest["build_id"] = ""
        (self.root / "toolchain-manifest.json").write_text(json.dumps(manifest))

        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("build id", result.stderr.lower())

    def test_verifier_rejects_missing_file(self) -> None:
        self.create_manifest()
        (self.root / "grammars" / "libtree-sitter-go.so").unlink()

        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("missing", result.stderr.lower())

    def test_verifier_rejects_wrong_platform(self) -> None:
        self.create_manifest()

        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", "macos-aarch64", succeeds=False
        )
        self.assertIn("platform", result.stderr.lower())

    def test_verifier_checks_declared_capabilities(self) -> None:
        self.create_manifest()

        self.run_manifest(
            "verify",
            "--root",
            str(self.root),
            "--platform",
            PLATFORM,
            "--require-capability",
            "discover.symbols",
        )
        result = self.run_manifest(
            "verify",
            "--root",
            str(self.root),
            "--platform",
            PLATFORM,
            "--require-capability",
            "discover.typed-declarations",
            succeeds=False,
        )
        self.assertIn("capability", result.stderr.lower())

    def test_generator_rejects_archive_missing_a_required_tool_or_grammar(self) -> None:
        (self.root / "chiasmus-plan").unlink()

        result = self.run_manifest(
            "create",
            "--root",
            str(self.root),
            "--platform",
            PLATFORM,
            "--source-commit",
            "a" * 40,
            "--build-id",
            "build-2026-10-15.1",
            "--capabilities-json",
            json.dumps(CAPABILITIES),
            "--schemas-json",
            json.dumps(SCHEMA_VERSIONS),
            succeeds=False,
        )
        self.assertIn("chiasmus-plan", result.stderr)

    def test_windows_manifest_requires_sqlite_runtime_dll(self) -> None:
        for name in TOOLS:
            (self.root / f"{name}.exe").write_bytes(f"placeholder:{name}".encode())
        grammar_dir = self.root / "grammars"
        for name in GRAMMARS:
            (grammar_dir / name.replace(".so", ".dll")).write_bytes(f"grammar:{name}".encode())

        result = self.run_manifest(
            "create", "--root", str(self.root), "--platform", "windows-x86_64",
            "--source-commit", "a" * 40, "--build-id", "windows-build",
            "--capabilities-json", json.dumps(CAPABILITIES),
            "--schemas-json", json.dumps(SCHEMA_VERSIONS), succeeds=False,
        )
        self.assertIn("sqlite3.dll", result.stderr)

    def test_verifier_rejects_unmanifested_files_and_symlinked_files(self) -> None:
        self.create_manifest()
        (self.root / "unexpected.txt").write_text("not covered by the manifest")
        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("unmanifested", result.stderr.lower())

        (self.root / "unexpected.txt").unlink()
        outside = Path(self.temp.name) / "outside"
        outside.write_text("outside archive")
        try:
            os.symlink(outside, self.root / "linked-file")
        except OSError:
            # Windows runners may lack the privilege to create symlinks.
            return
        result = self.run_manifest(
            "verify", "--root", str(self.root), "--platform", PLATFORM, succeeds=False
        )
        self.assertIn("symlink", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
