"""Independent exact M0 expectations plus the qualified conservative contract."""

import hashlib
from dataclasses import replace
from itertools import combinations, permutations

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from normalization_cases import CASES, FACTS, D, F, T, f, g
from yeokcham.identities import RecordId


def api():
    from yeokcham import composition, normalization

    return normalization, composition


def rid(name):
    return RecordId(hashlib.sha256(name.encode()).digest())


def tr(value):
    n, _ = api()
    return n.tree(
        {
            p: n.Node() if v == D else n.Node(n.Mode(v[1]), v[2])
            for p, v in value.items()
        }
    )


def plain(tree):
    return {p: D if v.mode is None else F(v.data, int(v.mode)) for p, v in tree}


def pool():
    n, _ = api()
    facts = []
    groups = {}
    roles = {row[0]: row[1] for row in FACTS}
    for name, role, inputs, value, previous, scope, choices in FACTS:
        change = groups.get(previous, hashlib.sha256(name.encode()).digest()[:16])
        groups[name] = change
        parents = (
            tuple(rid(v) for v in inputs if roles[v] != "candidate")
            if role == "accepted"
            else ()
        )
        selected = (
            tuple(rid(v) for v in inputs if roles[v] == "candidate")
            if role == "accepted"
            else ()
        )
        resolutions = []
        if choices:
            prepared = n.normalize(facts, parents, selected, reconcile=len(parents) > 1)
            for path, choice in choices.items():
                context = next(v for v in prepared.conflicts if v.path == path)
                resolutions.append(n.Resolution(context, rid(choice)))
        facts.append(
            n.Fact(
                rid(name),
                role,
                tr(value),
                basis=rid(inputs[0]) if role == "candidate" else None,
                parents=parents,
                selected=selected,
                predecessor=rid(previous) if previous else None,
                scope=scope,
                change=change,
                resolutions=tuple(resolutions),
            )
        )
    return facts


@pytest.mark.parametrize("case", CASES, ids=lambda c: c[0])
def test_m0_public_cases(case):
    n, _ = api()
    label, targets, selected, status, value = case
    kwargs = {}
    if label == "S18":
        kwargs = {"expected_heads": (rid("S0"),), "current_heads": (rid("SB"),)}
    result = n.normalize(
        pool(),
        tuple(map(rid, targets)),
        tuple(map(rid, selected)),
        reconcile=len(targets) > 1,
        **kwargs,
    )
    if label == "S13":
        # The original Ready expectation stays intact; inline Compose is explicitly
        # unsupported by this first conservative fact-adapter, never falsely Ready.
        assert status == "Ready" and result.status == "ChoiceRequired"
        assert result.reason == "unsupported-compose" and result.tree is None
        return
    assert result.status == status
    if value is not None:
        assert plain(result.tree) == value
    else:
        assert result.tree is None
    assert result.selected == tuple(sorted(map(rid, selected), key=lambda v: v.raw))


def test_pending_and_evolution():
    n, _ = api()
    facts = pool()
    r = n.normalize(facts, (rid("S0"),), (rid("A2"),))
    assert rid("B3") in r.pending and rid("A2") not in r.pending
    assert rid("B1") not in r.pending and rid("B2") not in r.pending
    assert rid("A1") in r.dependencies and rid("B1") not in r.dependencies
    old = n.normalize(facts, (rid("SA1"),), (rid("A2"), rid("Z1")))
    assert plain(old.tree) == {**T(2), g: F(b"z\n")}
    later = n.normalize(facts, (rid("S0"),), (rid("A3"),))
    assert plain(later.tree) == T(0, 1)


def test_equal_bytes_preserve_both_origins():
    n, _ = api()
    r = n.normalize(pool(), (rid("S0"),), (rid("A2"), rid("Bequal")))
    key = dict(r.lineage)[f]
    origin = dict(r.origins)[key]
    assert {v.record for v in origin.parents} == {rid("A2"), rid("Bequal")}


