"""Validate E694 surface replay against E483 G-buffer and shader-debug evidence.

This does not compare E694 final lighting. Original assets stay outside git.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def packed(path):
    data = path.read_bytes()
    if path.suffix == ".dds":
        assert data[:4] == b"DDS " and data[84:88] == b"DX10"
        assert np.frombuffer(data, "<u4", count=1, offset=128)[0] in (24, 26, 29)
        data = data[148:]
    return np.frombuffer(data, "<u4").reshape(1440, 2560)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
parser.add_argument("--prepare", action="store_true")
args = parser.parse_args()
root = args.evidence
mask = packed(root / "fresh-e689-133342.dds") != packed(root / "fresh-e694-133342.dds")
assert mask.sum() == 215604
if args.prepare:
    (root / "e694-mask.bin").write_bytes((mask.astype("u1") * 255).tobytes())
    print("E694_MASK_OK pixels=215604")
else:
    report = {"scope": "E694 dry surface only; E483 G-buffer reference; no final HDR parity", "pixels": int(mask.sum())}
    reference_hashes = {
        173779: "bb936768f363cf5771e583d2863e0d7092dfd781a730f83728c9521ae614ab6a",
        173776: "5430ead611fa385b9a74eb3c61aaf73d0c68331a6e80350afba5963e0e7111c5",
    }
    for name, resource in [("base", 173779), ("normal", 173776)]:
        actual = packed(root / f"e694-surface-{name}.bin")[mask]
        path = root / f"e483-surface-{resource}.dds"
        assert hashlib.sha256(path.read_bytes()).hexdigest() == reference_hashes[resource], "Reference differs from retained E483 export"
        expected = packed(path)[mask]
        bits = 8 if name == "base" else 10
        steps = np.stack([np.abs(((actual >> shift) & ((1 << bits)-1)).astype(int) - ((expected >> shift) & ((1 << bits)-1)).astype(int)) for shift in (0, bits, bits*2)], axis=-1)
        ys, xs = np.nonzero(mask)
        mismatches = [[int(x), int(y)] for x, y in zip(xs[actual != expected], ys[actual != expected])]
        report[name] = {"exact_pixels": int((actual == expected).sum()), "max_steps": int(steps.max()), "mae_steps": float(steps.mean()), "mismatches": mismatches, "reference_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    arrays = {}
    for name in ("parameters", "diffuse", "f0"):
        arrays[name] = np.fromfile(root / f"e694-surface-{name}.bin", "<f4").reshape(1440, 2560, 4)
        assert np.isfinite(arrays[name][mask]).all()
    report["missing_pixels"] = int((arrays["diffuse"][mask, 3] != 1).sum())
    # Independent RenderDoc Shader Debug, E694 (1311,730), primitive 15409.
    # Without primitive_id RenderDoc chooses an occluded triangle here.
    debug_expected = {
        "parameters": [0.0, 1.0, 0.9212939739, 1.0 - 0.3689784110],
        "diffuse": [0.2962499857, 0.2962499857, 0.3337499797, 1.0],
        "f0": [0.0399999991, 0.0399999991, 0.0399999991, 15409.0],
    }
    report["debug_max_errors"] = {name: float(np.abs(arrays[name][730, 1311] - expected).max()) for name, expected in debug_expected.items()}
    (root / "e694-surface-validation.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert report["missing_pixels"] == 0
    assert all(error <= 1e-6 for error in report["debug_max_errors"].values())
    # Keep all five known differences visible and fixed. These are cross-pass
    # surface differences, not established final-HDR parity or a relaxed MAE gate.
    known = [[1219, 133], [1200, 144], [1360, 866], [1260, 1013], [1313, 1066]]
    for name in ("base", "normal"):
        assert report[name]["mismatches"] == known
        assert report[name]["exact_pixels"] == 215599
    assert report["base"]["max_steps"] <= 72
    assert report["normal"]["max_steps"] <= 931
