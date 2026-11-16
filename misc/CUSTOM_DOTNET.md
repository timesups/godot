# Custom Forward .NET editor (Windows x64)

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

This builds the editor only. Export requires matching .NET export templates;
no export or mobile/Web support is established by the editor smoke tests.
