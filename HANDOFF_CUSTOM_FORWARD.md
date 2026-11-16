# 交接：Custom Forward 引擎

更新：2026-11-16。引擎仓库 `E:/ZcxCode/godot`；角色项目已分离到独立仓库
`E:/ZcxCode/Endfield`。项目工作请先读其 `HANDOFF_CUSTOM_FORWARD.md`、AGENTS.md 和 README.md。

## 当前状态

- 项目从引擎 `54b0358b8e` 迁出，材质、角色、抓帧导出/回放、完整集成回归和
  捕获文档由 Endfield 管理。引擎不再保存这些项目文件的第二份。
- 引擎 C++、内部 GLSL、shader 内建接口及构建规则没有修改。
  近接触修复 `e53eb25730` 和斜面 PCSS 修复 `7b8ce796b2` 保持不变；原始 Forward+ 不变。
- `tests/rendering/custom_forward` 保留独立最小 smoke 项目，构建引擎不依赖 Endfield。
  原完整测试全部迁入 Endfield，测试逻辑、阈值和历史基线保留。
- 证据仍在本仓库忽略目录 `.renderdoc-analysis`，未移动。不要清理其中素材和历史基线。
- 项目本机配置在 Endfield 的忽略文件 `config.local.json`，指定引擎可执行文件、证据根目录；
  只有生产后处理 GLSL 回放额外需要显式引擎源码路径。

## 验证与提交

迁移验证：`.renderdoc-analysis/project-separation/full/run.json`，全部通过。
包括九项材质、后处理、E641过滤、默认/live、AO/阴影独立性、双管线 smoke、
双管线新采集329组与160组/36跨界，以及历史193/249比较。
`project-separation/relocated-run/run.json` 验证不同层级/含空格目录及任意工作目录运行。
`project-separation/migration-audit.json` 记录77个材质/回放/比较文件的逻辑保留检查。
独立项目本地提交 `39574c9106`（Endfield，分支 `codex/project-separation`）。
引擎迁移提交号见本仓库 git log；两仓库均未 push。

移除旧文件后的兼容启动器、双管线最小 smoke再次通过；执行器负向控制通过。
独立复查无可操作发现。已核对底层 C++/内部 GLSL/构建规则无变更；无需重编引擎。

## C# / .NET 编辑器（2026-11-16）

已从 `5a924a3d67` 的引擎源码启用 `module_mono_enabled=yes`，生成绑定、
Debug/Release GodotSharp、编辑器工具及 `4.7.3-rc` 本地 NuGet 包。
复现入口：`.\.venv\Scripts\python.exe misc/build_custom_dotnet.py --jobs 12`；
环境与分发说明见 `misc/CUSTOM_DOTNET.md`。
二进制为 `bin/godot.windows.editor.x86_64.mono.console.exe`，配套目录为
`bin/GodotSharp` 和 `bin/nupkgs`。原非 .NET 二进制 SHA256 保持不变。

验证证据在 `.renderdoc-analysis/csharp-enablement/`：
- `build-dotnet.log`：原生构建、绑定生成、程序集及包构建成功。
- `full/run.json`：Endfield 完整 38 项通过（原 35 项加 C# 构建及双管线 GPU 场景）。
- `editor-and-engine-final/run.json`：C# 双管线、解决方案、编辑器构建、引擎独立双管线 smoke 共7项通过。
- `preservation-check.json`：888个历史基线文件哈希及原非 .NET 二进制保持不变。

初次 C# probe 的 `mono` 特性标签不适用于本分支，改用真实 `CSharpScript` 类型；
首次编辑器扫描把验证目录 `.obj` 当模型，项目通过 `artifacts/.gdignore` 排除产物。
失败日志保留，最终检查全部通过。绑定生成器的重名方法警告和包 README 提示
未阻断构建；本轮没有修改引擎渲染算法或绑定生成器。导出模板尚未构建。

## 后续项目工作

角色 atlas重建、E321/E301裁剪和项目材质组合在 Endfield 中继续；详见
`E:/ZcxCode/Endfield/docs/CAPTURE_MAIN_SHADOW.md`。不要在引擎树恢复重复项目源码。
需要增加渲染能力时才修改本仓库接口，并运行 Endfield 全部集成回归。
引擎接口文档：`servers/rendering/renderer_rd/custom_forward/ENGINE_CHARACTER_SHADOWS.md`。
完整历史交接已迁到 Endfield 的 `docs/HANDOFF_HISTORY.md`。

```powershell
# 引擎最小 smoke（另一管线改为 forward_plus）：
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://smoke.gd
# 外部完整回归，从任意目录运行：
& E:/ZcxCode/Endfield/.venv/Scripts/python.exe E:/ZcxCode/Endfield/tools/run.py regressions
```
