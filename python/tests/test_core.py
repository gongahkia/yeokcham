"""Behavioral oracles: M1A admission/RC01–07 and OCaml content verification tests."""

import hashlib
import tracemalloc

import pytest
from conftest import MANIFEST
from hypothesis import given, settings
from hypothesis import strategies as st


def api():
    from yeokcham import codec, content, errors, identities

    return identities, codec, content, errors


@pytest.mark.parametrize(
    "name,size",
    [
        ("RepositoryId", 32),
        ("WorkspaceId", 16),
        ("StoredObjectId", 32),
        ("SnapshotId", 32),
        ("ContentId", 32),
        ("TreeId", 32),
        ("ChunkId", 32),
        ("RecordId", 32),
        ("FullContentId", 32),
    ],
)
def test_identities(name, size):
    ids, _, _, _ = api()
    cls = getattr(ids, name)
    value = cls(bytes(size))
    assert value == cls.from_hex("00" * size) and value.hex() == "00" * size
    assert hash(value) == hash(cls(bytes(size)))
    for bad in [
        b"",
        bytes(size + 1),
        bytearray(size),
        "00" * size,
        ids.WorkspaceId(bytes(16)),
    ]:
        with pytest.raises((TypeError, ValueError)):
            cls(bad)
    for bad in ["x" * size * 2, "0" * (size * 2 - 1), "  " + "00" * size, "GG" * size]:
        with pytest.raises((TypeError, ValueError)):
            cls.from_hex(bad)
    assert (
        value != ids.RecordId(bytes(32))
        if name != "RecordId"
        else value != ids.StoredObjectId(bytes(32))
    )


def test_capture_identity():
    ids, _, _, _ = api()
    w = ids.WorkspaceId(bytes(16))
    for n in [0, 2**63 - 1]:
        assert ids.CaptureId(w, n).sequence == n
    for n in [-1, 2**63, True, 1.0]:
        with pytest.raises((TypeError, ValueError)):
            ids.CaptureId(w, n)
    with pytest.raises(TypeError):
        ids.CaptureId(ids.RepositoryId(bytes(32)), 0)


@pytest.mark.parametrize(
    "case", MANIFEST["generic_cbor_positive"], ids=lambda x: str(x.get("value"))
)
def test_generic_positive(case):
    _, c, _, _ = api()
    raw = raw_case(case)
    assert c.encode(c.decode(raw)) == raw


def raw_case(case):
    if "raw_hex" in case:
        return bytes.fromhex(case["raw_hex"])
    _, n = case["raw_recipe"]
    return b"\x9a" + n.to_bytes(4, "big") + bytes(n)


@pytest.mark.parametrize("case", MANIFEST["negative"], ids=lambda x: x["name"])
def test_negative_corpus(case, corpus):
    ids, c, ct, e = api()
    objects = {
        ids.StoredObjectId.from_hex(p.stem): p.read_bytes()
        for p in (corpus / "objects").iterdir()
    }
    root = case.get("root")
    if case.get("resolver"):
        refs = c.decode(c.unpack(objects[ids.StoredObjectId.from_hex(root)]).payload)[8]
        first = ids.StoredObjectId(refs[0][0])
        if case["resolver"] == "omit-first":
            objects.pop(first)
        else:
            objects[first] = objects[first][:-1] + bytes([objects[first][-1] ^ 1])
    with pytest.raises(e.ContentError) as raised:
        if case.get("layer") == "cbor":
            c.decode(raw_case(case))
        elif case.get("layer") == "envelope":
            c.unpack(bytes.fromhex(case["raw_hex"]))
        else:
            verifier = ct.Verifier(objects.get)
            rid = ids.StoredObjectId.from_hex(root)
            kind = objects[rid][5]
            if kind == 2:
                verifier.tree(ids.TreeId(rid.raw))
            elif kind == 3:
                verifier.snapshot(ids.SnapshotId(rid.raw))
            else:
                verifier.content(ids.ContentId(rid.raw), max_bytes=0)
    assert raised.value.code.value == case["expected"]


