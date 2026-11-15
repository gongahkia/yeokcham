"""Actual paused operations and fresh CLI recovery, using disposable test keys."""
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())
FIXTURE = str(Path(sys.argv.pop(1)).resolve())


class RecoveryCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yeokcham-recovery-cli-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        self.root = self.parent / "project"
        self.root.mkdir()
        keys = self.parent / "keys"
        keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(keys))
        (self.root / "private.txt").write_text("private original\n")
        (self.root / "note.txt").write_text("notes\n")
        result = subprocess.run([BINARY, "init", str(self.root)], env=self.environment,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.operation, self.integration_plan = self.fixture("start", self.root, "after-file")
        (self.root / "incoming.txt").write_text("unexpected X\n")
        (self.root / "private.txt").write_text("private external Y\n")
        self.data(self.cli("operation", "resume", self.operation), 8)

    def fixture(self, *arguments):
        result = subprocess.run([FIXTURE, *map(str, arguments)], env=self.environment,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        return result.stdout.strip().split()

    def cli(self, *arguments, machine=True, environment=None):
        args = list(map(str, arguments)) + ["--root", str(self.root)]
        if machine:
            args += ["--format", "json"]
        return subprocess.run([BINARY, *args], env=environment or self.environment,
                              capture_output=True, text=True, timeout=20)

    def data(self, result, status=0):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual(body["schema_version"], 2)
        return body

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def test_pending_operation_blocks_new_conflicts_with_recovery_outcome(self):
        before = self.head()
        result = self.data(self.cli("conflicts"), 8)
        self.assertEqual(result["error"]["code"], "integration-incomplete")
        self.assertEqual(result["operation_id"], self.operation)
        self.assertTrue(any("resume" in action["arguments"] for action in result["next_actions"]))
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "private.txt").read_text(), "private external Y\n")

    def test_preview_confirmation_recovery_and_observation_copyout(self):
        before = self.head()
        choice = self.data(self.cli("operation", "recover", self.operation), 3)
        self.assertEqual(choice["error"]["code"], "confirmation-required")
        self.assertEqual(self.head(), before)
        preview = self.data(self.cli("operation", "recover", self.operation, "--preview"))
        plan = preview["plan_id"]
        self.assertEqual(preview["data"]["mode"], "restore_safety")
        self.assertEqual(self.head(), before)
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        result = self.data(self.cli("operation", "recover", self.operation, "--plan", plan, "--yes", environment=unavailable))
        operation = result["data"]["operation"]
        self.assertTrue(operation["recovered"])
        self.assertFalse(operation["committed"])
        self.assertEqual(operation["outbound_state"], "not_committed")
        self.assertEqual((self.root / "private.txt").read_text(), "private original\n")
        self.assertFalse((self.root / "incoming.txt").exists())
        observed = operation["recovery"]["observed_snapshot"]
        destination = self.parent / "preserved-external-edits"
        self.data(self.cli("restore", observed, "--to", destination, "--yes"))
        self.assertEqual((destination / "incoming.txt").read_text(), "unexpected X\n")
        self.assertEqual((destination / "private.txt").read_text(), "private external Y\n")
        completed = self.head()
        repeat = self.data(self.cli("operation", "resume", self.operation, environment=unavailable))
        self.assertTrue(repeat["data"]["recovered"])
        retried = self.data(self.cli("integrate", "--plan", self.integration_plan, "--yes", environment=unavailable))
        self.assertEqual(retried["code"], "integration-recovered")
        self.assertEqual(self.head(), completed)
        self.data(self.cli("operation", "forget", self.operation, "--yes"))
        released = self.head()
        self.data(self.cli("operation", "forget", self.operation, "--yes"))
        self.assertEqual(self.head(), released)
        self.assertFalse(self.data(self.cli("operation", "show", self.operation))["data"]["recovery"]["retained"])
        historical = self.cli("operation", "recover", self.operation, "--preview", machine=False)
        self.assertEqual(historical.returncode, 0, historical.stderr)
        self.assertIn("retention was released", historical.stdout)

    def test_stale_recovery_preview_preserves_files_and_metadata(self):
        preview = self.data(self.cli("operation", "recover", self.operation, "--preview"))
        (self.root / "private.txt").write_text("changed after recovery preview\n")
        before = self.head()
        self.data(self.cli("operation", "recover", self.operation, "--plan", preview["plan_id"], "--yes"), 3)
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "incoming.txt").read_text(), "unexpected X\n")
        self.assertIsNone(self.data(self.cli("operation", "show", self.operation))["data"]["recovery"])

    def test_recovery_race_can_replan_keep_current_without_losing_old_observation(self):
        self.fixture("recover", self.root, self.operation, "after-file")
        (self.root / "private.txt").write_text("new external edit during recovery\n")
        self.data(self.cli("operation", "resume", self.operation), 8)
        result = self.data(self.cli("operation", "recover", self.operation, "--keep-current", "--replan", "--yes"))
        recovery = result["data"]["operation"]["recovery"]
        self.assertEqual(recovery["mode"], "keep_current")
        self.assertEqual(recovery["previous_attempts"], 1)
        self.assertEqual((self.root / "private.txt").read_text(), "new external edit during recovery\n")
        destination = self.parent / "older-recovery-observation"
        self.data(self.cli("restore", recovery["retained_observations"][0], "--to", destination, "--yes"))
        self.assertEqual((destination / "private.txt").read_text(), "private external Y\n")

    def test_plain_preview_and_default_cancellation(self):
        before = self.head()
        preview = self.cli("operation", "recover", self.operation, "--preview", machine=False)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("private recovery plan", preview.stdout)
        self.assertIn("restore_safety", preview.stdout)
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen([BINARY, "operation", "recover", self.operation, "--root", str(self.root)],
                                       env=self.environment, stdin=slave, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            os.write(master, b"n\n")
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertIn("cancelled", stdout)
        finally:
            os.close(master)
            os.close(slave)
        self.assertEqual(self.head(), before)


if __name__ == "__main__":
    unittest.main()
