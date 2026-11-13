"""Compare E674 raster replay against independently exported captured HDR.

Usage: python compare_material_replay.py <gbuffer-materials-directory> [--prepare]
--prepare creates the pixel mask before running material_replay.gd.
"""
import argparse
import json
from pathlib import Path
import numpy as np


def decode(words):
    channels=[]
    for shift,bits in [(0,6),(11,6),(22,5)]:
        value=(words>>shift)&((1<<(bits+5))-1)
        e=value>>bits;m=value&((1<<bits)-1)
        channels.append(np.where(e==0,np.ldexp(m.astype(float),1-15-bits),np.ldexp(1+m.astype(float)/(1<<bits),e.astype(int)-15)))
    return np.stack(channels,axis=-1)


args=argparse.ArgumentParser()
args.add_argument('evidence',type=Path)
args.add_argument('--prepare',action='store_true')
options=args.parse_args();root=options.evidence
p=np.load(root/'e674-validation-pixels.npz');x,y=p['x'],p['y']
if options.prepare:
    mask=np.zeros((1440,2560),dtype='u1');mask[y,x]=255
    (root/'e674-mask.bin').write_bytes(mask.tobytes())
    print(f'Prepared {len(x)} captured E674 pixels')
    raise SystemExit(0)
actual=np.frombuffer((root/'e674-gpu-hdr.bin').read_bytes(),'<u4').reshape(1440,2560)[y,x]
ref=np.frombuffer((root/'fresh-e674-133342.dds').read_bytes(),'<u4',offset=148).reshape(1440,2560)[y,x]
floating=np.frombuffer((root/'e674-gpu-float.bin').read_bytes(),'<f4').reshape(1440,2560,4)[y,x]
assert np.isfinite(floating).all()
assert np.all(floating[:,3]==1), 'Raster replay missed target pixels'
err=np.abs(decode(actual)-decode(ref))
code_errors=[]
for shift,bits in [(0,11),(11,11),(22,10)]:
    mask=(1<<bits)-1
    code_errors.append(np.abs(((actual>>shift)&mask).astype(int)-((ref>>shift)&mask).astype(int)))
code_errors=np.stack(code_errors,axis=-1)
worst=np.argsort(err.max(axis=1))[-10:][::-1]
report={'status':'measured_not_pixel_identical','pixels':len(x),
        'render_target_format':'B10G11R11_UFLOAT_PACK32',
        'fully_matching_pixels':int((actual==ref).sum()),
        'exact_rgb_component_fraction':float((code_errors==0).mean()),
        'rgb_components_within_one_encoded_step_fraction':float((code_errors<=1).mean()),
        'linear_hdr_rgb_mae':float(err.mean()),'linear_hdr_max_abs':float(err.max()),
        'missing_pixels':int((floating[:,3]!=1).sum()),
        'worst_pixels':[{'xy':[int(x[i]),int(y[i])],'reference':decode(ref[i]).tolist(),
                         'candidate':decode(actual[i]).tolist(),'encoded_steps':code_errors[i].tolist()} for i in worst],
        'scope':'Captured E674 visible subset, post-VS geometry, original BC7 sRGB base mip chain/LUT and ramp, recovered specialized lighting.',
        'limitations':['Test-only pixel mask/depth agreement replaces original visibility state.',
                       'Rounded shader literals and compiler/derivative differences remain; full material/pipeline parity not established.']}
(root/'e674-gpu-validation.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
# Keep the measured E674 baseline as a regression gate, not just a report.
assert len(x) == 683
assert (actual == ref).sum() >= 680, 'E674 exact-pixel coverage regressed'
assert code_errors.max() <= 1, 'E674 error exceeds one encoded step'
assert err.mean() <= 2.51e-6, 'E674 linear HDR error regressed'
