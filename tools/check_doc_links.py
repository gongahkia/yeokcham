#!/usr/bin/env python3
"""Check repository Markdown links to local files without network access."""

from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def main():
    root = Path(__file__).resolve().parent.parent
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    ).decode().split("\0")
    failures = []
    checked = 0
    for name in sorted(set(names)):
        source = root / name
        if source.suffix.lower() != ".md" or not source.is_file():
            continue
        # Ignore illustrative links in code fences. Both inline and reference
        # destinations are supported; heading fragments are deliberately not
        # interpreted as files.
        fenced = None
        for number, line in enumerate(source.read_text().splitlines(), 1):
            fence = re.match(r"\s*(`{3,}|~{3,})", line)
            if fence:
                marker = fence.group(1)[0]
                fenced = None if fenced == marker else marker
                continue
            if fenced:
                continue
            destinations = re.findall(
                r"\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)", line
            )
            reference = re.match(r"\s*\[[^]]+\]:\s*(<[^>]+>|\S+)", line)
            if reference:
                destinations.append(reference.group(1))
            for destination in destinations:
                target = urlsplit(destination.strip("<>"))
                if target.scheme or target.netloc or not target.path:
                    continue
                checked += 1
                if not (source.parent / unquote(target.path)).exists():
                    failures.append(f"{name}:{number}: missing {destination}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Documentation links passed ({checked} local file references)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