def structural(replacement=None, two=False):
    n, _ = api()
    d = (b"d",)
    child = d + (b"f",)
    new = d + (b"g",)
    u = (b"u",)
    base = {d: D, child: F(b"old"), u: F(b"old-u")}
    if two:
        base.update({(b"x",): D, (b"x", b"f"): F(b"old")})
    a = {u: F(b"old-u")}
    if replacement is not None:
        a[d] = replacement
    b = {**base, new: F(b"new"), u: F(b"new-u")}
    if two:
        b[(b"x", b"g")] = F(b"new")
    rows = [
        n.Fact(rid("sg"), "genesis", tr({})),
        n.Fact(rid("base"), "candidate", tr(base), basis=rid("sg"), scope=tuple(base)),
        n.Fact(
            rid("A"),
            "candidate",
            tr(a),
            basis=rid("base"),
            scope=((b"d",), (b"x",)) if two else (d,),
        ),
        n.Fact(
            rid("B"),
            "candidate",
            tr(b),
            basis=rid("base"),
            scope=((b"d",), (b"x",), u) if two else (d, u),
        ),
    ]
    return rows, a, b


@pytest.mark.parametrize(
    "replacement", [None, F(b"A"), F(b"target", 2)], ids=["delete", "file", "symlink"]
)
@pytest.mark.parametrize("chosen", ["A", "B"])
def test_exact_subtree_choices(replacement, chosen):
    n, _ = api()
    facts, a, b = structural(replacement)
    unresolved = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    assert unresolved.status == "Conflicted" and unresolved.tree is None
    context = next(c for c in unresolved.conflicts if c.path == (b"d",))
    # Context includes the new child contribution, even though d alone has a
    # singleton replacement frontier. This is independent of context round-trip.
    assert (b"d", b"g") in {row[0] for row in context.frontiers}
    assert rid("B") in {key.record for _, keys in context.frontiers for key in keys}
    resolved = n.normalize(
        facts,
        (rid("sg"),),
        (rid("B"), rid("A")),
        resolutions=(n.Resolution(context, rid(chosen)),),
    )
    expected = {**(a if chosen == "A" else b), (b"u",): F(b"new-u")}
    assert resolved.status == "Ready" and plain(resolved.tree) == expected
    key = dict(resolved.lineage)[(b"d", b"g")]
    if chosen == "A":
        assert key.record != rid("B")
    assert rid("A") in resolved.retained and rid("B") in resolved.retained
    bad = n.normalize(
        facts,
        (rid("sg"),),
        (rid("A"), rid("B")),
        resolutions=(
            n.Resolution(replace(context, selected=(rid("A"),)), rid(chosen)),
        ),
    )
    assert bad.status == "IntegrityFailure" and bad.tree is None


def test_disjoint_nested_literal_and_unused_resolution():
    n, _ = api()
    facts, _, b = structural(two=True)
    r = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    cs = {c.path: c for c in r.conflicts}
    choices = (n.Resolution(cs[(b"d",)], rid("A")), n.Resolution(cs[(b"x",)], rid("B")))
    r = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=choices)
    assert r.status == "Ready" and plain(r.tree) == {
        p: v for p, v in b.items() if p[:1] != (b"d",)
    }
    overlap = n.Resolution(replace(cs[(b"d",)], path=(b"d", b"g")), rid("B"))
    r = n.normalize(
        facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=(choices[0], overlap)
    )
    assert r.status == "InvalidContent" and r.tree is None
    literal = n.Resolution(cs[(b"d",)], None, replacement=tr({(b"d",): D}))
    r = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=(literal,))
    assert (
        r.status == "ChoiceRequired"
        and r.reason == "unsupported-literal-resolution"
        and r.tree is None
    )


