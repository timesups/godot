"""E704 visible-pixel HDR comparison against independent before/after exports."""
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
for name, digest in {'fresh-e699-133342.dds': 'f49ec9e3e591b6cd81a69b41c9f37354963e743fcd657a5508bc6e8b5b9f1c12', 'fresh-e704-133342.dds': '2cfd8c319f983b79b9a44933d92e3995b491dd63fb166aafe4da043007fa53de'}.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, name
before = np.frombuffer((root/'fresh-e699-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
after = np.frombuffer((root/'fresh-e704-133342.dds').read_bytes(), '<u4', offset=148).reshape(1440, 2560)
mask = before != after
assert mask.sum() == 20660
if args.prepare:
    (root/'e704-mask.bin').write_bytes((mask.astype('u1')*255).tobytes())
    print('E704_MASK_OK pixels=20660')
else:
    actual = np.fromfile(root/'e704-hdr-hdr.bin', '<u4').reshape(1440, 2560)[mask]
    raw = np.fromfile(root/'e704-hdr-float.bin', '<f4').reshape(1440, 2560, 4)[mask]
    error = np.abs(decode(actual)-decode(after[mask]))
    steps = np.stack([np.abs(((actual >> s) & ((1 << b)-1)).astype(int)-((after[mask] >> s) & ((1 << b)-1)).astype(int)) for s, b in [(0, 11), (11, 11), (22, 10)]], axis=-1)
    worst = np.argsort(error.max(axis=1))[-10:][::-1]
    ys, xs = np.nonzero(mask)
    report = {'status': 'measured_not_pixel_identical', 'pixels': int(mask.sum()), 'exact_pixels': int((actual == after[mask]).sum()),
              'mae': float(error.mean()), 'max': float(error.max()), 'max_encoded_steps': int(steps.max()),
              'within_one_step': float((steps <= 1).mean()), 'pixels_over_one_step': int((steps.max(axis=1) > 1).sum()),
              'missing_pixels': int((raw[:, 3] != 1).sum()),
              'scope': 'E704 captured visible subset, test-only depth/mask; not full visibility reconstruction',
              'worst_pixels': [{'xy': [int(xs[i]), int(ys[i])], 'encoded_steps': steps[i].tolist(),
                                'reference': decode(after[mask][i]).tolist(), 'candidate': decode(actual[i]).tolist()} for i in worst]}
    (root/'e704-gpu-validation.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    assert np.isfinite(raw).all() and np.all(raw[:, 3] == 1)
    # RTX 3050 measured bounds; every visible pixel must remain within one encoded step.
    assert report['exact_pixels'] >= 20630
    assert report['mae'] <= 1.9e-6 and report['max'] <= 0.0078125
    assert report['max_encoded_steps'] <= 1
    # Independent RenderDoc Shader Debug, E704 (1220,1190), winning primitive 4519.
    # Explicit primitive matters: the first overlapping hair triangle is occluded.
    for name, expected in {
        'float': [0.25202193856,0.03561422974,0.03669524193],
        'surface': [0.13361580670,0.01928035170,0.01957592368],
        'specular': [0.00636390224,0.00015847808,2.91132295e-7],
        'secondary': [0.83571642637,-0.04249075428,0.54751491547],
    }.items():
        value = np.fromfile(root/f'e704-hdr-{name}.bin','<f4').reshape(1440,2560,4)[1190,1220]
        np.testing.assert_allclose(value[:3],expected,rtol=1e-5,atol=1e-7)
        if name == 'secondary':
            assert value[3] == 4519
