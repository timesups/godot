# Custom Forward

An independent copy of the Forward+ scene renderer, initially preserving its
rendering behavior. Select **Custom Forward** in the editor's renderer menu or
the new project dialog, set `rendering/renderer/rendering_method="custom_forward"`
in `project.godot`, or launch with `--rendering-method custom_forward`.
The default renderer remains Forward+; mobile and web defaults remain unchanged.

## Modification points

- `render_custom_forward.cpp`: frame passes, draw lists, and render buffers.
- `scene_shader_custom_forward.cpp`: material shader compilation and pipelines.
- `../shaders/custom_forward/`: independent scene and lookup-table shaders.

Edit the `.glsl` source files, not generated `.glsl.gen.h` files. Rebuild with:

```powershell
.\.venv\Scripts\python.exe -m SCons platform=windows target=editor arch=x86_64 -j12
```

The copy has its own renderer/shader classes, generated shader names, and
`custom_forward` render-buffer scope. A CompositorEffect that accesses the normal
and roughness buffer must use `get_texture("custom_forward", "normal_roughness")`
instead of the original renderer's `forward_clustered` scope.
`CURRENT_RENDERER` intentionally remains `RENDERER_FORWARD_PLUS` for compatibility
with existing material shaders; query `RenderingServer.get_current_rendering_method()`
to distinguish the renderers in scripts.

RenderingDevice, GPU drivers, culling, storage, cluster building, and common RD
effects (including GI, sky, and post-processing) are still shared. Changes to
those shared implementations can affect the original renderer; fork the relevant
effect separately before customizing it. Hardware with fewer than 48 textures
per shader stage retains the existing Mobile renderer fallback.

## GPU smoke test

From the repository root, run the same scene with each renderer. Do not use
`--headless`, which would bypass the GPU renderer.

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --script res://smoke.gd --rendering-method custom_forward --rendering-driver vulkan --fixed-fps 60 -- --case=baseline --output=custom.png
```

Repeat with `--rendering-method forward_plus` and a different output filename.
Also repeat with `--case=msaa` and `--case=taa`. A successful test prints
`RENDER_SMOKE_OK` and exits with code 0. Check logs for errors and compare the
captured images. This exercises opaque and transparent geometry, shadows, screen
space effects, volumetric fog, the Forward+ material preprocessor contract, and
CompositorEffect color/depth/velocity/normal buffers.

## Capture bloom and LUT reconstruction

An opt-in post-processing implementation reconstructed from EndField frame
37917 is available in `custom_post_process.cpp` and the independent
`custom_bloom.glsl`, `custom_grade.glsl`, and `custom_grade_inc.glsl` shaders.
It replaces the final standard post-processing call only in Custom Forward.
It does not alter Forward+ or the shared Godot glow/tonemapper implementations.

The implementation includes the captured 13-tap soft-threshold/Karis prefilter,
nine-level R11G11B10 bloom pyramid, separable nine-tap reduction with FP16 sample
cache, bicubic upsampling (scatter 0.77), highlight compression, sharpening,
vignette, LogC strip-LUT lookup, sRGB encoding, and output dithering.
The repeated (-1, 1) prefilter tap is intentional and matches the capture.

Configure these project settings under `[rendering]`:

```ini
renderer/rendering_method="custom_forward"
custom_forward/post_process/enabled=true
custom_forward/post_process/lut_path="res://capture_lut.res"
```

The LUT is a **linear Image resource**, N*N pixels wide and N pixels high
(1024x32 in the reference). Save the original floating-point LUT image using
`ResourceSaver.save(image, "res://capture_lut.res")`, and include that resource
when exporting the project. An Image .res/.tres is loaded through ResourceLoader
and works inside a PCK. Do not substitute an sRGB screenshot, a Texture2D resource,
or a linear-input LUT: this shader addresses the LUT using LogC-encoded values.
External absolute EXR paths are also supported for local capture analysis;
they are not a portable project asset. A changed LUT path reloads the texture;
restart the renderer after overwriting the same path.

The captured LUT is not embedded in engine code. The MCP analysis directory
`.renderdoc-analysis/endfield-frame37917` contains `lut.dds`; running the GPU
test below creates `lut.res`, `lut.exr`, and a PCK fixture from it.

Additional settings under `rendering/custom_forward/post_process/`:

| Setting | Default |
| --- | --- |
| exposure | 1.0 |
| bloom_intensity | 0.3660402297973633 |
| bloom_scatter | 0.77 |
| bloom_threshold | 0.5225216150283813 |
| sharpness | 0.3 |
| vignette | true |

This first implementation targets **single-view SDR at 100% render scale**.
Godot TAA and 3D MSAA can precede it. HDR output, multiview, FSR/FSR2/MetalFX,
screen-space FXAA/SMAA, and 2D MSAA fall back to standard post-processing.
Missing or invalid LUTs also fall back. The enabled path replaces standard
Environment glow, adjustments, tonemapping, camera DoF and auto-exposure;
use the custom settings for exposure. It does not reconstruct the capture's
DoF, TAA, character lighting, or G-buffer.

### Reproduction and validation

From the repository root, with the captured DDS exports present:

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://post_process.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_post.py .renderdoc-analysis/endfield-frame37917
```

