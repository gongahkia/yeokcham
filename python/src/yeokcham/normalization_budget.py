"""Local, unsigned normalization profile. Logical charges never count cache misses."""

from collections.abc import Hashable, Iterable, Mapping
from dataclasses import dataclass, fields
from typing import TypeVar

from .errors import Code, ContentError

T = TypeVar("T", bound=Hashable)
Path = tuple[bytes, ...]
MAX_COUNT = (1 << 63) - 1


class BudgetExceeded(Exception):
    def __init__(self, dimension: str):
        self.dimension = dimension
        super().__init__("normalization-budget:" + dimension)


@dataclass(frozen=True)
class Limits:
    ancestor_units: int = 1_000_000
    pairs_path: int = 32768
    pairs_request: int = 131072
    cells_alignment: int = 4_000_000
    cells_path: int = 16_000_000
    cells_request: int = 64_000_000
    retained_path: int = 8 * 1024 * 1024
    retained_request: int = 64 * 1024 * 1024
    origins_path: int = 4096
    origins_request: int = 65536
    paths: int = 4096
    facts: int = 4096
    depth: int = 256
    path_depth: int = 256
    fanout: int = 64
    path_bytes: int = 1024 * 1024
    frontier: int = 6
    selected: int = 64
    states: int = 32
    text_input: int = 2 * 1024 * 1024
    text_request: int = 32 * 1024 * 1024
    lines: int = 131072

    def __post_init__(self) -> None:
        for field in fields(self):
            value = getattr(self, field.name)
            if (
                type(value) is not int
                or type(field.default) is not int
                or not 0 <= value <= field.default
            ):
                raise ValueError("limits may only reduce the local reference profile")


@dataclass(frozen=True)
class Charge:
    ancestor_units: int = 0
    pairs: int = 0
    cells: int = 0
    retained: int = 0
    origins: int = 0
    subsets: int = 0


def checked_add(current: int, amount: int, limit: int, dimension: str) -> int:
    if (
        type(amount) is not int
        or amount < 0
        or current < 0
        or amount > MAX_COUNT - current
    ):
        raise BudgetExceeded("counter-overflow")
    if current + amount > limit:
        raise BudgetExceeded(dimension)
    return current + amount


