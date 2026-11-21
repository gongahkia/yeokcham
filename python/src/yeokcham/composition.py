"""Pure byte-preserving line-hunks-v1 and logical tree values; no filesystem IO."""

import itertools
from array import array
from collections.abc import Mapping
from dataclasses import dataclass

from .content import Mode
from .errors import Code, ContentError
from .normalization_budget import Counter, Limits, Path

__all__ = [
    "Mode",
    "Node",
    "Path",
    "State",
    "Tree",
    "merge_bytes",
    "merge_state",
    "state_key",
    "structural_conflicts",
    "tree",
    "valid_path",
]


@dataclass(frozen=True)
class Node:
    mode: Mode | None = None
    data: bytes = b""

    def __post_init__(self) -> None:
        if type(self.data) is not bytes or (
            self.mode is not None and type(self.mode) is not Mode
        ):
            raise ContentError(Code.INVALID_CONTENT, "invalid file mode/bytes")
        if self.mode is None and self.data:
            raise ContentError(
                Code.INVALID_CONTENT, "directory cannot have payload bytes"
            )


Tree = tuple[tuple[Path, Node], ...]
State = Node | None


def tree(entries: Mapping[Path, Node]) -> Tree:
    return tuple(sorted(entries.items()))


def valid_path(path: Path) -> bool:
    return (
        type(path) is tuple
        and bool(path)
        and all(
            type(c) is bytes
            and c not in (b"", b".", b"..")
            and b"/" not in c
            and b"\0" not in c
            for c in path
        )
    )


def structural_conflicts(entries: Mapping[Path, Node]) -> tuple[Path, ...]:
    bad = set()
    for path in entries:
        for depth in range(1, len(path)):
            ancestor = path[:depth]
            node = entries.get(ancestor)
            if node is None or node.mode is not None:
                bad.add(ancestor)
    return tuple(
        sorted(p for p in bad if not any(q != p and p[: len(q)] == q for q in bad))
    )


def state_key(value: State) -> tuple[int, int, int, bytes]:
    if value is None:
        return (0, 0, 0, b"")
    if value.mode is None:
        return (1, 0, 0, b"")
    return (2, int(value.mode), len(value.data), value.data)


def _lines(raw: bytes) -> list[bytes]:
    parts = raw.split(b"\n")
    return [v + b"\n" for v in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


Hunk = tuple[int, int, tuple[bytes, ...]]


def _diff(base: bytes, result: bytes, counter: Counter, path: Path) -> list[Hunk]:
    counter.text(base)
    counter.text(result)
    a, b = _lines(base), _lines(result)
    prefix = suffix = 0
    while prefix < min(len(a), len(b)) and a[prefix] == b[prefix]:
        prefix += 1
    while (
        suffix < min(len(a) - prefix, len(b) - prefix)
        and a[-1 - suffix] == b[-1 - suffix]
    ):
        suffix += 1
    n, m = len(a) - prefix - suffix, len(b) - prefix - suffix
    counter.alignment(path, base, result, (n + 1) * (m + 1))
    scores = [array("I", [0]) * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            scores[i][j] = (
                1 + scores[i + 1][j + 1]
                if a[prefix + i] == b[prefix + j]
                else max(scores[i + 1][j], scores[i][j + 1])
            )
    output: list[Hunk] = []
    pending: int | None = None
    replacement: list[bytes] = []

    def flush(end: int) -> None:
        nonlocal pending, replacement
        if pending is not None:
            output.append((pending, prefix + end, tuple(replacement)))
            pending = None
            replacement = []

    i = j = 0
    while i < n or j < m:
        if i < n and j < m and a[prefix + i] == b[prefix + j]:
            flush(i)
            i += 1
            j += 1
        elif i < n and (j == m or scores[i + 1][j] >= scores[i][j + 1]):
            if pending is None:
                pending = prefix + i
            i += 1
        else:
            if pending is None:
                pending = prefix + i
            replacement.append(b[prefix + j])
            j += 1
    flush(i)
    return output


def _overlap(a: Hunk, b: Hunk) -> bool:
    x, y, _ = a
    u, v, _ = b
    if a == b:
        return False
    if x == y and u == v:
        return x == u
    if x == y:
        return u <= x <= v
    if u == v:
        return x <= u <= y
    return max(x, u) < min(y, v)


def merge_bytes(
    base: bytes,
    left: bytes,
    right: bytes,
    *,
    counter: Counter | None = None,
    path: Path = (),
) -> bytes | None:
    if any(type(v) is not bytes for v in (base, left, right)):
        raise TypeError("merge inputs must be bytes")
    if left == right:
        return left
    if left == base:
        return right
    if right == base:
        return left
    counter = counter or Counter(Limits())
    if any(len(v) > 2 * 1024 * 1024 or b"\0" in v for v in (base, left, right)):
        return None
    for value in (base, left, right):
        counter.text(value)
    try:
        for value in (base, left, right):
            value.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None
    hunks = sorted(
        set(_diff(base, left, counter, path) + _diff(base, right, counter, path))
    )
    if any(_overlap(a, b) for a, b in itertools.pairwise(hunks)):
        return None
    source = _lines(base)
    pieces: list[bytes] = []
    cursor = 0
    for first, last, replacement in hunks:
        pieces.extend(source[cursor:first])
        pieces.extend(replacement)
        cursor = last
    pieces.extend(source[cursor:])
    return b"".join(pieces)


def merge_state(
    base: State, left: State, right: State, counter: Counter, path: Path
) -> tuple[bool, State]:
    if left == right:
        return True, left
    if left == base:
        return True, right
    if right == base:
        return True, left
    if any(v is None or v.mode is None for v in (base, left, right)):
        return False, None
    assert base is not None and left is not None and right is not None
    mode = (
        left.mode
        if left.mode == right.mode or right.mode == base.mode
        else right.mode
        if left.mode == base.mode
        else None
    )
    if mode is None:
        return False, None
    # Symlinks permit independent unchanged mode/content rules but never text merging.
    if left.data == right.data:
        data = left.data
    elif left.data == base.data:
        data = right.data
    elif right.data == base.data:
        data = left.data
    elif Mode.SYMLINK in (base.mode, left.mode, right.mode):
        return False, None
    else:
        merged = merge_bytes(
            base.data, left.data, right.data, counter=counter, path=path
        )
        if merged is None:
            return False, None
        data = merged
    return True, Node(mode, data)
