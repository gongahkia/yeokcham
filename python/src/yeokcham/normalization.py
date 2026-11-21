"""Conservative pure normalization of externally authenticated public facts.

No signing, admission, storage, publication or application occurs here. RecordId
bindings and public eligibility must be established by the caller; structural,
causal, scope and claimed-result consistency are checked again. Derived origins
are request-local and are never a persisted source of authority.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from itertools import combinations, pairwise

from .composition import (
    Mode,
    Node,
    Path,
    State,
    Tree,
    merge_state,
    state_key,
    structural_conflicts,
    tree,
    valid_path,
)
from .errors import Code, ContentError
from .identities import RecordId
from .normalization_budget import (
    BudgetExceeded,
    Charge,
    Counter,
    Limits,
    logical_closure,
)

__all__ = [
    "Context",
    "Fact",
    "Limits",
    "Mode",
    "Node",
    "Origin",
    "OriginKey",
    "Resolution",
    "Result",
    "logical_closure",
    "normalize",
    "preserve_private",
    "tree",
]
PROFILE = ("path-frontiers-v1", "line-hunks-v1")


@dataclass(frozen=True)
class OriginKey:
    record: RecordId | None
    slot: str
    path: Path


@dataclass(frozen=True)
class Origin:
    state: State
    parents: tuple[OriginKey, ...]


@dataclass(frozen=True)
class Context:
    path: Path
    accepted: tuple[RecordId, ...]
    selected: tuple[RecordId, ...]
    sources: tuple[tuple[RecordId, tuple[tuple[Path, OriginKey], ...]], ...]
    frontiers: tuple[tuple[Path, tuple[OriginKey, ...]], ...]
    comparisons: tuple[tuple[Path, OriginKey], ...]


@dataclass(frozen=True)
class Resolution:
    context: Context
    choose: RecordId | None
    replacement: Tree | None = None


@dataclass(frozen=True)
class Fact:
    identity: RecordId
    kind: str
    tree: Tree
    basis: RecordId | None = None
    parents: tuple[RecordId, ...] = ()
    selected: tuple[RecordId, ...] = ()
    predecessor: RecordId | None = None
    scope: tuple[Path, ...] = ()
    change: bytes = bytes(16)
    resolutions: tuple[Resolution, ...] = ()
    profile: tuple[str, str] = PROFILE


@dataclass(frozen=True)
class Result:
    status: str
    tree: Tree | None = None
    reason: str = ""
    conflicts: tuple[Context, ...] = ()
    selected: tuple[RecordId, ...] = ()
    dependencies: tuple[RecordId, ...] = ()
    pending: tuple[RecordId, ...] = ()
    retained: tuple[RecordId, ...] = ()
    lineage: tuple[tuple[Path, OriginKey], ...] = ()
    origins: tuple[tuple[OriginKey, Origin], ...] = ()
    charge: Charge = field(default_factory=Charge)


class _Stop(Exception):
    def __init__(self, status: str, reason: str, contexts: tuple[Context, ...] = ()):
        self.status = status
        self.reason = reason
        self.contexts = contexts
        super().__init__(reason)


def _invalid(condition: bool, message: str) -> None:
    if not condition:
        raise ContentError(Code.INVALID_CONTENT, message)


def _ids(values: tuple[RecordId, ...]) -> tuple[RecordId, ...]:
    _invalid(
        type(values) is tuple and all(type(v) is RecordId for v in values),
        "expected exact record IDs",
    )
    _invalid(len(values) == len(set(values)), "duplicate exact selector")
    return tuple(sorted(values, key=lambda v: v.raw))


def _key(value: OriginKey) -> tuple[bytes, str, Path]:
    return (b"" if value.record is None else value.record.raw, value.slot, value.path)


def _prefix(parent: Path, child: Path) -> bool:
    return child[: len(parent)] == parent


class _Engine:
    def __init__(self, facts: Sequence[Fact], limits: Limits, cache: bool):
        self.limits = limits
        self.counter = Counter(limits)
        self.cache = cache
        self.pool: dict[RecordId, Fact] = {}
        self.views: dict[RecordId, dict[Path, OriginKey]] = {}
        self.origins: dict[OriginKey, Origin] = {}
        self.parent_map: dict[OriginKey, tuple[OriginKey, ...]] = {}
        self.queries: set[tuple[Path, tuple[OriginKey, ...]]] = set()
        self.anc_cache: dict[
            tuple[Path, tuple[OriginKey, ...]], frozenset[OriginKey]
        ] = {}
        self.closed: set[RecordId] = set()
        self.paths: tuple[Path, ...] = ()
        if len(facts) > limits.facts:
            raise BudgetExceeded("facts")
        for fact in facts:
            _invalid(
                type(fact) is Fact and type(fact.identity) is RecordId,
                "invalid fact identity/type",
            )
            prior = self.pool.get(fact.identity)
            if prior is not None and prior != fact:
                raise ContentError(Code.INTEGRITY, "conflicting immutable fact ID")
            self.pool[fact.identity] = fact

    def _dependencies(self, fact: Fact) -> tuple[RecordId, ...]:
        _invalid(
            type(fact.kind) is str
            and all(
                type(v) is tuple
                for v in (
                    fact.parents,
                    fact.selected,
                    fact.scope,
                    fact.resolutions,
                    fact.profile,
                )
            ),
            "fact fields must be immutable",
        )
        if fact.kind == "compose":
            raise _Stop("ChoiceRequired", "unsupported-compose")
        if fact.profile != PROFILE:
            raise _Stop("ChoiceRequired", "unsupported-profile")
        _invalid(
            fact.kind in ("genesis", "candidate", "accepted"), "unsupported fact kind"
        )
        _invalid(
            type(fact.change) is bytes and len(fact.change) == 16,
            "invalid change grouping",
        )
        if fact.kind == "genesis":
            _invalid(
                not fact.tree
                and fact.basis is None
                and not fact.parents
                and not fact.selected
                and fact.predecessor is None
                and not fact.scope
                and not fact.resolutions,
                "invalid genesis",
            )
            return ()
        if fact.kind == "candidate":
            _invalid(
                type(fact.basis) is RecordId
                and not fact.parents
                and not fact.selected
                and not fact.resolutions,
                "candidate basis/role mismatch",
            )
            assert fact.basis is not None
            deps = [fact.basis]
            if fact.predecessor is not None:
                _invalid(type(fact.predecessor) is RecordId, "invalid evolution ID")
                deps.append(fact.predecessor)
        else:
            _invalid(
                fact.basis is None
                and bool(fact.parents)
                and fact.predecessor is None
                and not fact.scope,
                "accepted role mismatch",
            )
            deps = list(_ids(fact.parents) + _ids(fact.selected))
        if len(set(deps)) > self.limits.fanout:
            raise BudgetExceeded("fanout")
        return tuple(sorted(set(deps), key=lambda v: v.raw))

    def prepare(self, roots: tuple[RecordId, ...]) -> None:
        colors: dict[RecordId, int] = {}
        deps: dict[RecordId, tuple[RecordId, ...]] = {}
        order = []
        stack = [(r, False) for r in reversed(roots)]
        while stack:
            rid, leaving = stack.pop()
            if leaving:
                colors[rid] = 2
                order.append(rid)
                continue
            color = colors.get(rid, 0)
            if color == 2:
                continue
            if color == 1:
                raise ContentError(Code.INVALID_CONTENT, "cyclic public dependencies")
            if rid not in self.pool:
                raise ContentError(
                    Code.UNAVAILABLE, "missing public dependency " + rid.hex()
                )
            if len(colors) >= self.limits.facts:
                raise BudgetExceeded("facts")
            colors[rid] = 1
            deps[rid] = self._dependencies(self.pool[rid])
            stack.append((rid, True))
            stack.extend((r, False) for r in reversed(deps[rid]))
        self.closed = set(order)
        heights: dict[RecordId, int] = {}
        paths: set[Path] = set()
        path_bytes = 0
        for rid in order:
            heights[rid] = max((heights[r] + 1 for r in deps[rid]), default=0)
            if heights[rid] > self.limits.depth:
                raise BudgetExceeded("depth")
            fact = self.pool[rid]
            self.validate_tree(fact.tree)
            if fact.kind == "candidate":
                _invalid(
                    type(fact.scope) is tuple
                    and all(valid_path(p) for p in fact.scope),
                    "invalid contribution scope",
                )
                _invalid(
                    len(fact.scope) == len(set(fact.scope)), "duplicate scope path"
                )
                if fact.predecessor is not None:
                    previous = self.pool[fact.predecessor]
                    _invalid(
                        previous.kind == "candidate" and previous.change == fact.change,
                        "evolution crosses change/type",
                    )
            elif fact.kind == "accepted":
                _invalid(
                    all(
                        self.pool[p].kind in ("genesis", "accepted")
                        for p in fact.parents
                    ),
                    "invalid accepted parent",
                )
                _invalid(
                    all(self.pool[p].kind == "candidate" for p in fact.selected),
                    "invalid selected dependency",
                )
            for path, _ in fact.tree:
                if path not in paths:
                    if len(paths) >= self.limits.paths:
                        raise BudgetExceeded("paths")
                    path_bytes += sum(map(len, path))
                    if path_bytes > self.limits.path_bytes:
                        raise BudgetExceeded("path_bytes")
                    paths.add(path)
        self.paths = tuple(sorted(paths))
        for rid in order:
            fact = self.pool[rid]
            target = dict(fact.tree)
            if fact.kind == "genesis":
                view = {
                    p: self.add(OriginKey(rid, "result", p), None, ())
                    for p in self.paths
                }
            elif fact.kind == "candidate":
                assert fact.basis is not None
                base = self.views[fact.basis]
                view = {}
                changed = [
                    p
                    for p in self.paths
                    if self.origins[base[p]].state != target.get(p)
                ]
                if any(
                    not any(_prefix(q, p) for q in fact.scope) for p in changed
                ) or any(not any(_prefix(q, p) for p in changed) for q in fact.scope):
                    raise ContentError(
                        Code.INTEGRITY, "false declared contribution scope"
                    )
                for p in self.paths:
                    value = target.get(p)
                    view[p] = (
                        base[p]
                        if p not in changed
                        else self.add(OriginKey(rid, "result", p), value, (base[p],))
                    )
            else:
                computed, view = self.compose(
                    _ids(fact.parents), _ids(fact.selected), fact.resolutions, rid
                )
                if computed != fact.tree:
                    raise ContentError(Code.INTEGRITY, "false accepted result claim")
            self.views[rid] = view

    def validate_tree(self, value: Tree) -> None:
        _invalid(type(value) is tuple, "tree must be immutable")
        if len(value) > self.limits.paths:
            raise BudgetExceeded("paths")
        previous: Path = ()
        entries: dict[Path, Node] = {}
        for row in value:
            _invalid(type(row) is tuple and len(row) == 2, "tree entry shape")
            path, node = row
            _invalid(valid_path(path) and type(node) is Node, "invalid path/node")
            if len(path) > self.limits.path_depth:
                raise BudgetExceeded("path_depth")
            _invalid(path > previous, "tree order/duplicate")
            previous = path
            _invalid(
                not any(c in (b".yeokcham", b".yeokcham-v2", b".git") for c in path),
                "metadata outside public tree",
            )
            entries[path] = node
        _invalid(not structural_conflicts(entries), "invalid input tree structure")

    def add(
        self, key: OriginKey, value: State, parents: tuple[OriginKey, ...]
    ) -> OriginKey:
        parents = tuple(sorted(set(parents), key=_key))
        origin = Origin(value, parents)
        if key in self.origins:
            if self.origins[key] != origin:
                raise ContentError(Code.INTEGRITY, "derived origin collision")
        else:
            self.counter.origin(key.path)
            self.origins[key] = origin
            self.parent_map[key] = parents
        return key

    def ancestors(
        self, path: Path, roots: tuple[OriginKey, ...]
    ) -> frozenset[OriginKey]:
        roots = tuple(sorted(set(roots), key=_key))
        query = (path, roots)
        if self.cache and query in self.anc_cache:
            return self.anc_cache[query]
        nodes, edges = logical_closure(
            self.parent_map,
            roots,
            max_nodes=self.limits.origins_path,
            unit_limit=1_000_000
            if query in self.queries
            else self.limits.ancestor_units - self.counter.ancestor_units,
        )
        if query not in self.queries:
            self.counter.units(len(nodes) + len(edges))
            self.queries.add(query)
        if self.cache:
            self.anc_cache[query] = nodes
        return nodes

    def maxima(
        self, path: Path, inputs: tuple[OriginKey, ...]
    ) -> tuple[OriginKey, ...]:
        roots = tuple(sorted(set(inputs), key=_key))
        closures = {o: self.ancestors(path, (o,)) for o in roots}
        return tuple(
            o
            for o in roots
            if not any(o != other and o in closures[other] for other in roots)
        )

    def common(
        self, path: Path, left: tuple[OriginKey, ...], right: tuple[OriginKey, ...]
    ) -> OriginKey | None:
        common = self.ancestors(path, left) & self.ancestors(path, right)
        # An ancestor-closed set's maxima are exactly its nodes not parented by
        # another node of the intersection; no synthetic or temporary base.
        nonmax = {p for node in common for p in self.parent_map[node]}
        maxima = common - nonmax
        return next(iter(maxima)) if len(maxima) == 1 else None

    def solve(
        self, path: Path, frontier: tuple[OriginKey, ...]
    ) -> tuple[set[State], bool]:
        if len(frontier) > self.limits.frontier:
            raise BudgetExceeded("frontier")
        values: dict[tuple[OriginKey, ...], set[State]] = {}
        ambiguity: dict[tuple[OriginKey, ...], bool] = {}
        for size in range(1, len(frontier) + 1):
            for subset in combinations(frontier, size):
                self.ancestors(path, subset)
                self.counter.subsets += 1
                states: set[State] = set()
                ambiguous = False
                if size == 1:
                    state = self.origins[subset[0]].state
                    self.retain(path, states, state)
                else:
                    for split_size in range(1, size):
                        for left in combinations(subset, split_size):
                            if subset[0] not in left:
                                continue
                            right = tuple(o for o in subset if o not in left)
                            ambiguous |= ambiguity[left] or ambiguity[right]
                            for a in sorted(values[left], key=state_key):
                                for b in sorted(values[right], key=state_key):
                                    self.counter.pair(path)
                                    base = self.common(path, left, right)
                                    if base is None:
                                        ambiguous = True
                                        continue
                                    self.counter.transient(
                                        path,
                                        (0 if a is None else len(a.data))
                                        + (0 if b is None else len(b.data)),
                                    )
                                    success, state = merge_state(
                                        self.origins[base].state,
                                        a,
                                        b,
                                        self.counter,
                                        path,
                                    )
                                    if success:
                                        self.retain(path, states, state)
                values[subset] = states
                ambiguity[subset] = ambiguous
        return values[frontier], ambiguity[frontier]

    def retain(self, path: Path, states: set[State], state: State) -> None:
        if state not in states:
            if len(states) >= self.limits.states:
                raise BudgetExceeded("states")
            self.counter.payload(path, 0 if state is None else len(state.data))
            states.add(state)

    def context(
        self,
        root: Path,
        accepted: tuple[RecordId, ...],
        selected: tuple[RecordId, ...],
        frontiers: Mapping[Path, tuple[OriginKey, ...]],
    ) -> Context:
        paths = tuple(p for p in self.paths if _prefix(root, p))
        inputs = accepted + selected
        sources = tuple(
            (rid, tuple((p, self.views[rid][p]) for p in paths)) for rid in inputs
        )
        # Drop only a whole scope-local source view dominated on EVERY path.
        # A changed child stops its unchanged parent source from disappearing.
        vectors = {rid: tuple(self.views[rid][p] for p in paths) for rid in inputs}
        survivors = []
        for rid in inputs:
            dominated = False
            for other in inputs:
                if rid == other:
                    continue
                relations = [
                    a == b or a in self.ancestors(p, (b,))
                    for p, a, b in zip(paths, vectors[rid], vectors[other])
                ]
                if all(relations) and vectors[rid] != vectors[other]:
                    dominated = True
                    break
            if not dominated:
                survivors.append(rid)
        comparisons = []
        for p in paths:
            original = tuple(
                sorted({self.views[rid][p] for rid in survivors}, key=_key)
            )
            common = set(self.ancestors(p, (original[0],)))
            for origin in original[1:]:
                common.intersection_update(self.ancestors(p, (origin,)))
            maxima = common - {
                parent for origin in common for parent in self.parent_map[origin]
            }
            if len(maxima) != 1:
                raise _Stop("ChoiceRequired", "comparison")
            comparisons.append((p, next(iter(maxima))))
        return Context(
            root,
            accepted,
            selected,
            sources,
            tuple((p, frontiers[p]) for p in paths),
            tuple(comparisons),
        )

    def accepted_comparison(self, accepted: tuple[RecordId, ...]) -> None:
        if len(accepted) < 2:
            return
        closures = []
        for root in accepted:
            visited = set()
            todo = [root]
            while todo:
                rid = todo.pop()
                if rid in visited:
                    continue
                visited.add(rid)
                fact = self.pool[rid]
                if fact.kind == "accepted":
                    todo.extend(fact.parents)
            closures.append(visited)
        common = set.intersection(*closures)
        nonmax = {parent for rid in common for parent in self.pool[rid].parents}
        if len(common - nonmax) != 1:
            raise _Stop("ChoiceRequired", "comparison")

    def compose(
        self,
        accepted: tuple[RecordId, ...],
        selected: tuple[RecordId, ...],
        resolutions: tuple[Resolution, ...],
        owner: RecordId | None = None,
    ) -> tuple[Tree, dict[Path, OriginKey]]:
        _invalid(bool(accepted), "an accepted target is required")
        _invalid(
            type(resolutions) is tuple
            and all(
                type(r) is Resolution and type(r.context) is Context
                for r in resolutions
            ),
            "invalid resolution/context",
        )
        if len(resolutions) > self.limits.paths:
            raise BudgetExceeded("paths")
        self.accepted_comparison(accepted)
        scopes = [r.context.path for r in resolutions]
        _invalid(all(valid_path(p) for p in scopes), "invalid resolution path")
        ordered_scopes = sorted(scopes)
        _invalid(
            not any(_prefix(a, b) for a, b in pairwise(ordered_scopes)),
            "overlapping resolutions",
        )
        if any(r.replacement is not None or r.choose is None for r in resolutions):
            raise _Stop("ChoiceRequired", "unsupported-literal-resolution")
        inputs = accepted + selected
        states: dict[Path, State] = {}
        frontiers = {}
        conflicts: set[Path] = set()
        reason = ""
        for p in self.paths:
            frontier = self.maxima(p, tuple(self.views[rid][p] for rid in inputs))
            frontiers[p] = frontier
            values, ambiguous = self.solve(p, frontier)
            if ambiguous:
                reason = "comparison"
            elif len(values) > 1 and reason != "comparison":
                reason = "nonconfluent"
            elif not values:
                conflicts.add(p)
            else:
                states[p] = next(iter(values))
        if reason:
            raise _Stop("ChoiceRequired", reason)
        tentative = {p: v for p, v in states.items() if v is not None}
        conflicts.update(structural_conflicts(tentative))
        roots = tuple(
            sorted(
                p
                for p in conflicts
                if not any(q != p and _prefix(q, p) for q in conflicts)
            )
        )
        contexts = tuple(
            self.context(root, accepted, selected, frontiers) for root in roots
        )
        by_scope = {r.context.path: r for r in resolutions}
        _invalid(all(path in roots for path in by_scope), "unused resolution")
        for context in contexts:
            resolution = by_scope.get(context.path)
            if resolution is not None:
                if resolution.context != context:
                    raise ContentError(Code.INTEGRITY, "resolution context changed")
                _invalid(
                    type(resolution.choose) is RecordId and resolution.choose in inputs,
                    "choice outside exact input context",
                )
        if any(root not in by_scope for root in roots):
            raise _Stop("Conflicted", "content-or-structure", contexts)
        view = {}
        for p in self.paths:
            resolution = next(
                (r for root, r in by_scope.items() if _prefix(root, p)), None
            )
            if resolution is not None:
                assert resolution.choose is not None
                view[p] = self.views[resolution.choose][p]
                states[p] = self.origins[view[p]].state
            elif len(frontiers[p]) == 1:
                view[p] = frontiers[p][0]
            else:
                view[p] = self.add(
                    OriginKey(owner, "proposed" if owner is None else "result", p),
                    states[p],
                    frontiers[p],
                )
        result = tree({p: v for p, v in states.items() if v is not None})
        if structural_conflicts(dict(result)):
            raise _Stop("ChoiceRequired", "structural-resolution")
        return result, view

    def pending(
        self, accepted: tuple[RecordId, ...], selected: tuple[RecordId, ...]
    ) -> tuple[RecordId, ...]:
        candidates = {r for r, f in self.pool.items() if f.kind == "candidate"}
        superseded = {
            f.predecessor
            for f in self.pool.values()
            if f.kind == "candidate" and f.predecessor is not None
        }
        accounted = set(selected)
        seen = set()
        todo = list(accepted)
        while todo:
            rid = todo.pop()
            if rid in seen:
                continue
            seen.add(rid)
            fact = self.pool[rid]
            if fact.kind == "accepted":
                accounted.update(fact.selected)
                todo.extend(fact.parents)
        return tuple(sorted(candidates - superseded - accounted, key=lambda r: r.raw))


def normalize(
    facts: Sequence[Fact],
    accepted: tuple[RecordId, ...],
    selected: tuple[RecordId, ...],
    *,
    resolutions: tuple[Resolution, ...] = (),
    limits: Limits | None = None,
    cache: bool = True,
    reconcile: bool = False,
    expected_heads: tuple[RecordId, ...] | None = None,
    current_heads: tuple[RecordId, ...] | None = None,
) -> Result:
    """Propose only; Ready does not authorize acceptance or change any state.

    Scope is one externally validated repository/branch input set. No authority,
    real-world head freshness or snapshot-object availability is inferred here.
    """
    limits = limits or Limits()
    engine: _Engine | None = None
    selection: tuple[RecordId, ...] = ()
    try:
        if type(selected) is tuple and len(selected) > limits.selected:
            raise BudgetExceeded("selected")
        if type(accepted) is tuple and len(accepted) > limits.fanout:
            raise BudgetExceeded("fanout")
        selection = _ids(selected)
        targets = _ids(accepted)
        if len(selection) > limits.selected:
            raise BudgetExceeded("selected")
        if expected_heads is not None:
            if current_heads is None:
                raise _Stop("ChoiceRequired", "head-context-required")
            if _ids(expected_heads) != _ids(current_heads):
                raise _Stop("Stale", "accepted-heads")
        if len(targets) > 1 and not reconcile:
            raise _Stop("ChoiceRequired", "accepted-heads")
        engine = _Engine(facts, limits, cache)
        roots = tuple(sorted(set(targets + selection), key=lambda r: r.raw))
        engine.prepare(roots)
        _invalid(
            all(engine.pool[r].kind in ("accepted", "genesis") for r in targets),
            "target is not accepted",
        )
        _invalid(
            all(engine.pool[r].kind == "candidate" for r in selection),
            "selection is not candidate",
        )
        result, view = engine.compose(targets, selection, resolutions)
        return Result(
            "Ready",
            result,
            selected=selection,
            dependencies=tuple(
                sorted(engine.closed - set(selection), key=lambda r: r.raw)
            ),
            pending=engine.pending(targets, selection),
            retained=tuple(sorted(engine.pool, key=lambda r: r.raw)),
            lineage=tuple(sorted(view.items())),
            origins=tuple(
                sorted(engine.origins.items(), key=lambda pair: _key(pair[0]))
            ),
            charge=engine.counter.snapshot(),
        )
    except (ContentError, BudgetExceeded, _Stop) as error:
        status = (
            error.code.value
            if isinstance(error, ContentError)
            else "ChoiceRequired"
            if isinstance(error, BudgetExceeded)
            else error.status
        )
        contexts = error.contexts if isinstance(error, _Stop) else ()
        return Result(
            status,
            reason=str(error) if not isinstance(error, _Stop) else error.reason,
            conflicts=contexts,
            selected=selection,
            retained=tuple(sorted(engine.pool, key=lambda r: r.raw)) if engine else (),
            charge=engine.counter.snapshot() if engine else Charge(),
        )


def preserve_private(known: Tree, accepted: Tree, private: Tree) -> Tree:
    """Conditional pure helper: caller must prove exact known-present correspondence.

    Unsupported divergence requires a private decision; never consult private work
    as an input to public normalization. No correspondence proof is manufactured.
    """
    engine = _Engine((), Limits(), True)
    for value in (known, accepted, private):
        engine.validate_tree(value)
    if known == accepted:
        return private
    raise ContentError(
        Code.UNSUPPORTED,
        "private divergent preservation requires a separate qualified plan",
    )