class Counter:
    def __init__(self, limits: Limits):
        self.limits = limits
        self.ancestor_units = 0
        self.pairs = 0
        self.cells = 0
        self.retained = 0
        self.origins = 0
        self.subsets = 0
        self.local_pairs: dict[Path, int] = {}
        self.local_cells: dict[Path, int] = {}
        self.local_payload: dict[Path, int] = {}
        self.local_origins: dict[Path, int] = {}
        self.text_seen: set[bytes] = set()
        self.text_bytes = 0
        self.aligned: set[tuple[bytes, bytes]] = set()
        self.path_aligned: set[tuple[Path, bytes, bytes]] = set()

    def snapshot(self) -> Charge:
        return Charge(
            self.ancestor_units,
            self.pairs,
            self.cells,
            self.retained,
            self.origins,
            self.subsets,
        )

    def units(self, amount: int) -> None:
        self.ancestor_units = checked_add(
            self.ancestor_units, amount, self.limits.ancestor_units, "ancestor_units"
        )

    def origin(self, path: Path) -> None:
        local = checked_add(
            self.local_origins.get(path, 0), 1, self.limits.origins_path, "origins_path"
        )
        total = checked_add(
            self.origins, 1, self.limits.origins_request, "origins_request"
        )
        self.local_origins[path] = local
        self.origins = total

    def pair(self, path: Path) -> None:
        local = checked_add(
            self.local_pairs.get(path, 0), 1, self.limits.pairs_path, "pairs_path"
        )
        total = checked_add(self.pairs, 1, self.limits.pairs_request, "pairs_request")
        self.local_pairs[path] = local
        self.pairs = total

    def payload(self, path: Path, size: int) -> None:
        local = checked_add(
            self.local_payload.get(path, 0),
            size,
            self.limits.retained_path,
            "retained_path",
        )
        total = checked_add(
            self.retained, size, self.limits.retained_request, "retained_request"
        )
        self.local_payload[path] = local
        self.retained = total

    def transient(self, path: Path, size: int) -> None:
        checked_add(
            self.local_payload.get(path, 0),
            size,
            self.limits.retained_path,
            "retained_path",
        )
        checked_add(
            self.retained, size, self.limits.retained_request, "retained_request"
        )

    def text(self, data: bytes) -> None:
        if len(data) > self.limits.text_input:
            raise BudgetExceeded("text_input")
        if data not in self.text_seen:
            self.text_bytes = checked_add(
                self.text_bytes, len(data), self.limits.text_request, "text_request"
            )
            self.text_seen.add(data)
        descriptors = data.count(b"\n") + (bool(data) and not data.endswith(b"\n"))
        if descriptors > self.limits.lines:
            raise BudgetExceeded("lines")

    def alignment(self, path: Path, base: bytes, result: bytes, cells: int) -> None:
        if cells > self.limits.cells_alignment:
            raise BudgetExceeded("cells_alignment")
        local_key = (path, base, result)
        global_key = (base, result)
        if local_key not in self.path_aligned:
            local = checked_add(
                self.local_cells.get(path, 0),
                cells,
                self.limits.cells_path,
                "cells_path",
            )
            total = (
                self.cells
                if global_key in self.aligned
                else checked_add(
                    self.cells, cells, self.limits.cells_request, "cells_request"
                )
            )
            self.local_cells[path] = local
            self.cells = total
            self.path_aligned.add(local_key)
            self.aligned.add(global_key)


def logical_closure(
    parents: Mapping[T, tuple[T, ...]],
    roots: Iterable[T],
    *,
    traversal: str = "dfs",
    max_nodes: int = 4096,
    unit_limit: int = 1_000_000,
) -> tuple[frozenset[T], frozenset[tuple[T, T]]]:
    """Bounded physical traversal; returned sets define logical cardinalities.

    Input order and traversal affect neither cardinalities nor cycle validation.
    Engine graphs are already topologically validated before this boundary.
    """
    if traversal not in ("dfs", "bfs"):
        raise ValueError("unsupported traversal")
    todo = list(roots)
    nodes: set[T] = set()
    edges: set[tuple[T, T]] = set()
    while todo:
        node = todo.pop(0 if traversal == "bfs" else -1)
        if node in nodes:
            continue
        if len(nodes) + len(edges) >= unit_limit:
            raise BudgetExceeded("ancestor_units")
        if len(nodes) >= max_nodes:
            raise BudgetExceeded("origins_path")
        if node not in parents:
            raise ContentError(Code.UNAVAILABLE, "missing material origin")
        nodes.add(node)
        ps = parents[node]
        if len(ps) > 64:
            raise BudgetExceeded("fanout")
        for parent in ps:
            if (node, parent) not in edges:
                if len(nodes) + len(edges) >= unit_limit:
                    raise BudgetExceeded("ancestor_units")
                edges.add((node, parent))
            todo.append(parent)
    # Kahn validation also catches a caller-supplied cycle in the standalone helper.
    incoming = {node: 0 for node in nodes}
    children: dict[T, list[T]] = {node: [] for node in nodes}
    for child, parent in edges:
        incoming[child] += 1
        children[parent].append(child)
    ready = [node for node in nodes if incoming[node] == 0]
    count = 0
    while ready:
        node = ready.pop()
        count += 1
        for child in children[node]:
            incoming[child] -= 1
            if incoming[child] == 0:
                ready.append(child)
    if count != len(nodes):
        raise ContentError(Code.INVALID_CONTENT, "cyclic material origins")
    return frozenset(nodes), frozenset(edges)