def test_rejected_descendant_is_not_material_ancestor():
    n, _ = api()
    facts, _a, b = structural()
    before = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    choice = n.Resolution(before.conflicts[0], rid("A"))
    accepted = n.Fact(
        rid("chosen"),
        "accepted",
        tr({(b"u",): F(b"new-u")}),
        parents=(rid("sg"),),
        selected=(rid("A"), rid("B")),
        resolutions=(choice,),
    )
    later = n.Fact(
        rid("later"),
        "candidate",
        tr({**b, (b"d", b"g"): F(b"newer")}),
        basis=rid("B"),
        scope=((b"d", b"g"),),
    )
    r = n.normalize(facts + [accepted, later], (rid("chosen"),), (rid("later"),))
    assert r.status == "Conflicted" and r.tree is None


@pytest.mark.parametrize("mode", [0, 2])
def test_file_or_symlink_to_directory_and_empty(mode):
    n, _ = api()
    g0 = n.Fact(rid("g0"), "genesis", tr({}))
    a = n.Fact(
        rid("typeA"),
        "candidate",
        tr({(b"d",): F(b"old", mode)}),
        basis=g0.identity,
        scope=((b"d",),),
    )
    b = n.Fact(
        rid("typeB"),
        "candidate",
        tr({(b"d",): D, (b"d", b"g"): F(b"new")}),
        basis=a.identity,
        scope=((b"d",),),
    )
    r = n.normalize([g0, a, b], (g0.identity,), (b.identity,))
    assert r.status == "Ready" and plain(r.tree) == {
        (b"d",): D,
        (b"d", b"g"): F(b"new"),
    }
    empty = replace(b, tree=tr({(b"d",): D}))
    assert plain(
        n.normalize([g0, a, empty], (g0.identity,), (empty.identity,)).tree
    ) == {(b"d",): D}


def test_nonconfluence_all_permutations():
    n, _ = api()
    root = n.Fact(rid("ng"), "genesis", tr({}))
    base = n.Fact(
        rid("nb"),
        "candidate",
        tr({f: F(b"a\nc\nb\n")}),
        basis=root.identity,
        scope=(f,),
    )
    values = [b"c\nb\nc\n", b"a\na\nb\nc\n", b"c\nc\nc\nb\n"]
    variants = [
        n.Fact(
            rid("n" + str(i)),
            "candidate",
            tr({f: F(v)}),
            basis=base.identity,
            scope=(f,),
        )
        for i, v in enumerate(values)
    ]
    for order in permutations(variants):
        r = n.normalize(
            [root, base, *order], (root.identity,), tuple(v.identity for v in order)
        )
        assert (
            r.status == "ChoiceRequired"
            and r.reason == "nonconfluent"
            and r.tree is None
        )


def test_private_preservation_separate_from_public_result():
    n, _ = api()
    known = tr(T(2))
    private = tr({**T(2, 1), (b"secret.txt",): F(b"private later\n")})
    assert n.preserve_private(known, known, private) == private
    public = n.normalize(pool(), (rid("S0"),), (rid("A2"),))
    assert (b"secret.txt",) not in dict(public.tree)


@pytest.mark.parametrize(
    "kind", ["missing", "cycle", "scope", "duplicate", "invalid-tree", "profile"]
)
def test_bad_inputs_never_ready(kind):
    n, _ = api()
    facts = pool()
    a = next(v for v in facts if v.identity == rid("A2"))
    if kind == "missing":
        facts = [v for v in facts if v.identity != rid("A1")]
    elif kind == "cycle":
        facts = [
            replace(v, basis=rid("A2")) if v.identity == rid("A1") else v for v in facts
        ]
    elif kind == "scope":
        facts = [replace(v, scope=()) if v.identity == rid("A2") else v for v in facts]
    elif kind == "duplicate":
        facts.append(replace(a, scope=()))
    elif kind == "invalid-tree":
        facts = [
            replace(v, tree=tr({(b"d", b"bad"): F(b"x")}))
            if v.identity == rid("A2")
            else v
            for v in facts
        ]
    else:
        facts = [
            replace(v, profile=("unknown", "line-hunks-v1"))
            if v.identity == rid("A2")
            else v
            for v in facts
        ]
    r = n.normalize(facts, (rid("S0"),), (rid("A2"),))
    assert (
        r.status
        in (
            "Unavailable",
            "InvalidContent",
            "IntegrityFailure",
            "ChoiceRequired",
            "UnsupportedFormat",
        )
        and r.tree is None
    )


