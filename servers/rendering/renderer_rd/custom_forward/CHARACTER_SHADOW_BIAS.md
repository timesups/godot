# Character self-shadow bias and contact validation

The initial fixture fixes below are retained. A subsequent Custom Forward-only
receiver-plane contact query now resolves the tested 0.002-unit leakage; see
"Receiver-plane contact correction" below.

First, captured world-space post-VS triangles were loaded with their original
counterclockwise winding, while Godot ArrayMesh uses clockwise front faces.
The materials are two-sided, so the mesh remained visible, but FRONT_FACING
flipped exterior normals and pushed normal bias inside the character. A real
material comparison with main shadows disabled exposed striped face self-shadow
that the synthetic sphere alone did not catch. `character_mesh.gd` now reverses
triangle winding once when importing the complete posed mesh. The default and
live complete-character previews both use this conversion. Captured clip-space
replay fixtures retain their original projection and indices.

Second, the isolated live character preview used an orthographic camera with the default
4000-unit far plane. Directional cascade fitting uses the camera far plane for
orthographic cameras, regardless of `directional_shadow_max_distance`. This made
shadow texels and depth bias too large for a roughly two-unit character: the
controlled character diagnostic lost all shadows. The default 20-unit pancake
margin further increased the light-space depth range and therefore depth bias.

`tests/rendering/custom_forward/character_shadow_preview.gd` now configures only
the final live preview, after existing material/AO/light-binding tests finish:

- camera far plane and directional max distance: 6 units;
- directional pancake margin: 2 units;
- depth bias 0.05, normal bias 1.0;
- 2-degree PCSS, high quality, 2048-pixel 32-bit atlas;
- four cascades, split blending disabled (as in the previous preview).

These settings fit this fixed posed mesh and its front/three-quarter cameras.
They are not engine defaults or a preset for arbitrary scenes: larger scenes,
external casters, camera movement and different asset scales need their own
camera/shadow ranges. Original Forward+, engine shader code, material lighting,
face SDF and screen AO are unchanged. AO is not used to hide contact leakage.

## GPU fixture and acceptance

`character_shadow_bias.gd` renders 193 cases per renderer at 320 x 320, without
TAA/MSAA. Custom Forward emits RID-selected shadow visibility in R, signed N.L
mapped to [0,1] in G, and geometry coverage in B. Original Forward+ emits the same
channels through `light()` and ATTENUATION. PNG values are decoded from sRGB.

The cases cover self-casting spheres, nonuniformly scaled/rotated ellipsoids,
two-sided zero-thickness casters at 0.002/0.01/0.05-unit gaps, and all eight posed
character parts. Five bias presets and PCF/2-degree PCSS expose both acne and
excessive-bias leaks. Orthographic controls vary far range, pancake margin and
bias. Final preview cases call the same configuration helper as the actual
preview, exercise both character views and repeat a stationary image.

`compare_character_shadow_bias.py` checks complete case inventory, matching scene
configuration and geometry coverage, reference mean/max errors below 0.005/0.015,
curve lit/dark interiors, thin-caster reversal identity, contact interiors,
character shadow coverage and exact stationary repeatability. Reference parity
alone is insufficient: the bad settings reproduce the same failures in both
renderers, so physical/negative-control checks are independent of parity.

## Initial fixture result (Windows / Vulkan / RTX 3050)

For the final preview configuration:

| Diagnostic | Linear visibility (1 = fully lit) |
| --- | --- |
| Sphere lit interior / backlit interior | 0.996888 / 0 |
| Ellipsoid lit interior / backlit interior | 0.998390 / 0 |
| Thin sheet, 0.01-unit gap | 0.000857 |
| Thin sheet, 0.05-unit gap | 0 |
| Thin sheet, 0.002-unit gap | 0.817231 (remaining limitation) |

