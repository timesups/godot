"""Validate character self-shadow/contact diagnostics and the isolated preview fix."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("character", type=Path)
parser.add_argument("reference", type=Path)
parser.add_argument("--contact", action="store_true", help="Require receiver-plane near-contact correction")
parser.add_argument("--baseline", type=Path, help="Unmodified Custom Forward 193-case capture")
args = parser.parse_args()
assert not args.contact or args.baseline, "Contact validation needs the unchanged renderer baseline"
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
baseline_names = set(expected)
if args.contact:
    expected |= {f"contact_y{yaw}_a{angle}_{suffix}" for yaw in [0, 30, 60, 75] for angle in [0, 2]
                 for suffix in ["clear", "g0.002", "g0.004", "g0.008", "g0.016", "g0.032"]}
    expected |= {"contact_face_side0", "contact_face_side1"}
    expected |= {f"contact_grazing_y{yaw:.1f}" for yaw in [83.9, 84.1, 84.2, 84.3, 84.4, 84.6]}
    assert json.loads((args.baseline / "cases.json").read_text()) == cases[:193]
assert len(cases) == len(expected) == (249 if args.contact else 193) and {c["name"] for c in cases} == expected


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
    assert mask.sum() > (100 if case["kind"] == "contact_face" else 9000), f"Missing geometry: {name}"
    assert np.array_equal(mask, b[..., 2] > .9), f"Geometry coverage differs: {name}"
    delta = np.abs(a[..., 0] - b[..., 0])[mask]
    # Stock lighting quantizes visibility to 8 bits; PNG adds sRGB quantization.
    if not args.contact:
        assert delta.mean() < .005 and delta.max() < .015, f"Reference mismatch: {name}"
    elif name in baseline_names:
        original = load(args.baseline, name)
        original_delta = np.abs(original[..., 0] - b[..., 0])[mask]
        assert original_delta.mean() < .005 and original_delta.max() < .015, f"Baseline reference mismatch: {name}"
        change = a[..., 0] - original[..., 0]
        assert change[mask].max() < .009, f"Contact correction brightened shadows: {name}"
        if case["kind"] in ["sphere", "ellipsoid", "ortho_sphere", "preview_curve"]:
            lit = mask & (a[..., 1] > .7)
            assert change[lit].mean() > -.001, f"Contact correction added curve acne: {name}"
        if case["bias"] == 0:
            assert np.array_equal(a, original), f"Zero-bias fallback changed: {name}"
    report["cases"].append(dict(case, reference_mae=float(delta.mean()), reference_max=float(delta.max())))
    if name.startswith("preview_"):
        assert not case["blend"], "Preview split blending changed"
        assert np.allclose([case["far"], case["projection"], case["bias"], case["normal_bias"],
                            case["angle"], case["pancake"]], [6, 1, .05, 1, 2, 2],
                           rtol=0, atol=1e-7), "Preview settings changed"


def curve(name, root=None):
    a = load(root, name) if root else images[name]
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
    assert curve(f"{shape}_p0_a0", args.baseline if args.contact else None)[0] < .7, "Zero-bias control no longer exposes acne"
    assert curve(f"{shape}_p4_a0", args.baseline if args.contact else None)[1] > .9, "Excessive-bias control no longer exposes leaks"

for gap in [.002, .01, .05]:
    a, b = [f"preview_sheet_b{back}_g{gap:.3f}" for back in [0, 1]]
    assert np.array_equal(images[a], images[b]), "Two-sided thin caster changed on reversal"
    visibility = contact(a)
    # Legacy mode records the leak; contact mode must also resolve the 2 mm gap.
    if args.contact or gap >= .01:
        assert visibility < .01, f"Detached preview contact shadow: {gap} {visibility}"
    report["preview"][f"gap_{gap:.3f}"] = visibility
for p in range(5):
    for angle in [0, 2]:
        for gap in [.002, .01, .05]:
            assert np.array_equal(images[f"sheet_b0_p{p}_a{angle}_g{gap:.3f}"],
                                  images[f"sheet_b1_p{p}_a{angle}_g{gap:.3f}"]), "Thin caster reversal"

# Old orthographic preview loses all character and contact shadows, even at 5 cm.
old = load(args.baseline, "ortho_f4000_b0.10_n2.0_a0_character") if args.contact else images["ortho_f4000_b0.10_n2.0_a0_character"]
assert old[..., 0][old[..., 2] > .9].mean() > .99
old_sheet = load(args.baseline, "ortho_f4000_b0.10_n2.0_a0_g0.050") if args.contact else images["ortho_f4000_b0.10_n2.0_a0_g0.050"]
assert old_sheet[120:200, 125:195, 0].mean() > .99
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
if args.contact:
    report["contact"] = {}
    for yaw in [0, 30, 60, 75]:
        for angle in [0, 2]:
            prefix = f"contact_y{yaw}_a{angle}_"
            clear = contact(prefix + "clear")
            reference_clear = float(load(args.reference, prefix + "clear")[120:200, 125:195, 0].mean())
            assert clear >= reference_clear - .005, f"Contact query added plane acne: {prefix} {clear}/{reference_clear}"
            if yaw <= 30:
                assert clear > .99, f"Receiver plane self-shadowed: {prefix} {clear}"
            values = [contact(prefix + f"g{gap:.3f}") for gap in [.002, .004, .008, .016, .032]]
            assert max(values) < .01, f"Near-contact leak: {prefix} {values}"
            report["contact"][prefix] = dict(clear=clear, reference_clear=reference_clear, visibility=values)
    for side in [0, 1]:
        name = f"contact_face_side{side}"
        a, b = images[name], load(args.reference, name)
        lit = (a[..., 2] > .9) & (a[..., 1] > .7)
        assert lit.sum() > 100
        loss = float((b[..., 0] - a[..., 0])[lit].mean())
        assert loss < .01, f"Captured face contact acne: {name} {loss}"
        report["contact"][name] = dict(lit_loss=loss)
    grazing = [contact(f"contact_grazing_y{yaw:.1f}") for yaw in [83.9, 84.1, 84.2, 84.3, 84.4, 84.6]]
    assert np.abs(np.diff(grazing)).max() < .05, f"Grazing fallback discontinuity: {grazing}"
    report["contact"]["grazing"] = grazing
(args.character / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"CHARACTER_SHADOW_BIAS_OK cases={len(cases)} contact={args.contact} " + json.dumps(report["preview"]))
