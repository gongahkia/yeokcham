"""Fresh CLI processes for private initialization and named local branches.

The explicit test signer lives outside the workspace and never represents
native credential-store or managed-service acceptance.
"""
import json
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


if __name__ == "__main__":
    unittest.main()
