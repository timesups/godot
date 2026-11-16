# Captured character main-shadow provenance and filtering replay

Updated 2026-11-16. Capture: `D:/Download/EndField-frame37917.rdc`, SHA256
`def7b7a19baed8b9dc89aada3b84c396897b78bb483bfb220cafcf85901d8143`.
Evidence: `.renderdoc-analysis/main-shadow/reexport/`; RenderDoc 1.46, Vulkan,
RTX 3050. This milestone reconstructs the active screen-space filtering branch
from captured inputs. It does not replace live Godot shadows or regenerate the atlas.

## Producer and consumer chain

1. E269–334 clears/stores `187141`, a 4096×2048 D16 character shadow atlas.
   Nine indexed draws write the first 1024×1024 tile, scissored to (1,1,1022,1022).
   Depth test/write: GreaterEqual, enabled; raster culling disabled; constant
   depth bias -8, slope bias 0. These are reversed-depth comparisons.
2. E631–642 writes screen texture `173767`, 2560×1440 RG8 UNorm. E637 and E641
   use depth/stencil `173794`. Depth test Always, no depth writes, no blending.
   E637 uses stencil NotEqual; E641 Equal; both reference 4, compare mask 7.
   Pixel histories at (1220,1190), (1255,1152), (1200,700) confirm the partition.
3. E637 writes `(global visibility, 1)`. E641 writes
   `(global visibility, character-atlas visibility)`. Thus G is **not SSAO**.
   In this frame the global branch is bypassed: shadow CB offset 560 is
   `(0,0,1,1)`, offset 544.x is 1. R is 255 everywhere in the exported RG8 target.
4. Character material draws read `173767`. Existing replay helpers call its G
   value `ao`/`screen_ao`, but that name describes how it shapes material lighting,
   not its provenance. For example E704 uses G in `min(G, parameters.b, ramp.a)`
   and `view_ramp * parameters.b * G`; R blends lit/unlit irradiance and surface
   branches. Multiplying final RGB by G would not reproduce this composition.
   E689 additionally has its independent face SDF; E679 does not consume this
   screen input. Preserve each material's existing captured behavior.

The existing live Godot SSAO connection remains an approximation and is unchanged.
Do not interpret this discovery as permission to multiply AO, SDF and shadow again,
or to rename public material controls before their live migration is designed.

### Atlas draw correspondence

Correspondence is established by buffer `111464`, index byte offset/stride,
draw index offset/count, and vertex buffer offsets, not only triangle counts.

| Atlas draw | Color draw / part | Index count | Index byte offset | Index stride |
| --- | --- | ---: | ---: | ---: |
| E281 | E674 face details | 1356 | 2937456 | 2 |
| E286 | E679 iris | 840 | 2919712 | 2 |
| E291 | E669 skin | 12762 | 2888800 | 2 |
| E296 | E694 clothes | 114840 | 1754032 | 2 |
| E301 | E684 accessory | 315 | 2674752 | 2 |
| E306 | E699 ear | 2862 | 2441312 | 4 |
| E311 | E689 face | 9978 | 2756192 | 2 |
| E316 | E704 hair | 41901 | 3370912 | 2 |
| E321 | additional caster range, not one of the eight opaque draws | 54378 | 2441312 | 4 |

E321 starts at index 2862 in the same buffer range as E306. Its pixel shader
compares `sqrt(texture alpha * material alpha)` with a screen-coordinate noise
value and discards. E301 uses an authored alpha threshold. Other seven pixel
shaders are empty depth-only shaders. The identity and visibility of E321's
additional geometry still need investigation; do not omit it or assume it is
the opaque ear. Raw vertex shaders are exported; their transforms/deformation
and caster geometry are the next reconstruction milestone.

## E641 inputs and algorithm

Pixel descriptor set 3:

| Binding | Resource | Meaning |
| --- | --- | --- |
| 4 | 173776, R10G10B10A2 | octahedral normal in XY, Y-up decoding |
| 5 | 173782, R10G10B10A2 | packed bit mask selecting character shadow record |
| 6 | 66373 | cloud texture, inactive global branch |
| 7 | 187141, D16 | character depth atlas |
| 8 | 173764, R32 float | screen depth |
| 9,10 | 7594, D16 1×1 | global shadow dummy textures in this frame |
| 11 | buffer452 @39808, 32864 bytes | global constants |
| 12 | buffer452 @148480, 11440 bytes | shadow constants |
| 13 | buffer452 @75328, 4512 bytes | camera constants |

Sampler 0 is point/clamp; 1 linear/repeat; 2 linear/clamp; 3 linear/clamp with
Greater depth comparison. Character atlas gathers use sampler 2, with explicit
depth comparisons in the shader. Sampler mip filtering is point.

The global branch contains cascade selection, bias, four weighted hardware
comparison samples, transitions/fade and cloud modulation. Its nontrivial
branches are disassembly evidence only, **not validated by this bypassed frame**.

