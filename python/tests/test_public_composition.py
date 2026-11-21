"""M1a.3 exact public expressions and comparison-based subtree replacement."""

from dataclasses import replace

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
        resolutions = ()
        if choices:
            preview = n.normalize(facts, parents, selected, reconcile=len(parents) > 1)
            resolutions = tuple(
                n.Resolution(
                    next(c for c in preview.conflicts if c.path == path), rid(choice)
                )
                for path, choice in choices.items()
            )
        facts.append(
            n.Fact(
                rid(name),
                role,
                tr(value),
                basis=expressions.get(rid(inputs[0]), rid(inputs[0]))
                if role == "candidate"
                else None,
                parents=parents,
                selected=selected,
                predecessor=rid(previous) if previous else None,
                scope=scope,
                change=change,
                resolutions=resolutions,
            )
        )
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
    kwargs = (
        {"expected_heads": (rid("S0"),), "current_heads": (rid("SB"),)}
        if label == "S18"
        else {}
    )
    result = n.normalize(
        needed_pool(facts, targets + selected),
        targets,
        selected,
        reconcile=len(targets) > 1,
        **kwargs,
    )
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
    assert set(dict(result.origins)[key].parents) == {
        n.OriginKey(rid("A1"), "result", f),
        n.OriginKey(rid("Y1"), "result", f),
    }
    twice = n.normalize(facts, (rid("S0"),), (rid("CQ"), rid("A1")))
    assert twice.status == "Ready" and twice.tree == result.tree


def test_compose_basis_result_slots_and_equal_history_distinction():
    facts = compose_facts()
    cq = next(v for v in facts if v.identity == rid("CQ"))
    other = replace(cq, identity=rid("other-CQ"))
    changed = replace(
        cq,
        identity=rid("changed-CQ"),
        tree=tr({**T(2, 1), (b"c.txt",): F(b"composed\n")}),
        scope=(f, (b"c.txt",)),
    )
    first = n.normalize(facts, (rid("S0"),), (cq.identity,))
    second = n.normalize(facts + [other], (rid("S0"),), (other.identity,))
    assert (
        first.tree == second.tree and dict(first.lineage)[f] != dict(second.lineage)[f]
    )
    result = n.normalize(facts + [other], (rid("S0"),), (cq.identity, other.identity))
    # Independent oracle: both A1 and Y1 are maximal recorded comparisons.
    assert result.status == "ChoiceRequired" and result.reason == "comparison"
    assert result.tree is None
    result = n.normalize(facts + [changed], (rid("S0"),), (changed.identity,))
    key = dict(result.lineage)[f]
    assert key == n.OriginKey(changed.identity, "result", f)
    assert dict(result.origins)[key].parents == (
        n.OriginKey(changed.identity, "basis", f),
    )


@pytest.mark.parametrize(
    "fault,status,reason",
    [
        ("claim", "IntegrityFailure", "claim"),
        ("missing", "Unavailable", "missing"),
        ("cycle", "InvalidContent", "cyclic"),
        ("profile", "ChoiceRequired", "profile"),
        ("conflict", "Conflicted", "content-or-structure"),
        ("private", "InvalidContent", "kind"),
        ("role", "InvalidContent", "accepted"),
    ],
)
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
        facts = [
            replace(v, kind="private") if v.identity == rid("Y1") else v for v in facts
        ]
    else:
        basis = replace(basis, accepted=(rid("A1"),))
    facts = [replace(v, basis=basis) if v.identity == cq.identity else v for v in facts]
    result = n.normalize(facts, (rid("S0"),), (cq.identity,))
    assert result.status == status and result.tree is None and reason in result.reason


