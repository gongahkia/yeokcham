"""Selected native publication through fresh CLI processes; disposable signers."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class NativeShareCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yeokcham-native-share-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        self.root = self.parent / "project"
        self.root.mkdir()
        self.keys = self.parent / "signers"
        self.keys.mkdir(mode=0o700)
        self.environment = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.keys))
        (self.root / "private.txt").write_text("PRIVATE SENTINEL never selected\n")
        (self.root / "note.txt").write_text("private initial note\n")
        result = self.cli("init", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def cli(self, *args, machine=False, environment=None):
        arguments = list(map(str, args))
        if machine:
            position = arguments.index("--") if "--" in arguments else len(arguments)
            arguments[position:position] = ["--format", "json"]
        return subprocess.run([BINARY, *arguments], env=environment or self.environment,
                              capture_output=True, text=True, timeout=20)

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def share(self, *args, machine=True):
        result = self.cli("share", "--root", self.root, *args, machine=machine)
        self.assertEqual(result.returncode, 0, result.stderr)
        if not machine:
            return result.stdout
        body = json.loads(result.stdout)
        self.assertEqual(body["schema_version"], 2)
        self.assertNotIn("\x1b[", result.stdout)
        return body

    def test_capture_selected_bytes_generated_ids_and_recorded_retry(self):
        (self.root / "note.txt").write_text("unsaved selected D\n")
        first = self.share("note.txt", "--title", "Selected note")
        data = first["data"]
        self.assertRegex(data["change_id"], r"^[0-9a-f]{32}$")
        self.assertRegex(data["revision_id"], r"^[0-9a-f]{64}$")
        self.assertRegex(first["operation_id"], r"^[0-9a-f]{32}$")
        self.assertTrue(data["captures_unsaved"])
        self.assertFalse(data["accepted"])
        self.assertEqual(data["transfer_state"], "pending")
        self.assertEqual([p["path"] for p in data["public_paths"]], ["note.txt"])
        self.assertEqual((self.root / "private.txt").read_text(), "PRIVATE SENTINEL never selected\n")
        recorded_head = self.head()
        repeated = self.share("note.txt", "--title", "Selected note")
        self.assertTrue(repeated["data"]["repeated"])
        self.assertEqual(repeated["data"]["revision_id"], data["revision_id"])
        self.assertEqual(repeated["operation_id"], first["operation_id"])
        self.assertEqual(self.head(), recorded_head)
        status = self.cli("status", "--root", self.root, machine=True)
        self.assertEqual(status.returncode, 0, status.stderr)
        state = json.loads(status.stdout)["data"]
        self.assertEqual(state["shared_revisions"][0]["revision_id"], data["revision_id"])
        self.assertEqual(state["local_publications"][0]["operation_id"], first["operation_id"])
        self.assertEqual(state["local_publications"][0]["transfer_state"], "pending")
        self.assertRegex(state["working_basis"], r"^[0-9a-f]{64}$")

    def test_preview_requires_no_signer_and_preserves_history(self):
        (self.root / "note.txt").write_text("preview unsaved\n")
        before = self.head()
        unavailable = dict(self.environment, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.parent / "missing-signers"))
        result = self.cli("share", "note.txt", "--root", self.root, "--preview", machine=True, environment=unavailable)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = json.loads(result.stdout)
        self.assertTrue(body["data"]["preview"])
        self.assertIsNone(body["data"]["change_id"])
        self.assertIsNone(body["data"]["revision_id"])
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "note.txt").read_text(), "preview unsaved\n")
        denied = self.cli("share", "note.txt", "--root", self.root, machine=True, environment=unavailable)
        self.assertEqual(denied.returncode, 5, denied.stderr)
        self.assertEqual(self.head(), before)

    def test_plain_share_and_explicit_update(self):
        first = self.share("note.txt")
        (self.root / "note.txt").write_text("explicit second revision\n")
        (self.root / "private.txt").write_text("private E after first share\n")
        second = self.share("--update", first["data"]["change_id"], "note.txt")
        self.assertEqual(first["data"]["change_id"], second["data"]["change_id"])
        self.assertNotEqual(first["data"]["revision_id"], second["data"]["revision_id"])
        self.assertEqual([p["path"] for p in second["data"]["public_paths"]], ["note.txt"])
        self.assertEqual((self.root / "private.txt").read_text(), "private E after first share\n")
        (self.root / "note.txt").write_text("third independent change\n")
        plain = self.share("./note.txt", machine=False)
        self.assertIn("change ", plain)
        self.assertIn("revision ", plain)
        self.assertIn("transfer pending", plain)
        self.assertIn("Share note.txt", plain)

    def test_same_content_explicit_update_has_new_version_and_exact_retry(self):
        first = self.share("note.txt", "--title", "First title")
        second = self.share("--update", first["data"]["change_id"], "note.txt", "--title", "Revised title")
        self.assertEqual(first["data"]["public_snapshot"], second["data"]["public_snapshot"])
        self.assertNotEqual(first["data"]["revision_id"], second["data"]["revision_id"])
        self.assertEqual(second["data"]["contributed_paths"], [])
        head = self.head()
        repeated = self.share("--update", first["data"]["change_id"], "note.txt", "--title", "Revised title")
        self.assertTrue(repeated["data"]["repeated"])
        self.assertEqual(repeated["data"]["revision_id"], second["data"]["revision_id"])
        self.assertEqual(repeated["operation_id"], second["operation_id"])
        self.assertEqual(self.head(), head)

    def test_root_selection_mixed_streamed_types_and_ignore(self):
        (self.root / ".yeokchamignore").write_text("private.txt\nignored.bin\n")
        (self.root / "ignored.bin").write_bytes(b"IGNORE SENTINEL")
        (self.root / "opaque.bin").write_bytes(bytes(range(256)) * 10000)
        (self.root / "empty").mkdir()
        (self.root / "link").symlink_to("note.txt")
        (self.root / "script").write_text("#!/bin/sh\nexit 0\n")
        (self.root / "script").chmod(0o755)
        shared = self.share("./")
        paths = {entry["path"] for entry in shared["data"]["public_paths"]}
        self.assertTrue({"note.txt", "opaque.bin", "empty", "link", "script"}.issubset(paths))
        self.assertNotIn("private.txt", paths)
        self.assertNotIn("ignored.bin", paths)

    def test_invalid_ignore_selection_and_paths_preserve_root(self):
        (self.root / ".yeokchamignore").write_text("private.txt\n")
        before = self.head()
        for args in [("private.txt",), ("../outside",), ("--update", "bad", "note.txt"), ("unknown.txt",)]:
            result = self.cli("share", "--root", self.root, *args, machine=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(self.head(), before)
            self.assertEqual(json.loads(result.stdout)["schema_version"], 2)
        (self.root / ".yeokchamignore").write_text("[bad\n")
        result = self.cli("share", "--root", self.root, machine=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.head(), before)

    def test_literal_option_filename_and_help(self):
        (self.root / "--change").write_text("literal selected path\n")
        result = self.share("--", "--change")
        self.assertEqual([p["path"] for p in result["data"]["public_paths"]], ["--change"])
        help_result = self.cli("help", "share")
        self.assertEqual(help_result.returncode, 0)
        for word in ["[PATH...]", "--update", "--preview", "identities are generated"]:
            self.assertIn(word, help_result.stdout)

    def test_preview_and_recorded_retry_do_not_repeat_explicit_share_hook(self):
        marker = self.parent / "hook-observations"
        script = self.parent / "observer.py"
        script.write_text("from pathlib import Path\nimport sys\nwith Path(sys.argv[1]).open('a') as out: out.write('observed\\n')\n")
        added = self.cli("hook", "add", "--root", self.root, "--event", "share", "--", sys.executable, script, marker)
        self.assertEqual(added.returncode, 0, added.stderr)
        self.share("note.txt", "--preview")
        self.assertFalse(marker.exists())
        self.share("note.txt")
        self.assertEqual(marker.read_text(), "observed\n")
        self.share("note.txt")
        self.assertEqual(marker.read_text(), "observed\n")


if __name__ == "__main__":
    unittest.main()
