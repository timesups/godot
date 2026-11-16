"""E679 visible-pixel HDR comparison against independent before/after exports."""
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
# Independent RenderDoc exports, pinned before evaluating the candidate.
for name, digest in {'iris-reference-before.dds': '5a3964ec44b0a2fa052e5d63213fef0273a4449046b1c99c41447af49b97fb7e', 'iris-reference-after.dds': '346fdb6e58eab4e3a837bb3d42a364dfbe4a7a796d91e1b89d437d81ca528354'}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, name
before = np.frombuffer((root/'iris-reference-before.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'iris-reference-after.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 513
if args.prepare:
    (root/'e679-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E679_MASK_OK pixels=513')
else:
    actual = np.fromfile(root/'e679-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e679-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'exact_captured_visible_subset', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E679 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e679-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    # Measured RTX 3050 baseline: all visible R11G11B10 pixels match exactly.
    assert report['exact_pixels'] == 513 and report['max_encoded_steps'] == 0
    assert report['mae'] == 0 and report['max'] == 0
    # Independent RenderDoc Shader Debug, visible primitive 54.
    value = np.fromfile(root/'e679-hdr-float.bin','<f4').reshape(1440,2560,4)[1152,1255]
    np.testing.assert_allclose(value[:3],[1.0288423299789429,1.3699231147766113,1.4993584156036377],rtol=0,atol=2e-5)
    value = np.fromfile(root/'e679-hdr-normal.bin','<f4').reshape(1440,2560,4)[1152,1255]
    np.testing.assert_allclose(value[:3],[0.2994830012321472,-0.21200309693813324,0.9302497506141663],rtol=0,atol=1e-6)
    assert value[3] == 54