def test_inner_comparison_and_nonconfluence_propagate():
    facts = public_pool()
    expr = n.Compose((rid("SL"), rid("SR")), (), tr(T(2, 1)))
    candidate = n.Fact(
        rid("ambiguous"),
        "candidate",
        tr({**T(2, 1), (b"new",): F(b"new")}),
        basis=expr,
        scope=((b"new",),),
    )
    r = n.normalize(facts + [candidate], (rid("S0"),), (candidate.identity,))
    assert r.status == "ChoiceRequired" and r.reason == "comparison" and r.tree is None
    root = n.Fact(rid("nc-G"), "genesis", ())
    base = n.Fact(
        rid("nc-base"),
        "candidate",
        tr({f: F(b"a\nc\nb\n")}),
        basis=root.identity,
        scope=(f,),
    )
    variants = [
        n.Fact(
            rid("nc-" + str(i)),
            "candidate",
            tr({f: F(data)}),
            basis=base.identity,
            scope=(f,),
        )
        for i, data in enumerate((b"c\nb\nc\n", b"a\na\nb\nc\n", b"c\nc\nc\nb\n"))
    ]
    expr = n.Compose((root.identity,), tuple(v.identity for v in variants), ())
    outer = n.Fact(rid("nc-outer"), "candidate", (), basis=expr)
    r = n.normalize([root, base, *variants, outer], (root.identity,), (outer.identity,))
    assert (
        r.status == "ChoiceRequired" and r.reason == "nonconfluent" and r.tree is None
    )


def nested(depth):
    root = n.Fact(rid("nested-G"), "genesis", ())
    facts = [root]
    for i in range(depth):
        expr = n.Compose(
            (root.identity,),
            () if i == 0 else (facts[-1].identity,),
            () if i == 0 else facts[-1].tree,
        )
        facts.append(
            n.Fact(
                rid("nested" + str(i)),
                "candidate",
                tr({f: F(str(i).encode())}),
                basis=expr,
                scope=(f,),
            )
        )
    return facts


def test_nested_depth_preflight_and_zero_budget():
    facts = nested(5)
    for cache in (False, True):
        r = n.normalize(
            facts,
            (facts[0].identity,),
            (facts[-1].identity,),
            limits=n.Limits(depth=10),
            cache=cache,
        )
        assert r.status == "Ready" and plain(r.tree) == {f: F(b"4")}
        r = n.normalize(
            facts,
            (facts[0].identity,),
            (facts[-1].identity,),
            limits=n.Limits(depth=9),
            cache=cache,
        )
        assert (
            r.status == "ChoiceRequired"
            and r.budget.dimension == "depth"
            and r.charge.origins == 0
        )
        r = n.normalize(
            facts,
            (facts[0].identity,),
            (facts[-1].identity,),
            limits=n.Limits(ancestor_units=0),
            cache=cache,
        )
        assert (
            r.status == "ChoiceRequired"
            and r.budget.dimension == "ancestor_units"
            and r.tree is None
        )


@seed(20261121)
@settings(max_examples=20, deadline=None)
@given(st.permutations(tuple(range(8))), st.booleans())
def test_compose_receipt_order_and_cache(fact_order, cache):
    facts = needed_pool(public_pool(), (rid("S0"), rid("CQ")))
    # Stable generated sort keys cover permutations without assuming fixture length.
    ordered = sorted(enumerate(facts), key=lambda v: (fact_order[v[0] % 8], v[0]))
    actual = n.normalize(
        [v for _, v in ordered], (rid("S0"),), (rid("CQ"),), cache=cache
    )
    expected = n.normalize(facts, (rid("S0"),), (rid("CQ"),))
    assert actual == expected and actual.status == "Ready"


d = (b"d",)
df = d + (b"f",)
dg = d + (b"g",)
u = (b"u",)


def structural():
    root = n.Fact(rid("lit-G"), "genesis", ())
    base = n.Fact(
        rid("lit-base"),
        "candidate",
        tr({d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"old-u")}),
        basis=root.identity,
        scope=(d, u),
    )
    a = n.Fact(
        rid("lit-A"),
        "candidate",
        tr({d: F(b"file"), u: F(b"old-u")}),
        basis=base.identity,
        scope=(d,),
    )
    b = n.Fact(
        rid("lit-B"),
        "candidate",
        tr({d: D, df: F(b"edited"), dg: F(b"g-old"), u: F(b"new-u")}),
        basis=base.identity,
        scope=(df, u),
    )
    facts = [root, base, a, b]
    preview = n.normalize(facts, (root.identity,), (a.identity, b.identity))
    assert preview.status == "Conflicted" and len(preview.conflicts) == 1
    return facts, preview.conflicts[0]