The old far=4000/default-bias control yields visibility 1 for the character and
even the 0.05-unit contact shadow. Final character front/three-quarter views have
28.55%/10.90% of covered pixels below 0.5 visibility. This establishes restored
self-occlusion, not artistic ground-truth for the captured character's normals.
A dedicated GPU orientation diagnostic requires over 95% of visible exterior
normals to face the camera; the corrected mesh measures 98.84%, versus 1.16%
for an independent legacy-winding capture (which fails this gate). This guards
against reintroducing reversed winding independently of reference parity.
Two-sided caster reversal and stationary repeats are exact. Maximum reference
mean error is 0.00224110 and maximum pixel error is 0.00889790.

**At the initial fixture milestone, the 0.002-unit gap was not solved.** At this atlas and bias,
near-contact separation still falls below the useful shadow-map precision. Zero
or very low bias restores more contact but introduces measurable curve acne;
excessive bias removes self-shadow. Do not label all contact leakage fixed, and
do not multiply AO/SDF into main-light visibility to disguise it. A future
receiver-plane/contact-shadow solution needs its own accuracy and performance
validation. Animated geometry, TAA/FSR2, multiview and performance are unverified.

## Reproduce

From the repository root, using the existing local capture evidence:

```powershell
$evidence = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://character_shadow_bias.gd -- --output=E:/ZcxCode/godot/.renderdoc-analysis/shadow-bias/character --evidence=$evidence
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method forward_plus --rendering-driver vulkan --script res://character_shadow_bias.gd -- --reference --output=E:/ZcxCode/godot/.renderdoc-analysis/shadow-bias/forward_plus --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_character_shadow_bias.py .renderdoc-analysis/shadow-bias/character .renderdoc-analysis/shadow-bias/forward_plus
.\debug_full_character.bat --smoke --live-lights
```

Ignored evidence: `.renderdoc-analysis/shadow-bias/{character,forward_plus}`;
comparison report: `character/validation.json`. Logs use the `shadow-bias-` prefix.
Existing cascade-quality, material, AO, default-character and renderer smoke
regressions remain intact. No engine rebuild is required for these script changes.

## Receiver-plane contact correction (2026-11-16)

`character_shadow_inc.glsl` retains the existing directional PCF/PCSS query and
adds a short shadow-map contact query per selected cascade, before split blending,
distance fade and opacity. It combines visibility with `min`, not multiplication.
Original Forward+, local lights, material AO and face SDF are unchanged.

The extra query projects geometric position derivatives into the directional
shadow map to reconstruct the receiver plane. Four point-fetched texels each
compare against that plane at their own texel centers, and requires all four texels to support the blocker. This conservative footprint
rejects isolated neighboring-surface samples that caused visible face acne in
the initial bilinear prototype.
This avoids treating an inclined receiver as a constant-depth plane. No screen
depth buffer is used: the shadows-only thin casters in this test remain visible
to this query even though they are absent from screen depth.

The contact query uses a rasterization margin capped at 0.25 shadow texels rather
than the broad PCF depth bias; the original filter's bias is untouched. Its reach
is eight shadow texels measured along the receiver normal, fading over the outer
half. This prevents changing distant PCSS penumbrae. Zero authored depth bias,
degenerate projected derivatives and grazing planes with absolute N.L below 0.1
fall back to the existing filter, with a smooth angular fade from absolute
N.L 0.2 to 0.1 to avoid a hard grazing-angle cutoff. This is a bounded contact approximation, not a
full replacement for shadow filtering or an exact soft-shadow solution.

Rejected experiments are retained only in ignored evidence: normal-offset depth
correction alone reduced the 2 mm leak to 0.399625 but lowered sphere/ellipsoid lit
visibility to 0.908755/0.929106; replacing all PCF/PCSS filtering resolved contact
but changed distant penumbrae and failed the existing reference thresholds.
Neither rejected algorithm is present in the final shader.

### Validation

