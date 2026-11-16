"""Build the Windows x64 .NET editor and its matching local C# packages."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 1, 12))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    root = Path(__file__).resolve().parents[1]
    packages = root / "bin" / "nupkgs"
    packages.mkdir(parents=True, exist_ok=True)
    commands = [
        [sys.executable, "-m", "SCons", "platform=windows", "target=editor", "arch=x86_64",
         "module_mono_enabled=yes", f"-j{args.jobs}"],
        [str(root / "bin/godot.windows.editor.x86_64.mono.console.exe"),
         "--headless", "--generate-mono-glue", str(root / "modules/mono/glue")],
        [sys.executable, "modules/mono/build_scripts/build_assemblies.py",
         "--godot-output-dir", str(root / "bin"), "--push-nupkgs-local", str(packages)],
    ]
    for command in commands:
        print(subprocess.list2cmdline(command), flush=True)
        subprocess.run(command, cwd=root, check=True)
    print(f"CUSTOM_DOTNET_BUILD_OK packages={packages}", flush=True)


if __name__ == "__main__":
    main()
