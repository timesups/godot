# E704 hair specialization

Source: local `EndField-frame37917.rdc`, SHA256
`DEF7B7A19BAED8B9DC89AADA3B84C396897B78BB483BFB220CAFCF85901D8143`.
Draw E704 (G-buffer E493), 41,901 indices, pixel shader 109866.
Assets remain local in `.renderdoc-analysis/endfield-frame37917/gbuffer-materials`.

## Confirmed active inputs

| Resource | Meaning | Sampling |
| --- | --- | --- |
| 185700 | Base color | BC7 sRGB, 11 mips, repeat |
| 186605 | RG diffuse normal, BA specular normal | BC7 linear, 11 mips, repeat |
| 187392 | Tangent blend, specular mask, material AO, secondary-lobe mask | BC7 linear, 11 mips |
| 173100 | Material color LUT | BC7 sRGB, 11 mips, clamp |
| 186747 | Primary specular lookup | Linear RGBA8, clamp |
| 188148 | Main/view lighting ramp | Linear RGBA8, clamp |
| 37600 | Strand noise | BC7 linear, 10 mips, UV scale (8,1), no global mip bias |
| 173764 | Screen depth for local rim visibility | R32, **nearest clamp** |

The shader has no discard instruction. This capture is opaque; base alpha is
not a transparency mask. The diffuse normal flips on back faces, the secondary
normal does not. Object-space view projection requires retaining the captured
head basis, including the tangent handedness.

`hair_lighting.gdshaderinc` is shared by the spatial material and GPU replay.
It implements the material LUT, main/view ramp, screen shadow/AO, two shifted
anisotropic lobes, view attenuation, stripe darkening/saturation, final
saturation, and local modes 0/1/3/4 with optional shadow atlas.
Captured main light is white (global g194); environment uses g191, unlike face
g192. Weather/snow branches are inactive. Other hair variants are not covered.

## Independent evidence and bounds

Fresh E699/E704 HDR exports define a 20,660-pixel changed subset. Their SHA256
hashes are pinned in `compare_hair_replay.py`. The replay uses captured posed
post-VS geometry, original BC blocks and mips, captured constants, light bins,
screen AO, depth and shadow atlas. Test-only mask/depth rejection limits the
comparison to visible hair; it does not reconstruct the engine visibility pass.

RTX 3050 results: **20,634/20,660 exact (99.8742%)**, linear HDR MAE
**1.87497479e-6**, maximum **0.0078125**, no missing pixels. Every channel is
within one R11G11B10 encoded step. Gates require >=20,630 exact pixels,
MAE <=1.9e-6, max <=0.0078125 and <=1 encoded step.

Independent Shader Debug at (1220,1190), winning primitive **4519**, confirms
surface RGB (0.133615807,0.019280352,0.019575924), main specular
(0.006363902,0.000158478,0.0000002911323), secondary normal
(0.835716426,-0.042490754,0.547514915), final HDR
(0.252021939,0.035614230,0.036695242). These are additional test gates.
An unspecified debug primitive may select an occluded overlapping hair triangle.
At (1369,1204), source rim UV is (0.535846829,0.837329865), point-sampled depth
0.032068267, depth delta 0.004651308 and rim visibility zero. Linear depth
filtering incorrectly mixes background depth and creates a bright edge.

## Scene integration and limits

`full_character.gd` now assigns `hair.gdshader` to E704, preserves its object
basis and transforms captured tangents back to mesh-local space. The default
scene uses reconstructed E674/E689/E694/E704; other four draws remain base-color
diagnostics. The manifest retains all hair mips and head transform.

The default material accepts explicit light/shadow/AO parameters. Mode 3 uses
`local_rim_visibility[16]`. The optional `--live-lights` fixture now selects the
real-time depth variant and Light3D bridge described in [LIVE_CHARACTER.md](LIVE_CHARACTER.md).
The replay computes the actual captured depth rim. Scene tests explicitly set
rim visibility and verify zero suppression, separately from the real-time depth regression. Scene texture filtering uses Godot's available
mip filtering and is not a bitwise capture sampler reproduction.

Scene regression checks cover specular off, shadow/AO, own-lighting blackout,
local modes 0/1/3/4, rim suppression, atlas blocked/visible and zero strength.
Existing E674, E689, E694 surface/HDR, Bloom/LUT regressions are retained.

## Run

From the repository root (PowerShell):

```powershell
$evidence = "E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials"
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_hair_replay.py $evidence --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://hair_replay.gd -- --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_hair_replay.py $evidence
.\debug_full_character.bat --smoke
```

`--diagnostics` on the replay writes separate `e704-hdr-diagnostic-*` files:
surface/base RGB, specular/parameter RGBA, secondary/normal-map RGBA. Standard
regression outputs remain intact. Standard secondary output stores world
secondary normal in XYZ and winning primitive ID in W.
