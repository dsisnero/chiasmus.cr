"""Contract tests for release publication and build submodule selection."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def named_block(text: str, name: str, indent: int) -> str:
    """Return a YAML mapping block using its indentation boundary."""
    lines = text.splitlines()
    start = next(
        (index for index, line in enumerate(lines) if line == " " * indent + name + ":"),
        None,
    )
    if start is None:
        raise AssertionError(f"missing YAML block {name!r} at indent {indent}")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            end = index
            break
    return "\n".join(lines[start:end])


def job_block(text: str, job: str) -> str:
    return named_block(named_block(text, "jobs", 0), job, 2)


def checkout_step(job: str) -> str:
    lines = job.splitlines()
    start = next(
        (index for index, line in enumerate(lines) if "uses: actions/checkout@" in line),
        None,
    )
    if start is None:
        raise AssertionError("job has no actions/checkout step")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"^\s{4}- ", lines[index]):
            end = index
            break
    return "\n".join(lines[start:end])


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.release = (WORKFLOWS / "release.yml").read_text()
        self.ci = (WORKFLOWS / "ci.yml").read_text()

    def test_dispatch_builds_artifacts_without_publishing_and_tags_publish_after_build(self) -> None:
        triggers = named_block(self.release, "on", 0)
        self.assertIn("tags: ['v*']", triggers)
        self.assertIn("workflow_dispatch:", triggers)

        publish = job_block(self.release, "publish")
        permissions = named_block(self.release, "permissions", 0)
        self.assertIn("contents: read", permissions)
        self.assertRegex(publish, r"(?m)^\s+needs:\s*build\s*$")
        self.assertRegex(publish, r"(?m)^\s+if:.*github\.event_name.*push")
        self.assertRegex(publish, r"(?m)^\s+if:.*startsWith\(github\.ref,\s*'refs/tags/v'\)")
        self.assertRegex(publish, r"(?m)^\s+contents:\s*write\s*$")
        self.assertIn("softprops/action-gh-release@", publish)

    def test_release_matrix_uploads_artifacts_for_all_three_platforms(self) -> None:
        build = job_block(self.release, "build")
        for runner in ("ubuntu-latest", "macos-latest", "windows-latest"):
            self.assertIn(f"os: {runner}", build)
        self.assertIn("python scripts/test_release_workflows.py", build)
        self.assertIn("uses: actions/upload-artifact@", build)

    def test_release_workflow_contract_uses_bash_on_all_platforms(self) -> None:
        step = re.search(
            r"(?ms)^    - name: Test release workflow contract\n(.*?)(?=^    - |\Z)",
            self.release,
        )
        self.assertIsNotNone(step, "release workflow contract step is missing")
        self.assertRegex(step.group(1), r"(?m)^      shell: bash$")

    def test_release_and_ci_build_jobs_initialize_grammar_submodules_without_openapi_cr(self) -> None:
        jobs = (
            ("release build", job_block(self.release, "build")),
            ("CI build-clis", job_block(self.ci, "build-clis")),
        )
        for label, job in jobs:
            with self.subTest(job=label):
                checkout = checkout_step(job)
                self.assertRegex(checkout, r"(?m)^\s+submodules:\s*false\s*$")
                self.assertNotRegex(checkout, r"(?i)recursive|vendor/openapi_cr")
                self.assertIn(
                    "bash scripts/init_build_grammars.sh",
                    job,
                    msg=f"{label} must initialize only the build grammars",
                )
                self.assertNotIn("vendor/openapi_cr", job)

    def test_build_submodule_selector_lists_only_pinned_grammars(self) -> None:
        result = subprocess.run(
            ["bash", "scripts/init_build_grammars.sh", "--list"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = result.stdout.splitlines()
        self.assertGreaterEqual(len(paths), 10)
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(all(path.startswith("grammars/tree-sitter-") for path in paths))
        self.assertNotIn("vendor/openapi_cr", paths)

    def test_ci_test_jobs_may_keep_recursive_submodules(self) -> None:
        test_job = job_block(self.ci, "test")
        self.assertIn("submodules: recursive", checkout_step(test_job))

    def test_release_build_installs_swi_prolog_on_unix_platforms(self) -> None:
        self.assertRegex(
            self.release,
            r"(?s)name: Install Linux dependencies.*?sudo apt-get install -y[^\n]*swi-prolog",
        )
        self.assertRegex(
            self.release,
            r"(?s)name: Install macOS dependencies.*?brew install[^\n]*swi-prolog",
        )


if __name__ == "__main__":
    unittest.main()