def literal(context, replacement):
    return n.Resolution(context, None, tr(replacement), intent="literal")


@pytest.mark.parametrize(
    "replacement",
    [
        {d: F(b"literal")},
        {d: F(b"run", 1)},
        {d: F(b"../raw\xff", 2)},
        {d: D, df: F(b"new"), dg: F(b"other")},
        {d: D},
        {},
    ],
)
def test_literal_exact_tree_and_comparison_only_lineage(replacement):
    facts, context = structural()
    root, _base, a, b = facts
    result = n.normalize(
        facts,
        (root.identity,),
        (a.identity, b.identity),
        resolutions=(literal(context, replacement),),
    )
    assert result.status == "Ready" and plain(result.tree) == {
        **replacement,
        u: F(b"new-u"),
    }
    for path, key in result.lineage:
        if path[:1] == d:
            assert key.record is None and key.slot == "proposed-resolution"
            assert dict(result.origins)[key].parents == (
                dict(context.comparisons)[path],
            )
    assert set(result.retained) == {v.identity for v in facts}
    # A public accepted fact rederives those origins; rejected continuation is not dominated.
    accepted = n.Fact(
        rid("literal-accepted"),
        "accepted",
        result.tree,
        parents=(root.identity,),
        selected=(a.identity, b.identity),
        resolutions=(literal(context, replacement),),
    )
    verified = n.normalize(facts + [accepted], (accepted.identity,), ())
    assert verified.status == "Ready" and verified.tree == result.tree
    parents = dict(verified.origins)[dict(verified.lineage)[d]].parents
    assert parents == (dict(context.comparisons)[d],)
    assert n.OriginKey(a.identity, "result", d) not in parents
    later = replace(
        b,
        identity=rid("later-rejected-B"),
        basis=b.identity,
        tree=tr({d: D, df: F(b"later"), dg: F(b"g-old"), u: F(b"new-u")}),
        scope=(df,),
    )
    proposed = n.normalize(
        facts + [accepted, later], (accepted.identity,), (later.identity,)
    )
    assert proposed.status == "Conflicted" and proposed.tree is None
    assert later.identity in proposed.retained


def test_comparison_choice_is_explicit_and_does_not_infer_equal_byte_lineage():
    facts, context = structural()
    r = n.normalize(
        facts,
        (facts[0].identity,),
        (facts[2].identity, facts[3].identity),
        resolutions=(n.Resolution(context, None, intent="comparison"),),
    )
    assert r.status == "Ready" and plain(r.tree) == {
        d: D,
        df: F(b"old"),
        dg: F(b"g-old"),
        u: F(b"new-u"),
    }
    for path, key in r.lineage:
        if path[:1] == d:
            assert key == dict(context.comparisons)[path]
    same = n.normalize(
        facts,
        (facts[0].identity,),
        (facts[2].identity, facts[3].identity),
        resolutions=(literal(context, {d: D, df: F(b"old"), dg: F(b"g-old")}),),
    )
    assert same.tree == r.tree and dict(same.lineage)[d] != dict(r.lineage)[d]


