"""M1a.3 exact public expressions and comparison-based subtree replacement."""

from dataclasses import replace
from itertools import permutations

import pytest
from hypothesis import given, seed, settings
from hypothesis import strategies as st
from normalization_cases import CASES, FACTS, D, F, T, f
from test_normalization import plain, rid, tr
from yeokcham import normalization as n


def public_pool():
    facts = []
    expressions = {}
    groups = {}
    roles = {row[0]: row[1] for row in FACTS}
    for name, role, inputs, value, previous, scope, choices in FACTS:
        if role == "compose":
            expressions[rid(name)] = n.Compose(
                tuple(rid(v) for v in inputs if roles[v] != "candidate"),
                tuple(rid(v) for v in inputs if roles[v] == "candidate"),
                tr(value),
            )
            continue
        change = groups.get(previous, rid(name).raw[:16])
        groups[name] = change
        parents = tuple(rid(v) for v in inputs if roles[v] != "candidate") if role == "accepted" else ()
        selected = tuple(rid(v) for v in inputs if roles[v] == "candidate") if role == "accepted" else ()
        resolutions = ()
        if choices:
            preview = n.normalize(facts, parents, selected, reconcile=len(parents) > 1)
            resolutions = tuple(n.Resolution(next(c for c in preview.conflicts if c.path == path), rid(choice)) for path, choice in choices.items())
        facts.append(n.Fact(rid(name), role, tr(value), basis=expressions.get(rid(inputs[0]), rid(inputs[0])) if role == "candidate" else None, parents=parents, selected=selected, predecessor=rid(previous) if previous else None, scope=scope, change=change, resolutions=resolutions))
    return facts


def needed_pool(facts, roots):
    by_id = {v.identity: v for v in facts}
    needed = set(roots)
    todo = list(roots)
    while todo:
        fact = by_id[todo.pop()]
        deps = fact.parents + fact.selected
        if isinstance(fact.basis, n.Compose):
            deps += fact.basis.accepted + fact.basis.selected
        elif fact.basis is not None:
            deps += (fact.basis,)
        if fact.predecessor is not None:
            deps += (fact.predecessor,)
        for dep in deps:
            if dep not in needed:
                needed.add(dep)
                todo.append(dep)
    return [v for v in facts if v.identity in needed]


@pytest.mark.parametrize("case", CASES, ids=lambda c: c[0])
def test_all_m0_normative_public_results(case):
    label, targets, selected, status, expected = case
    facts = public_pool()
    targets, selected = tuple(map(rid, targets)), tuple(map(rid, selected))
    kwargs = {"expected_heads": (rid("S0"),), "current_heads": (rid("SB"),)} if label == "S18" else {}
    result = n.normalize(needed_pool(facts, targets + selected), targets, selected, reconcile=len(targets) > 1, **kwargs)
    assert result.status == status
    assert (None if result.tree is None else plain(result.tree)) == expected


def compose_facts():
    return needed_pool(public_pool(), (rid("S0"), rid("CQ"), rid("A2"), rid("B2")))


def test_compose_exact_lineage_selection_and_double_application():
    facts = compose_facts()
    result = n.normalize(facts, (rid("S0"),), (rid("CQ"),))
    assert result.status == "Ready"
    assert plain(result.tree) == {**T(1, 1), (b"c.txt",): F(b"composed\n")}
    assert result.selected == (rid("CQ"),)
    assert rid("A1") in result.dependencies and rid("Y1") in result.dependencies
    assert rid("A1") not in result.selected and rid("B2") in result.pending
    key = dict(result.lineage)[f]
    assert key == n.OriginKey(rid("CQ"), "basis", f)
    assert set(dict(result.origins)[key].parents) == {n.OriginKey(rid("A1"), "result", f), n.OriginKey(rid("Y1"), "result", f)}
    twice = n.normalize(facts, (rid("S0"),), (rid("CQ"), rid("A1")))
    assert twice.status == "Ready" and twice.tree == result.tree


