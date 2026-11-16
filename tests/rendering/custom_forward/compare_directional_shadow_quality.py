"""Check directional visibility, cascade continuity and PCSS against stock Forward+."""
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
expected_names = {f"m{m}_b{b}_a{a}_d{d:.2f}" for m in range(3) for b in [0,1]
    for a in [0,5] for d in [3.98,4.,4.02,7.98,8.,8.02,11.98,12.,12.02,18.,19.,21.]}
expected_names |= {f"q{q}_a{a}_gap{g:.1f}" for q in [2,4] for a in [0,2,5] for g in [.5,2.]}
expected_names |= {"stable_a","stable_b","half_opacity","normal_bias"}
assert len(cases) == 160 and {c["name"] for c in cases} == expected_names
reference_cases = json.loads((args.reference / "cases.json").read_text())
assert reference_cases == cases, "Reference scene configurations differ"

def load(root, name):
    rgb = np.asarray(Image.open(root / (name + ".png")), dtype=float)[..., :3] / 255
    assert rgb.shape == (256, 256, 3) and np.isfinite(rgb).all()
    # Compare linear visibility, not gamma-encoded screenshots.
    return np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4).mean(axis=2)

def smooth(x):
    x = np.clip(x, 0, 1)
    return x*x*(3-2*x)

errors = []
report = {"cases": [], "continuity": [], "penumbra": []}
images = {}
for case in cases:
    name = case["name"]
    a, b = load(args.character, name), load(args.reference, name)
    images[name] = a
    delta = np.abs(a[32:224,32:224] - b[32:224,32:224])
    dark = float(a[64:192,64:96].mean())
    lit = float(a[64:192,160:192].mean())
    fade = float(smooth((case["depth"]-16)/4))
    expected = 1-case["opacity"]*(1-fade)
    # An unused cascade must never lighten a fully occluded interior.
    if abs(dark-expected) > .015 or abs(lit-1) > .015:
        errors.append(f"{name}: interior visibility {dark:.6f}/{lit:.6f}, expected {expected:.6f}/1")
    # Forward+ has an existing two-split bug: it blends to unused cascade 3.
    # Preserve that renderer and record the intentional difference, but still
    # require correct physical interior/fade and continuity above/below.
    stock_unused_split = (case["mode"] == 1 and case["blend"] and
        case["depth"] < 20 and (case["angle"] > 0 and case["depth"] >= 4 or case["depth"] >= 18))
    # Stock quantizes visibility to 8 bits before lighting; PNG adds sRGB quantization.
    if not stock_unused_split and (delta.mean() > .005 or delta.max() > .015):
        errors.append(f"{name}: reference mismatch mean={delta.mean():.6f} max={delta.max():.6f}")
    report["cases"].append(dict(case, dark=dark, lit=lit, reference_mae=float(delta.mean()),
        reference_max=float(delta.max()), stock_unused_split=stock_unused_split))

for mode in range(3):
    for blend in [0,1]:
        for angle in [0,5]:
            for depth in [4,8,12]:
                names = [f"m{mode}_b{blend}_a{angle}_d{d:.2f}" for d in [depth-.02,depth+.02]]
                a,b = [images[n][64:192,64:192] for n in names]
                delta = np.abs(a-b)
                # A 4 cm camera move across a split must not create a visible seam.
                if delta.mean() > .004 or delta.max() > .08:
                    errors.append(f"{names}: cascade discontinuity {delta.mean():.6f}/{delta.max():.6f}")
                report["continuity"].append(dict(mode=mode,blend=blend,angle=angle,depth=depth,
                    mae=float(delta.mean()),max=float(delta.max())))

for quality in [2,4]:
    widths = {}
    for angle in [0,2,5]:
        for gap in [.5,2.0]:
            name = f"q{quality}_a{angle}_gap{gap:.1f}"
            profile = images[name][96:160].mean(axis=0)
            width = int(((profile>.1)&(profile<.9)).sum())
            widths[angle,gap] = width
            report["penumbra"].append(dict(quality=quality,angle=angle,gap=gap,width_pixels=width))
    # PCSS must actually broaden with angular size AND blocker separation.
    if not (widths[5,2.] > widths[2,2.] > widths[0,2.] and widths[5,2.] > widths[5,.5]*2):
        errors.append(f"quality {quality}: penumbra failed to broaden: {widths}")
noise = {}
for quality in [2,4]:
    band = images[f"q{quality}_a5_gap2.0"][64:192]
    profile = band.mean(axis=0)
    penumbra = (profile > .1) & (profile < .9)
    noise[quality] = float(np.sqrt(np.mean((band[:,penumbra]-profile[penumbra])**2)))
    if np.diff(profile).min() < -.02:
        errors.append(f"quality {quality}: nonmonotonic shadow edge")
# The high-quality kernel must reduce spatial sampling noise on the same edge.
if noise[4] >= noise[2]*.8:
    errors.append(f"High-quality filtering did not reduce penumbra noise: {noise}")
report["penumbra_noise_rms"] = noise
opacity_error = float(np.abs(images["half_opacity"]-(.5+.5*images["stable_a"])).max())
if opacity_error > .015:
    errors.append(f"Half opacity changed visibility nonlinearly: {opacity_error}")
report["half_opacity_max_error"] = opacity_error
if not np.array_equal(images["stable_a"],images["stable_b"]):
    errors.append("Stationary non-TAA visibility flickers")
report["stationary_exact"] = np.array_equal(images["stable_a"],images["stable_b"])
report["errors"] = errors
report["status"] = "passed" if not errors else "failed"
(args.character / "validation.json").write_text(json.dumps(report,indent=2))
if errors:
    raise AssertionError("\n".join(errors))
print("DIRECTIONAL_SHADOW_QUALITY_OK cases=%d continuity=%d" % (len(cases),len(report["continuity"])))