def test_leaf_exactness():
    _, c = api()
    assert c.merge_bytes(b"x=0\r\ny=0", b"x=1\r\ny=0", b"x=0\r\ny=1") == b"x=1\r\ny=1"
    assert c.merge_bytes(b"a\n", b"x\na\n", b"y\na\n") is None
    assert c.merge_bytes(b"\0base", b"\0left", b"\0right") is None
    assert c.merge_bytes(b"a\\nb", b"x\\nb", b"a\\ny") is None


def test_budget_old_diagnostic_and_new_exact_units():
    n, _ = api()
    parents = {i: (i - 1,) if i else () for i in range(128)}
    parents.update({128 + i: (127,) for i in range(6)})
    totals = []
    for traversal in ("dfs", "bfs"):
        for cache in (False, True):
            total = 0
            for size in range(1, 7):
                for subset in combinations(range(128, 134), size):
                    nodes, edges = n.logical_closure(
                        parents, subset, traversal=traversal
                    )
                    total += len(nodes) + len(edges)
            totals.append(total * 4)
    assert totals == [65796] * 4


@pytest.mark.parametrize(
    "dimension",
    [
        "ancestor_units",
        "pairs_path",
        "pairs_request",
        "cells_path",
        "cells_request",
        "retained_path",
        "retained_request",
        "origins_path",
        "origins_request",
        "paths",
        "facts",
        "depth",
    ],
)
def test_tiny_budgets_return_no_partial_result(dimension):
    n, _ = api()
    limits = n.Limits(**{dimension: 0})
    r = n.normalize(pool(), (rid("S0"),), (rid("A2"), rid("Y1")), limits=limits)
    assert (
        r.status == "ChoiceRequired"
        and r.reason.startswith("normalization-budget")
        and r.tree is None
    )


def test_seven_before_subsets_and_near_limit():
    n, _ = api()
    root = n.Fact(rid("fg"), "genesis", tr({}))
    base = n.Fact(rid("fb"), "candidate", tr(T(0)), basis=root.identity, scope=(f,))
    variants = [
        n.Fact(
            rid("f" + str(i)), "candidate", tr(T(1)), basis=base.identity, scope=(f,)
        )
        for i in range(7)
    ]
    r = n.normalize(
        [root, base, *variants], (root.identity,), tuple(v.identity for v in variants)
    )
    assert (
        r.status == "ChoiceRequired"
        and r.reason == "normalization-budget:frontier"
        and r.tree is None
    )
    good = n.normalize(pool(), (rid("SA1"),), (rid("A2"), rid("Z1")))
    exact = good.charge.ancestor_units
    assert exact > 0
    for limit, status in [
        (exact - 1, "ChoiceRequired"),
        (exact, "Ready"),
        (exact + 1, "Ready"),
    ]:
        assert (
            n.normalize(
                pool(),
                (rid("SA1"),),
                (rid("A2"), rid("Z1")),
                limits=n.Limits(ancestor_units=limit),
            ).status
            == status
        )


@given(st.permutations(("A2", "Z1")), st.booleans())
@settings(max_examples=10, deadline=None)
def test_order_and_cache_independence(selection, cache):
    n, _ = api()
    facts = pool()
    a = n.normalize(facts, (rid("SA1"),), tuple(map(rid, selection)), cache=cache)
    b = n.normalize(
        list(reversed(facts)), (rid("SA1"),), (rid("A2"), rid("Z1")), cache=not cache
    )
    assert a.status == b.status == "Ready" and a.tree == b.tree and a.charge == b.charge


