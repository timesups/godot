# E694 clothes: surface reconstruction

Capture: EndField-frame37917.rdc, SHA256
`DEF7B7A19BAED8B9DC89AADA3B84C396897B78BB483BFB220CAFCF85901D8143`.
Forward draw E694 (shader 35804) pairs with G-buffer E483.
114840 indices, uint16; post-VS stride 144, tangent at byte 64.

## Confirmed bindings and dry surface

| Set / binding | Resource | Meaning |
| --- | --- | --- |
| 1 / 10 | 187399 | BC7 sRGB base, 12 mips |
| 1 / 6 | 187402 | BC7 linear: metallic, dielectric F0 multiplier, AO, smoothness; 12 mips |
| 1 / 9 | 187429 | BC5 linear tangent normal, 12 mips |
| 1 / 7 | 185914 | BC7 sRGB emission, 11 mips |
| 1 / 8 | 118829 | Main/view diffuse ramp |
| 1 / 5 | 39217 | Specular lookup |
| 0 / 36 | 8600 | Environment reflection cube |

Material constants: buffer 630, offset 417344, 336 bytes.
Normal strength = 1; backface-normal parameter = 0; base tint = (1,1,1,1);
emission tint = (1,0.838799119,0), intensity = 2.
The alternate/shadow color is base * 0.5 with saturation 1.
These differ from the face's material LUT path.

Source shader lines 448–543 decode the surface:
normal XY = (sample.a * sample.r, sample.g) * 2 - 1;
Z = sqrt(1 - clamp(dot(XY,XY),0,1)).
Only XY is multiplied by normal strength, before the tangent transform.
BC5 supplies alpha=1. Bitangent is cross(normal,tangent.xyz)*tangent.w.
The world normal is normalized, then reversed for backfaces.
Lines 1906–1916 split diffuse/F0:
diffuse = base * (0.96 - 0.96 * metallic),
F0 = mix(0.04 * parameter.g, base, metallic),
roughness = 1 - parameter.a.

## Independent validation

`clothes_surface_replay.gd` renders the original captured posed geometry with
the shared surface include. It isolates 215604 changed E694 pixels using the
fresh E689/E694 HDR exports and captured depth; this visibility mask is test-only.
Base is compared against E483 attachment 173779 (RGBA8 sRGB), octahedral normal
against attachment 173776 (RGB10A2). Both match exactly at 215599 pixels
(99.99768%). Five differences are retained explicitly in the report and gate:
(1219,133), (1200,144), (1360,866), (1260,1013), (1313,1066).
The later HDR replay resolves these by enabling reversed-depth testing between
clothes triangles. The original surface test remains unchanged for regression.

Shader Debug at (1311,730), **primitive 15409**, independently gives:
base=(0.30859375,0.30859375,0.34765625),
parameters=(0,1,0.921293974,0.368978411),
diffuse=(0.296249986,0.296249986,0.333749980), F0=(0.04,0.04,0.04).
The replay agrees within 3e-8. Omitting primitive_id chooses an occluded
triangle at this pixel and produces a misleading comparison.

## Running

Evidence directory is `.renderdoc-analysis/endfield-frame37917/gbuffer-materials`.
Assets are local only. Required new files: E694 post-VS vertex/index exports,
E694 texture 187399/187402/187429 mip0–11 DDS, E483 attachments 173779/173776,
fresh E689/E694 HDR exports, and existing e689-texture-173764 depth.
Each mip file is named `e694-texture-ID-mipN.dds`, mip0 omits the suffix.
BC5 DDS uses the 128-byte legacy header, BC7 uses the 148-byte DX10 header.

Run `compare_clothes_surface.py <evidence> --prepare`, then the Godot script
`res://clothes_surface_replay.gd -- --evidence=<absolute path>`, then
`compare_clothes_surface.py <evidence>`. Use custom_forward with Vulkan.
The replay writes separate e694-surface-* outputs.

`debug_full_character.bat --clothes-surface` enables the scene surface path.
For an automated run, use `--smoke --clothes-surface`.
It verifies and saves five isolated inspection views using
`materials/clothes_surface.gdshader`; default scene behavior remains unchanged.
Existing E674/E689 tests still run. This flag is surface inspection, not final
clothes lighting. Source geometry must retain tangents; normal textures must
remain linear and must not receive importer normal-channel swizzles.

## Final HDR replay and scene integration

`clothes.gdshader` now supplies E694 in the default assembled scene.
It shares `clothes_lighting.gdshaderinc` with `clothes_replay.frag`.
Implemented: main/view ramp, screen shadow/AO, analytic specular and lookup,
environment BRDF with energy compensation, emission, local modes 0/1/3/4,
and optional reversed-depth shadow atlas using the existing nine-tap tent helper.
This is the captured dry specialization. Wetness, snow, probe volumes, line
lights, cookies and mode 2 are not reconstructed; main rim color is zero and
the additional main rim branch is disabled by the captured parameters.

E694 uses white main light (CharacterParams5), environment tint
(0.849077106,0.895768583,1.150923014), and base*0.5 for alternate diffuse.
Environment reflection uses resource 8600, six 128x128 BC6 unsigned faces and
eight mips. LOD = 5 + 1.2*log2(max(roughness,0.001)), with nearest-mip selection.
The production cube sampler enables mips; the shared function rounds LOD
explicitly so project trilinear settings do not change the captured selection.

Additional evidence: e694-cb0/1/2.bin, e694-texture-118829.dds,
e694-texture-39217.dds, emission 185914 mips 0–10, and
e694-cube8600-faceF-mipM.dds (F=0–5, M=0–7).
Replay also uses the existing shadow atlas, screen mask and light-binning export.
Run:

```powershell
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_clothes_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://clothes_replay.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_clothes_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials
```

Measured RTX 3050: 215051/215604 exact pixels (99.7435%), linear HDR MAE
2.05975676e-6, max 0.0205078125, no missing pixels. Twelve pixels have a channel
error greater than one encoded step; the maximum is 19. All remain in the gate.
Comparison requires >=215000 exact, MAE<=2.1e-6 and these maximum-error bounds.
Reference DDS SHA256 values are pinned, independently of candidate outputs.

At (1311,730), primitive 15409, Shader Debug gives analytic specular
(0.022303779,0.014907449,0.013187119) and environment reflection
(0.004862541,0.004662335,0.004982024). Replay component gates are 3e-6 and 1e-7.
At (1340,967), primitive 36509, surface and environment agree while spotlight
shadow differs: Shader Debug 0.448434 versus replay 0.555524. Equal biased
world positions produce projected coordinates differing around 1e-5 due to
matrix evaluation at world coordinates near -300. Forcing scalar no-contraction
arithmetic improved that sample but worsened the full-frame result; it is not
used. Hardware comparison-sampler and floating-point differences remain open.

Scene inputs are explicit: screen_shadow_ao, light arrays, reflection cube,
and optional atlas. Atlas matrices must use scene coordinates; the recentered
fixture cannot use raw capture matrices without translation adjustment.
The fixture uses main/environment lighting by default and separately tests
local modes, specular/reflection toggles, AO/shadow, blackout, atlas blocked/
visible and zero-strength continuity. No automatic Light3D/shadow integration
or full-scene visibility reconstruction is claimed. Source fog is inactive in
this capture; the scene material still uses the engine's normal postprocessing.

E674, E689, surface replay, Bloom/LUT and albedo-only/inspection modes are retained.