The Python comparison requires numpy. It compares the production shader output
against independent captured textures, not a CPU copy of the new algorithm.
On the RTX 3050 Vulkan test, prefilter RGB matched exactly, 99.9947% of final bloom
RGB components matched exactly, and final SDR RGB had mean absolute error
0.0398 and maximum error 1 in 8-bit code values. These measurements apply to
the captured input and LUT; they are not a claim that a newly lit Godot scene
matches the original game's lighting or that all GPUs are bit-identical.

To launch the live scene with the new effect:

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --script res://smoke.gd --rendering-method custom_forward --rendering-driver vulkan --fixed-fps 60 -- --post-lut=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/lut.res
```

Use `--case=msaa` or `--case=taa` to exercise those input paths. The smoke test
checks that the custom bloom buffers were actually created. A packaged-resource
test uses `--post-pack=.../lut-test.pck --post-lut=res://capture_lut.res`.
`--case=fsr2` checks safe fallback at 100% scale.

### Captured character material validation

`CAPTURE_E674_LIGHTING.md` documents the independent `material_replay.gd`
raster test, its captured assets, commands, and current error measurements.
It uses original BC7 textures and post-VS geometry to validate reconstructed
lighting. The scene material and this replay now share
`materials/character_lighting.gdshaderinc`. The regression gate requires at
least 680/683 exact pixels, at most one encoded step per RGB component, and
linear HDR MAE at most 2.51e-6 on this fixture.

### Opt-in character scene materials

Copy `materials/character.gdshader` and `materials/character_lighting.gdshaderinc`
together into your project and assign the shader to a ShaderMaterial on a
MeshInstance3D. Set `base_map` (sRGB), `material_lut` (1024x32 sRGB strip), and
`ramp_map` (linear). These assets are supplied by the project, not embedded in
the engine. The provided test loads the local RenderDoc exports directly.

`render_mode custom_character` selects the Custom Forward character path:
the material supplies final linear HDR lighting in `EMISSION`, and `ALBEDO`
remains the base surface color. Standard clustered PBR lighting is skipped;
the result participates in scene depth, fog and post-processing, including
the custom Bloom/LUT when enabled. The separate-specular path writes character
color to diffuse and zero to specular. Other rendering methods reject this
mode explicitly. Existing materials and original Forward+ remain unchanged.

The current material reconstructs the E674 opaque dielectric specialization:
material LUT, two ramp lookups, main/environment lighting and explicit point
light modes 0/1. It accepts up to eight world-space local lights through
`local_positions`, `local_colors`, `local_parameters` and `local_light_count`.
See the shader comments for the array layout. Main/environment light values
are material parameters. Godot Light3D nodes, shadow maps, captured tiled light
lists, additional character materials, skinning and the original stencil
visibility scheme are not yet integrated. E674's inactive mode 3 is not a
general implementation of that light type. Use nonsingular model transforms.

For capture-like texture sampling, set
`rendering/textures/default_filters/use_nearest_mipmap_filter=true` and choose
8x viewport anisotropy. This is a project-wide sampler setting, not forced by
the material. The raw GPU replay already uses the exact captured samplers.

