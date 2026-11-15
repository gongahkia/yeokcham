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

    def cli(self, *arguments, machine=True, environment=None, timeout=20, cwd=None):
        args = [str(arg) for arg in arguments]
        if args[0] != "init":
            args += ["--root", str(self.root)]
        if machine:
            args += ["--format", "json"]
        return subprocess.run([BINARY, *args], env=environment or self.environment,
                              capture_output=True, text=True, timeout=timeout, cwd=cwd)

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

    def test_named_conflicts_deferral_and_exact_version_prepare_fresh_plan(self):
        first = self.share()
        (self.root / "note.txt").write_bytes(b"another independent shared version\r\n")
        second = self.share()
        (self.root / "note.txt").write_bytes(b"PRIVATE overlapping E\r\n")
        before = self.head()
        inspection = self.data(self.cli("conflicts"))["data"]
        self.assertEqual(self.head(), before)
        self.assertTrue(inspection["conflicts"])
        conflict = next(row for row in inspection["conflicts"] if not row["private_workspace"])
        self.assertRegex(conflict["conflict_id"], r"^[0-9a-f]{64}$")
        self.assertIn("revision:" + first["revision_id"], [row["version_id"] for row in conflict["versions"]])
        deferred = self.data(self.cli("resolve", conflict["conflict_id"], "--defer"))
        self.assertEqual(deferred["code"], "conflict-deferred")
        self.assertEqual(deferred["plan_id"], conflict["plan_id"])
        self.assertEqual(self.head(), before)
        chosen = self.data(self.cli("resolve", conflict["conflict_id"], "--use", "revision:" + first["revision_id"]))
        self.assertNotEqual(chosen["plan_id"], conflict["plan_id"])
        self.assertRegex(chosen["data"]["public_resolution"], r"^[0-9a-f]{64}$")
        self.assertTrue(chosen["data"]["retained"])
        proposal = next(row for row in self.data(self.cli("status"))["data"]["resolution_proposals"]
                        if row["resolution_id"] == chosen["data"]["public_resolution"])
        self.assertEqual(proposal["state"], "recorded_proposal")
        self.assertEqual(proposal["accepted_by"], [])
        self.assertEqual((self.root / "note.txt").read_bytes(), b"PRIVATE overlapping E\r\n")
        retained = self.head()
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        repeated = self.data(self.cli("resolve", conflict["conflict_id"], "--use", "revision:" + first["revision_id"], environment=unavailable))
        self.assertEqual(repeated["plan_id"], chosen["plan_id"])
        self.assertEqual(self.head(), retained)
        inspected = self.data(self.cli("conflicts"))["data"]
        self.assertEqual([row["plan_id"] for row in inspected["plans"]], [chosen["plan_id"]])
        self.assertEqual(self.data(self.cli("status"))["data"]["integration_operations"], [])
        private = next(row for row in inspected["conflicts"] if row["private_workspace"])
        kept = self.data(self.cli("resolve", private["conflict_id"], "--use", "working"))
        self.assertIsNone(kept["data"]["public_resolution"])
        self.assertEqual(self.head(), retained)
        self.assertEqual(kept["data"]["plan"]["readiness"], "ready")
        self.assertEqual(kept["data"]["plan"]["accepted_snapshot"], first["public_snapshot"])
        self.assertEqual(len(kept["data"]["plan"]["workspace_decisions"]), 1)
        self.data(self.cli("integrate", "--plan", kept["plan_id"], "--preview"))
        self.assertEqual(self.head(), retained)
        applied = self.data(self.cli("integrate", "--plan", kept["plan_id"], "--yes"))
        self.assertEqual(applied["data"]["accepted_snapshot"], first["public_snapshot"])
        proposal = next(row for row in self.data(self.cli("status"))["data"]["resolution_proposals"]
                        if row["resolution_id"] == chosen["data"]["public_resolution"])
        self.assertEqual(proposal["accepted_by"], [applied["data"]["operation"]["accepted_record"]])
        self.assertEqual((self.root / "note.txt").read_bytes(), b"PRIVATE overlapping E\r\n")
        self.assertEqual((self.root / "private.txt").read_text(), "PRIVATE SENTINEL\n")

    def test_conflict_replacement_streams_executable_bytes_and_defers_application(self):
        first = self.share()
        (self.root / "note.txt").write_bytes(b"independent variant\n")
        self.share()
        inspection = self.data(self.cli("conflicts"))["data"]
        conflict = next(row for row in inspection["conflicts"] if not row["private_workspace"])
        replacement = self.parent / "replacement.bin"
        content = bytes(range(251)) * 9001
        replacement.write_bytes(content)
        replacement.chmod(0o751)
        chosen = self.data(self.cli("resolve", conflict["conflict_id"], "--file", replacement))
        self.assertTrue(chosen["data"]["retained"])
        self.assertEqual((self.root / "note.txt").read_bytes(), b"independent variant\n")
        plain = self.cli("conflicts", "--plan", chosen["plan_id"], machine=False)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn(chosen["plan_id"], plain.stdout)
        self.assertNotIn(content[:100].decode("latin1"), plain.stdout)
        self.data(self.cli("integrate", "--plan", chosen["plan_id"], "--yes", timeout=120))
        self.assertEqual((self.root / "note.txt").read_bytes(), content)
        self.assertTrue((self.root / "note.txt").stat().st_mode & 0o100)
        self.assertEqual((self.root / "private.txt").read_text(), "PRIVATE SENTINEL\n")

    def test_stale_conflict_and_invalid_version_refuse_without_publication(self):
        first = self.share()
        (self.root / "note.txt").write_bytes(b"another version\n")
        self.share()
        conflict = self.data(self.cli("conflicts"))["data"]["conflicts"][0]
        before = self.head()
        self.data(self.cli("resolve", conflict["conflict_id"], "--use", "unknown"), 2)
        self.assertEqual(self.head(), before)
        (self.root / "private.txt").write_text("external edit after inspection\n")
        self.data(self.cli("resolve", conflict["conflict_id"], "--use", "revision:" + first["revision_id"]), 3)
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "private.txt").read_text(), "external edit after inspection\n")

    def test_resolution_alias_failure_reports_recorded_proposal_and_exact_retry(self):
        first = self.share()
        (self.root / "note.txt").write_text("second conflicting version\n")
        self.share()
        conflict = self.data(self.cli("conflicts"))["data"]["conflicts"][0]
        before = self.head()
        plans = self.root / ".yeokcham/integration-plans"
        plans.chmod(0o500)
        try:
            failed = self.data(self.cli("resolve", conflict["conflict_id"], "--use", "revision:" + first["revision_id"]), 8)
        finally:
            plans.chmod(0o700)
        self.assertEqual(failed["code"], "resolution-plan-incomplete")
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["outcome"], "interrupted")
        self.assertFalse(failed["data"]["retained"])
        self.assertRegex(failed["data"]["public_resolution"], r"^[0-9a-f]{64}$")
        self.assertNotEqual(self.head(), before)
        self.assertEqual((self.root / "note.txt").read_text(), "second conflicting version\n")
        status = self.data(self.cli("status"))["data"]
        self.assertEqual(status["integration_operations"], [])
        self.assertEqual(status["resolution_proposals"][0]["accepted_by"], [])
        recorded = self.head()
        action = failed["next_actions"][0]["arguments"]
        self.assertIn("resolution:" + failed["data"]["public_resolution"], action)
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        args = action[1:] if action[0] == "yeokcham" else action
        repeated = subprocess.run([BINARY, *args, "--format", "json"], env=unavailable,
                                  capture_output=True, text=True, timeout=20)
        repeated = self.data(repeated)
        self.assertTrue(repeated["data"]["retained"])
        self.assertEqual(repeated["data"]["public_resolution"], failed["data"]["public_resolution"])
        self.assertEqual(repeated["plan_id"], failed["plan_id"])
        self.assertEqual(self.head(), recorded)

    def test_replacement_filename_that_matches_legacy_option_is_literal(self):
        self.share()
        (self.root / "note.txt").write_text("second conflicting version\n")
        self.share()
        conflict = self.data(self.cli("conflicts"))["data"]["conflicts"][0]
        (self.parent / "--decision").write_bytes(b"explicit combined bytes\r\n")
        result = self.data(self.cli("resolve", conflict["conflict_id"], "--file", "--decision", cwd=self.parent))
        self.assertTrue(result["data"]["retained"])
        self.assertRegex(result["data"]["public_resolution"], r"^[0-9a-f]{64}$")
        self.assertEqual((self.root / "note.txt").read_text(), "second conflicting version\n")

    def test_recorded_file_choice_retries_after_source_is_gone(self):
        self.share()
        (self.root / "note.txt").write_text("second conflicting version\n")
        self.share()
        conflict = self.data(self.cli("conflicts"))["data"]["conflicts"][0]
        replacement = self.parent / "combined.txt"
        replacement.write_bytes(b"recorded exact replacement\r\n")
        plans = self.root / ".yeokcham/integration-plans"
        plans.chmod(0o500)
        try:
            failed = self.data(self.cli("resolve", conflict["conflict_id"], "--file", replacement), 8)
        finally:
            plans.chmod(0o700)
        self.assertFalse(failed["ok"])
        replacement.unlink()
        recorded = self.head()
        version = "resolution:" + failed["data"]["public_resolution"]
        inspection = self.data(self.cli("conflicts", "--plan", conflict["plan_id"]))["data"]
        self.assertIn(version, [row["version_id"] for row in inspection["conflicts"][0]["versions"]])
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing"))
        result = self.data(self.cli("resolve", conflict["conflict_id"], "--use", version, environment=unavailable))
        self.assertEqual(result["plan_id"], failed["plan_id"])
        self.assertEqual(result["data"]["public_resolution"], failed["data"]["public_resolution"])
        self.assertTrue(result["data"]["retained"])
        self.assertEqual(self.head(), recorded)
        self.assertEqual((self.root / "note.txt").read_text(), "second conflicting version\n")

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
        self.assertEqual(result.returncode, 5)
        self.assertEqual(json.loads(result.stdout)["schema_version"], 2)

    def test_conflicted_preview_is_incomplete_and_cannot_accept(self):
        first = self.share()
        (self.root / "note.txt").write_text("different independent addition\n")
        second = self.share()
        before = self.head()
        preview = self.data(self.cli("integrate", "--all", "--preview"))
        self.assertEqual(preview["outcome"], "incomplete")
        self.assertEqual(preview["data"]["readiness"], "conflicted")
        self.assertNotIn("accepted_snapshot", preview["data"])
        conflict = preview["data"]["conflicts"][0]
        self.assertEqual(conflict["path"]["path"], "note.txt")
        self.assertIn(first["revision_id"], conflict["versions"])
        self.assertIn(second["revision_id"], conflict["versions"])
        denied = self.data(self.cli("integrate", "--all", "--yes"), 4)
        self.assertEqual(denied["error"]["code"], "integration-conflicts")
        self.assertEqual(self.head(), before)
        self.assertEqual(self.data(self.cli("status"))["data"]["integration_operations"], [])
        self.assertEqual((self.root / "note.txt").read_text(), "different independent addition\n")

    def test_malformed_ignore_is_invalid_without_plan_or_history_change(self):
        self.share()
        before = self.head()
        (self.root / ".yeokchamignore").write_text("[unterminated\n")
        failed = self.data(self.cli("integrate", "--preview"), 2)
        self.assertEqual(failed["error"]["code"], "invalid-ignore-rule")
        self.assertEqual(self.head(), before)
        self.assertFalse((self.root / ".yeokcham/integration-plans").exists())


if __name__ == "__main__":
    unittest.main()