@pytest.mark.parametrize(
    "fault,status,reason",
    [
        ("stale", "IntegrityFailure", "context"),
        ("comparison", "IntegrityFailure", "context"),
        ("missing", "Unavailable", "replacement"),
        ("structure", "InvalidContent", "structure"),
        ("overlap", "InvalidContent", "overlap"),
        ("duplicate", "InvalidContent", "overlap"),
        ("scope", "InvalidContent", "unused"),
        ("new-path", "ChoiceRequired", "new-path"),
        ("profile", "ChoiceRequired", "profile"),
        ("budget", "ChoiceRequired", "retained_path"),
    ],
)
def test_literal_refusals(fault, status, reason):
    facts, context = structural()
    choice = literal(context, {d: F(b"literal")})
    resolutions = (choice,)
    limits = None
    if fault == "stale":
        resolutions = (replace(choice, context=replace(context, selected=())),)
    elif fault == "comparison":
        comparisons = tuple(
            (p, n.OriginKey(rid("fake"), "result", p)) for p, _ in context.comparisons
        )
        resolutions = (
            replace(choice, context=replace(context, comparisons=comparisons)),
        )
    elif fault == "missing":
        resolutions = (replace(choice, replacement=None),)
    elif fault == "structure":
        resolutions = (literal(context, {df: F(b"orphan")}),)
    elif fault in ("overlap", "duplicate"):
        resolutions = (
            choice,
            choice
            if fault == "duplicate"
            else replace(choice, context=replace(context, path=df)),
        )
    elif fault == "scope":
        resolutions = (
            replace(
                choice,
                context=replace(context, path=u),
                replacement=tr({u: F(b"literal")}),
            ),
        )
    elif fault == "new-path":
        resolutions = (literal(context, {d: D, (b"d", b"novel"): F(b"new")}),)
    elif fault == "profile":
        resolutions = (replace(choice, profile=("unsupported", "line-hunks-v1")),)
    else:
        limits = n.Limits(retained_path=4)
    r = n.normalize(
        facts,
        (facts[0].identity,),
        (facts[2].identity, facts[3].identity),
        resolutions=resolutions,
        limits=limits,
    )
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
    r = n.normalize(
        facts,
        (rid("lit-G"),),
        selected,
        resolutions=(literal(context, {d: F(data)}),),
        cache=cache,
    )
    assert r.status == "Ready" and plain(r.tree) == {d: F(data), u: F(b"new-u")}
    assert dict(r.origins)[dict(r.lineage)[d]].parents == (
        dict(context.comparisons)[d],
    )


def test_compose_with_resolution_then_continuation():
    facts, context = structural()
    root, _base, a, b = facts
    expression = n.Compose(
        (root.identity,),
        (a.identity, b.identity),
        tr({d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"new-u")}),
        resolutions=(n.Resolution(context, None, intent="comparison"),),
    )
    outer = n.Fact(
        rid("resolved-compose"),
        "candidate",
        tr({d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"outer")}),
        basis=expression,
        scope=(u,),
    )
    r = n.normalize(facts + [outer], (root.identity,), (outer.identity,))
    assert r.status == "Ready" and r.tree == outer.tree
    assert dict(r.lineage)[d] == dict(context.comparisons)[d]
    continuation = replace(
        outer,
        identity=rid("after-compose"),
        basis=outer.identity,
        predecessor=outer.identity,
        tree=tr({d: D, df: F(b"old"), dg: F(b"g-old"), u: F(b"continued")}),
        scope=(u,),
    )
    r = n.normalize(
        facts + [outer, continuation], (root.identity,), (continuation.identity,)
    )
    assert r.status == "Ready" and r.tree == continuation.tree
    assert dict(r.origins)[dict(r.lineage)[u]].parents == (
        n.OriginKey(outer.identity, "result", u),
    )


@pytest.mark.parametrize(
    "depth,status", [(127, "Ready"), (128, "Ready"), (129, "ChoiceRequired")]
)
def test_default_nested_depth_boundary(depth, status):
    facts = nested(depth)
    r = n.normalize(facts, (facts[0].identity,), (facts[-1].identity,))
    assert r.status == status
    if status == "Ready":
        assert r.tree == facts[-1].tree
    else:
        assert (
            r.tree is None and r.budget.dimension == "depth" and r.charge.origins == 0
        )


