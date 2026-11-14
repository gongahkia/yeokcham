"""Fresh CLI processes for private initialization and named local branches.

The explicit test signer lives outside the workspace and never represents
native credential-store or managed-service acceptance.
"""
import json
import pty
import select
import time
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class LocalBranchCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yeokcham-local-branch-")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "project"
        self.keys = self.parent / "test-signers"
        self.keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.keys))

    def run_cli(self, *arguments, machine=False):
        command = [BINARY, *map(str, arguments)]
        if machine:
            command += ["--format", "json"]
        return subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=15)

    def initialize(self):
        self.root.mkdir()
        (self.root / "notes.txt").write_bytes(b"initial private text\n")
        (self.root / "opaque.bin").write_bytes(bytes(range(256)))
        result = self.run_cli("init", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("initial files remain private", result.stdout)
        self.assertIn("automatic-capture not configured", result.stdout)
        self.assertIn("private-backup not configured", result.stdout)
        return result

    def branches(self):
        result = self.run_cli("branch", "list", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b[", result.stdout)
        return json.loads(result.stdout)["result"]

    def head_bytes(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def test_generated_names_and_ids_survive_restart(self):
        self.initialize()
        first = self.branches()
        self.assertRegex(first["workspace_id"], r"^[0-9a-f]{32}$")
        self.assertRegex(first["selected_branch_id"], r"^[0-9a-f]{32}$")
        self.assertEqual(len(first["branches"]), 1)
        branch = first["branches"][0]
        self.assertEqual(branch["names"], ["main"])
        self.assertTrue(branch["selected"])
        self.assertEqual(branch["private_position"]["sequence"], "0")
        self.assertRegex(branch["accepted_heads"][0], r"^[0-9a-f]{64}$")
        self.assertEqual(first, self.branches())
        plain = self.run_cli("branch", "list", "--root", self.root)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn(first["selected_branch_id"], plain.stdout)
        self.assertEqual((self.root / "opaque.bin").read_bytes(), bytes(range(256)))

    def test_creation_captures_unsaved_work_without_retargeting_or_selecting(self):
        self.initialize()
        first = self.branches()
        (self.root / "notes.txt").write_text("unsaved continuation\n")
        (self.root / "opaque.bin").write_bytes(b"\x00\xffalternative")
        result = self.run_cli("branch", "create", "experiment", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        created = json.loads(result.stdout)["result"]
        self.assertEqual(created["selected_branch_id"], first["selected_branch_id"])
        self.assertEqual(created["workspace_id"], first["workspace_id"])
        self.assertEqual(len(created["branches"]), 2)
        for branch in created["branches"]:
            self.assertEqual(branch["private_position"]["sequence"], "1")
        main = next(branch for branch in created["branches"] if branch["names"] == ["main"])
        self.assertEqual(main["accepted_heads"], first["branches"][0]["accepted_heads"])
        listed = self.branches()
        self.assertEqual(created["branches"], listed["branches"])
        self.assertEqual(created["selected_branch_id"], listed["selected_branch_id"])
        self.assertEqual(created["workspace_id"], listed["workspace_id"])
        experiment = next(branch for branch in created["branches"] if branch["names"] == ["experiment"])
        self.assertEqual(created["created_branch_id"], experiment["id"])
        self.assertIsNone(listed["created_branch_id"])
        before = self.head_bytes()
        duplicate = self.run_cli("branch", "create", "experiment", "--root", self.root, machine=True)
        self.assertEqual(duplicate.returncode, 2, duplicate.stderr)
        self.assertEqual(json.loads(duplicate.stdout)["error"]["code"], "branch-name-exists")
        self.assertEqual(before, self.head_bytes())
        self.assertEqual((self.root / "opaque.bin").read_bytes(), b"\x00\xffalternative")

    def test_incomplete_capture_retains_branch_state_and_history_root(self):
        self.initialize()
        original = self.branches()
        before = self.head_bytes()
        (self.root / ".yeokchamignore").write_text("# heading\n[malformed\n")
        result = self.run_cli("branch", "create", "blocked", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        failure = json.loads(result.stdout)["error"]
        self.assertEqual(failure["code"], "invalid-ignore-rule")
        self.assertIn(":2:", failure["message"])
        self.assertEqual(before, self.head_bytes())
        self.assertEqual(original, self.branches())

    def test_invalid_branch_name_is_an_argument_error(self):
        self.initialize()
        before = self.head_bytes()
        for name in ["", "x" * 1025]:
            result = self.run_cli("branch", "create", name, "--root", self.root, machine=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalid-branch-name")
            self.assertEqual(before, self.head_bytes())

    def test_missing_signer_is_unavailable_and_does_not_create_a_branch(self):
        self.initialize()
        before = self.head_bytes()
        for key in self.keys.iterdir():
            key.unlink()
        result = self.run_cli("branch", "create", "blocked", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 5, result.stderr)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["outcome"], "unavailable")
        self.assertEqual(envelope["code"], "credential-provider-unavailable")
        self.assertEqual(len(self.branches()["branches"]), 1)
        self.assertEqual(before, self.head_bytes())

    def test_private_ceremony_refuses_json_before_mutation(self):
        result = self.run_cli("init", self.root, machine=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "recovery-ceremony-requires-text")
        self.assertFalse(self.root.exists())
        self.assertEqual(list(self.keys.iterdir()), [])

    def test_reinitialization_refuses_before_creating_another_signer(self):
        self.initialize()
        before = self.head_bytes()
        keys = sorted(p.name for p in self.keys.iterdir())
        result = self.run_cli("init", self.root)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(before, self.head_bytes())
        self.assertEqual(keys, sorted(p.name for p in self.keys.iterdir()))

    def test_init_creates_requested_directory_and_help_is_complete(self):
        result = self.run_cli("init", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / ".yeokcham").is_dir())
        self.assertEqual(self.branches()["branches"][0]["names"], ["main"])
        for command in ["branch", "branch list", "branch create"]:
            result = self.run_cli("help", *command.split())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("usage:", result.stdout)

    def make_topic(self):
        result = self.run_cli("branch", "create", "topic", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["data"]

    def test_switch_choice_preview_and_confirmed_mixed_journey(self):
        self.initialize()
        original_notes = (self.root / "notes.txt").read_bytes()
        original_binary = (self.root / "opaque.bin").read_bytes()
        self.make_topic()
        (self.root / "notes.txt").write_bytes(b"B unsaved\n")
        (self.root / "opaque.bin").write_bytes(b"\0\xffprivate B")
        before = self.head_bytes()
        choice = self.run_cli("switch", "topic", "--root", self.root, machine=True)
        self.assertEqual(choice.returncode, 3, choice.stderr)
        value = json.loads(choice.stdout)
        self.assertEqual(value["schema_version"], 2)
        self.assertEqual(value["code"], "confirmation-required")
        self.assertFalse(value["ok"])
        self.assertFalse(value["data"]["applied"])
        self.assertTrue(value["data"]["captures_unsaved"])
        self.assertEqual({row["path"] for row in value["data"]["changes"]}, {"notes.txt", "opaque.bin"})
        self.assertTrue(any("--yes" in a["arguments"] and a["confirmation_required"] for a in value["next_actions"]))
        self.assertEqual(self.head_bytes(), before)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"B unsaved\n")
        preview = self.run_cli("switch", "topic", "--root", self.root, "--preview", machine=True)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)["code"], "switch-preview")
        self.assertEqual(self.head_bytes(), before)
        self.assertFalse((self.root / ".yeokcham/restore-staging").exists())
        selected = self.run_cli("switch", "topic", "--root", self.root, "--yes", machine=True)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        data = json.loads(selected.stdout)["data"]
        self.assertTrue(data["applied"])
        self.assertEqual(data["target_history"]["sequence"], "0")
        self.assertRegex(data["target_history"]["id"], r"^[0-9a-f]{32}:0$")
        self.assertRegex(data["recovery"]["operation_id"], r"^[0-9a-f]{64}$")
        self.assertTrue((self.root / data["recovery"]["retained_directory_relative"]).is_dir())
        self.assertEqual((self.root / "notes.txt").read_bytes(), original_notes)
        self.assertEqual((self.root / "opaque.bin").read_bytes(), original_binary)
        (self.root / "notes.txt").write_bytes(b"C topic\n")
        result = self.run_cli("switch", "main", "--root", self.root, "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("selected branch:", result.stdout)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"B unsaved\n")
        result = self.run_cli("switch", "topic", "--root", self.root, "--yes", machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"C topic\n")
        self.assertEqual(next(b for b in self.branches()["branches"] if b["selected"])["names"], ["topic"])

    def test_switch_same_branch_is_unchanged_and_needs_no_confirmation(self):
        self.initialize()
        (self.root / "notes.txt").write_bytes(b"unrecorded edits")
        before = self.head_bytes()
        for flags in [[], ["--yes"]]:
            result = self.run_cli("switch", "main", "--root", self.root, *flags, machine=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data["outcome"], "unchanged")
            self.assertFalse(data["data"]["applied"])
            self.assertEqual(self.head_bytes(), before)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"unrecorded edits")

    def test_switch_preserves_noncolliding_ignored_bytes(self):
        self.initialize()
        (self.root / ".yeokchamignore").write_text("cache\n")
        self.run_cli("save", "--root", self.root)
        self.make_topic()
        (self.root / "notes.txt").write_bytes(b"private")
        (self.root / "cache").write_bytes(b"ignored\0bytes")
        inode = (self.root / "cache").stat().st_ino
        result = self.run_cli("switch", "topic", "--root", self.root, "--yes", machine=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "cache").read_bytes(), b"ignored\0bytes")
        self.assertEqual((self.root / "cache").stat().st_ino, inode)

    def test_switch_ignored_obstruction_is_conflict_before_replacement(self):
        self.initialize()
        (self.root / ".yeokchamignore").write_text("*.private\n")
        (self.root / "node").write_bytes(b"target file")
        self.run_cli("save", "--root", self.root)
        self.make_topic()
        (self.root / "node").unlink()
        (self.root / "node").mkdir()
        (self.root / "node/secret.private").write_bytes(b"must survive")
        before = self.head_bytes()
        result = self.run_cli("switch", "topic", "--root", self.root, "--yes", machine=True)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(json.loads(result.stdout)["code"], "selection-conflict")
        self.assertEqual(self.head_bytes(), before)
        self.assertEqual((self.root / "node/secret.private").read_bytes(), b"must survive")

    def test_switch_unknown_name_does_not_retarget(self):
        self.initialize()
        before = self.head_bytes()
        result = self.run_cli("switch", "missing", "--root", self.root, "--yes", machine=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["code"], "unknown-branch")
        self.assertEqual(self.head_bytes(), before)

    def test_interactive_switch_cancel_leaves_root_and_files(self):
        self.initialize()
        self.make_topic()
        (self.root / "notes.txt").write_bytes(b"private pending")
        before = self.head_bytes()
        master, slave = pty.openpty()
        process = subprocess.Popen([BINARY, "switch", "topic", "--root", str(self.root)], env=self.environment,
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        os.close(slave)
        try:
            os.write(master, b"n\n")
            stdout, stderr = process.communicate(timeout=15)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("cancelled", stdout)
        self.assertEqual(self.head_bytes(), before)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"private pending")

    def test_confirmed_switch_refuses_stale_working_tree(self):
        self.initialize()
        self.make_topic()
        (self.root / "notes.txt").write_bytes(b"preview source")
        before = self.head_bytes()
        master, slave = pty.openpty()
        process = subprocess.Popen([BINARY, "switch", "topic", "--root", str(self.root)], env=self.environment,
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.close(slave)
        try:
            prompt = b""
            deadline = time.monotonic() + 15
            while b"[y/N]" not in prompt and time.monotonic() < deadline:
                readable, _, _ = select.select([process.stderr], [], [], 0.2)
                if readable:
                    chunk = os.read(process.stderr.fileno(), 1024)
                    if not chunk:
                        break
                    prompt += chunk
            self.assertIn(b"[y/N]", prompt)
            (self.root / "notes.txt").write_bytes(b"external edit after preview")
            os.write(master, b"y\n")
            stdout, stderr = process.communicate(timeout=15)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 3, stderr)
        self.assertIn(b"after preview", stderr)
        self.assertEqual(self.head_bytes(), before)
        self.assertEqual((self.root / "notes.txt").read_bytes(), b"external edit after preview")


    def test_switch_plan_refuses_changed_inputs_and_applies_exact_preview(self):
        self.initialize()
        self.make_topic()
        preview = self.run_cli("switch", "topic", "--preview", "--root", self.root, machine=True)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        plan = json.loads(preview.stdout)["plan_id"]
        before = self.head_bytes()
        (self.root / "notes.txt").write_bytes(b"changed after preview")
        refused = self.run_cli("switch", "topic", "--yes", "--plan", plan, "--root", self.root, machine=True)
        self.assertEqual(refused.returncode, 3, refused.stderr)
        self.assertEqual(before, self.head_bytes())
        preview = self.run_cli("switch", "topic", "--preview", "--root", self.root, machine=True)
        plan = json.loads(preview.stdout)["plan_id"]
        selected = self.run_cli("switch", "topic", "--yes", "--plan", plan, "--root", self.root, machine=True)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(json.loads(selected.stdout)["plan_id"], plan)

    def test_leading_dash_branch_name_actions_keep_literal_arguments(self):
        self.initialize()
        result = self.run_cli("branch", "create", "--root", self.root, "--format", "json", "--", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        preview = self.run_cli("switch", "--root", self.root, "--preview", "--format", "json", "--", "--yes")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        data = json.loads(preview.stdout)
        action = data["next_actions"][0]["arguments"]
        self.assertEqual(action[-2:], ["--", "--yes"])
        result = self.run_cli(*action[1:])
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = next(branch for branch in self.branches()["branches"] if branch["selected"])
        self.assertEqual(selected["names"], ["--yes"])


if __name__ == "__main__":
    unittest.main()
