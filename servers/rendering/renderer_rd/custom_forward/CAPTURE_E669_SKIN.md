# E669 skin reconstruction

The captured dry-skin specialization is implemented in `materials/skin.gdshader`
and `skin_lighting.gdshaderinc`. Shared BRDF utilities come from the existing
character/clothes includes; their behavior and older regression gates are unchanged.

## Capture inputs and scope

Source: `D:/Download/EndField-frame37917.rdc`, E669, shader module 28835,
12,762 uint16 indices, 2,814 post-VS vertices, stride 144. The existing posed mesh
and UVs are reused; this does not reconstruct skeletal animation.

- Material buffer 630, offset 2127680, size 368 (`e669-cb5.bin`).
- Base texture 185721: BC7 sRGB, 1024 square, 11 mip levels.
- Tangent normal 185726: BC5, 1024 square, 11 mip levels. Its legacy DDS header
  is 128 bytes, unlike the BC7 DX10 header of 148 bytes.
- Material LUT 172496 and ramp 186593 reuse the original compressed/data assets.
- Metallic 0, dielectric F0 scale .454, smoothness .258, normal strength 1.
- View-dependent base rim tint (.381326109,.124771841,.138431624), strength .85.
- Environment color (1.260404348,.739595652,.739595652), strength .287722468;
  exposure 1.05, shadow strength .55, ambient exposure .9.

The active path combines BC5 tangent normals, base alpha AO, LUT alternate color,
ramp shading, view-dependent rim tint, analytic dielectric specular, and flattened
normal environment lighting tinted by the main light. Local modes 0/1/3/4 are
supported; mode 0 uses the skin-specific half-bias. No active reflection cube,
emission, specular lookup, wet/snow or probe path was found in this captured
instance. Those optional variants and a general subsurface-scattering model are
not claimed as reconstructed.

## Independent GPU evidence

`skin_replay.gd/.vert/.frag` replays the original post-VS draw using the shared
lighting include and captured screen/shadow/light buffers. Test-only depth/mask
rejection isolates visible pixels; it is not the game's full visibility pipeline.
`compare_skin_replay.py --prepare` creates the mask from independent HDR exports.
The before event is E658 (the last preceding draw), and after is E669.

Pinned SHA256 values:

- `skin-reference-e658.dds`: `691b0a446dc5cd4a03d05e8ebe8e7d2b53e82bc7abb94b93a79bf78f7e97ab54`
- `skin-reference-after.dds`: `9fe28e8faa1387381b6f19d9a92edb10a7b6a8efbc702608393e1e509185735f`

RTX 3050 / Vulkan: 1,866 of 1,872 visible pixels exactly match R11G11B10 HDR;
all remaining channels differ by at most one encoded step. MAE 1.0085581375e-5,
maximum .015625, missing pixels 0. The comparison enforces these measured bounds.
Independent RenderDoc Shader Debug at (1072,665), visible primitive 1792, gives
RGB (.340437114,.182507753,.145996660) and normal
(.987012684,-.097022757,.128033519). Regression checks use absolute tolerances
5e-6 and 1e-6 respectively. This is measured agreement, not pixel identity.

Evidence lives in ignored `.renderdoc-analysis/endfield-frame37917/gbuffer-materials`:
`e669-gpu-validation.json`, `e669-debug-validation.json`, and `e669-hdr-*.bin`.
Exploratory exports named `skin-reference-before.dds` / `skin-reference-e664.dds`
used invalid event IDs and are NOT references; only the hash-pinned pair above is valid.

## Real-time integration and validation

`full_character.gd` uses the skin material by default and binds its live variant
through the existing 16-light bridge. `CHARACTER_ENGINE_SHADOWS` enables full-RID
Directional/Omni/Spot shadow lookup and screen AO. Main visibility feeds the existing
shadow channel once; AO uses `min(screen_shadow_ao.y, engine_ao)` independently.
Skin has no face SDF. There is no final-color AO multiply. Local visibility gates
the complete contribution once for modes 1/3; mode 0 and mode 4 retain their
original unshadowed/replacement behavior. Existing engine-toggle fallbacks remain.

Live tests extend the existing shadow and AO suites without removing old cases:
main RGB sum 34876.3107 visible / 0 fully blocked; Omni/Spot modes 1/3 also zero
when blocked. Unoccluded output exactly matches explicit material inputs.
AO is tested with orthographic/perspective cameras, MSAA4, resized viewport and
0.75 rendering scale. Moving the occluder restores the AO-disabled output;
manual-min and independent main-shadow/SDF diagnostics pass across all four materials.
The skin normal/rim/specular/AO parameter checks pass in both default and live fixtures.

Run `debug_full_character.bat --smoke --live-lights` for live coverage. Run
`skin_replay.gd` and `compare_skin_replay.py` using the same evidence directory as
the other material replays. Logs: `.renderdoc-analysis/skin-replay-regression.log`
and `live-skin-test.log`. Existing material, surface, post-process, default-character,
Custom Forward and original Forward+ smoke regressions were rerun successfully.
SSAO algorithm parity, animated skin, multiview, TAA/FSR2 and partial transparency
remain outside the validated scope.
