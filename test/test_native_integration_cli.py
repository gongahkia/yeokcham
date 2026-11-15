"""Fresh-process local acceptance journeys using explicit disposable signers."""
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class IntegrationCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yeokcham-integrate-cli-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        self.root = self.parent / "project"
        self.root.mkdir()
        keys = self.parent / "keys"
        keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(keys))
        (self.root / "private.txt").write_text("PRIVATE SENTINEL\n")
        (self.root / "note.txt").write_text("shared D\n")
        result = self.cli("init", self.root, machine=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def cli(self, *arguments, machine=True, environment=None):
        args = [str(arg) for arg in arguments]
        if args[0] != "init":
            args += ["--root", str(self.root)]
        if machine:
            args += ["--format", "json"]
        return subprocess.run([BINARY, *args], env=environment or self.environment,
                              capture_output=True, text=True, timeout=20)

    def data(self, result, status=0):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual(body["schema_version"], 2)
        self.assertNotIn("\x1b[", result.stdout)
        return body

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def share(self, path="note.txt"):
        return self.data(self.cli("share", path))["data"]

    def test_preview_exact_outputs_then_accept_private_E_and_retry(self):
        shared = self.share()
        (self.root / "note.txt").write_text("shared D\nprivate E\n")
        before = self.head()
        preview = self.data(self.cli("integrate", shared["change_id"], "--preview"))
        plan = preview["plan_id"]
        self.assertEqual(self.head(), before)
        proposed = preview["data"]
        self.assertEqual(proposed["accepted_snapshot"], shared["public_snapshot"])
        self.assertNotEqual(proposed["accepted_snapshot"], proposed["workspace_snapshot"])
        self.assertEqual(proposed["readiness"], "ready")
        self.assertEqual(proposed["exact_revisions"], [shared["revision_id"]])
        self.assertTrue(proposed["accepted_changes"])
        self.assertEqual(proposed["workspace_changes"], [])
        result = self.data(self.cli("integrate", "--plan", plan, "--yes"))
        operation = result["operation_id"]
        self.assertRegex(operation, r"^[0-9a-f]{32}$")
        facts = result["data"]["operation"]
        self.assertTrue(facts["committed"])
        self.assertEqual(facts["phase"], "completed")
        self.assertEqual(facts["outbound_state"], "pending")
        self.assertTrue(facts["target_sequence_allocated"])
        self.assertEqual((self.root / "note.txt").read_text(), "shared D\nprivate E\n")
        self.assertEqual((self.root / "private.txt").read_text(), "PRIVATE SENTINEL\n")
        committed = self.head()
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        repeated = self.data(self.cli("integrate", "--plan", plan, "--yes", environment=unavailable))
        self.assertEqual(repeated["operation_id"], operation)
        self.assertEqual(repeated["code"], "integration-repeated")
        self.assertEqual(repeated["outcome"], "unchanged")
        self.assertEqual(self.head(), committed)
        shown = self.data(self.cli("operation", "show", operation))
        self.assertEqual(shown["data"]["plan_id"], plan)
        resumed = self.data(self.cli("operation", "resume", operation, environment=unavailable))
        self.assertEqual(resumed["data"]["phase"], "completed")
        self.assertEqual(self.head(), committed)
        state = self.data(self.cli("status"))["data"]
        self.assertEqual(state["working_basis"], facts["accepted_record"])
        self.assertEqual(state["integration_operations"][0]["operation_id"], operation)
        noop = self.data(self.cli("integrate", shared["change_id"], "--yes", environment=unavailable))
        self.assertEqual(noop["code"], "integration-unchanged")
        self.assertTrue(noop["data"]["no_op"])
        self.assertEqual(self.head(), committed)

    def test_noninteractive_confirmation_and_stale_plan(self):
        shared = self.share()
        before = self.head()
        choice = self.data(self.cli("integrate", shared["change_id"]), 3)
        self.assertEqual(choice["error"]["code"], "confirmation-required")
        self.assertRegex(choice["plan_id"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.head(), before)
        (self.root / "private.txt").write_text("changed after preview\n")
        failed = self.data(self.cli("integrate", "--plan", choice["plan_id"], "--yes"), 3)
        self.assertEqual(failed["error"]["code"], "integration-choice-required")
        self.assertEqual(self.head(), before)
        self.assertEqual(self.data(self.cli("status"))["data"]["integration_operations"], [])

    def test_contextual_selection_and_explicit_all(self):
        first = self.share()
        (self.root / "other.txt").write_text("independent change\n")
        second = self.share("other.txt")
        before = self.head()
        choice = self.data(self.cli("integrate", "--yes"), 3)
        self.assertCountEqual(choice["data"]["eligible_changes"], [first["change_id"], second["change_id"]])
        self.assertEqual(self.head(), before)
        preview = self.data(self.cli("integrate", "--all", "--preview"))
        self.assertCountEqual(preview["data"]["exact_revisions"], [first["revision_id"], second["revision_id"]])
        self.data(self.cli("integrate", "--all", "--yes"))
        self.assertEqual((self.root / "other.txt").read_text(), "independent change\n")

    def test_preview_without_provider_and_plain_confirmation_cancel(self):
        self.share()
        before = self.head()
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        preview = self.cli("integrate", "--preview", machine=False, environment=unavailable)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("accepted changes:", preview.stdout)
        self.assertIn("+shared D", preview.stdout)
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen([BINARY, "integrate", "--root", str(self.root)],
                                       stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env=self.environment, text=True)
            os.write(master, b"n\n")
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertIn("cancelled", stdout)
        finally:
            os.close(master)
            os.close(slave)
        self.assertEqual(self.head(), before)

    def test_plain_commit_and_operation_inspection(self):
        shared = self.share()
        result = self.cli("integrate", shared["revision_id"], "--yes", machine=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("committed locally", result.stdout)
        self.assertIn("+shared D", result.stdout)
        status = self.data(self.cli("status"))["data"]
        operation = status["integration_operations"][0]["operation_id"]
        shown = self.cli("operation", "show", operation, machine=False)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn("phase completed", shown.stdout)

    def test_invalid_arguments_and_missing_repository_are_bounded(self):
        self.data(self.cli("integrate", "--all", "--plan", "a" * 64), 2)
        self.data(self.cli("operation", "show", "invalid"), 2)
        result = subprocess.run([BINARY, "integrate", "--root", str(self.parent / "absent"), "--yes", "--format", "json"],
                                env=self.environment, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["schema_version"], 2)


if __name__ == "__main__":
    unittest.main()
