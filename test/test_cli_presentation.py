"""Human first-use output, truthful refusal states and the structured-data boundary."""
import json
import fcntl
import os
import pty
from pathlib import Path
import re
import select
import subprocess
import struct
import sys
import tempfile
import termios
import time
import unittest
import unicodedata

BINARY = str(Path(sys.argv.pop(1)).resolve())


class PresentationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yeokcham-presentation-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        self.root = self.parent / "project"
        self.root.mkdir()
        self.keys = self.parent / "signers"
        self.keys.mkdir(mode=0o700)
        self.env = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(self.keys),
                        NO_COLOR="1", TERM="dumb", LC_ALL="C", COLUMNS="40")
        (self.root / "note.txt").write_text("First version\n")
        self.initial = self.run_cli("init").stdout

    def run_cli(self, *arguments, code=0, env=None):
        result = subprocess.run([BINARY, *map(str, arguments), "--root", str(self.root)],
                                capture_output=True, text=True, env=env or self.env, timeout=20)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def data(self, *arguments):
        return json.loads(self.run_cli(*arguments, "--format", "json").stdout)["data"]

    def head(self):
        return (self.root / ".yeokcham/refs/v1-project-state").read_bytes()

    def compact(self, text, lines):
        self.assertNotRegex(text, r"\b[0-9a-f]{32,}\b")
        self.assertNotIn("\x1b", text)
        self.assertLessEqual(len(text.splitlines()), lines)

    def test_real_first_use_journey_is_compact_and_recoverable(self):
        self.compact(self.initial, 20)
        self.assertIn("Project ready", self.initial)
        self.assertNotIn("root-verification-phrase", self.initial)
        words = self.initial.split("Recovery words - shown once\n", 1)[1].split("  Record offline", 1)[0].split()
        self.assertEqual(len(words), 24)
        self.assertTrue(all(re.fullmatch("[a-z]+", word) for word in words))
        (self.root / "note.txt").write_text("Second version\n")
        before = self.head()
        status = self.run_cli("status").stdout
        self.compact(status, 8)
        self.assertIn("main / saved #0", status)
        self.assertIn("M note.txt", status)
        self.assertIn("1 path to save", status)
        diff = self.run_cli("diff").stdout
        self.compact(diff, 7)
        self.assertIn("-First version", diff)
        self.assertIn("+Second version", diff)
        self.assertEqual(self.head(), before)
        saved = self.run_cli("save").stdout
        self.compact(saved, 1)
        self.assertIn("Saved on this device", saved)
        history = self.run_cli("history").stdout
        self.compact(history, 4)
        self.assertIn("* #1", history)
        self.assertIn("o #0", history)
        self.assertIn("No differences", self.run_cli("diff").stdout)
        for command, expected, number in [("undo", "First version\n", 0), ("redo", "Second version\n", 1)]:
            before = self.head()
            preview = self.run_cli(command, "--preview").stdout
            self.compact(preview, 4)
            self.assertIn("Preview only", preview)
            self.assertEqual(self.head(), before)
            result = self.run_cli(command, "--yes").stdout
            self.compact(result, 3)
            self.assertIn(f"Restored saved version #{number}", result)
            self.assertEqual((self.root / "note.txt").read_text(), expected)

    def test_details_and_json_keep_exact_identities_without_resaving(self):
        before = self.head()
        data = self.data("status")
        detailed = self.run_cli("status", "--details").stdout
        self.assertIn(data["saved"]["snapshot_id"], detailed)
        self.assertIn("working-basis", detailed)
        self.assertIn("watcher state not inspected", detailed)
        basic = json.loads(self.run_cli("status", "--format", "json").stdout)
        verbose = json.loads(self.run_cli("status", "--details", "--format", "json").stdout)
        self.assertEqual(basic, verbose)
        self.assertEqual(self.head(), before)
        self.assertNotIn("Recovery words", detailed)
        self.assertIn("root-verification-phrase", self.run_cli("device", "show").stdout)

    def test_incomplete_capture_is_never_rendered_as_clean(self):
        (self.root / ".yeokchamignore").write_text("[bad\n")
        before = self.head()
        output = self.run_cli("status").stdout
        self.assertIn("Changes unknown", output)
        self.assertIn("capture incomplete", output)
        self.assertNotIn("Working files match", output)
        self.assertEqual(self.head(), before)

    def test_alternatives_keep_their_parent_and_short_selectable_numbers(self):
        for value in ["B\n", "C\n"]:
            (self.root / "note.txt").write_text(value)
            self.run_cli("save")
        self.run_cli("undo", "--yes")
        (self.root / "note.txt").write_text("D\n")
        self.run_cli("save")
        output = self.run_cli("history").stdout
        self.assertIn("* #3", output)
        self.assertRegex(output, r"\| o #2")
        self.assertRegex(output, r"\|/ *\n")
        self.assertIn("o #1", output)
        page = self.run_cli("history", "--limit", "2").stdout
        self.assertIn(": #1 (earlier history)", page)
        self.assertIn("--before 2 --limit 2", " ".join(page.split()))
        self.assertNotRegex(output, r"\b[0-9a-f]{32,}\b")
        self.run_cli("restore", "2", "--yes")
        self.assertEqual((self.root / "note.txt").read_text(), "C\n")

    def test_mixed_paths_keep_type_mode_and_opaque_information(self):
        (self.root / "note.txt").chmod(0o755)
        (self.root / "asset.bin").write_bytes(b"\x00binary\xff")
        (self.root / "empty").mkdir()
        (self.root / "link").symlink_to("note.txt")
        output = self.run_cli("status").stdout
        self.assertIn("A asset.bin", output)
        self.assertIn("empty (directory)", output)
        self.assertIn("link (symlink)", output)
        self.assertIn("file -> executable file", output)
        diff = self.run_cli("diff").stdout
        self.assertNotIn("\x00", diff)
        self.assertIn("Text preview unavailable", diff)
        self.run_cli("save")
        (self.root / "link").unlink()
        (self.root / "link").symlink_to("missing-target")
        self.assertIn("Symlink target changed", self.run_cli("diff").stdout)

    def test_terminal_controls_are_escaped_and_json_has_no_styling(self):
        (self.root / "unsafe\x1b[31m.txt").write_text("literal filename\n")
        plain = self.run_cli("status", "--color", "never").stdout
        self.assertNotIn("\x1b", plain)
        colored = self.run_cli("status", "--color", "always").stdout
        self.assertIn("\x1b[", colored)
        self.assertNotIn("unsafe\x1b", colored)
        machine = self.run_cli("status", "--color", "always", "--format", "json").stdout
        self.assertNotIn("\x1b", machine)
        self.assertEqual(json.loads(machine)["schema_version"], 2)

    def test_details_option_does_not_consume_literal_values(self):
        root = self.parent / "--details"
        root.mkdir()
        result = subprocess.run([BINARY, "init", "--root", str(root), "--title", "--details"],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Project ready", result.stdout)
        self.assertNotIn("root-verification-phrase", result.stdout)
        duplicate = self.run_cli("status", "--details", "--details", code=2)
        self.assertIn("only once", duplicate.stderr)

    def test_unavailable_history_stays_visible_in_compact_output(self):
        (self.root / "note.txt").write_text("B\n")
        self.run_cli("save")
        saved = self.data("history")["entries"][0]["snapshot_id"]
        (self.root / "note.txt").write_text("C\n")
        self.run_cli("save")
        (self.root / ".yeokcham/objects" / saved[:2] / saved[2:4] / saved[4:]).unlink()
        before = self.head()
        output = self.run_cli("history").stdout
        self.assertIn("Contents unavailable", output)
        self.assertIn("* #2", output)
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "note.txt").read_text(), "C\n")

    def terminal(self, *arguments, env=None, columns=80, descriptors=None):
        master, slave = descriptors or pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, columns, 0, 0))
        process = subprocess.Popen([BINARY, *map(str, arguments), "--root", str(self.root)],
                                   env=env or self.env, stdin=subprocess.DEVNULL,
                                   stdout=slave, stderr=subprocess.PIPE)
        result = bytearray()
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.05)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    result.extend(chunk)
                elif process.poll() is not None:
                    break
            self.assertEqual(process.wait(timeout=2), 0, process.stderr.read().decode())
            return result.decode().replace("\r\n", "\n")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stderr.close()
            if descriptors is None:
                os.close(master)
                os.close(slave)

    def test_real_terminal_color_and_glyph_fallbacks(self):
        native = dict(self.env, LC_ALL="C.UTF-8", TERM="xterm-256color")
        native.pop("NO_COLOR", None)
        colored = self.terminal("status", env=native)
        self.assertIn("\x1b[", colored)
        self.assertIn("✓", colored)
        plain = self.terminal("status", env=dict(native, NO_COLOR="1"))
        self.assertNotIn("\x1b", plain)
        self.assertIn("✓", plain)
        ascii_only = self.terminal("status", env=dict(native, TERM="dumb", LC_ALL="C"))
        self.assertNotIn("\x1b", ascii_only)
        self.assertNotIn("✓", ascii_only)

    def test_actual_terminal_resize_overrides_stale_or_missing_columns(self):
        text = "é你好 " + "long content " * 17 + "end-of-line"
        (self.root / "note.txt").write_text(text)
        before = self.head()
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        for width in [120, 60, 24, 100, 40, 140]:
            env = dict(self.env, COLUMNS="240", TERM="xterm-256color", LC_ALL="C.UTF-8")
            if width == 40:
                env.pop("COLUMNS")
            diff = self.terminal("diff", columns=width, env=env, descriptors=(master, slave))
            self.assertEqual("Before" in diff and "After" in diff, width >= 100)
            self.assertIn("é你好", diff)
            self.assertIn("No newline", diff)
            for command in [("history",), ("status",), ("undo", "--preview")]:
                output = self.terminal(*command, columns=width, env=env, descriptors=(master, slave))
                self.assert_lines_fit(output, width)
            self.assert_lines_fit(diff, width)
        self.assertEqual(self.head(), before)
        self.assertEqual((self.root / "note.txt").read_text(), text)

    def assert_lines_fit(self, text, columns):
        plain = re.sub(r"\x1b\[[0-9;]*m", "", text)
        for line in plain.splitlines():
            cells = sum(0 if unicodedata.combining(c) else
                        2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in line)
            self.assertLessEqual(cells, columns, repr(line))

    def test_numbered_diff_keeps_wrapped_contents_and_exact_json(self):
        content = "a" * 143 + "end-old"
        (self.root / "note.txt").write_text(content)
        self.run_cli("save")
        changed = "b" * 168 + "end-new"
        (self.root / "note.txt").write_text(changed)
        original_data = self.data("diff")
        for width in [24, 40, 80, 99, 100, 120, 200]:
            env = dict(self.env, COLUMNS=str(width))
            output = self.run_cli("diff", env=env).stdout
            self.assert_lines_fit(output, width)
            self.assertIn("+1 -1", output)
            # reconstruct each displayed source line, including wrapped pieces.
            if width < 100:
                old, new, destination = [], [], None
                for row in output.splitlines():
                    match = re.match(r"\s*(\d*)\s+(\d*)\s*([-+>])(.*)", row)
                    if not match:
                        continue
                    marker, chunk = match[3], match[4]
                    if marker != ">":
                        destination = old if marker == "-" else new
                    destination.append(chunk)
                self.assertEqual("".join(old), content)
                self.assertEqual("".join(new), changed)
            else:
                left_width = (width - 3) // 2
                old, new = [], []
                for row in output.splitlines():
                    if len(row) <= left_width or row[left_width:left_width + 3] != " | ":
                        continue
                    for cell, destination in [(row[:left_width], old), (row[left_width + 3:], new)]:
                        match = re.match(r"[ 0-9]+ [-+>](.*)", cell)
                        if match:
                            destination.append(match[1].rstrip())
                self.assertEqual("".join(old), content)
                self.assertEqual("".join(new), changed)
            self.assertEqual(self.data("diff"), original_data)

    def test_many_alternatives_use_honest_parent_fallback_in_tiny_terminal(self):
        (self.root / "note.txt").write_text("B\n")
        self.run_cli("save")
        for value in ["C", "D", "E", "F"]:
            (self.root / "note.txt").write_text(value + "\n")
            self.run_cli("save")
            self.run_cli("restore", "1", "--yes")
        before = self.head()
        output = self.run_cli("history", env=dict(self.env, COLUMNS="24")).stdout
        self.assertIn("parent #1", output)
        self.assertIn("* #1", output)
        self.assert_lines_fit(output, 24)
        entries = self.data("history")["entries"]
        self.assertEqual([e["sequence"] for e in entries], ["5", "4", "3", "2", "1", "0"])
        self.assertEqual(len({e["parent"] for e in entries[:4]}), 1)
        self.assertEqual(self.head(), before)

    def test_equal_snapshots_remain_distinct_connected_versions(self):
        for value in ["B\n", "First version\n"]:
            (self.root / "note.txt").write_text(value)
            self.run_cli("save")
        rows = self.data("history")["entries"]
        self.assertEqual(rows[0]["snapshot_id"], rows[-1]["snapshot_id"])
        self.assertNotEqual(rows[0]["id"], rows[-1]["id"])
        output = self.run_cli("history").stdout
        self.assertRegex(output, r"\* #2 .*\no #1 .*\no #0 ")
        self.assertIn("No differences", self.run_cli("diff", "0", "2").stdout)

    def test_secondary_text_uses_readable_foreground_and_controls_stay_escaped(self):
        (self.root / "note.txt").write_text("hello\tworld\r\n\x1b[2Jdanger\n")
        for command in [("history",), ("diff",), ("undo", "--preview")]:
            colored = self.run_cli(*command, "--color", "always").stdout
            self.assertNotIn("\x1b[90m", colored)
            self.assertNotIn("\x1b[2m", colored)
            self.assertNotIn("\x1b[2J", colored)
        diff = self.run_cli("diff", env=dict(self.env, COLUMNS="120")).stdout
        self.assertIn("\\x1b[2Jdanger", diff)
        self.assertIn("\\r", diff)

    def test_json_is_indented_only_for_a_real_terminal(self):
        before = self.head()
        piped = self.run_cli("status", "--format", "json").stdout
        terminal = self.terminal("status", "--format", "json", "--color", "always", columns=80)
        self.assertEqual(len(piped.splitlines()), 1)
        self.assertGreater(len(terminal.splitlines()), 10)
        self.assertEqual(json.loads(terminal), json.loads(piped))
        self.assertNotIn("\x1b", terminal)
        self.assertEqual(self.head(), before)


if __name__ == "__main__":
    unittest.main()