@given(st.integers(0, 40), st.booleans())
@settings(max_examples=25, deadline=None)
def test_bounded_linear_history_no_double_apply(length, reverse):
    n, _ = api()
    root = n.Fact(rid("lg"), "genesis", tr({}))
    facts = [root]
    last = root.identity
    for i in range(length + 1):
        fct = n.Fact(
            rid("linear" + str(i)), "candidate", tr(T(i)), basis=last, scope=(f,)
        )
        facts.append(fct)
        last = fct.identity
    r = n.normalize(
        list(reversed(facts)) if reverse else facts, (root.identity,), (last,)
    )
    assert r.status == "Ready" and plain(r.tree) == T(length)


def test_logical_units_refuse_before_graph_read():
    n, _ = api()

    class NoRead(dict):
        def __getitem__(self, key):
            raise AssertionError("graph was read past zero budget")

    with pytest.raises(Exception) as error:
        n.logical_closure(NoRead({0: ()}), (0,), unit_limit=0)
    assert str(error.value) == "normalization-budget:ancestor_units"


def test_ambiguous_accepted_history_cannot_hide_in_empty_tree():
    n, _ = api()
    g0 = n.Fact(rid("emptyG"), "genesis", tr({}))
    u = n.Fact(rid("emptyU"), "accepted", tr({}), parents=(g0.identity,))
    v = n.Fact(rid("emptyV"), "accepted", tr({}), parents=(g0.identity,))
    q1 = n.Fact(rid("emptyQ1"), "accepted", tr({}), parents=(u.identity, v.identity))
    q2 = n.Fact(rid("emptyQ2"), "accepted", tr({}), parents=(u.identity, v.identity))
    r = n.normalize([g0, u, v, q1, q2], (q1.identity, q2.identity), (), reconcile=True)
    assert r.status == "ChoiceRequired" and r.reason == "comparison" and r.tree is None


def test_malformed_context_and_mutable_fact_fields_refuse():
    n, _ = api()
    facts, _, _ = structural()
    n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    bad = n.Resolution("not a context", rid("A"))
    assert (
        n.normalize(
            facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=(bad,)
        ).status
        == "InvalidContent"
    )
    fact = facts[0]
    assert (
        n.normalize([replace(fact, parents=[])], (fact.identity,), ()).status
        == "InvalidContent"
    )


def test_context_comparison_and_complete_source_binding():
    n, _ = api()
    facts, _, _ = structural(F(b"A"))
    r = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    context = r.conflicts[0]
    assert dict(context.comparisons)[(b"d",)].record == rid("base")
    assert {v for v, _ in context.sources} == {rid("sg"), rid("A"), rid("B")}


def test_budget_boundaries_overflow_and_long_material_graph():
    n, _ = api()
    from yeokcham.normalization_budget import (
        MAX_COUNT,
        BudgetExceeded,
        Counter,
        checked_add,
    )

    for limit in (65795, 65796, 65797):
        count = Counter(n.Limits(ancestor_units=limit))
        if limit < 65796:
            with pytest.raises(BudgetExceeded):
                count.units(65796)
        else:
            count.units(65796)
            assert count.snapshot().ancestor_units == 65796
    count = Counter(n.Limits())
    count.units(999999)
    count.units(1)
    with pytest.raises(BudgetExceeded):
        count.units(1)
    with pytest.raises(BudgetExceeded, match="counter-overflow"):
        checked_add(MAX_COUNT, 1, MAX_COUNT, "units")
    count = Counter(n.Limits())
    count.alignment((), b"a", b"b", 4000000)
    with pytest.raises(BudgetExceeded):
        count.alignment((), b"a", b"c", 4000001)
    for cells in (16000000, 64000000):
        assert cells > 4000000
    parents = {i: (i - 1,) if i else () for i in range(4096)}
    nodes, edges = n.logical_closure(parents, (4095,))
    assert (len(nodes), len(edges)) == (4096, 4095)
    parents[4096] = (4095,)
    with pytest.raises(BudgetExceeded):
        n.logical_closure(parents, (4096,))
    from yeokcham.errors import Code, ContentError

    with pytest.raises(ContentError) as cycle:
        n.logical_closure({0: (0,)}, (0,))
    assert cycle.value.code == Code.INVALID_CONTENT