The active character filter:

- Reconstructs world position with camera inverse matrix @384. Depth is fetched
  at pixel center, but clip XY uses the **integer pixel**, camera inverse size
  @1328.zw, and negated clip Y. Preserve this original half-pixel distinction.
- Rebuilds uint from the packed mask, takes `log2(float(mask))-8`, range-checks
  against shadow @8864.z, then truncates to the record index.
- Decodes and normalizes the oct normal. `slope=1-clamp(dot(N,L),0,.9)`;
  `Pbiased=P-L*(slope*bias.x)+N*(slope*bias.y)`. Record arrays: matrix @7168,
  bias @8128, direction @8368, atlas transform @8608. Projects without a W
  division, clamps Z to at least .01, rejects outside (0,1) or NaN Z.
- Rotates 16 exact Poisson offsets using a 4×4 screen-periodic lookup indexed
  `(x%4)*4+y%4`. Radius is **fixed**, `4 * shadow[8848].x` in normalized atlas UV
  (four horizontal texels, two vertical texels for this nonsquare atlas).
- Performs 16 gathers, four depths each. `step(0, stored-receiver)` gives 64
  reversed-depth blocker comparisons. B is blocker count, S the sum of positive
  depth differences. Let `d=clamp((S/B)/receiver,0,1)`, `c=clamp(B/64,0,1)`,
  `t=2*c-1`, `s=sign(t)`, `a=1-s*t`. Visibility is
  `min(1, .5-.5*(1-mix(a*a*a,a,d))*s)`.
- B=0 produces NaN intermediates in the captured shader; its final NMin returns
  1. The replay explicitly returns 1, avoiding undefined propagation.

This is fixed-radius coverage/depth remapping, not the live Godot two-phase PCSS
search/filter. Exact lookup constants came from raw SPIR-V, not rounded text.
`precise` on reconstruction, projection and atlas UV operations is necessary:
unconstrained contraction caused 1804 differing pixels (max 55 RG8 steps).

## Validation and limits

`main_shadow_replay.gd/.glsl` runs an independent compute reconstruction in Godot
RenderingDevice. The original SPIR-V is evidence only; it is not executed by the
replay. `export_main_shadow.py` explicitly sets each frame event before exporting
and writes separate native state/sampler/action evidence. Input hashes are pinned
in `main_shadow_inputs.json`; capture data are ignored and not committed.

- All 249573 stencil-selected pixels compared: 249572 identical RG8 pairs.
- Only (1306,542) differs: replay G=255, capture G=254. Maximum error 1 code;
  normalized G MAE 1.571311250596411e-8. Comparator permits this coordinate only,
  no general edge exclusion or average-error allowance.
- R and the complete noncharacter complement are exact. Reference subset has
  8196 black, 20164 fractional and 221213 white pixels, all checked.
- Export was repeated in a fresh native replay; all pinned inputs matched.
  Comparison image was visually inspected. This proves the active filter from
  captured inputs, not independent G-buffer/stencil/atlas generation.
- Existing material and post GPU replays are separate regressions; they still
  use original captured screen inputs. Live shadow implementation, contact/PCSS
  fixes, original Forward+, and old test thresholds are unchanged.

## Reproduce

From the repository root, with a GPU (not `--headless`):

```powershell
$env:MAIN_SHADOW_CAPTURE = 'D:/Download/EndField-frame37917.rdc'
$env:MAIN_SHADOW_EVIDENCE = 'E:/ZcxCode/godot/.renderdoc-analysis/main-shadow/reexport'
$job = Start-Process 'C:/Program Files/RenderDoc/qrenderdoc.exe' -ArgumentList '--python','E:/ZcxCode/godot/tests/rendering/custom_forward/export_main_shadow.py' -WindowStyle Hidden -PassThru
$job.WaitForExit()
# Require exit code 0 and export-success.json; inspect export-error.txt on failure.
$evidence = $env:MAIN_SHADOW_EVIDENCE
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://main_shadow_replay.gd --quit-after 600 -- --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_main_shadow.py $evidence
```

Require `MAIN_SHADOW_REPLAY_OK`, `MAIN_SHADOW_COMPARE_OK`, and no ERROR lines.
The exporter deliberately exits its dedicated qrenderdoc process; do not execute
it inside the user's interactive RenderDoc process.

## Next stages

1. Rebuild atlas generation independently: extract post-VS shadow geometry and
   transforms, resolve E321, reproduce E301 threshold/E321 dither and -8 D16 bias;
   compare atlas depths before feeding them into this already verified filter.
2. Feed the reconstructed screen result through the eight existing material
   replays, then design opt-in live integration while preserving current engine
   quality fixes and full regression coverage. Keep global and character shadow
   channels distinct from actual SSAO and face SDF.
3. Find a capture with active global cascade/cloud branches before claiming
   those branches are validated. Trace actual AO separately; this G channel is
   not evidence for an AO algorithm. Then inspect remaining post-processing.
