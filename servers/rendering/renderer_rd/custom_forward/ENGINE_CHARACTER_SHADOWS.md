# Live character engine shadows

The optional `--live-lights` E689/E694/E704 paths consume the engine's actual Omni/Spot
shadow atlas and directional cascades. Captured-constant materials/replays are
unchanged. Face and clothes opt in with `CHARACTER_ENGINE_SHADOWS`; hair uses
`HAIR_REALTIME_DEPTH`.

## Interface and identity

`Light3D.get_light_rid()` exposes the underlying RenderingServer light RID.
`VisualInstance3D.get_base()` is empty for Light3D in this source revision because
its constructor assigns the server instance directly. The new getter is read-only
and distinct from `get_instance()`; no instance ownership changes.

The CPU light bridge uploads low/high 32-bit words in uint arrays, and the native
light-buffer upload writes the same two words into the previously unused 8-byte
padding of LightData. `memcpy`/`floatBitsToUint` preserve the bits without numerical
float conversion. Buffer size, stride and all existing fields are unchanged;
ordinary renderers ignore the padding. This distinguishes coincident lights and
survives cluster sorting, list reordering and resource generations.

The shader mode `custom_character_shadows` enables the Custom Forward-only
function:

```glsl
float custom_forward_local_shadow(uvec2 light_id, bool is_spot,
                                  vec3 view_position, vec3 view_normal);
```

Use it in the fragment stage, with view-space inputs. The helper scans only the
current clustered light range and verifies both RID words plus the mesh layer
mask. Missing/out-of-cluster lights return visibility one; material attenuation
and cone tests still determine their contribution. A depth/shadow-pass stub
returns one, preventing feedback while rendering the atlas itself.

`character_shadow_inc.glsl` copies the existing engine's local shadow evaluation:
spot projection, point dual paraboloids, normal/depth bias, atlas rectangles,
PCF/soft shadow filtering and shadow opacity. The shared Forward+ lighting code
is not edited. Updates to that upstream evaluation should also be checked against
this copied helper. Current GPU tests exercise the hard-shadow/PCF path; soft
penumbra quality and multiview are not validated.

Live hair applies engine visibility in modes 1 and 3. Mode 0 remains unshadowed
and mode 4 retains its captured replacement behavior. Geometry normals supply
shadow bias. `engine_local_shadows_enabled=false` restores the manual atlas/
radial fallback path. Screen AO is a separate live input; see LIVE_CHARACTER.md.
Live face/clothes also use these functions (see below). This implementation scans
a cluster per explicit local light; larger light populations need profiling.

## Build and validation

An updated engine binary is required:

```powershell
.\.venv\Scripts\scons.exe platform=windows target=editor arch=x86_64 -j8
.\debug_full_character.bat --smoke --live-lights
```

The live test uses a hair-material quad and a **shadows-only** BoxMesh that cannot
occlude the camera or change its scene-depth image. Tests cover Omni and Spot
lights, blocked/unblocked mode 1 and mode 3, moving the caster, zero opacity,
shadow disable, unshadowed mode 0, coincident lights and reordered light lists.
The test also rejects an invalid light RID. All failures propagate exit 1.

RTX 3050 mode-1 summed RGB: Omni visible 53467.7854, blocked 0; Spot visible
52727.2010, blocked 0. Removing the caster restores illumination. Opacity zero
and disabled shadows match unshadowed output (Omni differs from shadow-enabled
visible output by <0.2% due to minor self-shadowing). Coincident light identity
and list reordering retain the correct visibility.

Evidence is in `hair-live-validation.json`, `hair-shadow-omni-visible.png`,
`hair-shadow-omni-blocked.png` and corresponding spot images under the local
capture evidence directory. These tests validate engine integration rather than
claiming pixel parity with the game's shadow filtering.

Existing E674/E689/E694/E704 capture comparisons, Bloom/LUT, default character,
Custom Forward and original Forward+ smoke tests remain independent gates.

## Directional cascades

`custom_forward_directional_shadow(uvec2 light_id, vec3 view_position,
vec3 view_normal)` resolves the explicitly bound main light using both RID
words and the mesh layer mask. DirectionalLightData has two uint padding words
(GLSL uvec2), unlike the float padding in local LightData. The upload fills
these directly without changing buffer layout or original Forward+ evaluation.
Only active directional entries are searched; missing IDs return one.
Depth/shadow passes also return one to avoid atlas feedback.

The helper mirrors the scene shader's dynamic directional shadow evaluation:
1/2/4 cascades, split blending, PCF/soft filtering, geometric-normal/depth bias,
distance fade and opacity. Baked shadow masks are outside this bridge.
Live hair multiplies the existing main shadow input by engine visibility before
diffuse, main specular and local-light main-shadow modulation. AO is unchanged.
`engine_directional_shadows_enabled=false` restores the explicit input.

GPU validation covers real hair with a moving shadows-only caster, disabled
shadows, zero opacity, explicit fallback, two coincident directional lights,
visibility reordering, and a diagnostic material sampling the same helper.
The diagnostic sweeps 1/2/4 cascades with blending off/on across configured
4/8/12-unit boundaries, plus depths 18/19 inside the fade and 21 beyond it.
It uses a perspective camera: the engine intentionally ignores directional
max distance for orthographic cameras and uses camera.far instead.
The receiving quad does not cast during this test, isolating the external
caster from precision-dependent self-shadowing. A large caster covers the
filter footprint in every cascade. This checks visibility and continuity under
full coverage, not pixel parity of partial shadow edges or soft penumbrae.

