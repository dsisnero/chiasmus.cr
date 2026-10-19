#!/usr/bin/env python3
"""Exercise an unpacked Chiasmus release as a complete parity toolchain."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


SOURCES = {
    "java": ("Widget.java", "class Widget { int size() { return 1; } }\n"),
    "go": ("widget.go", "package sample\ntype Widget struct{}\nfunc (w Widget) Size() int { return 1 }\n"),
}
CRYSTAL = "class Widget\n  def size : Int32\n    1\n  end\nend\n"


def success_message(language: str) -> str:
    return f"{language} - Crystal release smoke passed"


def run(command: list[str], env: dict[str, str], cwd: Path,
        output: Path | None = None, expected_code: int = 0) -> str:
    result = subprocess.run(command, env=env, cwd=cwd, capture_output=True, text=True, check=False, timeout=180)
    if result.returncode != expected_code:
        raise RuntimeError(f"{' '.join(command)} failed ({result.returncode}): {result.stderr}")
    if output:
        output.write_text(result.stdout, encoding="utf-8")
    return result.stdout


def isolated_environment(root: Path, scratch: Path) -> dict[str, str]:
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("CHIASMUS_", "XDG_"))}
    for key, name in (("HOME", "home"), ("USERPROFILE", "home"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                      ("XDG_RUNTIME_DIR", "runtime"), ("APPDATA", "config"),
                      ("LOCALAPPDATA", "cache"), ("TMPDIR", "tmp"),
                      ("TMP", "tmp"), ("TEMP", "tmp")):
        directory = scratch / name
        directory.mkdir(mode=0o700, exist_ok=True)
        environment[key] = str(directory)
    environment["XDG_CONFIG_DIRS"] = environment["XDG_CONFIG_HOME"]
    environment["XDG_DATA_DIRS"] = environment["XDG_DATA_HOME"]
    environment["CHIASMUS_GRAMMAR_DIR"] = str(root / "grammars")
    return environment


def check_discovery(text: str, expected: set[str]) -> None:
    rows = [line.split("\t") for line in text.splitlines()
            if line.strip() and not line.startswith("#")]
    if not rows or any(len(row) != 5 or row[4] != "parser=tree-sitter" for row in rows):
        raise RuntimeError("discovery lacks tree-sitter provenance")
    names = {row[0].rsplit("::", 1)[-1] for row in rows}
    if not expected <= names:
        raise RuntimeError(f"discovery missing expected symbols: {expected - names}")


def check_declarations(path: Path, expected: set[str]) -> None:
    declarations = [declaration for line in path.read_text(encoding="utf-8").splitlines()
                    if line.strip() for declaration in json.loads(line)["declarations"]]
    if not declarations or any(item.get("extraction_method") != "tree_sitter_ast"
                               for item in declarations):
        raise RuntimeError(f"{path.name} lacks tree-sitter provenance")
    if not expected <= {item["name"] for item in declarations}:
        raise RuntimeError(f"{path.name} missing expected declarations")


def report_rows(path: Path) -> list[dict[str, str]]:
    content = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines()
                        if line.strip() and not line.startswith("#"))
    return list(csv.DictReader(io.StringIO(content), delimiter="\t"))


def check_reports(report: Path, language: str) -> None:
    mappings = report_rows(report / "maps.tsv")
    surfaces = report_rows(report / "surfaces.tsv")
    method = "Size" if language == "go" else "size"
    for source_name, target_name in (("Widget", "Widget"), (f"Widget.{method}", "Widget.size")):
        matches = [row for row in mappings if row.get("source_name") == source_name
                   and row.get("target_name") == target_name and row.get("status") == "matched"
                   and row.get("source_id") not in (None, "", "-")
                   and row.get("target_id") not in (None, "", "-")]
        if len(matches) != 1:
            raise RuntimeError(f"{language} missing matched mapping {source_name} -> {target_name}")
        if source_name != "Widget":
            mapping = matches[0]
            if not any(row.get("source_id") == mapping["source_id"]
                       and row.get("target_id") == mapping["target_id"]
                       and row.get("status") == "surface_match"
                       and row.get("source_arity") == row.get("target_arity") == "0"
                       for row in surfaces):
                # Return type names differ without conversion rules (int vs Int32).
                raise RuntimeError(f"{language} missing zero-arity surface match for {source_name}")
    for name in ("maps.pl", "port-concepts.jsonl"):
        if not (report / name).read_text(encoding="utf-8").strip():
            raise RuntimeError(f"{language} reconciliation wrote empty {name}")


def check_planning(tool, environment: dict[str, str], scratch: Path) -> None:
    fixture = scratch / "planning"
    fixture.mkdir()
    source_id = "src/api.ts::function::smoke"
    facts = fixture / "source.pl"
    facts.write_text("defines('src/api.ts', smoke, function, 1, 0).\nentry_point(smoke).\n",
                     encoding="utf-8")
    inventory = fixture / "inventory.tsv"
    parity = fixture / "parity.tsv"
    for complete in (False, True):
        status = "ported" if complete else "missing"
        inventory.write_text(
            "# source_id\tkind\tstatus\tcrystal_refs\ttarget_symbol\ttest_refs\tnotes\n"
            f"{source_id}\tfunction\t{status}\tsrc/api.cr:1\tsmoke\tspec/api_spec.cr:1\t-\n",
            encoding="utf-8",
        )
        parity.write_text(
            "# parser_mode=fixture\n"
            "# source_id\tkind\tinventory_status\tmatch_status\tconfidence\tcrystal_name\t"
            "crystal_kind\tcrystal_path\tbasis\tstructural_status\tstructural_details\tnotes\n"
            f"{source_id}\tfunction\t{status}\tmatched\t100\tsmoke\tfunction\t"
            "src/api.cr\texplicit\tstructural_match\t-\t-\n", encoding="utf-8",
        )
        ranked = json.loads(run(
            [tool("plan"), "rank", "--facts", str(facts), "--inventory", str(inventory),
             "--parity-report", str(parity), "--format", "json"], environment, scratch))
        if not any(row.get("name") == "smoke" and row.get("file") == "src/api.ts"
                   for row in ranked.get("reports", [])):
            raise RuntimeError("plan rank omitted fixture symbol")
        command = [tool("complete"), "--inventory", str(inventory), "--source-facts", str(facts),
                   "--parity-report", str(parity), "--root", str(fixture)]
        result = run(command, environment, scratch, expected_code=0 if complete else 2)
        expected = {"status": "complete" if complete else "incomplete",
                    "complete_count": str(int(complete)), "incomplete_count": str(int(not complete))}
        if dict(line.split("\t") for line in result.splitlines() if line.strip()) != expected:
            raise RuntimeError("complete returned incorrect status/counts")
        for query in ("complete", "incomplete"):
            result = run(command + ["--query", query, "--format", "ids"], environment, scratch)
            wanted = [source_id] if (query == "complete") == complete else []
            if result.splitlines() != wanted:
                raise RuntimeError(f"complete --query {query} returned incorrect IDs")


def smoke(root: Path, platform: str) -> None:
    root = root.resolve()
    executable = ".exe" if platform.startswith("windows-") else ""
    tool = lambda name: str(root / f"chiasmus-{name}{executable}")
    with tempfile.TemporaryDirectory(prefix="chiasmus-release-smoke-") as temporary:
        scratch = Path(temporary).resolve()
        environment = isolated_environment(root, scratch)
        help_output = {name: run([tool(name), "--help"], environment, scratch)
                       for name in ("discover", "facts", "parity", "plan", "complete")}
        parity_cache_args = (["--cache-dir", str(scratch / "cache" / "extraction")]
                             if "--cache-dir" in help_output["parity"] else [])
        check_planning(tool, environment, scratch)
        target = scratch / "crystal"
        target.mkdir()
        (target / "widget.cr").write_text(CRYSTAL, encoding="utf-8")
        for language, (filename, content) in SOURCES.items():
            source = scratch / language
            source.mkdir()
            (source / filename).write_text(content, encoding="utf-8")
            discovered = run(
                [tool("discover"), "--language", language, "--dir", str(source), "--parser", "tree-sitter",
                 "--cache-dir", str(scratch / "cache" / "extraction")],
                environment, scratch,
            )
            method = "Size" if language == "go" else "size"
            check_discovery(discovered, {"Widget", f"Widget.{method}"})
            report = scratch / f"{language}-report"
            report.mkdir()
            source_facts = report / "source.pl"
            target_facts = report / "target.pl"
            source_declarations = report / "source.jsonl"
            target_declarations = report / "target.jsonl"
            for lang, directory, facts, declarations in (
                (language, source, source_facts, source_declarations),
                ("crystal", target, target_facts, target_declarations),
            ):
                run(
                    [tool("facts"), "--language", lang, "--dir", str(directory),
                     "--declarations-out", str(declarations),
                     "--cache-dir", str(scratch / "cache" / "extraction")],
                    environment, scratch,
                    facts,
                )
                if not facts.stat().st_size or not declarations.stat().st_size:
                    raise RuntimeError(f"{lang} facts or typed declarations are empty")
                check_declarations(declarations, {"Widget", "size" if lang == "crystal" else method})
            run(
                [tool("parity"), "--source-facts", str(source_facts),
                 "--crystal-facts", str(target_facts),
                 "--source-declarations", str(source_declarations),
                 "--target-declarations", str(target_declarations),
                 "--bundle-dir", str(report)] + parity_cache_args,
                environment, scratch,
            )
            check_reports(report, language)
            print(success_message(language))

        rust = scratch / "rust"
        rust.mkdir()
        rust_source = "\n".join(
            f"pub fn f_{index}(x: usize) -> usize {{ x + {index} }}"
            for index in range(10_000)
        )
        (rust / "large.rs").write_text(rust_source, encoding="utf-8")
        discovered = run(
            [tool("discover"), "--language", "rust", "--dir", str(rust), "--parser", "tree-sitter"],
            environment, scratch,
        )
        check_discovery(discovered, {"f_0", "f_9999"})
        print("rust release smoke passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--platform", required=True)
    arguments = parser.parse_args()
    try:
        smoke(arguments.root, arguments.platform)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"release smoke: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
