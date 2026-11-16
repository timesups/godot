# Character self-shadow bias and contact validation

Two fixture defects were found and fixed; the engine algorithms are unchanged.

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

## Measured result (Windows / Vulkan / RTX 3050)

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

**The 0.002-unit (2 mm at meter scale) gap is not solved.** At this atlas and bias,
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
