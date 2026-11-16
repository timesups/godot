"""Validate character self-shadow/contact diagnostics and the isolated preview fix."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("character", type=Path)
parser.add_argument("reference", type=Path)
args = parser.parse_args()
cases = json.loads((args.character / "cases.json").read_text())
assert cases == json.loads((args.reference / "cases.json").read_text()), "Scene configurations differ"
expected = {f"{shape}_p{p}_a{a}" for shape in ["sphere", "ellipsoid", "character"]
            for p in range(5) for a in [0, 2]}
expected |= {f"sheet_b{b}_p{p}_a{a}_g{g:.3f}" for b in [0, 1] for p in range(5)
             for a in [0, 2] for g in [.002, .01, .05]}
expected |= {"character_stable"}
expected |= {f"ortho_f{far}_b{bias:.2f}_n{normal:.1f}_a{a}_{suffix}"
             for far in [4000, 6, 5] for bias, normal in [(.1, 2), (.02, .5), (.05, 1)]
             for a in [0, 2] for suffix in ["sphere", "character", "g0.002", "g0.010", "g0.050"]}
expected |= {"preview_sphere", "preview_ellipsoid", "preview_character_side0",
             "preview_character_side1", "preview_stable", "preview_orientation"}
expected |= {f"preview_sheet_b{b}_g{g:.3f}" for b in [0, 1] for g in [.002, .01, .05]}
assert len(cases) == len(expected) == 193 and {c["name"] for c in cases} == expected


def load(root, name):
    rgb = np.asarray(Image.open(root / (name + ".png")), dtype=float)[..., :3] / 255
    assert rgb.shape == (320, 320, 3) and np.isfinite(rgb).all()
    return np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)


images = {}
report = {"cases": [], "preview": {}}
for case in cases:
    name = case["name"]
    a, b = load(args.character, name), load(args.reference, name)
    images[name] = a
    mask = a[..., 2] > .9
    assert mask.sum() > 9000, f"Missing geometry: {name}"
    assert np.array_equal(mask, b[..., 2] > .9), f"Geometry coverage differs: {name}"
    delta = np.abs(a[..., 0] - b[..., 0])[mask]
    # Stock lighting quantizes visibility to 8 bits; PNG adds sRGB quantization.
    assert delta.mean() < .005 and delta.max() < .015, f"Reference mismatch: {name}"
    report["cases"].append(dict(case, reference_mae=float(delta.mean()), reference_max=float(delta.max())))
    if name.startswith("preview_"):
        assert not case["blend"], "Preview split blending changed"
        assert np.allclose([case["far"], case["projection"], case["bias"], case["normal_bias"],
                            case["angle"], case["pancake"]], [6, 1, .05, 1, 2, 2],
                           rtol=0, atol=1e-7), "Preview settings changed"


def curve(name):
    a = images[name]
    mask = a[..., 2] > .9
    # G encodes signed N.L; avoid the terminator and silhouettes.
    lit, dark = mask & (a[..., 1] > .7), mask & (a[..., 1] < .3)
    assert lit.sum() > 500 and dark.sum() > 100
    return float(a[..., 0][lit].mean()), float(a[..., 0][dark].mean())


def contact(name):
    # Well inside the analytically centered 0.8 x 1.0 projected sheet shadow.
    return float(images[name][120:200, 125:195, 0].mean())


for shape in ["sphere", "ellipsoid"]:
    lit, dark = curve("preview_" + shape)
    assert lit > .99 and dark < .01, f"Preview curve acne/leak: {shape} {lit}/{dark}"
    report["preview"][shape] = dict(lit=lit, dark=dark)
    # Negative controls prove the scene exposes both insufficient and excessive bias.
    assert curve(f"{shape}_p0_a0")[0] < .7, "Zero-bias control no longer exposes acne"
    assert curve(f"{shape}_p4_a0")[1] > .9, "Excessive-bias control no longer exposes leaks"

for gap in [.002, .01, .05]:
    a, b = [f"preview_sheet_b{back}_g{gap:.3f}" for back in [0, 1]]
    assert np.array_equal(images[a], images[b]), "Two-sided thin caster changed on reversal"
    visibility = contact(a)
    # Sub-texel 2 mm contact is measured, not incorrectly claimed to be solved.
    if gap >= .01:
        assert visibility < .01, f"Detached preview contact shadow: {gap} {visibility}"
    report["preview"][f"gap_{gap:.3f}"] = visibility
for p in range(5):
    for angle in [0, 2]:
        for gap in [.002, .01, .05]:
            assert np.array_equal(images[f"sheet_b0_p{p}_a{angle}_g{gap:.3f}"],
                                  images[f"sheet_b1_p{p}_a{angle}_g{gap:.3f}"]), "Thin caster reversal"

# Old orthographic preview loses all character and contact shadows, even at 5 cm.
old = images["ortho_f4000_b0.10_n2.0_a0_character"]
assert old[..., 0][old[..., 2] > .9].mean() > .99
assert contact("ortho_f4000_b0.10_n2.0_a0_g0.050") > .99
for side in [0, 1]:
    a = images[f"preview_character_side{side}"]
    mask = a[..., 2] > .9
    shadowed = float((a[..., 0][mask] < .5).mean())
    assert .1 < shadowed < .9, "Character shadow coverage vanished or blacked out"
    report["preview"][f"character_side{side}_shadowed"] = shadowed
# Outward normals of visible surfaces must face the camera. Reversed captured
# winding incorrectly flips the normal-bias direction even on front exteriors.
a = images["preview_orientation"]
mask = a[..., 2] > .9
facing = float((a[..., 1][mask] > .5).mean())
assert facing > .95, f"Captured mesh winding reverses exterior normals: {facing}"
report["preview"]["camera_facing_normals"] = facing
assert np.array_equal(images["preview_character_side1"], images["preview_stable"])
assert np.array_equal(images["character_p4_a2"], images["character_stable"])
(args.character / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
print("CHARACTER_SHADOW_BIAS_OK cases=193 " + json.dumps(report["preview"]))
