"""E699 visible-pixel HDR comparison against independent before/after exports."""
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
    "fresh-e694-133342.dds": "4c8e462f5d97de2e4d5832a3d4b155533ba50557247b656a98fcb84738e98c41",
    "ear-reference-after.dds": "f49ec9e3e591b6cd81a69b41c9f37354963e743fcd657a5508bc6e8b5b9f1c12",
}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == expected, "Capture reference mismatch: " + name
before = np.frombuffer((root/'fresh-e694-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'ear-reference-after.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 2522
if args.prepare:
    (root/'e699-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E699_MASK_OK pixels=2522')
else:
    actual = np.fromfile(root/'e699-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e699-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'captured_visible_subset_exact', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E699 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e699-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    assert report['exact_pixels'] == 2522
    assert report['mae'] == 0 and report['max_encoded_steps'] == 0
    # Independent RenderDoc Shader Debug, (1250,1274), visible primitive 783.
    for name, expected, tolerance in [
        ('float', [0.5347810387611389,0.1981145143508911,0.06418965011835098], 1e-6),
        ('surface', [0.19914717972278595,0.07762091606855392,0.0271348524838686], 1e-7),
        ('specular', [0,0,0], 1e-7),
        ('reflection', [0.002064273227006197,0.0023974331561475992,0.0033066270407289267], 1e-8),
    ]:
        value = np.fromfile(root/f'e699-hdr-{name}.bin','<f4').reshape(1440,2560,4)[1274,1250,:3]
        np.testing.assert_allclose(value,expected,rtol=0,atol=tolerance)
