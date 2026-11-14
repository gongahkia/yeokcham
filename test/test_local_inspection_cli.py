"""Read-only local domain journeys through fresh CLI processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class LocalInspectionCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yeokcham-inspection-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "workspace"
        self.root.mkdir()
        self.keys = self.parent / "test-signers"
        self.keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.keys))
        (self.root / "notes").write_bytes(b"A\n")
        (self.root / "opaque").write_bytes(b"\x00old")
        (self.root / "run").write_bytes(b"#!/bin/sh\n")
        result = self.run_cli("init", self.root, root=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_cli(self, *arguments, machine=False, root=True):
        argv = [BINARY, *map(str, arguments)]
        if root:
            argv += ["--root", str(self.root)]
        if machine:
            argv += ["--format", "json"]
        return subprocess.run(argv, env=self.environment, capture_output=True, text=True, timeout=20)

    def machine(self, *arguments):
        result = self.run_cli(*arguments, machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b", result.stdout)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schema_version"], 2)
        self.assertEqual(envelope["data"], envelope["result"])
        self.assertIsInstance(envelope["next_actions"], list)
        return envelope

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def save(self, value):
        (self.root / "notes").write_bytes(value)
        return self.machine("save")

    def test_mixed_status_and_readable_diff_are_domain_results(self):
        before = self.head()
        (self.root / "notes").write_bytes(b"B")
        (self.root / "opaque").write_bytes(b"\x00new")
        (self.root / "run").chmod(0o751)
        (self.root / "empty").mkdir()
        (self.root / "link").symlink_to("missing-target")
        envelope = self.machine("status")
        data = envelope["data"]
        self.assertEqual(envelope["outcome"], "completed")
        self.assertTrue(data["uncaptured"])
        self.assertEqual(data["capture"]["state"], "complete")
        self.assertEqual([row["path"] for row in data["changes"]], ["empty", "link", "notes", "opaque", "run"])
        self.assertEqual(data["saved"]["history"]["sequence"], "0")
        self.assertEqual(data["watcher"]["state"], "not-inspected")
        self.assertEqual(data["private_backup"], "not-configured")
        self.assertIn("save", [action["arguments"][1] for action in envelope["next_actions"]])
        comparison = self.machine("diff")["data"]
        rows = {row["path"]: row for row in comparison["differences"]}
        self.assertEqual(rows["notes"]["text"]["state"], "text")
        self.assertFalse(rows["notes"]["text"]["hunks"][0]["lines"][-1]["newline"])
        self.assertEqual(rows["opaque"]["text"]["state"], "opaque")
        self.assertEqual(rows["run"]["text"]["state"], "metadata-only")
        plain = self.run_cli("diff", "--color", "never")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn("-A", plain.stdout)
        self.assertIn("+B", plain.stdout)
        self.assertIn("\\ No newline at end of file", plain.stdout)
        self.assertNotIn("\x00", plain.stdout)
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"B")

    def test_alternatives_pagination_and_exact_saved_comparisons(self):
        self.save(b"B\n")
        self.save(b"C\n")
        result = self.run_cli("undo", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.save(b"D\n")
        before = self.head()
        first = self.machine("history", "--limit", "2")["data"]
        self.assertEqual([row["sequence"] for row in first["entries"]], ["3", "2"])
        self.assertEqual(first["next_before"], "2")
        second = self.machine("history", "--before", first["next_before"], "--limit", "2")["data"]
        self.assertEqual([row["sequence"] for row in second["entries"]], ["1", "0"])
        b = second["entries"][0]
        self.assertEqual([child.rsplit(":", 1)[1] for child in b["children"]], ["2", "3"])
        self.assertEqual(b["changed_paths"][0]["path"], "notes")
        comparison = self.machine("diff", b["id"], first["entries"][1]["id"])["data"]
        self.assertEqual(comparison["before"]["id"], b["id"])
        self.assertEqual(comparison["after"]["history"]["sequence"], "2")
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"D\n")
        plain = self.run_cli("history")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn("children", plain.stdout)
        self.assertIn("UTC", plain.stdout)
        self.assertIn("archive not configured", plain.stdout)

    def test_equal_contents_preserve_distinct_history_ids(self):
        self.save(b"B\n")
        self.save(b"A\n")
        envelope = self.machine("diff", "0", "2")
        self.assertEqual(envelope["outcome"], "unchanged")
        self.assertEqual(envelope["data"]["differences"], [])
        self.assertNotEqual(envelope["data"]["before"]["id"], envelope["data"]["after"]["id"])
        self.assertEqual(envelope["data"]["before"]["snapshot_id"], envelope["data"]["after"]["snapshot_id"])

    def test_malformed_capture_is_successful_incomplete_inspection(self):
        before = self.head()
        (self.root / ".yeokchamignore").write_text("[malformed\n")
        envelope = self.machine("status")
        self.assertEqual(envelope["outcome"], "incomplete")
        self.assertEqual(envelope["code"], "capture-incomplete")
        self.assertIsNone(envelope["data"]["uncaptured"])
        self.assertIsNone(envelope["data"]["changes"])
        self.assertEqual(envelope["data"]["capture"]["state"], "incomplete")
        plain = self.run_cli("status")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn("uncaptured unknown", plain.stdout)
        self.assertNotIn("uncaptured no", plain.stdout)
        self.assertEqual(self.machine("history")["data"]["entries"][0]["availability"], "available")
        failed = self.run_cli("diff", machine=True)
        self.assertEqual(failed.returncode, 2, failed.stderr)
        self.assertEqual(json.loads(failed.stdout)["code"], "invalid-ignore-rule")
        self.assertEqual(self.machine("diff", "0", "0")["outcome"], "unchanged")
        self.assertEqual(before, self.head())

    def test_missing_contents_are_truthful_and_read_only(self):
        self.save(b"B\n")
        b = self.machine("history")["data"]["entries"][0]
        self.save(b"C\n")
        before = self.head()
        identity = b["snapshot_id"]
        (self.root / ".yeokcham/objects" / identity[:2] / identity[2:4] / identity[4:]).unlink()
        history = self.machine("history")["data"]
        row = next(row for row in history["entries"] if row["sequence"] == "1")
        self.assertEqual(row["availability"], "unavailable")
        self.assertIsNotNone(row["unavailable_reason"])
        failed = self.run_cli("diff", "1", "2", machine=True)
        self.assertEqual(failed.returncode, 5, failed.stderr)
        self.assertEqual(json.loads(failed.stdout)["outcome"], "unavailable")
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"C\n")

    def test_terminal_controls_and_non_utf8_paths_are_data(self):
        (self.root / "notes").write_bytes(b"text\x1b[31mcontrol\n")
        raw_path = os.fsencode(self.root) + b"/bad-\xff"
        descriptor = os.open(raw_path, os.O_CREAT | os.O_WRONLY, 0o600)
        os.write(descriptor, b"ordinary bytes\n")
        os.close(descriptor)
        envelope = self.machine("diff")
        row = next(row for row in envelope["data"]["differences"] if row["path"] is None)
        self.assertEqual(row["path_bytes_hex"], b"bad-\xff".hex())
        plain = self.run_cli("diff", "--color", "never")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertNotIn("\x1b", plain.stdout)
        self.assertIn("\\x1b", plain.stdout)

    def test_ignore_explain_preserves_byte_patterns_in_json(self):
        raw_name = b"bad-\xff"
        (self.root / ".yeokchamignore").write_bytes(raw_name + b"\n")
        envelope = self.machine("ignore", "explain", os.fsdecode(raw_name))
        self.assertTrue(envelope["data"]["ignored"])
        self.assertIsNone(envelope["data"]["path"])
        self.assertEqual(envelope["data"]["path_bytes_hex"], raw_name.hex())
        self.assertIsNone(envelope["data"]["pattern"])
        self.assertEqual(envelope["data"]["pattern_bytes_hex"], raw_name.hex())

    def test_non_utf8_workspace_roots_have_safe_display_and_actions(self):
        root_bytes = os.fsencode(self.parent) + b"/workspace-\xff"
        root = Path(os.fsdecode(root_bytes))
        result = self.run_cli("init", root, root=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.root = root
        envelope = self.machine("status")
        self.assertEqual(envelope["data"]["capture"]["state"], "complete")
        self.assertTrue(envelope["next_actions"])
        self.assertFalse(envelope["next_actions"][0]["applicable"])
        self.assertIn("not UTF-8", envelope["next_actions"][0]["explanation"])

    def test_scope_and_limit_errors_have_actionable_domain_outcomes(self):
        for arguments in [("history", "--limit", "0"), ("diff", "f" * 32 + ":0", "working")]:
            failed = self.run_cli(*arguments, machine=True)
            self.assertEqual(failed.returncode, 2, failed.stderr)
            data = json.loads(failed.stdout)
            self.assertEqual(data["outcome"], "invalid")
            self.assertTrue(data["next_actions"])
            self.assertEqual(data["next_actions"][0]["arguments"][:2], ["yeokcham", "help"])
        for command in ["history", "diff", "status"]:
            result = self.run_cli("help", command, root=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("usage:", result.stdout)


if __name__ == "__main__":
    unittest.main()