@pytest.mark.parametrize(
    "fault,dimension",
    [
        ("selected", "selected"),
        ("fanout", "fanout"),
        ("pairs", "pairs_path"),
        ("cells", "cells_alignment"),
        ("payload", "retained_path"),
    ],
)
def test_inner_compose_resource_guards(fault, dimension):
    facts = compose_facts()
    cq = next(v for v in facts if v.identity == rid("CQ"))
    limits = n.Limits()
    if fault == "selected":
        cq = replace(
            cq,
            basis=replace(
                cq.basis, selected=tuple(rid("unresolved" + str(i)) for i in range(65))
            ),
        )
    elif fault == "fanout":
        cq = replace(
            cq,
            basis=replace(
                cq.basis, accepted=tuple(rid("unresolved" + str(i)) for i in range(65))
            ),
        )
    elif fault == "pairs":
        limits = n.Limits(pairs_path=0)
    elif fault == "cells":
        limits = n.Limits(cells_alignment=0)
    else:
        limits = n.Limits(retained_path=1)
    facts = [cq if v.identity == cq.identity else v for v in facts]
    r = n.normalize(facts, (rid("S0"),), (cq.identity,), limits=limits)
    assert (
        r.status == "ChoiceRequired"
        and r.budget.dimension == dimension
        and r.tree is None
    )


@pytest.mark.parametrize(
    "replacement", [(), [], ((f, n.Node(n.Mode.REGULAR, b"wrong")),)]
)
def test_malformed_or_incomplete_compose_fields(replacement):
    facts = compose_facts()
    cq = next(v for v in facts if v.identity == rid("CQ"))
    if replacement == ():
        basis = replace(cq.basis, accepted=())
        expected = "InvalidContent"
    else:
        basis = replace(cq.basis, claimed=replacement)
        expected = (
            "InvalidContent" if isinstance(replacement, list) else "IntegrityFailure"
        )
    r = n.normalize(
        [replace(v, basis=basis) if v.identity == cq.identity else v for v in facts],
        (rid("S0"),),
        (cq.identity,),
    )
    assert r.status == expected and r.tree is None


def test_disjoint_literal_resolutions_keep_outside_work():
    x = (b"x",)
    facts, _ = structural()
    root, base, a, b = facts
    facts = [
        root,
        replace(
            base,
            tree=n.tree({**dict(base.tree), x: n.Node(n.Mode.REGULAR, b"old-x")}),
            scope=(d, u, x),
        ),
        replace(
            a,
            tree=n.tree({**dict(a.tree), x: n.Node(n.Mode.REGULAR, b"A-x")}),
            scope=(d, x),
        ),
        replace(
            b,
            tree=n.tree({**dict(b.tree), x: n.Node(n.Mode.REGULAR, b"B-x")}),
            scope=(df, u, x),
        ),
    ]
    selected = (a.identity, b.identity)
    preview = n.normalize(facts, (root.identity,), selected)
    assert {c.path for c in preview.conflicts} == {d, x}
    resolutions = tuple(
        literal(c, {c.path: F(b"new-" + c.path[0])}) for c in preview.conflicts
    )
    r = n.normalize(facts, (root.identity,), selected, resolutions=resolutions)
    other = n.normalize(
        list(reversed(facts)),
        (root.identity,),
        tuple(reversed(selected)),
        resolutions=tuple(reversed(resolutions)),
        cache=False,
    )
    assert r == other and r.status == "Ready"
    assert plain(r.tree) == {d: F(b"new-d"), x: F(b"new-x"), u: F(b"new-u")}


def test_ambiguous_literal_cannot_override_comparison():
    facts = public_pool()
    # S14 has incomparable accepted histories and material comparisons.
    preview = n.normalize(facts, (rid("SL"), rid("SR")), (), reconcile=True)
    assert preview.status == "ChoiceRequired"
    _, context = structural()
    guessed = replace(
        context,
        path=f,
        accepted=tuple(sorted((rid("SL"), rid("SR")), key=lambda v: v.raw)),
        selected=(),
    )
    r = n.normalize(
        facts,
        (rid("SL"), rid("SR")),
        (),
        reconcile=True,
        resolutions=(literal(guessed, {f: F(b"guessed")}),),
    )
    assert r.status == "ChoiceRequired" and r.reason == "comparison" and r.tree is None


