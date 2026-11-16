# Custom Forward .NET editor and export templates (Windows x64)

Prerequisites: .NET 8 SDK, Python with SCons, and the existing MSVC x64/Windows SDK toolchain.
The repository's `modules/mono/global.json` controls SDK selection.

From the engine checkout:

```powershell
.\.venv\Scripts\python.exe misc/build_custom_dotnet.py --jobs 12
```

The entry point runs SCons with `module_mono_enabled=yes`, generates bindings
from that binary, then builds Debug/Release GodotSharp and editor tools using
the upstream assembly builder. Local NuGet packages are published to `bin/nupkgs`.
It does not register a global NuGet source. Upstream local publication refreshes
matching package versions in the user's NuGet cache.

Distribute `bin/godot.windows.editor.x86_64.mono.exe`, its console launcher,
`bin/GodotSharp`, and `bin/nupkgs` together. Keep existing native runtime DLLs
beside the executable. The non-.NET binary retains its original filename.
Generated bindings, assemblies and packages remain build outputs, not source commits.

Endfield configures its own local package source from the executable directory.
Run its `tools/run.py csharp` followed by `tools/run.py regressions` with the new
executable. Full regressions retain all existing shader/shadow gates.
The engine's standalone `tests/rendering/custom_forward/smoke.gd` must also pass
on both `custom_forward` and `forward_plus` using Vulkan.

The default target builds the editor only. Build matching export templates with:

```powershell
.\.venv\Scripts\python.exe misc/build_custom_dotnet.py --target templates --jobs 12
```

This produces `bin/godot.windows.template_debug.x86_64.mono.exe` and
`bin/godot.windows.template_release.x86_64.mono.exe`, plus console wrappers.
Use `--target all` to build editor/packages and templates together after engine changes.
Keep all outputs on matching engine/API source revisions; documentation-only or
build-workflow commits do not change the API. Rebuilding templates alone does not
refresh the editor API bindings or packages.

Endfield's `tools/export_csharp.py` reads its configured editor directory and uses
these templates explicitly. It exports the existing C# validation scene, relocates
the outputs, and checks Debug/Release on both real GPU pipelines with the bundled
.NET runtime. It does not install or overwrite global Godot export templates.
The exported executable must be distributed with its PCK and data directory.
This workflow targets Windows x64 only; it establishes no mobile/Web support.