The original 193 captures, inventory checks, geometry coverage, orientation,
static repeatability and thin-caster reversal checks remain. Legacy comparison
mode still validates the original captures against Forward+. `--contact` adds
56 cases (249 total): yaw 0/30/60/75 degrees, PCF/2-degree PCSS, self-casting clear
planes, and 2/4/8/16/32 mm gaps; six angles straddling the grazing fallback;
and two isolated captured-face views under the actual preview light direction. The new mode requires the saved unmodified Custom
Forward baseline. It checks baseline/reference parity, prohibits brightening by
the new query, checks no added curve acne at every bias preset, and requires the
2 mm contacts to be dark. Excessive/zero-bias and far=4000 negative controls are
still asserted against the original baseline because added contact occlusion
intentionally changes excessive-bias behavior.

Final preview sphere lit/dark is 0.996888/0; ellipsoid 0.998390/0, unchanged from
the baseline. All three original gaps (2/10/50 mm) now have visibility 0. All 40
added gap cases are below 0.000035. Character front/side shadow coverage is
29.36%/11.12%; exterior orientation is 98.84%. These are geometry diagnostics,
not proof of artistic agreement with the captured game.

At the contact-query milestone, the expanded clear-plane tests exposed oblique PCSS self-shadow:
yaw 60/75 degrees has visibility 0.972686/0.809968, versus Forward+ values
0.971231/0.808106 (8-bit quantization). The extra query does not worsen it; this
separate filtering limitation is fixed by the subsequent blocker-search change below. Angles 83.9–84.6 degrees have a maximum adjacent visibility change of 0.0271;
that checks continuity, not accurate grazing contact. Other atlas sizes, animation,
TAA/FSR2 and multiview remain unvalidated. The conservative footprint can miss
sub-texel casters and contact edges; the existing PCF/PCSS result remains there. The extra four texture reads per selected cascade have not been
performance-profiled. The reach depends on cascade texel size, so this is not a
world-space guarantee at arbitrary camera ranges.

The unchanged directional-quality test passes all 160 cases and 36 crossings;
no parity thresholds were relaxed. Build log: `build-contact-coherent.log`.
Default/live full character and both renderer smoke tests are also rerun; see
`contact-verified-{default,live,smoke-custom_forward,smoke-forward_plus}.log`.
The real-material isolation log is `contact-real-coherent.log`; its screenshots
are `contact-real-b*.png` and the final live three-quarter image was inspected.
Evidence: `.renderdoc-analysis/contact-coherent/validation.json`,
`contact-coherent-reference`, `contact-verified-quality/validation.json`. The original
193-case baseline remains `.renderdoc-analysis/shadow-bias/character`.

```powershell
$evidence = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://character_shadow_bias.gd -- --contact --output=E:/ZcxCode/godot/.renderdoc-analysis/contact-coherent --evidence=$evidence
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method forward_plus --rendering-driver vulkan --script res://character_shadow_bias.gd -- --reference --contact --output=E:/ZcxCode/godot/.renderdoc-analysis/contact-coherent-reference --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_character_shadow_bias.py .renderdoc-analysis/contact-coherent .renderdoc-analysis/contact-coherent-reference --contact --baseline .renderdoc-analysis/shadow-bias/character
```

Do not overwrite the old baseline with the new renderer output. On a new machine,
capture that baseline with the pre-contact engine at `e6f1305834` first, using the
original 193-case command above. An engine rebuild is required for this GLSL
change (unlike the earlier fixture-only changes).

## PCSS receiver rejection (2026-11-16)

`custom_directional_soft_shadow()` now rejects the geometric receiver during
blocker search. The original search used the center comparison depth at every
offset, so an inclined receiver could count as a blocker and create a spurious
penumbra. Projected position derivatives reconstruct the plane at each sample;
the plane anchor retains the authored depth bias. A sample can only be excluded
if it passed the original center test, lies behind the corrected plane, and all
four footprint texels contain depth consistent with that plane. Clear-depth
texels prevent exclusion, preserving bilinear caster-silhouette statistics.
Rejection fades near grazing incidence; zero bias/degenerate planes retain the
original search. Accepted blockers retain their raw depths and the final PCF
filter is unchanged. The independent contact query from `e53eb25730` is intact.

