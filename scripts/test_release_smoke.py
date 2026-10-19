import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts import release_smoke


class ReleaseSmokeOutputTests(unittest.TestCase):
    def test_success_message_is_ascii_for_legacy_console_encodings(self):
        self.assertTrue(release_smoke.success_message("java").isascii())


class ReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.scratch = Path(self.temporary.name).resolve()

    def write_reports(self, language="java"):
        method = "Size" if language == "go" else "size"
        (self.scratch / "maps.tsv").write_text(
            "# total=2 matched=2\n"
            "source_id\tsource_name\ttarget_id\ttarget_name\tstatus\n"
            "class-id\tWidget\ttarget-class\tWidget\tmatched\n"
            f"method-id\tWidget.{method}\ttarget-method\tWidget.size\tmatched\n",
            encoding="utf-8",
        )
        (self.scratch / "surfaces.tsv").write_text(
            "source_id\ttarget_id\tstatus\tsource_arity\ttarget_arity\treturn_match\n"
            "method-id\ttarget-method\tsurface_match\t0\t0\tfalse\n", encoding="utf-8",
        )
        (self.scratch / "maps.pl").write_text("maps_to('method-id', 'target-method').\n")
        (self.scratch / "port-concepts.jsonl").write_text('{"concept": "size"}\n')

    def test_discovery_requires_provenance_on_every_row(self):
        good = "widget.java::class::Widget\tclass\tported\t-\tparser=tree-sitter\n"
        release_smoke.check_discovery(good, {"Widget"})
        for bad in ("", "# Widget parser=tree-sitter\n", good.replace("tree-sitter", "regex"),
                    good.replace("parser=tree-sitter", ""),
                    good + "other::function::size\tfunction\tported\t-\tparser=regex\n",
                    good.replace("::Widget", "::OtherWidget")):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                release_smoke.check_discovery(bad, {"Widget"})

    def test_declarations_require_ast_provenance_and_expected_names(self):
        path = self.scratch / "declarations.jsonl"
        good = [{"name": name, "extraction_method": "tree_sitter_ast"}
                for name in ("Widget", "size")]
        path.write_text(json.dumps({"declarations": good}) + "\n")
        release_smoke.check_declarations(path, {"Widget", "size"})
        for declarations in ([], good[:1],
                             [good[0], {"name": "size", "extraction_method": "regex"}]):
            path.write_text(json.dumps({"declarations": declarations}) + "\n")
            with self.subTest(declarations=declarations), self.assertRaises(RuntimeError):
                release_smoke.check_declarations(path, {"Widget", "size"})

    def test_reports_allow_unmapped_return_type_names(self):
        for language in ("java", "go"):
            self.write_reports(language)
            release_smoke.check_reports(self.scratch, language)

    def test_reports_reject_empty_header_only_or_incorrect_mappings(self):
        for mutation in (lambda text: "", lambda text: text.splitlines()[1] + "\n",
                         lambda text: text.replace("Widget.size", "Widget.wrong"),
                         lambda text: text.replace("matched", "unmapped_source"),
                         lambda text: text.replace("class-id\tWidget", "class-id\tOther"),
                         lambda text: text.replace("target-method", "-")):
            self.write_reports()
            path = self.scratch / "maps.tsv"
            path.write_text(mutation(path.read_text()))
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                release_smoke.check_reports(self.scratch, "java")

    def test_reports_reject_empty_wrong_or_unrelated_surfaces(self):
        for mutation in (lambda text: "", lambda text: text.splitlines()[0] + "\n",
                         lambda text: text.replace("surface_match", "surface_mismatch"),
                         lambda text: text.replace("method-id", "another-id"),
                         lambda text: text.replace("target-method", "another-target"),
                         lambda text: text.replace("\t0\t0\t", "\t1\t1\t")):
            self.write_reports()
            path = self.scratch / "surfaces.tsv"
            path.write_text(mutation(path.read_text()))
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                release_smoke.check_reports(self.scratch, "java")

    def test_reports_reject_empty_auxiliary_artifacts(self):
        for name in ("maps.pl", "port-concepts.jsonl"):
            self.write_reports()
            (self.scratch / name).write_text("")
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                release_smoke.check_reports(self.scratch, "java")

    def test_environment_removes_external_overrides_and_isolates_storage(self):
        inherited = {"PATH": "/bin", "HOME": "/outside", "XDG_CONFIG_DIRS": "/outside",
                     "CHIASMUS_GRAMMAR_DIR": "/outside", "CHIASMUS_HOME": "/outside",
                     "CHIASMUS_CACHE_DIR": "/outside", "CHIASMUS_FACTS_CACHE_DIR": "/outside",
                     "CHIASMUS_FACTS_REPO_KEY": "outside", "CHIASMUS_FUTURE_OVERRIDE": "outside"}
        root = self.scratch / "package"
        with patch.dict(os.environ, inherited, clear=True):
            environment = release_smoke.isolated_environment(root, self.scratch)
            self.assertEqual(dict(os.environ), inherited)
        self.assertEqual(environment["PATH"], "/bin")
        self.assertEqual({key for key in environment if key.startswith("CHIASMUS_")},
                         {"CHIASMUS_GRAMMAR_DIR"})
        self.assertEqual(environment["CHIASMUS_GRAMMAR_DIR"], str(root / "grammars"))
        for key in ("HOME", "USERPROFILE", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                    "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_DIRS", "XDG_DATA_DIRS",
                    "APPDATA", "LOCALAPPDATA", "TMPDIR", "TMP", "TEMP"):
            with self.subTest(key=key):
                self.assertTrue(Path(environment[key]).is_relative_to(self.scratch))
                self.assertTrue(Path(environment[key]).is_dir())

    def test_run_passes_cwd_and_checks_exact_expected_exit_status(self):
        result = subprocess.CompletedProcess(["tool"], 2, "status\tincomplete\n", "")
        with patch.object(release_smoke.subprocess, "run", return_value=result) as child:
            self.assertEqual(release_smoke.run(["tool"], {}, self.scratch, expected_code=2),
                             result.stdout)
            self.assertEqual(child.call_args.kwargs["cwd"], self.scratch)
            with self.assertRaises(RuntimeError):
                release_smoke.run(["tool"], {}, self.scratch)
            result.returncode = 0
            with self.assertRaises(RuntimeError):
                release_smoke.run(["tool"], {}, self.scratch, expected_code=2)

    def test_relative_package_root_is_absolute_and_help_is_isolated(self):
        calls = []

        def stop_after_help(command, environment, cwd, **kwargs):
            calls.append((command, environment, cwd))
            if len(calls) == 5:
                raise RuntimeError("stop after help")
            return "help"

        root = Path("relative-package")
        with patch.object(release_smoke, "run", side_effect=stop_after_help):
            with self.assertRaisesRegex(RuntimeError, "stop after help"):
                release_smoke.smoke(root, "windows-x86_64")
        for command, environment, cwd in calls:
            self.assertEqual(Path(command[0]).parent, root.resolve())
            self.assertTrue(command[0].endswith(".exe"))
            self.assertTrue(cwd.is_absolute())
            self.assertNotEqual(cwd, Path.cwd())
            self.assertTrue(Path(environment["HOME"]).is_relative_to(cwd))

    def planning_child(self, command, environment, cwd, **kwargs):
        self.assertEqual(cwd, self.scratch)
        if "rank" in command:
            return json.dumps({"reports": [{"name": "smoke", "file": "src/api.ts"}]})
        inventory = Path(command[command.index("--inventory") + 1]).read_text()
        complete = "\tported\t" in inventory
        if "--query" in command:
            query = command[command.index("--query") + 1]
            return "src/api.ts::function::smoke\n" if (query == "complete") == complete else ""
        self.assertEqual(kwargs["expected_code"], 0 if complete else 2)
        return (f"status\t{'complete' if complete else 'incomplete'}\n"
                f"complete_count\t{int(complete)}\nincomplete_count\t{int(not complete)}\n")

    def test_planning_checks_both_complete_and_incomplete_fixtures(self):
        with patch.object(release_smoke, "run", side_effect=self.planning_child) as child:
            release_smoke.check_planning(lambda name: name, {}, self.scratch)
        self.assertEqual(child.call_count, 8)

    def test_planning_rejects_empty_rank_or_incorrect_completion_output(self):
        for failure in ("rank", "status", "ids"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                self.scratch = Path(directory)

                def bad_child(command, environment, cwd, **kwargs):
                    if failure == "rank" and "rank" in command:
                        return '{"reports": []}'
                    if failure == "status" and "rank" not in command and "--query" not in command:
                        return "status\tcomplete\ncomplete_count\t0\nincomplete_count\t0\n"
                    if failure == "ids" and "--query" in command:
                        return "wrong-id\n"
                    return self.planning_child(command, environment, cwd, **kwargs)

                with patch.object(release_smoke, "run", side_effect=bad_child):
                    with self.assertRaises(RuntimeError):
                        release_smoke.check_planning(lambda name: name, {}, self.scratch)


if __name__ == "__main__":
    unittest.main()
