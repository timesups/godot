"""E684 visible-pixel HDR comparison against independent before/after exports."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np


def decode(words):
    channels = []
    for shift, bits in [(0, 6), (11, 6), (22, 5)]:
        value = (words >> shift) & ((1 << (bits + 5)) - 1)
        e = value >> bits
        m = value & ((1 << bits) - 1)
        channels.append(np.where(e == 0, np.ldexp(m.astype(float), 1-15-bits), np.ldexp(1+m.astype(float)/(1 << bits), e.astype(int)-15)))
    return np.stack(channels, axis=-1)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', type=Path)
parser.add_argument('--prepare', action='store_true')
args = parser.parse_args()
root = args.evidence
for name, expected in {
    "fresh-e679-133342.dds": "346fdb6e58eab4e3a837bb3d42a364dfbe4a7a796d91e1b89d437d81ca528354",
    "accessory-reference-after.dds": "93c6cc325b09f10971d292a0caed88fe30d486cd085ca95defcb12fce7e11a69",
}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == expected, "Capture reference mismatch: " + name
before = np.frombuffer((root/'fresh-e679-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'accessory-reference-after.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 503
if args.prepare:
    (root/'e684-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E684_MASK_OK pixels=503')
else:
    actual = np.fromfile(root/'e684-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e684-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'measured_not_pixel_identical', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E684 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e684-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    # RTX 3050 measured baseline; keep the single green-channel rounding difference.
    assert report['exact_pixels'] >= 502
    assert report['mae'] <= 6.48e-7 and report['max'] <= 0.0009765625
    assert report['max_encoded_steps'] <= 1 and report['pixels_over_one_step'] == 0
    # Independent RenderDoc Shader Debug, (1385,251), visible primitive 53.
    for name, expected, tolerance in [
        ('float', [0.37315553426742554,0.3911488652229309,0.4047587513923645], 3e-6),
        ('surface', [0.19895218312740326,0.20825040340423584,0.21293361485004425], 1e-6),
        ('specular', [0.0002991492219734937,0.000299767532851547,0.0003031464875675738], 2e-6),
        ('reflection', [0.005921266973018646,0.005971014034003019,0.006486392114311457], 1e-7),
    ]:
        value = np.fromfile(root/f'e684-hdr-{name}.bin','<f4').reshape(1440,2560,4)[251,1385,:3]
        np.testing.assert_allclose(value,expected,rtol=0,atol=tolerance)
