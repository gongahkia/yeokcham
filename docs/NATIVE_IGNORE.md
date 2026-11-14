# Native ignore rules

Capture uses `.yeokchamignore` in the workspace root and included subdirectories.
It does not read `.gitignore`, global Git rules or invoke Git. Files of any
extension are captured unless a native rule excludes them. Root `.git` and
Yeokcham metadata remain excluded even when a negation would otherwise include them.

Rules apply from ancestor files to descendant files, in line order. The last
applicable match wins. An excluded directory is not visited; re-include it before
trying to re-include a child. Nested rules apply only within their directory.
Ignore files are themselves captured unless a rule excludes them.

| Syntax | Meaning |
| --- | --- |
| `name` | Match that basename anywhere below this rule file |
| `/name` | Match relative to this rule file's directory |
| `src/*.ml` | Slash-containing patterns are relative to the rule file |
| `cache/` | Match directories named cache and exclude their subtree |
| `*`, `?`, `[a-z]`, `[!a-z]` | Match bytes within one path component |
| `**/draft.txt` | A whole `**` component matches zero or more directory components |
| `!pattern` | Re-include a matching entry, provided its parents are included |
| `\#note`, `\!name`, `literal\*` | Backslash quotes the following pattern byte |
| `# comment` | An unescaped leading hash starts a comment |

Empty lines are ignored. Unescaped trailing spaces are trimmed; `name\ ` matches
a name ending in a space. Names, path bytes and captured file contents are not
normalized or converted. CRLF line endings in the rule file are accepted.
Malformed syntax stops capture and reports the file/line; it does not silently
fall back to a different rule set or replace the last saved history state.
Rule files are bounded to the scanner's 64-KiB inline limit and individual rules
to 4,096 bytes; oversized inputs report an error, without truncation.

For example:

```text
*.tmp
cache/
!cache/
cache/*
!cache/keep.txt
```

This excludes temporary files and cache entries while keeping `cache/keep.txt`.
A nested file can add `!keep.tmp` to include that basename within its own scope.

Inspect a decision with:

```sh
yeokcham ignore explain src/notes.tmp
yeokcham ignore explain cache/ --format json
```

The result names the winning rule and file/line, or a mandatory metadata
exclusion. A trailing slash supplies a directory hint for a path that does not
exist yet. An excluded parent is reported directly; the command does not read
rule files inside that excluded subtree. It creates no repository, checkpoint
or scan objects. JSON provides actual path/rule data, not only completion.

Changing rules affects future capture. It does not remove previously saved
history or delete live files. Local switch/undo/redo/restore preserve noncolliding ignored files. A target
covering an ignored or untracked obstruction refuses before replacement; use a
separate recovery copy or move the obstruction explicitly. See [Local undo](LOCAL_UNDO.md).

Capture opens child entries relative to their parent directory descriptor and
refuses to follow symlinks. It records symlink target bytes instead. It compares
file identity, mode, size and nanosecond modification/change times before and
after reading, checks directory entries again, and rechecks observed paths and
ignore configuration before storing the snapshot. A replaced root is refused.
Detected instability restarts the complete scan at most three times; continued
changes return an incomplete-capture error and leave the saved head alone.
Large files use bounded streaming reads rather than a file-sized buffer. FIFOs,
sockets and device files are refused without reading their contents.

These checks observe a live filesystem; they do not freeze other programs or
provide a filesystem transaction. An edit after the final observation belongs
to the next capture. The native descriptor adapter is implemented for POSIX;
this checkpoint was exercised on Linux, with macOS execution still unverified.