The first implementation excluded candidates using just their bilinear depth;
this fixed the clear plane but failed several existing far-edge thresholds
(maximum error 0.037719). Requiring the full footprint resolved those failures.
Original Forward+, local lights, material AO/SDF and cascade/opacity logic are
unchanged. This is an engine quality correction, not a reconstruction of the
captured game's shadow-generation algorithm.

### Results and regression coverage

- Original 60/75-degree clear PCSS planes: 0.972686/0.809968 -> 1/1.
- Preview sphere and ellipsoid lit/dark: 1/0; 2/10/50 mm gaps remain 0.
- `--pcss-plane` keeps all 249 prior cases and adds 80 (329 total): 32 clear
  oblique planes and 32 paired 2 mm casters, across low/high quality, 2/5-degree
  lights, orthographic/perspective cameras and single/dual-axis light rotations;
  then 16 distant-caster edge cases at 60/75 degrees and 0.25/0.5-unit gaps.
- All 32 added clear planes are 1 and all 32 added near blockers are 0. The
  16 distant edge cases preserve strict full-image Forward+ parity (MAE <=
  0.000739, maximum <= 0.008898; thresholds remain 0.005/0.015), real occlusion,
  clear corners and increasing penumbra area with light angle and separation.
  Wide penumbrae of the finite sheet can overlap, so their center is not assumed
  to be a full umbra; narrow near cases still require one.
- In PCSS validation mode only, intentional removal of false self-shadow may
  brighten PCSS pixels. PCF images must remain exactly equal to the contact
  baseline, zero-bias controls remain exact, and all prior curve, thin-caster,
  contact, orientation, stationary and isolated-face checks remain. Saved
  60/75-degree contact baselines must fail the new clear-plane acceptance.
- Original 193- and 249-case comparison modes pass on their preserved captures.
  The unchanged 160-case directional quality/36-crossing suite also passes.
  Default/live full character, AO/shadow independence, real-material isolation,
  both renderer smoke tests and independent review pass. Actual material and
  final live three-quarter images were inspected. Independent HDR replay was
  not rerun because its paths are unchanged.

Evidence: `.renderdoc-analysis/pcss-final/validation.json`,
`pcss-final-reference`, `pcss-coherent-quality/validation.json`;
logs `build-pcss-coherent.log`, `pcss-final{-reference,-compare}.log`,
`pcss-coherent-quality{-compare}.log`, `pcss-{legacy,contact}-baseline-compare.log`,
`pcss-verified-{default,live,smoke-custom_forward,smoke-forward_plus}.log`,
`pcss-real.log` and `pcss-real-b*.png`.

```powershell
$evidence = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://character_shadow_bias.gd -- --pcss-plane --output=E:/ZcxCode/godot/.renderdoc-analysis/pcss-final --evidence=$evidence
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method forward_plus --rendering-driver vulkan --script res://character_shadow_bias.gd -- --reference --pcss-plane --output=E:/ZcxCode/godot/.renderdoc-analysis/pcss-final-reference --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_character_shadow_bias.py .renderdoc-analysis/pcss-final .renderdoc-analysis/pcss-final-reference --contact --pcss-plane --baseline .renderdoc-analysis/shadow-bias/character --contact-baseline .renderdoc-analysis/contact-coherent
```

Preserve both historical baselines: `shadow-bias/character` is the original
193-case engine; `contact-coherent` is the 249-case engine at `e53eb25730`.
The new search can cost up to four extra point fetches per suspect blocker-search
sample. Performance, other atlas scales, animated/deformed geometry, TAA/FSR2 and
multiview remain unvalidated. Receiver-plane extrapolation and conservative
contact support are approximations; these tests do not prove arbitrary curved
occluder correctness or exact soft-shadow ground truth.
