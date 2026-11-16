# Live hair depth and scene light bridge

Run `debug_full_character.bat --live-lights` to validate and preview E704 hair
with a DirectionalLight3D and blue OmniLight3D rim. Use
`debug_full_character.bat --smoke --live-lights` for an automatic exit.
Default captured-constant materials and independent HDR replays remain unchanged.
Only E704 uses live inputs in this fixture; the other materials retain their
existing setup, so the preview is not a globally relit reconstruction.

## Depth material variant

Compile `hair.gdshader` with `#define HAIR_REALTIME_DEPTH` prepended to its source
(the fixture expands local includes before setting `Shader.code`). For an
imported project, copy the shader and its includes into the same asset folder,
then put the define at the top of a dedicated material variant.

The variant uses a nearest-filtered `hint_depth_texture` and `depth_prepass_alpha`.
It writes opaque hair depth in the prepass and reads the copied depth in its
later color pass. Its output alpha remains one. No original Forward+ code or
engine shader was changed. This uses the existing renderer's screen-reading
material scheduling; it is not an opaque-pass attachment feedback loop.

Mode 3 projects the shading normal into view space, applies aspect-correct
screen offsets (`parameters.x * 0.006`), flips view Y to framebuffer UV Y,
and reconstructs linear depth with
`INV_PROJECTION_MATRIX`. The captured `smoothstep(0.1,0.2,depth difference)`
therefore works with both perspective and orthogonal cameras. Scene units are
assumed to be meters. UVs clamp one pixel inside the viewport. The depth image
contains opaque geometry and participating depth-prepass surfaces, not ordinary
transparent occluders. `realtime_rim_enabled=false` selects the original explicit
`local_rim_visibility` fallback. Without the compile define, no depth sampler
is declared and the original opaque material path remains intact.

## Light bridge

`materials/character_light_binding.gd` is a Node script. Assign a target
MeshInstance3D with its own ShaderMaterial, an optional DirectionalLight3D,
and an ordered `local_lights` array of OmniLight3D/SpotLight3D. It synchronizes
on each frame, or call `sync_lights()` explicitly before rendering. It supports
the 16-light E704/E694 layout, or E689 with `face_layout=true` (8 lights,
modes 0/1/3). E674 is not compatible.
Sharing a material across targets with different layers or light lists is not
supported: duplicate the material for each target.

The first 16 (face: 8) eligible entries win, preserving array order. Hidden, deleted,
layer-mismatched, zero-energy, zero-range and unsupported light entries are
skipped. A missing/hidden directional light clears main energy. Removing all
local lights sets count to zero, so old array values cannot illuminate a mesh.
Color is converted from sRGB to linear, energy/specular/range/attenuation and
transforms update live, including local distance fade. Light type and artistic
parameters map into the reconstructed lighting model, not stock Godot PBR.

Optional per-light metadata:

| Key | Type/default | Meaning |
| --- | --- | --- |
| `character_mode` | int, 0 | Captured local mode 0, 1, 3 (depth rim), or 4 (replacement) |
| `character_parameters` | Vector4(1,0.5,0,0) | Mode-specific bias/width, blend weight, unused, normal blend |

Spot cones use their world -Z direction, angle and the captured squared cone
falloff. Godot `spot_angle_attenuation` is not mapped. Energy uses `light_energy`,
not physical intensity or exposure normalization. Bake modes, projector textures,
and area lights are not bridged. Live E704 now
uses engine Omni/Spot shadow maps in modes 1 and 3; see
[ENGINE_CHARACTER_SHADOWS.md](ENGINE_CHARACTER_SHADOWS.md). The bridge disables
the captured explicit-atlas flag to prevent stale slot matrices after reordering.
The default/manual material retains its radial fallback; live hair replaces that
fallback with engine visibility (one when a light has no engine shadow).
Live hair also resolves the bound main directional light by RID and samples its
cascaded shadows. Live screen AO now samples the engine SSAO buffer separately. E689 and E694 opt in via `CHARACTER_ENGINE_SHADOWS`; the live fixture binds
them alongside hair. See ENGINE_CHARACTER_SHADOWS.md for face SDF composition.

## Validation

`full_character.gd --live-lights` first runs the existing fixture tests, then
`live_character.gd` checks a textured hair quad against moving opaque background
geometry. A 0.03-unit gap suppresses all rim pixels; a 0.6-unit gap exposes the
rim while the quad interior stays black, checking both occlusion and self-depth.
It repeats with orthogonal/perspective cameras, 4x MSAA, resized aspect ratio and
camera motion. An upward-normal check requires only the top edge to light;
this caught and fixed a view-to-screen Y reversal. It also checks manual fallback, Omni movement/color/energy/range/
fade/visibility/layer masks, Spot direction, directional visibility/rotation,
freed light references, and the 16-light cap. Failures return process exit 1.