def test_compose_basis_result_slots_and_equal_history_distinction():
    facts = compose_facts()
    cq = next(v for v in facts if v.identity == rid("CQ"))
    other = replace(cq, identity=rid("other-CQ"))
    changed = replace(cq, identity=rid("changed-CQ"), tree=tr({**T(2, 1), (b"c.txt",): F(b"composed\n")}), scope=(f, (b"c.txt",)))
    result = n.normalize(facts + [other, changed], (rid("S0"),), (cq.identity, other.identity))
    assert result.status == "Ready"
    parents = dict(result.origins)[dict(result.lineage)[f]].parents
    assert set(parents) == {n.OriginKey(cq.identity, "basis", f), n.OriginKey(other.identity, "basis", f)}
    result = n.normalize(facts + [changed], (rid("S0"),), (changed.identity,))
    key = dict(result.lineage)[f]
    assert key == n.OriginKey(changed.identity, "result", f)
    assert dict(result.origins)[key].parents == (n.OriginKey(changed.identity, "basis", f),)


@pytest.mark.parametrize("fault,status,reason", [
    ("claim", "IntegrityFailure", "claim"),
    ("missing", "Unavailable", "missing"),
    ("cycle", "InvalidContent", "cyclic"),
    ("profile", "ChoiceRequired", "profile"),
    ("conflict", "Conflicted", "content-or-structure"),
    ("private", "InvalidContent", "kind"),
    ("role", "InvalidContent", "accepted"),
])
def test_inner_compose_refusals(fault, status, reason):
    facts = compose_facts()
    cq = next(v for v in facts if v.identity == rid("CQ"))
    basis = cq.basis
    if fault == "claim":
        basis = replace(basis, claimed=tr(T(9)))
    elif fault == "missing":
        facts = [v for v in facts if v.identity != rid("Y1")]
    elif fault == "cycle":
        basis = replace(basis, selected=(cq.identity,))
    elif fault == "profile":
        basis = replace(basis, profile=("unknown", "line-hunks-v1"))
    elif fault == "conflict":
        basis = replace(basis, selected=(rid("A2"), rid("B2")))
    elif fault == "private":
        facts = [replace(v, kind="private") if v.identity == rid("Y1") else v for v in facts]
    else:
        basis = replace(basis, accepted=(rid("A1"),))
    facts = [replace(v, basis=basis) if v.identity == cq.identity else v for v in facts]
    result = n.normalize(facts, (rid("S0"),), (cq.identity,))
    assert result.status == status and result.tree is None and reason in result.reason


def test_inner_comparison_and_nonconfluence_propagate():
    facts = public_pool()
    expr = n.Compose((rid("SL"), rid("SR")), (), tr(T(2, 1)))
    candidate = n.Fact(rid("ambiguous"), "candidate", tr({**T(2, 1), (b"new",): F(b"new")}), basis=expr, scope=((b"new",),))
    r = n.normalize(facts + [candidate], (rid("S0"),), (candidate.identity,))
    assert r.status == "ChoiceRequired" and r.reason == "comparison" and r.tree is None
    root = n.Fact(rid("nc-G"), "genesis", ())
    base = n.Fact(rid("nc-base"), "candidate", tr({f: F(b"a\nc\nb\n")}), basis=root.identity, scope=(f,))
    variants = [n.Fact(rid("nc-" + str(i)), "candidate", tr({f: F(data)}), basis=base.identity, scope=(f,)) for i, data in enumerate((b"c\nb\nc\n", b"a\na\nb\nc\n", b"c\nc\nc\nb\n"))]
    expr = n.Compose((root.identity,), tuple(v.identity for v in variants), ())
    outer = n.Fact(rid("nc-outer"), "candidate", (), basis=expr)
    r = n.normalize([root, base, *variants, outer], (root.identity,), (outer.identity,))
    assert r.status == "ChoiceRequired" and r.reason == "nonconfluent" and r.tree is None


def nested(depth):
    root = n.Fact(rid("nested-G"), "genesis", ())
    facts = [root]
    for i in range(depth):
        expr = n.Compose((root.identity,), () if i == 0 else (facts[-1].identity,), () if i == 0 else facts[-1].tree)
        facts.append(n.Fact(rid("nested" + str(i)), "candidate", tr({f: F(str(i).encode())}), basis=expr, scope=(f,)))
    return facts