def test_equal_literal_values_in_distinct_accepted_histories_do_not_collapse():
    facts, context = structural()
    root, _, a, b = facts
    resolution = literal(context, {d: F(b"same")})
    result = n.normalize(
        facts, (root.identity,), (a.identity, b.identity), resolutions=(resolution,)
    )
    accepted = [
        n.Fact(
            rid("literal-history" + str(i)),
            "accepted",
            result.tree,
            parents=(root.identity,),
            selected=(a.identity, b.identity),
            resolutions=(resolution,),
        )
        for i in range(2)
    ]
    combined = n.normalize(
        facts + accepted, tuple(v.identity for v in accepted), (), reconcile=True
    )
    assert combined.status == "Ready" and combined.tree == result.tree
    parents = dict(combined.origins)[dict(combined.lineage)[d]].parents
    assert set(parents) == {n.OriginKey(v.identity, "result", d) for v in accepted}


@seed(20261123)
@settings(max_examples=15, deadline=None)
@given(st.integers(min_value=1, max_value=12), st.booleans())
def test_nested_cache_charge_property(depth, cache):
    facts = nested(depth)
    result = n.normalize(
        facts, (facts[0].identity,), (facts[-1].identity,), cache=cache
    )
    permuted = n.normalize(
        list(reversed(facts)),
        (facts[0].identity,),
        (facts[-1].identity,),
        cache=not cache,
    )
    assert result == permuted and result.status == "Ready"


@seed(20261124)
@settings(max_examples=15, deadline=None)
@given(st.integers(min_value=1, max_value=10), st.booleans())
def test_nested_exact_logical_charge_boundaries(depth, cache):
    facts = nested(depth)
    # One path: queries for chain prefixes have costs 1,3,...,2*depth+1.
    exact = (depth + 1) ** 2
    ready = n.normalize(
        facts,
        (facts[0].identity,),
        (facts[-1].identity,),
        limits=n.Limits(ancestor_units=exact),
        cache=cache,
    )
    refused = n.normalize(
        facts,
        (facts[0].identity,),
        (facts[-1].identity,),
        limits=n.Limits(ancestor_units=exact - 1),
        cache=not cache,
    )
    assert ready.status == "Ready" and ready.charge.ancestor_units == exact
    assert (
        refused.status == "ChoiceRequired"
        and refused.budget.dimension == "ancestor_units"
    )
    assert refused.tree is None


def test_wide_dag_logical_set_reference():
    from yeokcham.normalization_budget import logical_closure

    parents = {0: (), 1: (0,), 2: (0,), 3: (1, 2), 4: (1, 2), 5: (3, 4)}
    expected_edges = frozenset((child, p) for child, ps in parents.items() for p in ps)
    for traversal in ("dfs", "bfs"):
        nodes, edges = logical_closure(
            parents, (5,), traversal=traversal, unit_limit=14
        )
        assert nodes == frozenset(parents) and edges == expected_edges
        assert len(nodes) + len(edges) == 14
    from yeokcham.normalization_budget import BudgetExceeded

    with pytest.raises(BudgetExceeded, match="ancestor_units"):
        logical_closure(parents, (5,), unit_limit=13)