@pytest.mark.parametrize("depth,status", [(256, "Ready"), (257, "ChoiceRequired")])
def test_dependency_depth_is_edges_and_has_no_recursive_stack(depth, status):
    n, _ = api()
    root = n.Fact(rid("deep-root"), "genesis", tr({}))
    facts = [root]
    for i in range(depth):
        facts.append(
            n.Fact(
                rid("deep" + str(i)),
                "candidate",
                tr(T(i)),
                basis=facts[-1].identity,
                scope=(f,),
            )
        )
    result = n.normalize(facts, (root.identity,), (facts[-1].identity,))
    assert result.status == status
    if status != "Ready":
        assert result.reason == "normalization-budget:depth" and result.tree is None


def test_value_saturation_and_multiple_budget_failure_priority():
    n, _ = api()
    root = n.Fact(rid("sat-root"), "genesis", tr({}))
    base = n.Fact(
        rid("sat-base"),
        "candidate",
        tr({f: F(b"a\nc\nb\n")}),
        basis=root.identity,
        scope=(f,),
    )
    values = [b"c\nb\nc\n", b"a\na\nb\nc\n", b"c\nc\nc\nb\n"]
    variants = [
        n.Fact(
            rid("sat" + str(i)),
            "candidate",
            tr({f: F(v)}),
            basis=base.identity,
            scope=(f,),
        )
        for i, v in enumerate(values)
    ]
    result = n.normalize(
        [root, base, *variants],
        (root.identity,),
        tuple(v.identity for v in variants),
        limits=n.Limits(states=1),
    )
    assert (
        result.status == "ChoiceRequired"
        and result.reason == "normalization-budget:states"
        and result.tree is None
    )
    a = n.normalize(
        pool(),
        (rid("S0"),),
        (rid("A2"), rid("Y1")),
        limits=n.Limits(pairs_path=0, pairs_request=0),
    )
    assert a.reason == "normalization-budget:pairs_path"


def test_six_valid_receipt_orders_and_unselected_bytes():
    n, _ = api()
    all_facts = pool()
    base = [v for v in all_facts if v.identity in set(map(rid, ("G", "R0", "S0")))]
    actors = {
        name: next(v for v in all_facts if v.identity == rid(name))
        for name in ("A1", "A2", "B1", "B2")
    }
    count = 0
    for order in permutations(actors):
        if order.index("A1") > order.index("A2") or order.index("B1") > order.index(
            "B2"
        ):
            continue
        result = n.normalize(
            base + [actors[v] for v in order], (rid("S0"),), (rid("A2"),)
        )
        assert (
            result.status == "Ready"
            and plain(result.tree) == T(2)
            and result.pending == (rid("B2"),)
        )
        count += 1
    assert count == 6
    secret = n.Fact(
        rid("outside"),
        "candidate",
        tr({**T(0), (b"secret",): F(b"not selected")}),
        basis=rid("S0"),
        scope=((b"secret",),),
    )
    result = n.normalize(all_facts + [secret], (rid("S0"),), (rid("A2"),))
    assert result.status == "Ready" and (b"secret",) not in dict(result.tree)
    assert rid("outside") not in result.dependencies
    assert not any(key.record == rid("outside") for key, _ in result.origins)