@pytest.mark.parametrize("case", MANIFEST["files"], ids=lambda x: x["name"])
def test_files_and_writer(case, corpus):
    _ids, _c, ct, _ = api()
    data = (corpus / "inputs" / f"{case['name']}.bin").read_bytes()
    objects = {}

    def put(identity, raw):
        objects[identity] = raw

    identity = ct.write_content(
        (data[i : i + 63] for i in range(0, len(data), 63)),
        put,
        expected_size=len(data),
    )
    assert identity.hex() == case["content_object"]
    for key, raw in objects.items():
        assert raw == (corpus / "objects" / f"{key.hex()}.bin").read_bytes()
    verifier = ct.Verifier(objects.get)
    assert verifier.content(identity, max_bytes=len(data)).data == data
    assert verifier.content(identity, max_bytes=0).data == (b"" if not data else None)
    assert verifier.content(identity).full_id.hex() == case["full_content_id"]
    assert (
        [x for x in ct.chunk_bytes([data])]
        == [data[a:b] for a, b in zip([0] + case["chunk_ends"], case["chunk_ends"])]
        if case["chunk_ends"]
        else b"".join(ct.chunk_bytes([data])) == data
    )


def test_all_envelopes(corpus):
    ids, c, _, _ = api()
    for identity, info in MANIFEST["objects"].items():
        raw = (corpus / "objects" / f"{identity}.bin").read_bytes()
        env = c.unpack(raw, ids.StoredObjectId.from_hex(identity))
        assert env.kind == info["kind"]
        assert c.pack(env.kind, env.payload) == raw
        assert hashlib.sha256(env.payload).hexdigest() == info["payload_sha256"]


def test_tree_fidelity_and_legacy(corpus):
    ids, _c, ct, e = api()
    objects = {
        ids.StoredObjectId.from_hex(p.stem): p.read_bytes()
        for p in (corpus / "objects").iterdir()
    }
    v = ct.Verifier(objects.get)
    tree = v.snapshot(ids.SnapshotId.from_hex(MANIFEST["trees"][0]["snapshot"]))
    assert tree[(b"bad-\xff",)].data == b"\0\xff"
    assert tree[(b"empty",)].kind == "directory"
    assert (
        tree[(b"link",)].mode == ct.Mode.SYMLINK
        and tree[(b"link",)].data == b"missing/target"
    )
    assert tree[(b"run",)].mode == ct.Mode.EXECUTABLE
    root = ids.ContentId.from_hex(MANIFEST["legacy"]["root"])
    with pytest.raises(e.ContentError):
        v.content(root)
    result = v.inspect_legacy(root, max_bytes=0)
    assert (
        result.classification == "LegacyReadableNoncanonical"
        and result.identity == root
        and result.data is None
    )
    with pytest.raises(TypeError):
        v.content(ids.FullContentId(root.raw))


@given(
    st.recursive(
        st.one_of(
            st.none(),
            st.booleans(),
            st.integers(-(2**63), 2**63 - 1),
            st.binary(max_size=50),
            st.text(max_size=30),
        ),
        lambda s: st.lists(s, max_size=5),
        max_leaves=25,
    )
)
@settings(max_examples=100, deadline=None)
def test_codec_property(value):
    _, c, _, _ = api()
    raw = c.encode(value)
    assert c.decode(raw) == value and c.encode(value) == raw


@given(st.binary(max_size=20000), st.integers(1, 2048))
@settings(max_examples=30, deadline=None)
def test_stream_property(data, feed):
    _, _, ct, _ = api()
    a = list(ct.chunk_bytes([data]))
    b = list(ct.chunk_bytes(data[i : i + feed] for i in range(0, len(data), feed)))
    assert a == b and b"".join(b) == data
    assert all(0 < len(x) <= 131072 for x in b)


def test_writer_length_and_verification_after_display_limit(corpus):
    _ids, _c, ct, e = api()
    for size in [0, 10]:
        with pytest.raises(e.ContentError) as error:
            ct.write_content([b"abc"], lambda *_: None, expected_size=size)
        assert error.value.code == e.Code.INVALID_CONTENT
    data = b"z" * 200000
    objects = {}
    rid = ct.write_content([data], lambda k, v: objects.__setitem__(k, v))
    # Discard display bytes without skipping any dependency/hash validation.
    chunk = next(k for k, v in objects.items() if v[5] == 13)
    objects.pop(chunk)
    with pytest.raises(e.ContentError) as error:
        ct.Verifier(objects.get).content(rid, max_bytes=0)
    assert error.value.code == e.Code.UNAVAILABLE