def test_later_new_descendant_requires_resolution_domain_qualification():
    facts, context = structural()
    root, _, a, b = facts
    chosen = n.normalize(
        facts,
        (root.identity,),
        (a.identity, b.identity),
        resolutions=(literal(context, {d: D}),),
    )
    accepted = n.Fact(
        rid("domain-accepted"),
        "accepted",
        chosen.tree,
        parents=(root.identity,),
        selected=(a.identity, b.identity),
        resolutions=(literal(context, {d: D}),),
    )
    new_path = (b"d", b"future")
    later = n.Fact(
        rid("domain-later"),
        "candidate",
        tr({d: D, new_path: F(b"new"), u: F(b"new-u")}),
        basis=accepted.identity,
        scope=(new_path,),
    )
    r = n.normalize(facts + [accepted, later], (accepted.identity,), (later.identity,))
    assert r.status == "ChoiceRequired" and r.reason == "unsupported-resolution-domain"
    assert r.tree is None


def test_literal_output_claim_cannot_supply_its_own_supported_path_domain():
    facts, context = structural()
    root, _, a, b = facts
    new_path = (b"d", b"novel")
    absent = n.OriginKey(root.identity, "result", new_path)
    expanded = replace(
        context,
        sources=tuple(
            (record, tuple(sorted(view + ((new_path, absent),))))
            for record, view in context.sources
        ),
        frontiers=tuple(sorted(context.frontiers + ((new_path, (absent,)),))),
        comparisons=tuple(sorted(context.comparisons + ((new_path, absent),))),
    )
    replacement = {d: D, new_path: F(b"new")}
    accepted = n.Fact(
        rid("self-domain"),
        "accepted",
        tr({**replacement, u: F(b"new-u")}),
        parents=(root.identity,),
        selected=(a.identity, b.identity),
        resolutions=(literal(expanded, replacement),),
    )
    r = n.normalize(facts + [accepted], (accepted.identity,), ())
    assert (
        r.status == "ChoiceRequired" and r.reason == "unsupported-new-path-resolution"
    )
    assert r.tree is None


def test_literal_nested_scope_retains_external_ancestor():
    root = n.Fact(rid("nested-scope-G"), "genesis", ())
    base = n.Fact(
        rid("nested-scope-base"),
        "candidate",
        tr({d: D, df: F(b"base"), dg: F(b"outside")}),
        basis=root.identity,
        scope=(d,),
    )
    a = n.Fact(
        rid("nested-scope-a"),
        "candidate",
        tr({d: D, df: F(b"A"), dg: F(b"outside")}),
        basis=base.identity,
        scope=(df,),
    )
    b = n.Fact(
        rid("nested-scope-b"),
        "candidate",
        tr({d: D, df: F(b"B"), dg: F(b"outside")}),
        basis=base.identity,
        scope=(df,),
    )
    facts = [root, base, a, b]
    preview = n.normalize(facts, (root.identity,), (a.identity, b.identity))
    assert preview.status == "Conflicted" and preview.conflicts[0].path == df
    result = n.normalize(
        facts,
        (root.identity,),
        (a.identity, b.identity),
        resolutions=(literal(preview.conflicts[0], {df: F(b"literal")}),),
    )
    assert result.status == "Ready" and plain(result.tree) == {
        d: D,
        df: F(b"literal"),
        dg: F(b"outside"),
    }


def test_compose_depth_does_not_add_a_basis_edge_to_evolution_only_predecessor():
    root = n.Fact(rid("depth-role-G"), "genesis", ())
    facts = [root]
    for i in range(255):
        previous = facts[-1]
        facts.append(
            n.Fact(
                rid("depth-role-" + str(i)),
                "candidate",
                tr({f: F(str(i).encode())}),
                basis=previous.identity,
                predecessor=None if i == 0 else previous.identity,
                scope=(f,),
            )
        )
    rebased = n.Fact(
        rid("depth-role-rebased"),
        "candidate",
        tr({f: F(b"rebased")}),
        basis=n.Compose((root.identity,), (), ()),
        predecessor=facts[-1].identity,
        scope=(f,),
    )
    r = n.normalize(facts + [rebased], (root.identity,), (rebased.identity,))
    assert r.status == "Ready" and plain(r.tree) == {f: F(b"rebased")}
    assert dict(r.origins)[dict(r.lineage)[f]].parents == (
        n.OriginKey(root.identity, "result", f),
    )
