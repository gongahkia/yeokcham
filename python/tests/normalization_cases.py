"""Hand-authored exact M0 inputs/expected trees; no production output or oracle imports."""

f = (b"f.txt",)
g = (b"g.txt",)
c = (b"c.txt",)
binary = (b"bin",)
secret = (b"secret.txt",)


def F(data, mode=0):
    return ("F", mode, data)


D = ("D",)


def T(x, y=0):
    return {f: F(f"x={x}\ny={y}\n".encode())}


# name, role, material inputs, exact result, evolution predecessor, declared scope, choices
FACTS = [
    ("G", "genesis", (), {}, None, (), {}),
    ("R0", "candidate", ("G",), T(0), None, (f,), {}),
    ("S0", "accepted", ("G", "R0"), T(0), None, (), {}),
    ("A1", "candidate", ("R0",), T(1), "R0", (f,), {}),
    ("B1", "candidate", ("R0",), T(3), "R0", (f,), {}),
    ("A2", "candidate", ("A1",), T(2), "A1", (f,), {}),
    ("B2", "candidate", ("B1",), T(4), "B1", (f,), {}),
    ("SA1", "accepted", ("S0", "A1"), T(1), None, (), {}),
    ("SA", "accepted", ("S0", "A2"), T(2), None, (), {}),
    ("SB", "accepted", ("S0", "B2"), T(4), None, (), {}),
    ("Cind", "candidate", ("S0",), {**T(0), g: F(b"c\n")}, None, (g,), {}),
    ("Z1", "candidate", ("S0",), {**T(0), g: F(b"z\n")}, None, (g,), {}),
    ("Cdep", "candidate", ("A1",), {**T(1), c: F(b"requires x=1\n")}, None, (c,), {}),
    ("Y1", "candidate", ("R0",), T(0, 1), None, (f,), {}),
    ("Bequal", "candidate", ("B1",), T(2), "B1", (f,), {}),
    ("B3", "candidate", ("B2",), T(5), "B2", (f,), {}),
    ("O0", "candidate", ("S0",), {**T(0), binary: F(b"\0zero")}, None, (binary,), {}),
    ("SO", "accepted", ("S0", "O0"), {**T(0), binary: F(b"\0zero")}, None, (), {}),
    ("OA", "candidate", ("O0",), {**T(0), binary: F(b"\0alice")}, "O0", (binary,), {}),
    ("OB", "candidate", ("O0",), {**T(0), binary: F(b"\0bob")}, "O0", (binary,), {}),
    ("Q", "compose", ("S0", "A1", "Y1"), T(1, 1), None, (), {}),
    ("CQ", "candidate", ("Q",), {**T(1, 1), c: F(b"composed\n")}, None, (c,), {}),
    ("U", "accepted", ("S0", "A1"), T(1), None, (), {}),
    ("V", "accepted", ("S0", "Y1"), T(0, 1), None, (), {}),
    ("Q1", "accepted", ("U", "V"), T(1, 1), None, (), {}),
    ("Q2", "accepted", ("U", "V"), T(1, 1), None, (), {}),
    ("L", "candidate", ("Q1",), T(2, 1), None, (f,), {}),
    ("R", "candidate", ("Q2",), T(3, 1), None, (f,), {}),
    ("SL", "accepted", ("Q1", "L"), T(2, 1), None, (), {}),
    ("SR", "accepted", ("Q2", "R"), T(3, 1), None, (), {}),
    ("ChooseB", "accepted", ("S0", "A1", "B1"), T(3), None, (), {f: "B1"}),
    ("A3", "candidate", ("S0",), T(0, 1), "A2", (f,), {}),
    ("R3", "candidate", ("G",), {f: F(b"x=0\ny=0\nz=0\n")}, None, (f,), {}),
    ("S3", "accepted", ("G", "R3"), {f: F(b"x=0\ny=0\nz=0\n")}, None, (), {}),
    ("AX1", "candidate", ("R3",), {f: F(b"x=1\ny=0\nz=0\n")}, "R3", (f,), {}),
    ("AX2", "candidate", ("AX1",), {f: F(b"x=2\ny=0\nz=0\n")}, "AX1", (f,), {}),
    ("AY1", "candidate", ("R3",), {f: F(b"x=0\ny=1\nz=0\n")}, None, (f,), {}),
    ("CZ1", "candidate", ("S3",), {f: F(b"x=0\ny=0\nz=1\n")}, None, (f,), {}),
    ("W", "accepted", ("S3", "AX1", "AY1"), {f: F(b"x=1\ny=1\nz=0\n")}, None, (), {}),
    ("DEL", "candidate", ("R0",), {}, None, (f,), {}),
]
CASES = [
    ("S01", ("S0",), (), "Ready", T(0)),
    ("S02", ("S0",), (), "Ready", T(0)),
    ("S03", ("S0",), (), "Ready", T(0)),
    ("S04", ("S0",), ("A2",), "Ready", T(2)),
    ("S05", ("SA1",), ("A2",), "Ready", T(2)),
    ("S06", ("SA1",), ("A2", "Cind"), "Ready", {**T(2), g: F(b"c\n")}),
    ("S07", ("SA1",), ("A2", "Z1"), "Ready", {**T(2), g: F(b"z\n")}),
    ("S08", ("S0",), ("Cdep",), "Ready", {**T(1), c: F(b"requires x=1\n")}),
    ("S09", ("S0",), ("A2", "Cdep"), "Ready", {**T(2), c: F(b"requires x=1\n")}),
    ("S10", ("S0",), ("A2", "B2"), "Conflicted", None),
    ("S11", ("S0",), ("A2", "Bequal"), "Ready", T(2)),
    ("S12", ("SO",), ("OA", "OB"), "Conflicted", None),
    ("S13", ("S0",), ("CQ",), "Ready", {**T(1, 1), c: F(b"composed\n")}),
    ("S14", ("SL", "SR"), (), "ChoiceRequired", None),
    ("S15", ("SA", "SB"), (), "Conflicted", None),
    ("S16", ("S0",), ("A2",), "Ready", T(2)),
    ("S17", ("S0",), ("A2",), "Ready", T(2)),
    ("S18", ("S0",), ("A2",), "Stale", None),
    ("S19", ("S0",), ("A3",), "Ready", T(0, 1)),
    ("S20", ("ChooseB",), ("A2",), "Conflicted", None),
    ("S21", ("W",), ("AX2", "CZ1"), "Ready", {f: F(b"x=2\ny=1\nz=1\n")}),
    ("S22", ("S0",), ("DEL", "A2"), "Conflicted", None),
]