def test_traversal_and_envelope_budget():
    ids, c, ct, e = api()
    objects = {}

    def put(kind, value, cls):
        raw = c.pack(kind, c.encode(value))
        rid = c.object_id(raw)
        objects[rid] = raw
        return cls(rid.raw)

    leaf = put(1, [1, b"x"], ids.ContentId)
    empty = put(2, [1, []], ids.TreeId)
    tree = put(
        2,
        [1, [[1, b"a", empty.raw], [1, b"b", empty.raw], [0, b"f", 0, leaf.raw]]],
        ids.TreeId,
    )
    assert len(ct.Verifier(objects.get).tree(tree)) == 3
    for limits in [
        ct.Limits(objects=0),
        ct.Limits(entries=1),
        ct.Limits(path_bytes=1),
        ct.Limits(depth=0),
    ]:
        with pytest.raises(e.ContentError) as error:
            ct.Verifier(objects.get, limits=limits).tree(tree)
        assert error.value.code == e.Code.RESOURCE_LIMIT
    raw = c.pack(1, c.encode([1, b"x"]))
    for cap, valid in [(len(raw) - 1, False), (len(raw), True), (len(raw) + 1, True)]:
        if valid:
            assert c.unpack(raw, max_bytes=cap).kind == 1
        else:
            with pytest.raises(e.ContentError):
                c.unpack(raw, max_bytes=cap)


def test_bounded_stream_memory():
    _, _, ct, _ = api()
    tracemalloc.start()
    count = sum(len(chunk) for chunk in ct.chunk_bytes(b"x" * 65536 for _ in range(64)))
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    assert count == 4 * 1024 * 1024 and peak < 2 * 1024 * 1024


@pytest.mark.parametrize("size", [0, 1, 16384, 65535, 65536, 65537, 200000])
def test_repeated_zero_writer_threshold(size):
    _, _c, ct, _ = api()
    objects = {}
    identity = ct.write_content([bytes(size)], lambda k, v: objects.__setitem__(k, v))
    assert objects[next(k for k in objects if k.raw == identity.raw)][5] == (
        1 if size <= 65536 else 14
    )
    assert ct.Verifier(objects.get).content(identity, max_bytes=size).data == bytes(
        size
    )


def test_expected_size_stops_input_early():
    _, _, ct, e = api()

    def feeds():
        yield b"xx"
        raise AssertionError("input was consumed past declared size")

    with pytest.raises(e.ContentError):
        ct.write_content(feeds(), lambda *_: None, expected_size=1)


def test_typed_tree_writers():
    ids, c, ct, e = api()
    objects = {}
    rid = ct.write_content([b"target"], lambda k, v: objects.__setitem__(k, v))
    empty = c.object_id(ct.encode_tree([]))
    objects[empty] = ct.encode_tree([])
    raw = ct.encode_tree(
        [ct.Directory(b"d", ids.TreeId(empty.raw)), ct.File(b"s", ct.Mode.SYMLINK, rid)]
    )
    tree = c.object_id(raw)
    objects[tree] = raw
    snap = ct.encode_snapshot(ids.TreeId(tree.raw))
    sid = c.object_id(snap)
    objects[sid] = snap
    assert (
        ct.Verifier(objects.get).snapshot(ids.SnapshotId(sid.raw))[(b"s",)].data
        == b"target"
    )
    with pytest.raises((TypeError, e.ContentError)):
        ct.encode_snapshot(rid)
    for entries in [
        [ct.File(b"../bad", ct.Mode.REGULAR, rid)],
        [ct.File(b"x", True, rid)],
        [ct.File(b"x", ct.Mode.REGULAR, ids.FullContentId(rid.raw))],
        [
            ct.Directory(b"d", ids.TreeId(tree.raw)),
            ct.Directory(b"d", ids.TreeId(tree.raw)),
        ],
    ]:
        with pytest.raises((TypeError, e.ContentError)):
            ct.encode_tree(entries)