@given(st.binary(max_size=30), st.sampled_from([0, 2]), st.booleans())
@settings(max_examples=25, deadline=None)
def test_generated_structural_choices_preserve_whole_tree(payload, mode, choose_b):
    n, _ = api()
    facts, a, b = structural(F(payload, mode))
    prepared = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    choice = n.Resolution(prepared.conflicts[0], rid("B" if choose_b else "A"))
    result = n.normalize(
        facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=(choice,)
    )
    assert result.status == "Ready" and plain(result.tree) == {
        **(b if choose_b else a),
        (b"u",): F(b"new-u"),
    }


def _exhaustive_reference(parents, states, roots, leaf):
    # Independent whole-binary-tree oracle. It shares the separately tested byte
    # leaf, not the production subset solver, frontier reduction or charging.
    from itertools import product

    def ancestors(s):
        out = set()
        todo = list(s)
        while todo:
            node = todo.pop()
            if node not in out:
                out.add(node)
                todo.extend(parents[node])
        return out

    def maximal(s):
        return tuple(
            sorted(
                v for v in set(s) if not any(v != w and v in ancestors((w,)) for w in s)
            )
        )

    roots = maximal(roots)

    def walk(s):
        if len(s) == 1:
            return {states[s[0]]}, False
        values = set()
        ambiguous = False
        for size in range(1, len(s)):
            for left in combinations(s, size):
                if s[0] not in left:
                    continue
                right = tuple(v for v in s if v not in left)
                a, aa = walk(left)
                b, ba = walk(right)
                ambiguous |= aa or ba
                for x, y in product(a, b):
                    common = maximal(ancestors(left) & ancestors(right))
                    if len(common) != 1:
                        ambiguous = True
                        continue
                    success, value = leaf(states[common[0]], x, y)
                    if success:
                        values.add(value)
        return values, ambiguous

    values, ambiguous = walk(roots)
    return (
        ("ChoiceRequired", None)
        if ambiguous or len(values) > 1
        else ("Conflicted", None)
        if not values
        else ("Ready", next(iter(values)))
    )


@given(
    st.lists(st.tuples(st.integers(0, 20), st.integers(0, 3)), min_size=3, max_size=9),
    st.booleans(),
)
@settings(max_examples=35, deadline=None)
def test_generated_dag_against_exhaustive_tree_oracle(steps, reverse):
    n, c = api()
    from yeokcham.normalization_budget import Counter

    root = n.Fact(rid("dagroot"), "genesis", tr({}))
    facts = [root]
    origins = [0]
    parents = {0: ()}
    states = {0: None}
    for i, (parent, value) in enumerate(steps, 1):
        index = parent % len(facts)
        node = n.Node(n.Mode.REGULAR, f"x={value}\n".encode())
        basis = facts[index]
        old = origins[index]
        facts.append(
            n.Fact(
                rid("dag" + str(i)),
                "candidate",
                n.tree({f: node}),
                basis=basis.identity,
                scope=() if states[old] == node else (f,),
            )
        )
        if states[old] == node:
            origins.append(old)
        else:
            parents[i] = (old,)
            states[i] = node
            origins.append(i)
    selected = tuple(v.identity for v in facts[-3:])

    def leaf(base, left, right):
        return c.merge_state(base, left, right, Counter(n.Limits()), f)

    expected, value = _exhaustive_reference(
        parents, states, tuple([0] + origins[-3:]), leaf
    )
    result = n.normalize(
        list(reversed(facts)) if reverse else facts, (root.identity,), selected
    )
    assert result.status == expected
    if expected == "Ready":
        assert dict(result.tree)[f] == value
    else:
        assert result.tree is None


def test_ancestor_subset_input_is_bounded_before_copy():
    n, _ = api()
    from yeokcham.normalization_budget import BudgetExceeded

    with pytest.raises(BudgetExceeded, match="origins_path"):
        n.logical_closure({0: ()}, tuple(range(4097)))
    with pytest.raises(ValueError):
        n.logical_closure({0: ()}, (0,), max_nodes=4097)


