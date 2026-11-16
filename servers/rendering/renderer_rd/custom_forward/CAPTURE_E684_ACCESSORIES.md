# E684 accessory reconstruction

The active dry-accessory specialization is implemented in `materials/accessory.gdshader`
and `accessory_lighting.gdshaderinc`. It reuses existing surface, BRDF and local-light
utilities, leaving the original E694 clothing material and regression unchanged.

## Capture inputs and differences from clothing

Source: `D:/Download/EndField-frame37917.rdc`, E684, pixel shader module 109864.
The existing posed post-VS mesh has 110 vertices (stride 144) and 315 uint16 indices.
Material buffer 630, offset 2206528, size 336 is saved as `e684-cb5.bin`.

| Resource | Captured use |
| --- | --- |
| 187399 | BC7 sRGB base color, 2048 square, 12 mips |
| 187402 | BC7 linear metallic/F0 scale/AO/smoothness, 2048 square, 12 mips |
| 187429 | BC5 tangent normal, 2048 square, 12 mips |
| 118829 | Shared RGBA8 lighting ramp |
| 8600 | BC6H unsigned reflection cube, 128 square, 8 mips |

All these texture resources are already exported for E694 and are reused directly.
Normal strength is 1, base tint white, alternate value .5 / saturation 1.
The analytic specular uses material F0 directly: **no specular lookup texture** is
bound in this specialization. The emission factor/tint are zero and no emission
texture is bound. Adding E694's lookup or emission would be incorrect.

The active path includes mapped normals, metallic diffuse/F0, ramp shading,
analytic specular, environment BRDF and cube reflection, plus local modes 0/1/3/4.
It uses white main tint (global vec4 194), environment color vec4 191, strength
.2877224684, exposure 1.05, shadow strength .55 and ambient exposure .9.
Wet/snow/probe/fog variants inactive in this captured instance are not reconstructed.
The model remains a posed mesh without recovered animation.

## Independent captured evidence

`accessory_replay.gd/.vert/.frag` uses the same accessory lighting include as the
scene material, original post-VS vertices/indices, and captured light, shadow and
screen inputs. The mask/depth rejection is test-only visible-subset isolation,
not reconstruction of the full visibility system. Depth sampling is nearest.

The independent HDR references are hash-pinned:

- E679 before, `fresh-e679-133342.dds`:
  `346fdb6e58eab4e3a837bb3d42a364dfbe4a7a796d91e1b89d437d81ca528354`
- E684 after, `accessory-reference-after.dds`:
  `93c6cc325b09f10971d292a0caed88fe30d486cd085ca95defcb12fce7e11a69`

RTX 3050 / Vulkan: **502/503 visible pixels exactly match R11G11B10 HDR**.
The remaining pixel (1295,1050) differs by one green encoding step; red/blue match.
MAE 6.471587144e-7, maximum .0009765625, no missing pixels. The comparison keeps
that pixel and enforces these measured bounds rather than claiming pixel identity.

Independent RenderDoc Shader Debug at (1385,251), visible primitive 53:

| Component | Reference RGB | Absolute tolerance |
| --- | --- | --- |
| Final | (.373155534,.391148865,.404758751) | 3e-6 |
| Surface | (.198952183,.208250403,.212933615) | 1e-6 |
| Analytic specular | (.000299149,.000299768,.000303146) | 2e-6 |
| Reflection | (.005921267,.005971014,.006486392) | 1e-7 |

`compare_accessory_replay.py` checks these values, finite raw output, coverage and
encoded error bounds. Evidence lives in ignored
`.renderdoc-analysis/endfield-frame37917/gbuffer-materials`:
`e684-gpu-validation.json`, `e684-debug-validation.json`, and `e684-hdr-*.bin`.

Run from repository root with a real Vulkan display driver:

```powershell
$ev = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_accessory_replay.py $ev --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://accessory_replay.gd --quit-after 600 -- --evidence=$ev
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_accessory_replay.py $ev
.\debug_full_character.bat --smoke --live-lights
```

## Scene integration

The full character uses a dedicated accessory material with original tangent
handedness. Isolated checks verify normal, analytic specular, reflection and
shadow/AO responses. The fixture has 1547 silhouette pixels and 779 textured colors.

The live variant uses the existing 16-light bridge and full-RID directional/local
shadow helpers. Main visibility enters the existing shadow channel once. Local
modes 1/3 gate their complete contribution once, while modes 0/4 retain their
original unshadowed/replacement behavior. Explicit-input fallbacks remain available.
Screen AO uses the existing minimum with manual AO in its own channel; no face SDF
or additional final-color AO multiply is introduced. Reflection stays in its
captured environment-light path, outside direct-light shadow gating.

Existing shadow/AO test suites are extended to accessories without removing older
cases. They cover direct/Omni/Spot occlusion, moving/disabled/zero-opacity shadows,
coincident light RIDs, 16-light cap/deletion, and five screen-AO camera/rendering
configurations. Runtime evidence and final regression results are recorded in
`HANDOFF_CUSTOM_FORWARD.md` after verification. No renderer C++ or original Forward+
changes are required. Soft-edge parity, multiview, TAA/FSR2 and animation remain
outside the validated scope.
