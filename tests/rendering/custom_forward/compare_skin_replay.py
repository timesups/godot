"""E669 visible-pixel HDR comparison against independent before/after exports."""
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
for name, digest in {'skin-reference-e658.dds': '691b0a446dc5cd4a03d05e8ebe8e7d2b53e82bc7abb94b93a79bf78f7e97ab54', 'skin-reference-after.dds': '9fe28e8faa1387381b6f19d9a92edb10a7b6a8efbc702608393e1e509185735f'}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, name
before = np.frombuffer((root/'skin-reference-e658.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'skin-reference-after.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 1872
if args.prepare:
    (root/'e669-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E669_MASK_OK pixels=1872')
else:
    actual = np.fromfile(root/'e669-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e669-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'measured_not_pixel_identical', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E669 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e669-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    # RTX 3050 measured bounds; every visible pixel must remain within one encoded step.
    assert report['exact_pixels'] >= 1866
    assert report['mae'] <= 1.01e-5 and report['max'] <= 0.015625
    assert report['max_encoded_steps'] <= 1
    # Independent RenderDoc Shader Debug: E669 (1072,665), visible primitive 1792.
    value = np.fromfile(root/'e669-hdr-float.bin','<f4').reshape(1440,2560,4)[665,1072]
    np.testing.assert_allclose(value[:3],[0.340437114238739,0.18250775337219238,0.14599665999412537],rtol=0,atol=5e-6)
    value = np.fromfile(root/'e669-hdr-normal.bin','<f4').reshape(1440,2560,4)[665,1072]
    np.testing.assert_allclose(value[:3],[0.9870126843452454,-0.09702275693416595,0.12803351879119873],rtol=0,atol=1e-6)
    assert value[3] == 1792