def test_budget_refusal_is_structured_data():
    n, _ = api()
    result = n.normalize(
        pool(), (rid("S0"),), (rid("A2"),), limits=n.Limits(ancestor_units=0)
    )
    assert (
        result.tree is None
        and result.budget.dimension == "ancestor_units"
        and result.budget.limit == 0
    )


def test_alignment_memo_does_not_repeat_matrix_allocation(monkeypatch):
    _, c = api()
    from yeokcham.normalization_budget import Counter, Limits

    counter = Counter(Limits())
    base = b"x=0\ny=0\n"
    left = b"x=1\ny=0\n"
    right = b"x=0\ny=1\n"
    assert c.merge_bytes(base, left, right, counter=counter, path=f) == b"x=1\ny=1\n"

    def forbidden(*args, **kwargs):
        raise AssertionError("repeated matrix allocation")

    monkeypatch.setattr(c, "array", forbidden)
    assert c.merge_bytes(base, left, right, counter=counter, path=g) == b"x=1\ny=1\n"
    assert counter.local_cells[f] == counter.local_cells[g]


@pytest.mark.parametrize("base_mode,left_mode", [(0, 2), (2, 0)])
def test_symlink_conversion_and_concurrent_content_edit_conflict(base_mode, left_mode):
    n, _ = api()
    root = n.Fact(rid("link-root"), "genesis", tr({}))
    base = n.Fact(
        rid("link-base"),
        "candidate",
        tr({f: F(b"old", base_mode)}),
        basis=root.identity,
        scope=(f,),
    )
    left = n.Fact(
        rid("link-left"),
        "candidate",
        tr({f: F(b"old", left_mode)}),
        basis=base.identity,
        scope=(f,),
    )
    right = n.Fact(
        rid("link-right"),
        "candidate",
        tr({f: F(b"new", base_mode)}),
        basis=base.identity,
        scope=(f,),
    )
    result = n.normalize(
        [root, base, left, right], (root.identity,), (left.identity, right.identity)
    )
    assert result.status == "Conflicted" and result.tree is None


def test_executable_bit_and_regular_content_change_can_combine():
    n, _ = api()
    root = n.Fact(rid("exec-root"), "genesis", tr({}))
    base = n.Fact(
        rid("exec-base"),
        "candidate",
        tr({f: F(b"old")}),
        basis=root.identity,
        scope=(f,),
    )
    left = n.Fact(
        rid("exec-left"),
        "candidate",
        tr({f: F(b"old", 1)}),
        basis=base.identity,
        scope=(f,),
    )
    right = n.Fact(
        rid("exec-right"),
        "candidate",
        tr({f: F(b"new")}),
        basis=base.identity,
        scope=(f,),
    )
    result = n.normalize(
        [root, base, left, right], (root.identity,), (left.identity, right.identity)
    )
    assert result.status == "Ready" and plain(result.tree) == {f: F(b"new", 1)}


@pytest.mark.parametrize("replacement", [None, F(b"file"), F(b"target", 2)])
@pytest.mark.parametrize("chosen", ["A", "B"])
def test_parent_replacement_with_existing_child_edit_lifts_conflict(
    replacement, chosen
):
    n, _ = api()
    facts, a, b = structural(replacement)
    b = {p: v for p, v in b.items() if p != (b"d", b"g")}
    b[(b"d", b"f")] = F(b"edited")
    facts = [replace(v, tree=tr(b)) if v.identity == rid("B") else v for v in facts]
    prepared = n.normalize(facts, (rid("sg"),), (rid("A"), rid("B")))
    assert prepared.status == "Conflicted" and prepared.conflicts[0].path == (b"d",)
    choice = n.Resolution(prepared.conflicts[0], rid(chosen))
    resolved = n.normalize(
        facts, (rid("sg"),), (rid("A"), rid("B")), resolutions=(choice,)
    )
    assert resolved.status == "Ready" and plain(resolved.tree) == {
        **(a if chosen == "A" else b),
        (b"u",): F(b"new-u"),
    }