def test_nested_depth_preflight_and_zero_budget():
    facts = nested(5)
    for cache in (False, True):
        r = n.normalize(facts, (facts[0].identity,), (facts[-1].identity,), limits=n.Limits(depth=10), cache=cache)
        assert r.status == "Ready" and plain(r.tree) == {f: F(b"4")}
        r = n.normalize(facts, (facts[0].identity,), (facts[-1].identity,), limits=n.Limits(depth=9), cache=cache)
        assert r.status == "ChoiceRequired" and r.budget.dimension == "depth" and r.charge.origins == 0
        r = n.normalize(facts, (facts[0].identity,), (facts[-1].identity,), limits=n.Limits(ancestor_units=0), cache=cache)
        assert r.status == "ChoiceRequired" and r.budget.dimension == "ancestor_units" and r.tree is None


@seed(20261121)
@settings(max_examples=20, deadline=None)
@given(st.permutations(tuple(range(8))), st.booleans())
def test_compose_receipt_order_and_cache(fact_order, cache):
    facts = needed_pool(public_pool(), (rid("S0"), rid("CQ")))
    # Stable generated sort keys cover permutations without assuming fixture length.
    ordered = sorted(enumerate(facts), key=lambda v: (fact_order[v[0] % 8], v[0]))
    actual = n.normalize([v for _, v in ordered], (rid("S0"),), (rid("CQ"),), cache=cache)
    expected = n.normalize(facts, (rid("S0"),), (rid("CQ"),))
    assert actual == expected and actual.status == "Ready"


d = (b"d",)
df = d + (b"f",)
dg = d + (b"g",)
u = (b"u",)


def structural():
    root = n.Fact(rid("lit-G"), "genesis", ())
    base = n.Fact(rid("lit-base"), "candidate", tr({d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"old-u")}), basis=root.identity, scope=(d, u))
    a = n.Fact(rid("lit-A"), "candidate", tr({d: F(b"file"), u: F(b"old-u")}), basis=base.identity, scope=(d,))
    b = n.Fact(rid("lit-B"), "candidate", tr({d: D, df: F(b"edited"), dg: F(b"g-old"), u: F(b"new-u")}), basis=base.identity, scope=(df, u))
    facts = [root, base, a, b]
    preview = n.normalize(facts, (root.identity,), (a.identity, b.identity))
    assert preview.status == "Conflicted" and len(preview.conflicts) == 1
    return facts, preview.conflicts[0]


def literal(context, replacement):
    return n.Resolution(context, None, tr(replacement), intent="literal")


@pytest.mark.parametrize("replacement", [
    {d: F(b"literal")}, {d: F(b"run", 1)}, {d: F(b"../raw\xff", 2)},
    {d: D, df: F(b"new"), dg: F(b"other")}, {d: D}, {},
])
def test_literal_exact_tree_and_comparison_only_lineage(replacement):
    facts, context = structural()
    root, base, a, b = facts
    result = n.normalize(facts, (root.identity,), (a.identity, b.identity), resolutions=(literal(context, replacement),))
    assert result.status == "Ready" and plain(result.tree) == {**replacement, u: F(b"new-u")}
    for path, key in result.lineage:
        if path[:1] == d:
            assert key.record is None and key.slot == "proposed-resolution"
            assert dict(result.origins)[key].parents == (dict(context.comparisons)[path],)
    assert set(result.retained) == {v.identity for v in facts}
    # A public accepted fact rederives those origins; rejected continuation is not dominated.
    accepted = n.Fact(rid("literal-accepted"), "accepted", result.tree, parents=(root.identity,), selected=(a.identity, b.identity), resolutions=(literal(context, replacement),))
    verified = n.normalize(facts + [accepted], (accepted.identity,), ())
    assert verified.status == "Ready" and verified.tree == result.tree
    parents = dict(verified.origins)[dict(verified.lineage)[d]].parents
    assert parents == (dict(context.comparisons)[d],)
    assert n.OriginKey(a.identity, "result", d) not in parents
    later = replace(b, identity=rid("later-rejected-B"), basis=b.identity, tree=tr({d: D, df: F(b"later"), dg: F(b"g-old"), u: F(b"new-u")}), scope=(df,))
    proposed = n.normalize(facts + [accepted, later], (accepted.identity,), (later.identity,))
    assert proposed.status in ("Ready", "Conflicted")
    if proposed.status == "Ready":
        assert proposed.tree != accepted.tree
    assert later.identity in proposed.retained


