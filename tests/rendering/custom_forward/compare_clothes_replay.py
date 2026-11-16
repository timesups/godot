"""E694 visible-pixel HDR comparison against independent before/after exports."""
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
    "fresh-e689-133342.dds": "6f8102b0f79fbc2bc9839e2dfab005de6d8524ff40ba14635c490ea1d14c62a3",
    "fresh-e694-133342.dds": "4c8e462f5d97de2e4d5832a3d4b155533ba50557247b656a98fcb84738e98c41",
}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == expected, "Capture reference mismatch: " + name
before = np.frombuffer((root/'fresh-e689-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'fresh-e694-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 215604
if args.prepare:
    (root/'e694-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E694_MASK_OK pixels=215604')
else:
    actual = np.fromfile(root/'e694-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e694-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'measured_not_pixel_identical', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E694 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e694-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    # Measured RTX 3050 bounds, including residual shadow-edge differences.
    # Never exclude those pixels or replace the independent HDR target.
    assert report['exact_pixels'] >= 215000
    assert report['mae'] <= 0.0000021
    assert report['max'] <= 0.0205078125 and report['max_encoded_steps'] <= 19
    assert report['pixels_over_one_step'] <= 15
    for name, expected, tolerance in [
        ('surface', [0.2445732653, 0.2442341298, 0.2745767236], 1e-6),
        ('specular', [0.0223037787, 0.0149074495, 0.0131871188], 3e-6),
        ('reflection', [0.0048625409, 0.0046623354, 0.0049820240], 1e-7),
    ]:
        value = np.fromfile(root/f'e694-hdr-{name}.bin', '<f4').reshape(1440, 2560, 4)[730, 1311, :3]
        assert np.isfinite(value).all() and np.max(np.abs(value - expected)) <= tolerance, name
