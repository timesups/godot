# E699 ears: captured dry material

This specialization restores the visible E699 draw from
`D:/Download/EndField-frame37917.rdc` in Custom Forward. It does not modify
Forward+ or replace the existing hair/clothes regressions.

## Capture evidence

- Pixel shader 109859, vertex shader 109858; 520 posed vertices, stride 128,
  2862 uint32 indices (954 triangles). Existing post-VS buffers are reused.
- Material Buffer 630, offset 504768, size 336 (`e699-cb5.bin`). Global/light/
  shadow buffers have the same bindings and ranges as E684; replay reuses
  `e684-cb{0,1,2}.bin` and the existing clustered light bins.
- Base 185700: BC7 sRGB, 1024 square, 11 mips. Parameters 187392: BC7 linear,
  1024 square, 11 mips. Both reuse E704 exports without recompression.
- Ramp 188148: RGBA8, 256x1. Analytic specular lookup 184121: RGBA8,
  256x256. Reflection cube 8600 reuses E694's BC6H faces and eight mips.
- No normal texture or hair anisotropic lobes. Use normalized, face-oriented
  geometric normals. Alternate color uses value 0.55, saturation 1.1; base
  tint is white. No emission, alpha modulation, wetness or snow in this frame.
- Main and local analytic specular use the lookup-modulated F0; environment
  reflection uses unmodulated F0 (material lookup-selection factor is zero).
- The radial fallback origin is (-299.97705078125, *, -299.95166015625) in
  captured coordinates, or (0.02294921875, *, 0.04833984375) after fixture
  translation. The vertical epsilon is exactly 0.00006103515625 (2^-14).
  RenderDoc's four-decimal disassembly displays it as 0.0001: do not copy
  that rounded display or the clothes origin into the ear specialization.

## Independent validation

Before: `fresh-e694-133342.dds`, SHA256
`4c8e462f5d97de2e4d5832a3d4b155533ba50557247b656a98fcb84738e98c41`.
After: fresh `ear-reference-after.dds`, SHA256
`f49ec9e3e591b6cd81a69b41c9f37354963e743fcd657a5508bc6e8b5b9f1c12`.
The after export also matches the existing independent E699 export.

2522/2522 visible pixels match R11G11B10 HDR encoding exactly; MAE/max=0,
no missing pixels. The mask and captured depth isolate this draw's visible
subset; this is not a reconstruction of the full game's visibility system.

Independent Shader Debug at (1250,1274), visible primitive 783:

| Quantity | Reference RGB |
| --- | --- |
| Final | 0.534781039, 0.198114514, 0.064189650 |
| Surface | 0.199147180, 0.077620916, 0.027134852 |
| Main analytic specular | 0, 0, 0 |
| Reflection | 0.002064273, 0.002397433, 0.003306627 |

These values have assertions independent of the encoded-image comparison.
Evidence remains ignored under `.renderdoc-analysis/endfield-frame37917/gbuffer-materials`:
`e699-gpu-validation.json`, `e699-debug-validation.json`, and the DDS/binary
inputs. Captured assets are not committed.

## Live integration and reproduction

The full character fixture loads `ear.gdshader`; `ear_lighting.gdshaderinc`
is shared with the independent replay. Existing BRDF/local helpers remain
unchanged. Live ears use the 16-light bridge, directional cascades and
Omni/Spot shadows. Local modes 1/3 apply engine visibility once to their
complete contribution; 0/4 retain their existing behavior. Screen AO uses
min(manual, engine), independently from main shadow. E699 has no face SDF.

```powershell
$evidence = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_ear_replay.py $evidence --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://ear_replay.gd --quit-after 600 -- --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_ear_replay.py $evidence
.\debug_full_character.bat --smoke
.\debug_full_character.bat --smoke --live-lights
```

Existing live shadow/AO tests extend to E699 without removing old cases.
Final run results and limitations are recorded in `HANDOFF_CUSTOM_FORWARD.md`.
