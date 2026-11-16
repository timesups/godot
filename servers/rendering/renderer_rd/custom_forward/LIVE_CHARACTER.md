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
area lights and directional cascaded shadow maps are not bridged. Live E704 now
uses engine Omni/Spot shadow maps in modes 1 and 3; see
[ENGINE_CHARACTER_SHADOWS.md](ENGINE_CHARACTER_SHADOWS.md). The bridge disables
the captured explicit-atlas flag to prevent stale slot matrices after reordering.
The default/manual material retains its radial fallback; live hair replaces that
fallback with engine visibility (one when a light has no engine shadow).
Live hair also resolves the bound main directional light by RID and samples its
cascaded shadows; screen AO remains an explicit input. E689 and E694 opt in via `CHARACTER_ENGINE_SHADOWS`; the live fixture binds
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
