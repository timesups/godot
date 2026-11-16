# Engine smoke fixture

This directory is intentionally self-contained: `project.godot`, `smoke.gd` and its UID.
Run it with Custom Forward and original Forward+ using a real GPU.

The complete character, capture replay and shadow-quality regressions were migrated
without removing coverage to the independent Endfield repository at
`E:/ZcxCode/Endfield`. Run `tools/run.py regressions` there with a matching engine.
The project configuration explicitly supplies binary, evidence and (for production
post-process replay only) engine-source paths. See its README for setup and full commands.

Keep both levels of coverage when changing the engine; the minimum smoke is not a
replacement for the project's 329-case contact/PCSS and 160-case/36-crossing suites.
