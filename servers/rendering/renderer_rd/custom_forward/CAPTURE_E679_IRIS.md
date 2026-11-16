# E679 iris reconstruction

The active captured iris path is implemented in `materials/iris.gdshader` and
`iris_lighting.gdshaderinc`, with a separate captured RD replay. The full character
now uses this material instead of the base-color diagnostic.

## Evidence and active specialization

Source: `D:/Download/EndField-frame37917.rdc`, event 679, pixel shader module 28850.
The existing posed post-VS mesh has 190 vertices (stride 144), 840 uint16 indices.
Material buffer 630, offset 401088, size 400 is saved as `e679-cb5.bin`.

| Input | Captured value |
| --- | --- |
| Base texture | 186177, BC7 sRGB, 512 square, 10 mips |
| MatCap texture | 187349, BC7 sRGB, 256 square, 9 mips |
| Ramp | 186593, RGBA8, existing shared asset |
| Base tint | (.704253137,.704253137,.704253137,1) |
| UV parallax | .01, tangent-view XY scaled by (1,.25), radial falloff |
| Procedural curvature | 1.5; separate diffuse and MatCap normals |
| Iris / outside tint | (2,2,2) / (1.4980392,1.4980392,1.4980392) |
| Alternate color | value .55, saturation 1.4; no LUT |
| MatCap tint | (.0083189,.0131716,.02357023,1) |
| Main tint | white, global vec4 194; energy 1.6243867874 |
| Environment | global vec4 191, strength .2877224684 |

The base UV shifts with tangent-space view direction. An analytic sphere supplies
two normals: reduced curvature for diffuse light, full curvature for MatCap UVs.
The original alpha is a color mask, not transparency. MatCap RGB and tinted alpha
both contribute. The material uses the head-local horizontal main-light projection,
ramp shading, flattened-normal environment, and local modes 0/1/4. Captured mode 3
explicitly has zero final attenuation and remains zero.

The shader does not use screen AO or face SDF. `screen_shadow_ao.x` is main shadow;
its y channel is intentionally ignored. No extra AO multiply was added. Optional
snow/probe/post-material adjustment branches inactive in this instance are not
claimed as reconstructed. The model remains a static posed mesh.

Base and MatCap both require anisotropic repeat sampling. Clamping MatCap at the
texture edge produces visible mismatches even for UVs inside [0,1], because the
anisotropic footprint crosses the edge. The replay preserves BC7 blocks and all
mips, using min/mag linear, nearest mip selection and 8x anisotropy, consistent
with the shared capture sampler setup and verified by exact HDR comparison.

## Independent captured validation

`iris_replay.gd/.vert/.frag` uses the same lighting include as the scene material.
It consumes the original post-VS draw, captured depth/screen-shadow/light buffers,
and a test-only visible-pixel mask. The shared head transform from
`e674-record0-transform.bin` agrees with E679 Shader Debug's projected direction.
The raw instance record is not that skinned head transform.

Independent exports are pinned by SHA256:

- E674 before, `iris-reference-before.dds`:
  `5a3964ec44b0a2fa052e5d63213fef0273a4449046b1c99c41447af49b97fb7e`
- E679 after, `iris-reference-after.dds`:
  `346fdb6e58eab4e3a837bb3d42a364dfbe4a7a796d91e1b89d437d81ca528354`

RTX 3050 / Vulkan: **513/513 changed visible pixels exactly match R11G11B10 HDR**;
MAE 0, maximum error 0, missing pixels 0. `compare_iris_replay.py` enforces exact
encoded equality and finite raw output. This establishes the captured visible
subset, not full visibility reconstruction or universal renderer equivalence.

Independent RenderDoc Shader Debug at (1255,1152), visible primitive 54:
RGB (1.028842330,1.369923115,1.499358416), diffuse normal
(.299483001,-.212003097,.930249751). Raw replay tolerances are 2e-5 for RGB and
1e-6 for normal. `e679-debug-validation.json` retains selected intermediate values;
`e679-gpu-validation.json` contains the comparison report. Both are in ignored
`.renderdoc-analysis/endfield-frame37917/gbuffer-materials` alongside capture assets.

Run from repository root with a real Vulkan display driver:

```powershell
$ev = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_iris_replay.py $ev --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://iris_replay.gd --quit-after 600 -- --evidence=$ev
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_iris_replay.py $ev
.\debug_full_character.bat --smoke --live-lights
```

## Scene and real-time validation

The fixture preserves tangent handedness and the head object basis. Isolated tests
verify parallax, curvature and MatCap parameter responses, and exact independence
from screen AO. The iris silhouette contains 241 pixels / 225 textured colors at
the fixture resolution. Full-character default/live views were generated and the
live three-quarter view inspected.

The live variant uses the existing 16-light bridge and full-RID engine shadows.
Main visibility feeds the existing shadow channel once. Local mode 1 gates its
complete contribution once, including its artistic dark-side floor. Modes 0/4
retain their original behavior; mode 3 is tested as zero both visible and blocked.

GPU summed RGB: directional visible 22322.726 / blocked 0; Omni mode 1
34453.314 / 0; Spot mode 1 34003.891 / 0. Unoccluded output matches explicit material
inputs. Existing tests also cover moved/disabled/zero-opacity shadows, coincident
light identities, light-count limit and deleted-light cleanup.

Logs: `iris-iris_replay-regression.log`, `live-iris-test.log`,
`iris-full-character.log`, `iris-*-regression.log`, `iris-smoke-*.log` under
`.renderdoc-analysis`. All older material/surface/post-process/live AO and original
Forward+ / Custom Forward smoke cases remain intact and passed again. This task
adds no renderer C++ changes. Animated eye deformation, arbitrary material variants,
multiview and TAA/FSR2 remain unvalidated.