RTX 3050 measured summed RGB (SDR): orthogonal 396.2471, perspective 155.0588,
4x MSAA 162.5490, resized 21.1804 for distant backgrounds; all near-background
and center-region sums are zero. The upward-normal case measures top=3777.4431
and bottom=0. Outputs: `hair-live-validation.json`,
`hair-live-rim-*.png`, `character-full-live-front.png` and three-quarter view.
These prove live depth/light behavior, not fidelity to another game frame.
Multiview, TAA/FSR2 rim behavior and transparent occluders are not validated.

Existing E674/E689/E694/E704 HDR, E694 surface, full-character, Bloom/LUT and
ordinary-material smoke regressions must continue to pass separately.

## Live screen AO

Live E669/E689/E694/E704 enable `custom_character_ao` and
`custom_forward_screen_ao(SCREEN_UV)`. The existing material inputs become
`min(face_ao, engine_ao)` or `min(screen_shadow_ao.y, engine_ao)`; the main shadow
channel and face SDF are not changed. There is no extra final-color AO multiply.
Set `engine_screen_ao_enabled=false` to use only the manual material AO.
Environment SSAO enable/radius/intensity/power control the generated buffer.
Stock SSAO direct-light/AO-channel affect controls are not re-applied: the
reconstructed material's own lighting functions determine how AO affects light.

The engine generates SSAO after depth/normal prepass and before opaque shading.
Hair's opaque depth prepass also participates, although its depth-texture read
schedules color in the transparent pass. A separate Custom Forward flag exposes
that same AO buffer to these opt-in materials without enabling stock transparent
SSAO. Only geometry represented in the prepass can safely use this interface;
ordinary blended transparent receivers/occluders are outside its scope.
Depth/shadow passes and SSAO-disabled or unavailable views return one.

`live_character_ao.gd` checks all four real captured materials with contact and
moving occluders, orthographic/perspective cameras, camera movement, resized
viewport, MSAA 4x and 0.75 internal rendering scale. Environment-disable exactly
matches material-disable after a previous AO frame, checking stale-buffer guards.
A stronger manual AO produces an exact match with/without screen AO, checking
min rather than multiplication. Diagnostic output verifies AO changes neither
actual half-opacity main-shadow visibility nor face SDF values. Raw AO sampling
matches between face/clothes opaque passes and hair's transparent color pass.

Evidence: `character-screen-ao-validation.json`, `e{669,689,694,704}-live-ao-*.png`,
`.renderdoc-analysis/live-screen-ao-test.log` (`CHARACTER_SCREEN_AO_OK`). Live
preview enables Environment SSAO after independent legacy/shadow tests complete.
These checks do not establish parity with the captured game's AO algorithm;
multiview, TAA/FSR2 and partial transparency remain unvalidated.

## E669 skin

E669 now uses the captured dry-skin material with BC5 normal mapping, LUT/ramp,
view-dependent rim tint and analytic specular. Its live variant uses the existing
16-light bridge, full-RID directional/local shadows and independent screen AO.
Local modes 1/3 gate the complete contribution once; modes 0/4 retain their behavior.
AO combines by minimum in the existing input; skin has no face SDF.
See [CAPTURE_E669_SKIN.md](CAPTURE_E669_SKIN.md) for resources, independent HDR
comparison (1866/1872 exact, all within one encoded step), live coverage and limits.
The previous material and post-process regression cases remain intact.

## E679 iris

The full character now uses the captured iris material: tangent-view UV parallax,
procedural diffuse/MatCap normals, iris tints, ramp and MatCap lighting. Independent
captured replay matches all 513 visible HDR pixels exactly. See
[CAPTURE_E679_IRIS.md](CAPTURE_E679_IRIS.md) for evidence, controls and scope.

The live variant uses the existing 16-light bridge and directional/Omni/Spot engine
shadows. Mode 1 gates the complete local contribution once; modes 0/4 retain their
behavior and captured mode 3 stays zero. Unlike the four AO-enabled materials,
this captured iris specialization ignores screen AO and has no face SDF.
Default/live fixtures verify parallax, curvature, MatCap and AO independence;
existing shadow tests now also cover iris without removing previous cases.
