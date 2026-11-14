"""Exercise native exclusion explanations through fresh CLI processes."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class IgnoreCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yeokcham-ignore-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_command(self, path, *, machine=True):
        args = [BINARY, "ignore", "explain", path, "--root", str(self.root)]
        if machine:
            args += ["--format", "json"]
        return subprocess.run(args, capture_output=True, text=True, timeout=10)

    def test_nested_rule_has_real_domain_data_without_repository_mutation(self):
        (self.root / ".yeokchamignore").write_text("*.tmp\n")
        (self.root / "src").mkdir()
        (self.root / "src/.yeokchamignore").write_text("!keep.tmp\n")
        (self.root / "src/keep.tmp").write_text("private content")
        result = self.run_command("src/keep.tmp")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)["result"]
        self.assertEqual(data["path"], "src/keep.tmp")
        self.assertFalse(data["ignored"])
        self.assertEqual((data["source"], data["line"]), ("src/.yeokchamignore", 1))
        self.assertEqual(data["pattern"], "!keep.tmp")
        self.assertFalse((self.root / ".yeokcham").exists())
        self.assertEqual((self.root / "src/keep.tmp").read_text(), "private content")

    def test_parent_and_directory_hint(self):
        (self.root / ".yeokchamignore").write_text("cache/\n!cache/keep.txt\n")
        for path in ["cache/", "cache/keep.txt"]:
            result = self.run_command(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)["result"]
            self.assertTrue(data["ignored"])
            self.assertEqual(data["line"], 1)
        self.assertTrue(data["blocked_by_parent"])

    def test_malformed_config_and_missing_root_fail_explicitly(self):
        (self.root / ".yeokchamignore").write_text("# heading\n[broken\n")
        result = self.run_command("note")
        self.assertEqual(result.returncode, 2)
        data = json.loads(result.stdout)
        self.assertEqual(data["error"]["code"], "invalid-ignore-rule")
        self.assertIn(":2:", data["error"]["message"])
        self.assertFalse((self.root / ".yeokcham").exists())
        self.root = self.root / "missing"
        result = self.run_command("note")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "ignore-inspection-unavailable")

    def test_metadata_and_untrusted_path_text(self):
        (self.root / ".yeokchamignore").write_text("*.tmp\n!.git/\n")
        result = self.run_command(".git/config")
        self.assertTrue(json.loads(result.stdout)["result"]["mandatory"])
        result = self.run_command("a\nb.tmp", machine=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"a\\nb.tmp"', result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