@pytest.mark.parametrize(
    "options",
    [{"max_depth": 65}, {"max_depth": -1}, {"max_items": 131201}, {"max_bytes": 2**31}],
)
def test_cannot_weaken_parser_limits(options):
    _, c, _, _ = api()
    with pytest.raises(ValueError):
        c.decode(b"\x00", **options)


@given(st.binary(max_size=256))
@settings(max_examples=150, deadline=None)
def test_arbitrary_bytes_fail_structurally(raw):
    _, c, _, e = api()
    try:
        value = c.decode(raw)
    except e.ContentError:
        pass
    else:
        assert c.encode(value) == raw
    try:
        c.unpack(raw)
    except e.ContentError:
        pass


def test_resolver_budget_before_read_and_wrong_child():
    ids, c, ct, e = api()
    reads = []

    def resolver(identity):
        reads.append(identity)
        raise AssertionError("budget checked too late")

    with pytest.raises(e.ContentError) as error:
        ct.Verifier(resolver, limits=ct.Limits(objects=0)).tree(ids.TreeId(bytes(32)))
    assert error.value.code == e.Code.RESOURCE_LIMIT and not reads
    chunk = c.pack(13, c.encode([1, b"x"]))
    cid = c.object_id(chunk)
    tree = c.pack(2, c.encode([1, [[1, b"d", cid.raw]]]))
    objects = {cid: chunk, c.object_id(tree): tree}
    with pytest.raises(e.ContentError) as error:
        ct.Verifier(objects.get).tree(ids.TreeId(c.object_id(tree).raw))
    assert error.value.code == e.Code.INVALID_CONTENT


def test_stream_envelope_guards():
    import io

    _, c, _, e = api()
    raw = c.pack(1, c.encode([1, b"x"]))
    for cap in [len(raw) - 1, len(raw), len(raw) + 1]:
        if cap < len(raw):
            with pytest.raises(e.ContentError):
                c.read_envelope(io.BytesIO(raw), max_bytes=cap)
        else:
            assert c.read_envelope(io.BytesIO(raw), max_bytes=cap) == c.unpack(raw)
    for broken in [raw[:-1], raw + b"x"]:
        with pytest.raises(e.ContentError) as error:
            c.read_envelope(io.BytesIO(broken))
        assert error.value.code == e.Code.INVALID_ENCODING
    header = bytearray(raw[:57])
    header[17:25] = (128 * 1024 * 1024).to_bytes(8, "big")

    class Guard(io.BytesIO):
        def read(self, n=-1):
            assert 0 < n <= 65536
            assert self.tell() < 57, "oversized payload was requested"
            return super().read(n)

    with pytest.raises(e.ContentError) as error:
        c.read_envelope(Guard(header))
    assert error.value.code == e.Code.RESOURCE_LIMIT


@pytest.mark.parametrize(
    "options",
    [
        {"depth": 257},
        {"objects": 65537},
        {"entries": 1048577},
        {"path_bytes": 64 * 1024 * 1024 + 1},
    ],
)
def test_cannot_weaken_tree_limits(options):
    _, _, ct, _ = api()
    with pytest.raises(ValueError):
        ct.Limits(**options)


@given(st.binary(max_size=4096))
@settings(max_examples=30, deadline=None)
def test_payload_corruption_is_never_admitted(data):
    ids, c, ct, e = api()
    raw = c.pack(1, c.encode([1, data]))
    rid = c.object_id(raw)
    corrupt = raw[:-1] + bytes([raw[-1] ^ 1])
    with pytest.raises(e.ContentError) as error:
        ct.Verifier(lambda _: corrupt).content(ids.ContentId(rid.raw), max_bytes=0)
    assert error.value.code == e.Code.INTEGRITY


@pytest.mark.parametrize("name", ["RC02-P200000", "RC02-P1048589", "RC02-zero262145"])
@pytest.mark.parametrize("feed", [1, 64, 65, 16384, 65536])
def test_reference_feed_boundaries(name, feed, corpus):
    _, _, ct, _ = api()
    case = next(c for c in MANIFEST["files"] if c["name"] == name)
    data = (corpus / "inputs" / f"{name}.bin").read_bytes()
    offset = 0
    ends = []
    for chunk in ct.chunk_bytes(data[i : i + feed] for i in range(0, len(data), feed)):
        offset += len(chunk)
        ends.append(offset)
    assert ends == case["chunk_ends"]
