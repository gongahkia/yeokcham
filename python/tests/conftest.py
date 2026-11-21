import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = ROOT / "docs/v2/m0/m1a-reference"
MANIFEST = json.loads((REFERENCE / "content-vectors.json").read_text())


@pytest.fixture(scope="session")
def corpus(tmp_path_factory):
    output = tmp_path_factory.mktemp("reference") / "emission"
    subprocess.run(
        [
            sys.executable,
            "-B",
            str(REFERENCE / "emit_content_reference.py"),
            "--out",
            str(output),
        ],
        check=True,
        capture_output=True,
    )
    assert json.loads((output / "corpus.json").read_text()) == MANIFEST
    return output