Run the real scene integration test (requires the compiled custom engine):

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://character_scene.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials
```

Append `--keep-open` to inspect it. This creates an ArrayMesh from the original
398 post-VS vertices and 452 triangles, retaining this frame's pose, UVs and
normals. It is the E674 face-detail submesh, not the complete character. The
scene uses actual rasterization/depth without the replay's captured pixel mask;
it verifies main-light shutdown, distinct local modes 0/1, and identical output
when a CompositorEffect requests a separate-specular render target. Its enlarged
camera view is an integration check, not a pixel-identical capture comparison.
The image is saved as `character-scene.png` in the evidence directory.

Keep running `material_replay.gd` / `compare_material_replay.py`, the existing
`post_process.gd` / `compare_post.py`, and `smoke.gd` separately: the scene test
does not replace their accuracy and ordinary-material regression checks.

### Complete posed character fixture

Run `debug_full_character.bat` from the repository root to validate the local
exports and open the assembled character. Pass `--albedo-only` to show base
color for every part; `--smoke` as the first argument exits after validation.
The default uses the E674, E689, E694 and E704 materials on their
original face-detail, face, clothes and hair draws; all other draws deliberately use a base-color
diagnostic shader through `custom_character`. This is a geometry/material
inspection fixture, not a claim of complete lighting reconstruction.

The fixture contains eight paired character draws, 52,489 post-VS vertices and
61,618 triangles. Original posed world positions, UVs, normals and indices are
preserved, with a common origin subtraction for scene coordinates. It handles
128/144-byte vertex layouts and 16/32-bit indices independently. There is no
recovered skeleton or animation. Textures retain the captured BC7 blocks;
unverified materials currently sample base mip only. E674 keeps its original
model orientation and the full base mip chain.

| Forward / G-buffer event | Part | Base texture | Current material scope |
| --- | --- | --- | --- |
| 669 / 468 | Skin | 185721 | Base color; normal map 185726 retained |
| 674 / 457 | Face details | 185716 | Validated E674 lighting |
| 679 / 462 | Iris | 186177 | Base color; distinct iris shader |
| 684 / 473 | Accessories | 187399 | Base color; normal map 187429 retained |
| 689 / 478 | Face | 185716 | E689 SDF face lighting; measured capture differences remain |
| 694 / 483 | Clothes | 187399 | Measured dry lighting, normal map, specular and environment reflection |
| 699 / 488 | Ears | 185700 | Base color; distinct ear shader |
| 704 / 493 | Hair | 185700 | Measured opaque dual-normal, dual-lobe anisotropic lighting and strand noise |

The RenderDoc MCP export metadata, fragment SPIR-V, texture bindings and SHA256
of every fixture file are retained in the local evidence directory. Run:

```powershell
.\.venv\Scripts\python.exe tests/rendering/custom_forward/prepare_character.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://full_character.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials
```

Preparation checks output signatures, index ranges, finite vertex data,
normalized normals, draw counts and texture bindings. The GPU test renders
each part separately to verify coverage and nonconstant textured color, then saves front and three-quarter
images plus `character-full-validation.json`. This avoids hidden submeshes
silently disappearing in a combined-only smoke test. Assets remain outside
version control; the committed scripts require the local RenderDoc exports.
The existing E674 and Bloom/LUT regression scripts are unchanged.
These automatic checks detect missing parts and missing texture variation;
correct semantic texture assignment still relies on the retained bindings and
visual inspection, not on palette size alone. On RTX 3050 the eight-part scene,
E674 scene/replay (680/683 exact), and Bloom/LUT comparisons all passed after
assembly. The reviewed front and three-quarter outputs show the assembled
character; additional material lighting is still pending per the table above.

### E689 face material

`materials/face.gdshader` adds the face-specific path while keeping E674's
shader and regression unchanged. Copy it with both `face_lighting.gdshaderinc`
and `character_lighting.gdshaderinc`, plus `face_shadow.gdshaderinc`, into a project. Required textures:

| Uniform | Captured resource | Color space / purpose |
| --- | --- | --- |
| base_map | 185716 | sRGB base color; alpha is lighting weight, not opacity |
| material_lut | 172496 | sRGB material LUT |
| face_mask | 37722 | Linear BC7 mask, full mip chain |
| face_sdf | 4874 | Linear RGBA face SDF, explicit LOD 0 |
| face_specular | 37745 | Linear BC7 painted highlight, full mip chain |
| face_ramp | 53468 | Linear RGBA ramp; distinct from E674 ramp 186593 |

The reconstruction includes mirrored SDF sampling according to object-space
main-light direction, mask-controlled normal blending, view-dependent face rim
tint, material LUT, face ramp, view-offset painted highlight and local modes 0/1/3. E689's
mode 3 is active, unlike E674's captured specialization. The model basis must
retain the captured head orientation; the fixture uses its exported transform.

This is the captured dry dielectric specialization: makeup weight is zero,
analytic specular is zero, and wetness/snow/probe effects are not implemented.
Main-light tint also modulates the environment with E689's captured tint.
The environment color is CharacterParams3 (1.2604043, 0.73959565, 0.73959565),
not E674's CharacterParams2. This distinction matters in AO-darkened areas.
Scene `face_ao` is an explicit input, default 1; the replay instead reads the
captured screen AO texture. Local point/spot parameters and shadow factors are
explicit arrays documented in the shader. No automatic Light3D/shadow mapping
has been added. An optional reversed-depth shadow atlas is now supported:
enable `shadow_atlas_enabled`, bind a linear single-channel depth texture,
set the relevant `local_shadow_enabled` entries, and provide per-light
`local_shadow_matrices`, `local_shadow_rects` and
`local_shadow_bias`. Matrices map the scene's world coordinates to 0..1 shadow
coordinates; rects contain atlas min/max UVs. The filter uses the captured 5x5
tent weights, nine bilinear depth comparisons, and radial/normal bias. Modes
1 and 3 accept atlas shadows; mode 0 stays unshadowed as in the capture.
Per-light enable is independent of strength: strength zero means full visibility,
whereas a missing/disabled shadow slot selects mode 1's radial fallback.
The fixture's recentered world coordinates require correspondingly adjusted
matrices; raw capture matrices should only be used with raw capture positions.

The dedicated GPU replay shares production face-lighting functions and compares
all 5,390 changed E689 pixels against independent fresh E684/E689 HDR exports.
Its mask/depth filtering is test-only and does not recreate original visibility.
On RTX 3050, 5,266 pixels match exactly (97.70%), linear HDR MAE is 0.00008890,
maximum absolute error is 0.015625, and all encoded channel errors are at most 1 step.
These are measured bounds, not pixel parity. The comparison enforces these
bounds (at least 5,260 exact pixels and MAE <= 0.00009) to catch regressions.
It now uses the captured 6144x4096 D16 atlas and shadow slots 40/41 rather than
assuming full visibility. Shader Debug at (1298,1105) measured light 5's shadow
factor as 0.8237022. A second debug point (1336,1141) isolated the environment
color mismatch: base/mask/SDF/surface values agreed while irradiance differed.
Manual bilinear comparisons and shader arithmetic may still differ from the
original hardware comparison sampler; bitwise parity is not claimed.

```powershell
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_face_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://face_replay.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_face_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials
```

`full_character.gd` also checks that E689 responds to left/right SDF lighting,
AO, and local modes 0/1/3, and turns black when its own lighting is disabled.
It also checks the optional atlas using all-blocked and all-visible depth maps.
This integration test complements, rather than replaces, the capture replay.
For diagnosis, pass `--diagnostics` to `face_replay.gd`: it writes separate
`e689-diagnostic-*` buffers whose base/uv-dx/dy-primitive outputs contain face
mask/SDF/surface color respectively. Normal regression outputs remain intact.

### E694 clothes surface inspection

See [CAPTURE_E694_SURFACE.md](CAPTURE_E694_SURFACE.md) for confirmed texture
channels, independent G-buffer/Shader Debug evidence, and replay commands.
`debug_full_character.bat --clothes-surface` enables an independent clothes
surface material with base, normal, parameter, F0 and diffuse inspection views.
This inspection flag replaces the default clothes lighting with surface views.
The surface replay matches base and normal at 215599/215604 pixels each; five
known differences remain explicitly gated in that original surface test.

### E694 clothes lighting

`materials/clothes.gdshader` now supplies the default clothes material. Its shared
`clothes_lighting.gdshaderinc` implements the captured dry specialization:
main/view ramp, shadow/AO modulation, analytic specular and lookup, BC6 cubemap
reflection with nearest-mip selection, emission, and local modes 0/1/3/4.
Light parameters and optional shadow atlas are explicit inputs, as for E689;
automatic Godot Light3D binding is not implemented.

The new `clothes_replay.gd` and `compare_clothes_replay.py` retain the original
surface test and compare final HDR against fresh E689/E694 exports. Reversed
depth testing between clothes triangles fixes the five surface-test visibility
differences. On RTX 3050, 215051/215604 pixels match exactly (99.7435%), MAE is
2.05976e-6, maximum error is 0.0205078125. Twelve pixels exceed one encoded
channel step, with a maximum of 19 steps; these remain in the comparison.
Shadow-edge precision differences remain, so this is measured reconstruction,
not bitwise parity. See CAPTURE_E694_SURFACE.md for evidence and commands.

### E704 hair lighting

`materials/hair.gdshader` is now the default E704 material in the full-character
fixture. It shares dual-normal, dual-lobe anisotropic lighting and stripe noise
with the independent HDR replay. See [CAPTURE_E704_HAIR.md](CAPTURE_E704_HAIR.md)
for texture channels, source Shader Debug evidence, commands and limits.

The captured visible subset matches at 20634/20660 pixels exactly (99.8742%),
MAE 1.87497e-6; all channel errors are <=1 HDR encoded step. The test pins
reference hashes and enforces these measured bounds, plus independent surface,
specular and secondary-normal checks. Existing material and post tests remain.

The default material still accepts explicit inputs. The optional
`debug_full_character.bat --live-lights` now uses live depth rim visibility and
Directional/Omni/SpotLight3D bindings for E704. Hair stays opaque via a depth
prepass; its color pass is scheduled after opaque geometry because it reads
screen depth. See [LIVE_CHARACTER.md](LIVE_CHARACTER.md) for setup, tested
configurations and limits (including shadows and transparent occluders).

### Engine local shadows for live E704

The live hair variant now resolves Omni/Spot shadow maps by complete light RID,
including projection/bias/filter/opacity from engine light data. It preserves
mode 0's unshadowed behavior and validates moving shadows-only casters, disabled
shadows, zero opacity, coincident lights and list reordering. Rebuild the engine
before using this version of `--live-lights`. See
[ENGINE_CHARACTER_SHADOWS.md](ENGINE_CHARACTER_SHADOWS.md) for the interface and
scope. Live E704 also consumes directional cascades by full main-light RID, with
split blending, distance fade, bias and opacity. GPU tests cover 1/2/4 cascades,
camera movement and coincident directional lights. E689/E694 now opt in with `CHARACTER_ENGINE_SHADOWS`, and the live fixture binds
all three materials. Face external visibility affects direct irradiance once,
preserving SDF ramp shading and environment. Local shadows gate the completed
face/clothes contribution so SDF highlights cannot bypass occlusion. See
`ENGINE_CHARACTER_SHADOWS.md` for the tested composition and remaining limits.

### Live screen AO for E669/E689/E694/E704

The live variants sample the existing SSAO buffer through
`custom_forward_screen_ao(SCREEN_UV)` with `custom_character_ao`. Engine AO and
manual AO combine by minimum in each material's existing AO input; directional
visibility and face SDF remain independent. `engine_screen_ao_enabled=false`
restores manual AO. Live preview enables environment SSAO. Depth-writing hair
reads the buffer in its later color pass through an independent character flag;
stock transparent lighting and original Forward+ are unchanged.

See `LIVE_CHARACTER.md` for GPU coverage and limits, and
`tests/rendering/custom_forward/live_character_ao.gd` for regression checks.

## E669 skin

E669 now uses the captured dry-skin material with BC5 normal mapping, LUT/ramp,
view-dependent rim tint and analytic specular. Its live variant uses the existing
16-light bridge, full-RID directional/local shadows and independent screen AO.
Local modes 1/3 gate the complete contribution once; modes 0/4 retain their behavior.
AO combines by minimum in the existing input; skin has no face SDF.
See [CAPTURE_E669_SKIN.md](CAPTURE_E669_SKIN.md) for resources, independent HDR
comparison (1866/1872 exact, all within one encoded step), live coverage and limits.
The previous material and post-process regression cases remain intact.
