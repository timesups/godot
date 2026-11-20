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
- 2026-11-20：证据实体已移至独立 `D:/ZCXCode/EndfieldData`。旧 `.renderdoc-analysis` 仅为兼容历史配置的目录联接；不要删除其目标或清理素材与历史基线。
- `debug_custom_forward.bat` 默认不依赖捕获素材；可显式传 `--post-lut=<绝对路径>` 验证后处理。
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
未阻断构建；该轮没有修改引擎渲染算法或绑定生成器。

## Windows x64 .NET 导出模板（2026-11-16）

已构建 `bin/godot.windows.template_debug.x86_64.mono.exe`、
`bin/godot.windows.template_release.x86_64.mono.exe` 及两种 console wrapper。
构建入口支持 `--target templates`（仅模板）和 `--target all`（编辑器、绑定、包与模板）。
模板源码基于 `b2a21c0746`；相对已验证编辑器的 `5a924a3d67` 仅有构建入口和文档变化，
渲染/API 源码一致。本轮也未修改 C++/GLSL 或绑定接口。

证据目录 `.renderdoc-analysis/csharp-export/`：
- `build-templates.log`：两套模板成功，首次构建分别约16分22秒和16分47秒。
- `full/run.json`：Endfield 原有38项完整回归全部通过。
- `final/run.json`：C# 构建、编辑器双管线、导入、Debug/Release 导出及搬迁后四组合运行，共10项通过。
- `preservation-check.json`：888个历史基线文件及现有 .NET 编辑器哈希未变。

实际导出程序通过模板类型、随包 .NET 运行时位置、真实 GPU 像素检查；
复现方式见 Endfield `tools/export_csharp.py` 与 README。验证内容是现有 C# smoke 场景，
没有分发外部角色素材。Windows x64 / Vulkan 之外的平台与完整角色内容打包尚未验证。
导出工具直接等待 editor EXE，并禁用持久化构建服务器，避免 console wrapper
等待 Roslyn 子进程不退出；修正后 Debug 和最终双版本流程均无需人工干预。

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

## frame80538 附加绘制状态（2026-11-17）

Endfield 的透明头发必须使用严格 Greater；默认 GreaterEqual 会重复覆盖已有不透明头发。
头发轮廓还要求模板位16比较。新增 opt-in spatial render modes：
`custom_depth_greater`、`custom_depth_equal`、`custom_stencil_mask16`。
仅 Custom Forward 在颜色阶段使用这些状态，深度预通道、默认状态、原始 Forward+ 实现保持。
模板 mask16 同时用于 read/write/write_depth_fail，其他位保持。

构建：`.venv/Scripts/python.exe -m SCons platform=windows target=editor arch=x86_64 module_mono_enabled=yes -j12`。
项目测试 `tests/integration/additional_render_states.gd` 已验证严格深度、Equal、
模板36/52读取、默认对照、masked write和depth-fail保留其他位。
证据在 `.renderdoc-analysis/endfield-frame80538/stencil-transparent-20261117-121418/render-states-v2`。
渲染状态独立复核未发现缺陷；同一证据根下 `regressions/run.json` 的54项旧回归全部通过，
包含双管线、近接触/PCSS及历史193/249比较。888个历史证据文件哈希不变。
项目集成说明见 Endfield 交接文档。

## A06c3 材质模板掩码（2026-11-18）

空间 shader 的 `stencil_mode` 接受 `custom_read_mask(n)` 和 `custom_write_mask(n)`，参数为 0–255 的整数字面量。Custom Forward 颜色通道对前后两面应用相同状态。两侧默认 255，旧 `render_mode custom_stencil_mask16` 将两侧默认设为 16，显式掩码覆盖对应的一侧。`read` 启用比较掩码，`write` 和 `write_depth_fail` 的 Replace 操作使用写掩码。原始 Forward+ 继续使用其全字节掩码。

```glsl
stencil_mode read, write, compare_greater_or_equal, custom_read_mask(16), custom_write_mask(239), 36;
```

Endfield 项目的 `examples/stencil_masks80538.tscn` 展示上述 E542 材质与 E763 写掩码 32 的串联。专项复验使用项目的 `tools/check_stencil_masks80538.py`；项目 A06c3 报告记录二进制指纹、两条管线的实际验证和历史基线核验。

Custom Forward 支持在 PRE_TRANSPARENT 合成回调中调用 RenderDataRD.custom_forward_after_transparent_priority，在当前帧指定材质优先级绘制完毕后访问视口附件。Endfield A23 在优先级 0、6、8 之后执行环境绘制，并验证随后的角色混合。证据位于项目 docs/RESTORATION_A23.md 和 docs/a23/viewport-pixels.json。

A23 的捕获视口在 PRE_TRANSPARENT 使用 RenderDataRD.custom_forward_set_transparent_framebuffer 选取同尺寸的 R11G11B10 颜色附件并复用视口深度模板。环境桥和实时角色按优先级在该附件混合，最后一个回调将结果写回视口。28 个角色域 HDR 检查点与 A22 连续链相同。原 Forward+ 继续由双管线 smoke 覆盖。数值范围及 A24 入口见 Endfield 项目 docs/RESTORATION_A23.md、docs/RESTORATION_ROADMAP.md。

A23 回归中的 37917 展示在完成验证后挂于 WorkerThreadPool::exit_languages_threads 的第一道等待。16 个工作线程都在等新任务，未在排队任务排空后重新确认空闲。线程池在语言关闭准备阶段处理完任务、两个队列均空时唤醒尚未确认的线程。修正后同一展示连续两次通过并正常退出，详见项目 A23 专项。

分离验证：项目双管线 smoke（`Endfield/artifacts/20261120-141510-500696`）及新数据路径的 19 部件展示、C# 构建、素材校验（`Endfield/artifacts/20261120-141550-690258`）通过。引擎调试 BAT 退出码 0 且有 RENDER_SMOKE_OK，但 --debug 日志报告系统 RenderDoc 注册的 capturef.json 不存在，故不记为无 ERROR 的完整通过。此次未重跑完整 54 项或重建历史阴影基线。
