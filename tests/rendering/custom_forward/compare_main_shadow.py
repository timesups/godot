"""Validate E641's active filtering branch against the independently exported RG8 target."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def validate(evidence):
    hashes = json.loads(Path(__file__).with_name("main_shadow_inputs.json").read_text())
    for name, expected in hashes.items():
        actual = hashlib.sha256((evidence / name).read_bytes()).hexdigest()
        assert actual == expected, f"Captured input changed: {name}"
    shadow = np.fromfile(evidence / "shadow.bin", "<f4")
    # Only the active bypassed global branch is implemented in this replay.
    assert np.array_equal(shadow[560 // 4:560 // 4 + 4], [0, 0, 1, 1])
    assert shadow[544 // 4] == 1
    reference = np.fromfile(evidence / "e641-texture-173767.bin", "u1").reshape(1440, 2560, 2)
    actual = np.fromfile(evidence / "main-shadow-replay.bin", "u1").reshape(reference.shape)
    stencil = np.fromfile(evidence / "e641-texture-173794.bin", "<u4").reshape(1440, 2560, 2)
    mask = (stencil[:, :, 1] & 7) == 4
    assert mask.sum() == 249573, "Wrong stencil selection or empty coverage"
    assert np.all(reference[:, :, 0] == 255), "Global bypass is not constant visibility"
    assert np.all(actual[:, :, 0] == reference[:, :, 0])
    assert np.all(actual[~mask] == reference[~mask]), "E637 complement changed"
    difference = np.abs(actual.astype(np.int16) - reference.astype(np.int16))
    # One measured quantization boundary; no general image-error budget or edge exclusions.
    allowed = np.zeros(mask.shape, dtype=bool)
    allowed[542, 1306] = True
    assert np.all(difference[~allowed] == 0), "Unexpected RG8 mismatch"
    assert difference.max() <= 1
    assert np.count_nonzero(reference[mask, 1] == 0) == 8196
    assert np.count_nonzero(reference[mask, 1] == 255) == 221213
    assert np.count_nonzero((reference[mask, 1] > 0) & (reference[mask, 1] < 255)) == 20164
    states = json.loads((evidence / "pipeline-evidence.json").read_text())
    for event, compare in (("637", 7), ("641", 6)):
        state = states[event]
        ds = state["depthStencil"]
        assert ds["stencilTestEnable"] and not ds["depthWriteEnable"]
        for face in ("frontFace", "backFace"):
            assert ds[face]["function"] == compare
            assert ds[face]["reference"] == 4 and ds[face]["compareMask"] == 7
        assert not state["colorBlend"]["blends"][0]["enabled"]
    report = {
        "role_pixels": int(mask.sum()),
        "exact_role_pixels": int(np.all(difference[mask] == 0, axis=1).sum()),
        "max_rg8_error": int(difference.max()),
        "role_g_mae": float(difference[mask, 1].mean() / 255),
        "global_r_exact": True,
        "nonrole_exact": True,
        "scope": "Captured atlas/input replay; atlas rasterization and live integration are not reconstructed",
    }
    (evidence / "main-shadow-validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print("MAIN_SHADOW_COMPARE_OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    validate(parser.parse_args().evidence)
