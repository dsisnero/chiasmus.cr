#!/usr/bin/env python3
"""Exercise an unpacked Chiasmus release as a complete parity toolchain."""

from __future__ import annotations

import argparse
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


def run(command: list[str], env: dict[str, str], output: Path | None = None) -> str:
    result = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{' '.join(command)} failed ({result.returncode}): {result.stderr}")
    if output:
        output.write_text(result.stdout, encoding="utf-8")
    return result.stdout


def smoke(root: Path, platform: str) -> None:
    executable = ".exe" if platform.startswith("windows-") else ""
    tool = lambda name: str(root / f"chiasmus-{name}{executable}")
    environment = os.environ.copy()
    environment["CHIASMUS_GRAMMAR_DIR"] = str(root / "grammars")
    for name in ("discover", "facts", "parity", "plan", "complete"):
        run([tool(name), "--help"], environment)
    with tempfile.TemporaryDirectory(prefix="chiasmus-release-smoke-") as temporary:
        scratch = Path(temporary)
        target = scratch / "crystal"
        target.mkdir()
        (target / "widget.cr").write_text(CRYSTAL, encoding="utf-8")
        for language, (filename, content) in SOURCES.items():
            source = scratch / language
            source.mkdir()
            (source / filename).write_text(content, encoding="utf-8")
            discovered = run(
                [tool("discover"), "--language", language, "--dir", str(source), "--parser", "tree-sitter"],
                environment,
            )
            if "Widget" not in discovered:
                raise RuntimeError(f"{language} tree-sitter discovery found no Widget")
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
                     "--declarations-out", str(declarations)],
                    environment,
                    facts,
                )
                if not facts.stat().st_size or not declarations.stat().st_size:
                    raise RuntimeError(f"{lang} facts or typed declarations are empty")
            run(
                [tool("parity"), "--source-facts", str(source_facts),
                 "--crystal-facts", str(target_facts),
                 "--source-declarations", str(source_declarations),
                 "--target-declarations", str(target_declarations),
                 "--bundle-dir", str(report)],
                environment,
            )
            for name in ("maps.tsv", "surfaces.tsv", "maps.pl", "port-concepts.jsonl"):
                if not (report / name).is_file():
                    raise RuntimeError(f"{language} reconciliation did not write {name}")
            print(success_message(language))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--platform", required=True)
    arguments = parser.parse_args()
    try:
        smoke(arguments.root, arguments.platform)
    except (OSError, RuntimeError) as error:
        print(f"release smoke: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