RTX 3050 hair RGB sums: visible/moved/zero-opacity/disabled/fallback/second sun
25601.0714, blocked/reordered 0. Evidence: `hair-live-validation.json`,
`hair-shadow-directional-{visible,blocked}.png` and
`.renderdoc-analysis/live-directional-shadow-test.log`.

## E689 face and E694 clothes

The live fixture binds all three reconstructed materials to the same main/local
scene lights, using separate ShaderMaterials and bridge nodes. Set `face_layout`
on the bridge for E689: eight lights, modes 0/1/3 only. E694/E704 keep sixteen
lights and modes 0/1/3/4. Unsupported modes are skipped before counting slots.
The default captured materials and their manual atlas paths are unchanged.

Face SDF remains the existing directional ramp/color-shaping input. Engine
main-light visibility scales only `main_color * main_energy`, once, before the
existing lighting function. It is not multiplied into the SDF, ramp, AO or final
color a second time. Thus external shadows suppress direct diffuse and its
specular stamp while retaining environment illumination. This deliberately
keeps SDF art direction and geometric visibility separate; it does not claim a
reconstruction of the game's real-time SDF/shadow composition.

Clothes main visibility feeds the existing `screen_shadow_ao.x` path, as with
hair, preserving AO and leaving emission outside the shadow evaluation.
For face/clothes local modes 1/3, engine visibility gates the complete local
contribution once. It replaces the manual/radial shadow fallback; it is not also
passed as the stylized response mask. This prevents the face SDF `max()` highlight
and both materials' artistic shadow-side floors from leaking light through a
fully blocked engine shadow. Mode 0 remains unshadowed; clothes mode 4 remains
the original replacement effect. The older hair behavior is unchanged.
Both `engine_directional_shadows_enabled` and `engine_local_shadows_enabled`
can disable the engine path independently.

`live_material_shadows.gd` uses the captured material textures on a receiving
quad and shadows-only boxes. GPU checks include:
- Unoccluded live shading exactly matches the default shader.
- Main/local blocked and released shadows, moving caster, zero opacity and
  disabled shadows; coincident local lights with distinct RIDs.
- Face left/right SDF: opacity 0.5 exactly matches unshadowed main energy 0.5,
  detecting accidental squared attenuation. A fully shadowed face with
  environment enabled exactly matches zero direct light with environment.
- Face mode 1 forced SDF highlight plus nonzero artistic floor still becomes
  dark under full engine occlusion; clothes mode 1 floor is also blocked.
- Mode 0 unchanged, clothes mode 4 unchanged, clothes emission preserved,
  face mode 4 rejected, 8/16-light caps and freed-light cleanup.

RTX 3050 main RGB sums: E689 visible 30245.5303 / blocked 0; E694 visible
20581.1928 / blocked 0. Local modes 1/3 also reach zero under full coverage.
Evidence: `face-clothes-engine-shadow-validation.json`,
`e{689,694}-engine-directional-blocked.png`, and
`.renderdoc-analysis/live-face-clothes-shadow-test.log`.

## E669 skin extension

The skin live variant reuses `CHARACTER_ENGINE_SHADOWS` and the 16-light binding.
Main visibility enters its existing screen-shadow channel; screen AO independently
uses minimum with manual AO. Local modes 1/3 gate the complete contribution once,
while 0/4 retain their original behavior. `live_material_shadows.gd` now covers
E669 as well as face/clothes, preserving all older cases and output markers.
Main visible/blocked sums are 34876.3107/0; Omni/Spot 1/3 fully blocked sums are 0.
See `CAPTURE_E669_SKIN.md` and `.renderdoc-analysis/live-skin-test.log` for evidence.

## E684 accessory extension

`accessory.gdshader` uses the existing 16-light bridge and `CHARACTER_ENGINE_SHADOWS`
variant. Main visibility enters screen-shadow x once; local modes 1/3 gate their
complete contribution once. Modes 0/4 preserve the original behavior. Reflection
remains environment lighting, and the active captured specialization has no emission.
AO stays separate in screen-shadow y and combines by minimum with manual AO.
`live_material_shadows.gd` and `live_character_ao.gd` include the accessory material;
see `CAPTURE_E684_ACCESSORIES.md` and the handoff for measured results.

## E699 ears

The full character now uses `ear.gdshader`, restoring all eight captured draws.
E699 uses geometric normals, its own alternate color and analytic lookup,
with reflection and the existing 16-light bridge, directional/Omni/Spot
shadows and independently combined screen AO. It has no hair anisotropic
lobes or face SDF. Existing shaders and regression cases are preserved.

Independent captured HDR validation is exact for all 2522 visible pixels;
see [capture evidence and commands](CAPTURE_E699_EARS.md). This statement is
limited to the captured visible subset and active dry material branch.

## Directional cascade edge and PCSS regression

Character shadows now skip unused cascade matrices when only one or two
cascades exist. This fixes fully occluded areas becoming lit with two-split
PCSS blending, and invalid PCF blending near the last split. Original Forward+
is unchanged, including its reproducible version of this defect.

The new independent partial-coverage fixture validates 160 cases per renderer,
36 camera crossings, penumbra growth, filter noise, distance fade and opacity.
See [quality evidence and reproduction](DIRECTIONAL_SHADOW_QUALITY.md).