def test_comparison_choice_is_explicit_and_does_not_infer_equal_byte_lineage():
    facts, context = structural()
    r = n.normalize(facts, (facts[0].identity,), (facts[2].identity, facts[3].identity), resolutions=(n.Resolution(context, None, intent="comparison"),))
    assert r.status == "Ready" and plain(r.tree) == {d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"new-u")}
    for path, key in r.lineage:
        if path[:1] == d:
            assert key == dict(context.comparisons)[path]
    same = n.normalize(facts, (facts[0].identity,), (facts[2].identity, facts[3].identity), resolutions=(literal(context, {d: D, df: F(b"old"), dg: F(b"g-old")}),))
    assert same.tree == r.tree and dict(same.lineage)[d] != dict(r.lineage)[d]


@pytest.mark.parametrize("fault,status,reason", [
    ("stale", "IntegrityFailure", "context"), ("comparison", "IntegrityFailure", "context"),
    ("missing", "Unavailable", "replacement"), ("structure", "InvalidContent", "structure"),
    ("overlap", "InvalidContent", "overlap"), ("duplicate", "InvalidContent", "overlap"),
    ("scope", "InvalidContent", "unused"), ("new-path", "ChoiceRequired", "new-path"),
    ("profile", "ChoiceRequired", "profile"), ("budget", "ChoiceRequired", "retained_path"),
])
def test_literal_refusals(fault, status, reason):
    facts, context = structural()
    choice = literal(context, {d: F(b"literal")})
    resolutions = (choice,)
    limits = None
    if fault == "stale":
        resolutions = (replace(choice, context=replace(context, selected=())),)
    elif fault == "comparison":
        comparisons = tuple((p, n.OriginKey(rid("fake"), "result", p)) for p, _ in context.comparisons)
        resolutions = (replace(choice, context=replace(context, comparisons=comparisons)),)
    elif fault == "missing":
        resolutions = (replace(choice, replacement=None),)
    elif fault == "structure":
        resolutions = (literal(context, {df: F(b"orphan")}),)
    elif fault in ("overlap", "duplicate"):
        resolutions = (choice, choice if fault == "duplicate" else replace(choice, context=replace(context, path=df)))
    elif fault == "scope":
        resolutions = (replace(choice, context=replace(context, path=u)),)
    elif fault == "new-path":
        resolutions = (literal(context, {d: D, (b"d", b"novel"): F(b"new")}),)
    elif fault == "profile":
        resolutions = (replace(choice, profile=("unsupported", "line-hunks-v1")),)
    else:
        limits = n.Limits(retained_path=4)
    r = n.normalize(facts, (facts[0].identity,), (facts[2].identity, facts[3].identity), resolutions=resolutions, limits=limits)
    assert r.status == status and r.tree is None and reason in r.reason


@seed(20261122)
@settings(max_examples=20, deadline=None)
@given(st.binary(max_size=32), st.booleans(), st.booleans())
def test_literal_permutation_property(data, reverse, cache):
    facts, context = structural()
    selected = (facts[2].identity, facts[3].identity)
    if reverse:
        facts = list(reversed(facts))
        selected = tuple(reversed(selected))
    r = n.normalize(facts, (rid("lit-G"),), selected, resolutions=(literal(context, {d: F(data)}),), cache=cache)
    assert r.status == "Ready" and plain(r.tree) == {d: F(data), u: F(b"new-u")}
    assert dict(r.origins)[dict(r.lineage)[d]].parents == (dict(context.comparisons)[d],)
