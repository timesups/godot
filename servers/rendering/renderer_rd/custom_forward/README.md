# Custom Forward engine

Custom Forward is an independent Forward+ scene renderer. Select it in the editor,
set `rendering/renderer/rendering_method="custom_forward"`, or pass
`--rendering-method custom_forward`. Original Forward+ and platform defaults remain.

## Engine-owned implementation

- `render_custom_forward.cpp`: frame passes, draw lists, render buffers.
- `scene_shader_custom_forward.cpp`: shader compilation and pipelines.
- `../shaders/custom_forward/`: internal shaders, including character shadow helpers.
- `custom_post_process.cpp`: opt-in captured Bloom/LUT processing and project settings.
- `ENGINE_CHARACTER_SHADOWS.md`: light RID identity and shadow interfaces.

Edit `.glsl`, not generated `.glsl.gen.h`. Build from the engine root:

```powershell
.\.venv\Scripts\scons.exe platform=windows target=editor arch=x86_64 -j8
```

Custom Forward has its own shader classes and `custom_forward` render-buffer scope.
`CURRENT_RENDERER` remains `RENDERER_FORWARD_PLUS` for compatibility; scripts should
use `RenderingServer.get_current_rendering_method()`. RenderingDevice, drivers,
culling, storage and common effects remain shared. Changes there can affect stock
Forward+. Hardware with fewer than 48 textures per shader stage retains Mobile fallback.

## Standalone project

Character materials, light binding, capture reconstruction, full-character previews,
and integration regressions now belong to the separate **Endfield** repository
(current workspace: `E:/ZcxCode/Endfield`). See its README and HANDOFF_CUSTOM_FORWARD.md.
No engine build step reads that project. Project runtime uses the built executable;
only production post-processing replay explicitly requires `engine_source`.

All prior capture/quality documentation and full tests were retained in Endfield.
The former mixed README is preserved there as `docs/ENGINE_HISTORY.md`.
Contact/PCSS helpers and original Forward+ were not changed by separation.
Full regressions must run when changing the character shader interfaces or shadows:

```powershell
& E:/ZcxCode/Endfield/.venv/Scripts/python.exe E:/ZcxCode/Endfield/tools/run.py regressions
```

The optional root `debug_full_character.bat` forwards to an explicitly configured
`ENDFIELD_PROJECT`; it contains no project implementation.

## Self-contained engine GPU smoke

`tests/rendering/custom_forward` retains only project.godot and smoke.gd (plus UID).
It needs no capture assets or external project:

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --script res://smoke.gd --rendering-method custom_forward --rendering-driver vulkan --fixed-fps 60 -- --case=baseline --output=custom.png
```

Repeat for `forward_plus`; `--case=msaa` and `--case=taa` remain available.
Require `RENDER_SMOKE_OK`, code 0, and no ERROR lines. Do not use `--headless`.
The test covers opaque/transparent geometry, shadows, screen effects, fog, material
preprocessor behavior and CompositorEffect color/depth/velocity/normal buffers.

## Post-processing boundary

The opt-in Bloom/LUT implementation and `custom_bloom.glsl`, `custom_grade.glsl`,
`custom_grade_inc.glsl` remain engine-owned. Configure
`rendering/custom_forward/post_process/enabled` and `lut_path` in the external project.
The LUT is a linear Image resource (N*N by N); use an imported resource or external EXR.
Project-side replay reads these shaders from an explicit matching engine source path,
so there is one production shader implementation. Stock post-processing is unchanged.
