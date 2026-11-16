# Directional cascade edges and soft-shadow validation

The character directional-shadow helper now samples only real cascades.
Unused split distances repeat the final distance, while their shadow matrices,
atlas regions and PCSS parameters are not valid. Previously, two-split PCSS
with split blending could sample cascade 3 and lighten fully occluded pixels.
The PCF blend path could also sample that nonexistent cascade near the final
fade range. The helper now checks increasing split distances before sampling
or blending, and returns full visibility beyond the final shadow distance.

This change is confined to `shaders/custom_forward/character_shadow_inc.glsl`.
Original Forward+ and its ordinary-material shadow path are unchanged. The
same unused-cascade defect is reproducible in original Forward+; the quality
comparison records this intentional difference rather than treating that
renderer as a correct reference for those cases.

## Independent fixture

`tests/rendering/custom_forward/directional_shadow_quality.gd` renders a
partially shadowed flat receiver. The caster is shadows-only; the receiver
does not cast shadows, isolating filtering and split selection from acne.
The character variant emits the actual RID-selected visibility. The reference
variant emits the ordinary shader `light()` ATTENUATION and runs in original
Forward+. They use the same scene and case configuration.

160 cases per renderer cover:

- 1/2/4 cascades, blending off/on, PCF and 5-degree PCSS;
- perspective camera at 3.98/4/4.02, 7.98/8/8.02 and 11.98/12/12.02 units;
- 18/19-unit distance fade and 21 units beyond the 20-unit shadow range;
- low/high filtering, 0/2/5-degree angular size and 0.5/2-unit caster gaps;
- repeated stationary images, half opacity, and nonzero normal bias.

The fixture fixes a 2048-pixel, 32-bit directional atlas, 256-square viewport,
30-degree camera FOV, no MSAA and no TAA. Exposure is linear, without ambient
lighting. The comparison decodes PNG sRGB to linear visibility. Ordinary
Forward+ quantizes shadow visibility to eight bits before lighting, so parity
allows mean error 0.005 and maximum 0.015, including screenshot quantization.
This is not a pixel-exact HDR parity claim.

The comparison independently requires correct fully lit/shadowed interiors,
distance fade, continuity over camera crossings, increasing PCSS penumbra,
reduced noise at high quality, linear opacity and stationary image identity.
These checks remain active even where Forward+ contains the known defect.

## Measured result (Windows / Vulkan / RTX 3050)

- Before the fix, two-split blended PCSS had interior visibility 0.152926 at
  depth 8 and 0.496933 at depth 12 instead of zero. The new interior assertion
  failed on the saved pre-fix images. Both become exactly zero after the fix.
- All 160 cases and 36 camera-crossing comparisons pass after the fix.
- Largest crossing mean change: 0.000530231; largest individual pixel change:
  0.036248 for a 4 cm camera move. These include shadow-map sampling changes.
- Outside known defective stock cases, maximum reference mean error is
  0.00403711 and maximum pixel error is 0.00889791.
- High-quality PCF at a 2-unit gap has a 4-pixel 10–90% penumbra. PCSS at
  2 and 5 degrees has 8 and 20 pixels respectively. At a 0.5-unit gap,
  5-degree PCSS has 3 pixels.
- Spatial penumbra RMS noise drops from 0.0597792 (low) to 0.0226380 (high).
  Repeated stationary visibility images are identical.

Evidence is ignored under `.renderdoc-analysis/shadow-quality/`: `character`
contains pre-fix images, `character-fixed` contains post-fix images and
`validation.json`, and `forward_plus` contains the unchanged renderer's
reference. Logs: `shadow-quality-before-compare.log`,
`shadow-quality-fixed-compare.log`, and `shadow-quality-{character-fixed,forward-plus}.log`.

## Reproduce

Run from the repository root, with a real GPU/display driver:

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://directional_shadow_quality.gd -- --output=E:/ZcxCode/godot/.renderdoc-analysis/shadow-quality/character-fixed
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method forward_plus --rendering-driver vulkan --script res://directional_shadow_quality.gd -- --reference --output=E:/ZcxCode/godot/.renderdoc-analysis/shadow-quality/forward_plus
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_directional_shadow_quality.py .renderdoc-analysis/shadow-quality/character-fixed .renderdoc-analysis/shadow-quality/forward_plus
```

The existing complete-character, shadow/AO, material, post-process and both
renderer smoke regressions remain in place. This fixture does not establish
animated-mesh self-shadow quality, multiview, TAA/FSR2 behavior or performance.
