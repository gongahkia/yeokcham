"""Local selection contracts across processes and actual native mutation exits."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())
FAULT = str(Path(sys.argv.pop(1)).resolve())


class LocalSelectionCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yeokcham-selection-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        self.root = self.parent / "workspace"
        self.root.mkdir()
        keys = self.parent / "signers"
        keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(keys))
        (self.root / "notes").write_bytes(b"A\n")
        (self.root / "binary").write_bytes(bytes(range(256)))
        (self.root / "empty").mkdir()
        (self.root / "link").symlink_to("missing-target")
        (self.root / "run").write_bytes(b"#!/bin/sh\n")
        (self.root / "run").chmod(0o751)
        result = self.run_cli("init", self.root, root=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_cli(self, *arguments, root=True, machine=False):
        command = [BINARY, *map(str, arguments)]
        if root:
            command += ["--root", str(self.root)]
        if machine:
            command += ["--format", "json"]
        return subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=20)

    def machine(self, *arguments, code=0):
        result = self.run_cli(*arguments, machine=True)
        self.assertEqual(result.returncode, code, result.stderr)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schema_version"], 2)
        if code == 0:
            self.assertEqual(envelope["data"], envelope["result"] )
        else:
            self.assertIsNone(envelope["result"])
            self.assertIsInstance(envelope["data"], dict)
        self.assertNotIn("\x1b", result.stdout)
        return envelope

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def save(self, value):
        (self.root / "notes").write_bytes(value)
        self.machine("save")

    def cursor(self):
        return self.machine("history")["data"]["current"]

    def interrupt(self, boundary, *copy_args):
        result = subprocess.run([FAULT, str(self.root), boundary, *map(str, copy_args)],
                                env=self.environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 73, result.stderr)
        status = self.machine("status")
        self.assertEqual(status["outcome"], "incomplete")
        self.assertEqual(status["data"]["capture"]["state"], "incomplete")
        operations = status["data"]["pending_operations"]
        self.assertEqual(len(operations), 1)
        operation = operations[0]
        self.assertFalse(operation["current_contents_verified"])
        self.assertIn(operation["operation_id"], json.dumps(status["next_actions"]))
        return operation

    def test_noninteractive_requires_confirmation_and_preview_binds_plan(self):
        self.save(b"B\n")
        before = self.head()
        refusal = self.machine("undo", code=3)
        self.assertEqual(refusal["outcome"], "choice-required")
        self.assertEqual(refusal["data"]["target_history"]["sequence"], "0")
        self.assertRegex(refusal["plan_id"], r"^[0-9a-f]{64}$")
        self.assertEqual(before, self.head())
        plain = self.run_cli("undo")
        self.assertEqual(plain.returncode, 3)
        self.assertIn("--yes", plain.stderr)
        preview = self.machine("undo", "--preview")
        self.assertEqual(before, self.head())
        applied = self.machine("undo", "--yes", "--plan", preview["plan_id"])
        self.assertTrue(applied["data"]["applied"])
        self.assertEqual(applied["data"]["target_history"]["sequence"], "0")
        self.assertRegex(applied["operation_id"], r"^[0-9a-f]{64}$")
        self.assertEqual((self.root / "notes").read_bytes(), b"A\n")
        self.assertEqual((self.root / "binary").read_bytes(), bytes(range(256)))
        self.assertEqual(os.readlink(self.root / "link"), "missing-target")
        self.assertTrue((self.root / "empty").is_dir())
        self.assertTrue((self.root / "run").stat().st_mode & 0o111)

    def test_stale_preview_refuses_without_capturing_later_disk_edits(self):
        self.save(b"B\n")
        preview = self.machine("undo", "--preview")
        before = self.head()
        (self.root / "notes").write_bytes(b"external edit\n")
        refused = self.machine("undo", "--yes", "--plan", preview["plan_id"], code=3)
        self.assertEqual(refused["error"]["code"], "stale-selection-plan")
        self.assertIsNotNone(refused["data"]["saved"]["history"])
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"external edit\n")

    def test_alternate_continuations_and_unsaved_work_have_exact_targets(self):
        self.save(b"B\n")
        self.save(b"C\n")
        self.machine("undo", "--yes")
        self.save(b"D\n")
        self.machine("undo", "--yes")
        choice = self.machine("redo", "--yes", code=3)
        self.assertEqual(choice["outcome"], "choice-required")
        self.assertEqual([choice["history"]["sequence"] for choice in choice["data"]["redo_choices"]], ["2", "3"])
        self.assertEqual(len([a for a in choice["next_actions"] if a["arguments"][1] == "redo"]), 2)
        history = self.machine("history")["data"]
        c = next(row for row in history["entries"] if row["sequence"] == "2")
        selected = self.machine("redo", "--node", c["id"], "--yes")
        self.assertEqual(selected["data"]["target_history"]["sequence"], "2")
        (self.root / "notes").write_bytes(b"E unsaved\n")
        selected = self.machine("undo", "--to", "1", "--yes")
        self.assertTrue(selected["data"]["captures_unsaved"])
        self.assertEqual((self.root / "notes").read_bytes(), b"B\n")
        history = self.machine("history")["data"]
        self.assertIn("4", [row["sequence"] for row in history["entries"]])
        plain = self.run_cli("restore", "4", "--yes")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn("current node 4", plain.stdout)
        self.assertEqual((self.root / "notes").read_bytes(), b"E unsaved\n")

    def test_dirty_redo_refuses_with_conflict_and_invalid_scope_is_argument_error(self):
        self.save(b"B\n")
        self.machine("undo", "--yes")
        (self.root / "notes").write_bytes(b"private\n")
        before = self.head()
        result = self.machine("redo", "--yes", code=4)
        self.assertEqual(result["outcome"], "conflict")
        self.machine("restore", "00" * 16 + ":0", "--yes", code=2)
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"private\n")

    def test_equal_bytes_keep_distinct_history_positions_without_rewriting_files(self):
        self.save(b"B\n")
        self.save(b"A\n")
        stamp = (self.root / "notes").stat()
        result = self.machine("restore", "0", "--yes")
        self.assertEqual(result["data"]["changes"], [])
        self.assertEqual(result["data"]["target_history"]["sequence"], "0")
        self.assertIsNotNone(result["operation_id"])
        after = (self.root / "notes").stat()
        self.assertEqual((stamp.st_ino, stamp.st_mtime_ns, stamp.st_ctime_ns),
                         (after.st_ino, after.st_mtime_ns, after.st_ctime_ns))
        self.assertFalse(result["data"]["recovery"]["source_proof"])

    def test_copy_preview_and_exact_full_state_do_not_move_source(self):
        state = self.machine("history")["data"]["entries"][0]
        self.save(b"B\n")
        (self.root / "notes").write_bytes(b"private unsaved\n")
        before = self.head()
        destination = self.parent / "copy"
        self.machine("restore", state["id"], "--to", destination, code=3)
        preview = self.machine("restore", state["id"], "--to", destination, "--preview")
        self.assertFalse(destination.exists())
        result = self.machine("restore", state["id"], "--to", destination, "--yes", "--plan", preview["plan_id"])
        self.assertFalse(result["data"]["source_history_changed"])
        self.assertFalse(result["data"]["source_branch_changed"])
        self.assertEqual(before, self.head())
        self.assertEqual((destination / "notes").read_bytes(), b"A\n")
        self.assertEqual((destination / "binary").read_bytes(), bytes(range(256)))
        self.assertEqual(os.readlink(destination / "link"), "missing-target")
        self.assertEqual((self.root / "notes").read_bytes(), b"private unsaved\n")
        retry = self.machine("restore", "--resume", "--operation", result["operation_id"], "--yes")
        self.assertEqual(retry["outcome"], "unchanged")
        self.assertTrue(retry["data"]["already_completed"])
        self.assertEqual(before, self.head())

    def test_copy_stale_destination_and_unavailable_targets_preserve_all_live_bytes(self):
        destination = self.parent / "copy"
        preview = self.machine("restore", "0", "--to", destination, "--preview")
        destination.mkdir()
        self.machine("restore", "0", "--to", destination, "--yes", "--plan", preview["plan_id"], code=3)
        (destination / "untracked").write_bytes(b"keep")
        self.machine("restore", "0", "--to", destination, "--yes", code=4)
        before = self.head()
        self.machine("restore", "0" * 64, "--yes", code=5)
        self.assertEqual(before, self.head())
        self.assertEqual((destination / "untracked").read_bytes(), b"keep")

    def test_interruption_resumes_exact_operation_with_no_duplicate_undo(self):
        self.save(b"B\n")
        self.save(b"C\n")
        operation = self.interrupt("mutation")
        before = self.head()
        op = operation["operation_id"]
        preview = self.machine("restore", "--resume", "--operation", op, "--preview")
        self.assertEqual(preview["data"]["target_history"]["sequence"], "1")
        self.assertEqual(before, self.head())
        self.machine("restore", "--resume", "--operation", op, code=3)
        resumed = self.machine("restore", "--resume", "--operation", op, "--yes", "--plan", operation["plan_id"])
        self.assertEqual(resumed["operation_id"], op)
        self.assertEqual((self.root / "notes").read_bytes(), b"B\n")
        after = self.head()
        (self.root / "notes").write_bytes(b"later edit\n")
        retry = self.machine("restore", "--resume", "--operation", op, "--yes")
        self.assertTrue(retry["data"]["already_completed"])
        self.assertEqual(after, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"later edit\n")
        self.assertEqual(self.cursor().rsplit(":", 1)[1], "1")

    def test_interrupted_external_edit_is_preserved_with_actionable_operation(self):
        self.save(b"B\n")
        operation = self.interrupt("mutation")
        op = operation["operation_id"]
        (self.root / "notes").write_bytes(b"unexpected external edit\n")
        failure = self.machine("restore", "--resume", "--operation", op, "--yes", code=8)
        self.assertEqual(failure["operation_id"], op)
        self.assertEqual(failure["data"]["pending_operations"][0]["operation_id"], op)
        self.assertIn(op, json.dumps(failure["next_actions"]))
        self.assertEqual((self.root / "notes").read_bytes(), b"unexpected external edit\n")

    def test_materialized_and_metadata_interruptions_preserve_later_edits(self):
        for boundary in ["materialized", "metadata"]:
            self.save(("before " + boundary + "\n").encode())
            operation = self.interrupt(boundary)
            (self.root / "notes").write_bytes(b"later external edit\n")
            self.machine("restore", "--resume", "--operation", operation["operation_id"], "--yes")
            self.assertEqual((self.root / "notes").read_bytes(), b"later external edit\n")

    def test_copy_interruption_uses_original_destination_and_no_source_scan(self):
        state = self.machine("history")["data"]["entries"][0]
        self.save(b"B\n")
        before = self.head()
        destination = self.parent / "copy"
        operation = self.interrupt("mutation", state["snapshot_id"], destination)
        self.assertEqual(operation["scope"], "copy-out")
        (self.root / ".yeokchamignore").write_bytes(b"[malformed\n")
        result = self.machine("restore", "--resume", "--operation", operation["operation_id"], "--yes")
        self.assertFalse(result["data"]["result"]["source_history_changed"])
        self.assertEqual(before, self.head())
        self.assertEqual((destination / "notes").read_bytes(), b"A\n")
        self.assertEqual((self.root / "notes").read_bytes(), b"B\n")

    def test_default_tty_cancellation_preserves_files_history_and_journals(self):
        self.save(b"B\n")
        before = self.head()
        master, slave = pty.openpty()
        process = subprocess.Popen([BINARY, "undo", "--root", str(self.root)], env=self.environment,
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.close(slave)
        try:
            prompt = b""
            deadline = time.monotonic() + 15
            while b"[y/N]" not in prompt and time.monotonic() < deadline:
                ready, _, _ = select.select([process.stderr], [], [], 0.2)
                if ready:
                    chunk = os.read(process.stderr.fileno(), 1024)
                    if not chunk:
                        break
                    prompt += chunk
            self.assertIn(b"[y/N]", prompt)
            os.write(master, b"\n")
            output, errors = process.communicate(timeout=15)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 0, errors)
        self.assertIn(b"cancelled", output)
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"B\n")
        self.assertEqual(self.machine("status")["data"]["pending_operations"], [])

    def test_multiple_pending_scopes_require_exact_choice_and_remain_visible(self):
        state = self.machine("history")["data"]["entries"][0]
        self.save(b"B\n")
        original = self.interrupt("mutation")
        (self.root / "notes").write_bytes(b"external after original mutation\n")
        destination = self.parent / "safety-copy"
        result = subprocess.run([FAULT, str(self.root), "mutation", state["snapshot_id"], str(destination)],
                                env=self.environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 73, result.stderr)
        status = self.machine("status")
        operations = status["data"]["pending_operations"]
        self.assertEqual(len(operations), 2)
        self.assertEqual({operation["scope"] for operation in operations}, {"in-place", "copy-out"})
        choice = self.machine("restore", "--resume", "--yes", code=3)
        self.assertEqual(len(choice["data"]["operations"]), 2)
        copy = next(operation for operation in operations if operation["scope"] == "copy-out")
        self.machine("restore", "--resume", "--operation", copy["operation_id"], "--yes")
        self.assertEqual((destination / "notes").read_bytes(), b"A\n")
        status = self.machine("status")
        self.assertEqual([op["operation_id"] for op in status["data"]["pending_operations"]], [original["operation_id"]])
        self.machine("restore", "--resume", "--operation", original["operation_id"], "--yes", code=8)
        self.assertEqual((self.root / "notes").read_bytes(), b"external after original mutation\n")

    def test_copy_byte_destination_is_exact_data_and_actions_are_inapplicable(self):
        destination_bytes = os.fsencode(self.parent) + b"/copy-\xff"
        destination = os.fsdecode(destination_bytes)
        preview = self.machine("restore", "0", "--to", destination, "--preview")
        self.assertIsNone(preview["data"]["destination"]["path"])
        self.assertEqual(preview["data"]["destination"]["bytes_hex"], destination_bytes.hex())
        self.assertFalse(any(action["applicable"] for action in preview["next_actions"]))
        self.machine("restore", "0", "--to", destination, "--yes", "--plan", preview["plan_id"])
        with open(destination_bytes + b"/notes", "rb") as stream:
            self.assertEqual(stream.read(), b"A\n")

    def test_missing_and_corrupt_saved_targets_refuse_before_any_replacement(self):
        initial = self.machine("history")["data"]["entries"][0]
        self.save(b"B\n")
        identity = initial["snapshot_id"]
        object_path = self.root / ".yeokcham/objects" / identity[:2] / identity[2:4] / identity[4:]
        original = object_path.read_bytes()
        before = self.head()
        object_path.unlink()
        self.machine("restore", initial["id"], "--yes", code=5)
        object_path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
        self.machine("restore", initial["id"], "--yes", code=6)
        self.assertEqual(before, self.head())
        self.assertEqual((self.root / "notes").read_bytes(), b"B\n")
        self.assertEqual((self.root / "binary").read_bytes(), bytes(range(256)))

    def test_selection_flag_errors_and_unknown_recovery_do_not_change_state(self):
        before = self.head()
        for args in [("undo", "--preview", "--yes"), ("undo", "--plan", "bad"),
                     ("restore", "--resume", "0"), ("restore", "0", "--operation", "0" * 64),
                     ("restore", "working", "--yes"), ("undo", "--yes", "--yes")]:
            self.machine(*args, code=2)
        self.machine("restore", "--resume", "--operation", "0" * 64, "--yes", code=2)
        self.assertEqual(self.machine("restore", "--resume", "--yes")["outcome"], "unchanged")
        self.assertEqual(before, self.head())


if __name__ == "__main__":
    unittest.main()
