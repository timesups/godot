# 交接：Custom Forward 抓帧还原

更新：2026-11-16。工作目录 `E:\ZcxCode\godot`，分支 `4.7`，HEAD `9b458e9092`。
本文件写入前已核对 git status/log/diff、构建日志及本地 GPU 验证报告。

## 目标与约束

在独立 `custom_forward` 管线中逐步还原 EndField 抓帧的后处理和角色渲染。
用户要求保留原始 Forward+、保留已有回归，允许从本机抓帧提取测试模型/纹理。
按阶段实现、编译、GPU 验证，不把近似结果称为逐像素一致。

- **保留工作区全部未提交修改和未跟踪源码，不要 reset/clean。** 本轮开始时已有实时 AO 未提交修改；本轮 E669 与之前 AO 修改均保留、尚未提交。
- 优先继续使用此工作目录。仅 checkout HEAD 或创建新 worktree 不会带上未提交/未跟踪文件，也不会带上忽略的抓帧素材。
- 本轮已完成 E669 皮肤还原及实时灯光/阴影/AO 接入；此前 E689/E694/E704 实时 AO 保留并重验；没有待运行的后台构建或需要继续等待的任务。
- 不主动提交修改。没有必要重新安装 RenderDoc MCP 或重新提取全部资源。

## 已完成

1. 独立 Custom Forward、Bloom/LUT、E674 角色路径。
2. E689 脸部 SDF 材质与捕获阴影图；E694 衣服法线/高光/环境反射/自发光；E704 头发双法线、双层各向异性高光、条纹。
3. 完整静态角色 fixture：8 个 draw、52,489 顶点、61,618 三角形。E669/E674/E689/E694/E704 使用还原材质；虹膜、附件、耳朵仍是基础颜色诊断。
4. 可选 `--live-lights`：E704 实时深度轮廓光，方向光/点光/聚光灯场景绑定。测试覆盖相机投影、MSAA、缩放、灯光移动/隐藏/颜色/范围/删除/16 灯上限。
5. E704 的引擎 Omni/Spot 阴影。模式 1/3 读取真实阴影，模式 0 保持不受阴影影响，模式 4 保持原有替换行为。新引擎已编译成功。

## 最新引擎阴影设计

- `Light3D.get_light_rid()` 新增只读接口。不要用 `get_base()`：此版本 Light3D 构造器直接给服务器实例设置 base，场景 getter 返回空 RID；`get_instance()` 也不是灯光资源 RID。
- `light_storage.cpp` 把灯光完整 RID 的两个 32 位字 memcpy 到现有 `LightData.pad` 的 8 字节中；GPU 用 floatBitsToUint 读取。数据布局/步长不变，原始 Forward+ 不使用这些填充字段。
- 场景绑定器上传 uint low/high 数组与 spot 类型。不能用位置匹配灯光，也不能把 RID 转成数值浮点，避免同位置灯、排序和精度错误。
- `render_mode custom_character_shadows` 在 Custom Forward 中启用 `custom_forward_local_shadow(uvec2, bool, vec3 view_position, vec3 view_normal)`。
- helper 只查询当前 cluster，匹配完整 RID 和 layer mask，复制原引擎的 Omni/Spot 投影、bias、过滤、opacity 逻辑。深度/阴影 pass 返回 1，避免反馈。
- 默认抓帧材质保持不变。`HAIR_REALTIME_DEPTH` 启用头发实时深度/阴影；E689/E694 通过 `CHARACTER_ENGINE_SHADOWS` 启用引擎阴影。
- `character_light_binding.gd` 默认 E704/E694 的 16 灯布局；`face_layout=true` 选择 E689 的 8 灯布局并拒绝模式 4。E674 不兼容。各目标使用独立 ShaderMaterial。

## 最新完成：E704 方向光级联阴影

- DirectionalLightData 的 uint padding 存储完整 RID，与局部灯 float padding 区分；缓冲区布局、原始 Forward+ 求值未变。
- 新增 `custom_forward_directional_shadow(uvec2, vec3, vec3)`，按完整 RID、有效灯列表和 mesh layer mask 查找。深度/阴影 pass 返回 1，避免反馈。
- helper 镜像引擎动态方向光 PCF/软阴影、1/2/4 级联及混合、bias、距离淡出、opacity；不接烘焙 shadowmask。
- 只有 HAIR_REALTIME_DEPTH 头发版本将引擎可见度乘入原有 main shadow，AO 不变；`engine_directional_shadows_enabled=false` 回退。live 预览主光已开启投影。
- GPU 真实头发 RGB 和：可见 25601.0714，完全遮挡 0；移开遮挡物、零 opacity、关闭阴影、手动回退、绑定第二盏无阴影主光均恢复；重排仍为 0。
- 诊断测试覆盖 1/2/4 级联、blend 开关、相机跨 4/8/12 边界、18/19 淡出区间、21 距离外。
- 正交相机忽略方向光 max_distance，使用 camera.far。级联边界测试用透视相机；大 caster 覆盖过滤范围，接收 quad 关闭投影以隔离自阴影。
- 完全遮挡测试不等于半影边缘逐像素精度。软阴影质量、多视图、TAA/FSR2 仍未验证。

## 最新完成：E689/E694 引擎阴影

- 两者均按完整 RID 采样方向光级联和 Omni/Spot 阴影；live fixture 将 E689/E694/E704 绑定到共享场景灯光，各自有独立材质和绑定节点。
- E689 SDF 继续控制原有 ramp/颜色。引擎主光可见度只乘一次主光输入，不再乘入 SDF、ramp、AO 或最终颜色；环境光保留。未遮挡时与默认材质逐像素一致。
- E689 左右 SDF 测试：0.5 阴影 opacity 与无阴影、0.5 主光能量逐像素相等；完全遮挡且开启环境光时，与仅开环境光逐像素相等。这验证没有重复衰减，不代表恢复了原游戏的实时组合算法。
- E694 主光沿用 E704 的 screen shadow 输入，自发光仍在阴影计算之外。
- 两材质局部模式 1/3：引擎阴影乘入完整局部贡献一次，替代手动 atlas/radial 回退，不再同时作为明暗 response mask。脸部 SDF max() 提亮与艺术暗部底色不会穿过完全遮挡。
- 模式 0 保持不受阴影影响，衣服模式 4 保持替换行为；旧 E704 局部光行为不改。engine_directional_shadows_enabled / engine_local_shadows_enabled 可分别关闭引擎路径。
- 新增 `tests/rendering/custom_forward/live_material_shadows.gd`：主光遮挡/移动/关闭/零 opacity，局部 0/1/3（衣服另含 4）、禁用/零 opacity、同位置不同 RID，8/16 灯上限、删除清理、脸部拒绝模式 4、自发光保留。
- E689 主光可见 RGB 和 30245.5303，E694 为 20581.1928；完全遮挡均为 0，Omni/Spot 模式 1/3 也均为 0。
- 证据：`face-clothes-engine-shadow-validation.json`、`e{689,694}-engine-directional-blocked.png`，日志 `.renderdoc-analysis/live-face-clothes-shadow-test.log`（含 FACE_CLOTHES_ENGINE_SHADOWS_OK / CHARACTER_LIVE_OK / FULL_CHARACTER_OK）。

## 最新完成：E689/E694/E704 实时 screen AO

- 新增 Custom Forward-only `custom_character_ao` / `custom_forward_screen_ao(SCREEN_UV)`，读取引擎 SSAO final buffer；深度/阴影 pass、关闭或不可用 SSAO 时返回 1。
- 现有 SSAO 在深度/normal prepass 后、不透明绘制前生成。头发已写入 prepass，但颜色绘制因 depth texture 在透明阶段；通过独立 character SSAO flag 允许它读取同一缓冲区，不开启普通透明材质的 stock SSAO。
- E689 使用 min(face_ao, engine_ao)，E694/E704 使用 min(screen_shadow_ao.y, engine_ao)。主光阴影 x 和脸部 SDF 不变，不额外乘最终颜色，避免重复遮蔽。
- `engine_screen_ao_enabled=false` 恢复手动 AO。Environment 的 SSAO 开关、radius/intensity/power 控制缓冲；不额外套用 stock direct_light_affect / ao_channel_affect，因为材质已有 AO 光照模型。
- live 变体默认启用采样；完整角色 live fixture 在旧独立测试结束后启用 Environment SSAO。默认捕获回放保持原样。
- 新增 `live_character_ao.gd`，三材质 × 正交/透视/MSAA4/窗口尺寸与相机移动/0.75 内部分辨率，共 15 组接触测试；移动遮挡物恢复，关闭环境 AO 与关闭材质 AO 逐像素一致（防残留）。
- 较强手动 AO 与实时 AO 并用逐像素等于手动 AO，验证 min 组合。真实 0.5 opacity 主光阴影的诊断中，AO 开关不改变阴影值及脸部 SDF 值，只改变 AO 通道。
- 不透明脸/衣服与透明阶段头发读到相同 raw AO（诊断 RGB 和 contact 7990.153 / disabled 8400）。实际材质也均有接触响应；这不是原游戏 AO 算法的逐像素还原。
- 仅支持写入 prepass 的不透明角色；普通半透明接收者/遮挡物、多视图、TAA/FSR2 尚未验证。
- 证据：`.renderdoc-analysis/live-screen-ao-test.log`，`character-screen-ao-validation.json`，`e{689,694,704}-live-ao-*.png`。

## 最新完成：E669 皮肤

- 新增 `skin.gdshader` / `skin_lighting.gdshaderinc`：BC5 法线、LUT/ramp、base alpha AO、皮肤边缘色及解析高光，复用既有 BRDF 工具。只还原本帧有效的干燥分支，不宣称恢复湿润/积雪/探针或通用 SSS。
- 完整角色 E669 已替换基础色诊断，接入既有 16 灯绑定、方向光级联、Omni/Spot 阴影与 screen AO。AO 独立使用 min，主光阴影进入原 shadow 通道；无脸部 SDF、无额外最终颜色 AO 相乘。局部模式 1/3 整体贡献只乘一次可见度；0/4 保留原行为。
- 新增独立 `skin_replay` / `compare_skin_replay.py`；E658→E669 独立 HDR 导出 hash 固定，1872 可见像素中 1866 完全一致，其余全部 <=1 编码步长；MAE 1.0085581375e-5，最大 .015625，无漏像素。
- 独立 Shader Debug (1072,665)、primitive 1792 的最终 RGB/法线也有回归断言。资源、常量、范围详见 `CAPTURE_E669_SKIN.md`。
- 既有 live shadow/AO 测试扩展到 E669：主光可见 RGB 和 34876.3107，完全遮挡 0；Omni/Spot 模式 1/3 同样归零；五种 AO 配置、手动 min 和阴影/SDF 独立诊断均通过。原有案例保留。
- 默认与 live 完整角色的皮肤法线/边缘色/高光/AO 参数响应测试通过，9542 个轮廓像素、1327 种纹理颜色。live 三分之四视图已目检。
- BC5 DDS 使用 128 字节 legacy header，BC7 使用 148 字节 DX10 header，不能统一跳过 148 字节。
- 证据：`e669-gpu-validation.json`、`e669-debug-validation.json`；日志 `skin-replay-regression.log` / `live-skin-test.log`。E664/E668 不是有效参考 draw；旧探索导出不要当基准。

## 下一步（尚未开始）

1. 其余三种基础颜色诊断材质待接入（E679 虹膜、E684 附件、E699 耳朵）。优先提取 E679 的绑定与有效 shader 分支，建立独立回放基线，再接入实时灯光。
2. 如提高阴影质量，增加局部遮挡边缘的级联过渡、软阴影定量测试；当前测试以完全覆盖为主，未承诺半影逐像素精度。
3. 动态角色脸部 SDF 与几何自阴影的艺术效果仍可进一步调校；当前使用静态 posed mesh，没有骨骼动画还原。保留全部现有回归。

## 已验证基线

最新构建：`build-custom-skin.log`，成功（up to date），17.79 秒；皮肤接入无需新增引擎 C++ 修改。运行环境 Windows / Vulkan / RTX 3050。
最新 live 日志：`.renderdoc-analysis/live-skin-test.log`，含 `CHARACTER_SCREEN_AO_OK`、`FACE_CLOTHES_ENGINE_SHADOWS_OK`、`CHARACTER_LIVE_OK`、`FULL_CHARACTER_OK`，无 shader/runtime 错误。

| 检查 | 最新结果 |
| --- | --- |
| E669 HDR | 1866/1872 完全一致，MAE 1.0085581375e-5，所有误差 <=1 编码步长 |
| E689 HDR | 5266/5390 完全一致，MAE 8.889919604e-5，最大 0.015625 |
| E694 HDR | 215051/215604 完全一致，MAE 2.05975676e-6，12 像素超过一个编码步长，最大 19 步 |
| E694 原有 surface 回归 | base/normal 各 215599/215604 一致，固定 5 个差异点仍保留 |
| E704 HDR | 20634/20660 完全一致，MAE 1.87497479e-6，全部通道误差 <=1 编码步长 |
| E674 / Bloom/LUT | 独立回放和比较通过；最终 SDR 最大差 1/255 |
| 引擎局部阴影 | Omni/Spot 模式 1、3 完全遮挡时 RGB 总和为 0；移开/禁用/零 opacity 恢复；同位置双灯和重排通过 |
| 原始 Forward+ / Custom Forward | baseline smoke 均通过 |
| 默认完整角色 / live 完整角色 | 均通过 |

最新比较日志：`.renderdoc-analysis/skin-{material_replay,face_replay,clothes_surface_replay,clothes_replay,hair_replay}-regression.log` 及 `skin-post-regression.log`。
本轮全部重跑，误差维持上表基线。两管线 baseline smoke：`skin-smoke-{custom_forward,forward_plus}.log`；默认完整角色：`skin-full-character.log`；live 完整角色：`live-skin-test.log`。成功 marker 和无 ERROR 已核对。
方向光证据另见 `hair-live-validation.json`、`hair-shadow-directional-{visible,blocked}.png`。
最近独立审查未发现引擎局部阴影的 blocking/should-fix 问题。软阴影质量、多视图和大 cluster 性能未验证。

## 命令

从仓库根目录 PowerShell 执行：

```powershell
.\.venv\Scripts\scons.exe platform=windows target=editor arch=x86_64 -j8
.\debug_full_character.bat --smoke
.\debug_full_character.bat --smoke --live-lights
# 打开持续预览：
.\debug_full_character.bat --live-lights
```

独立回放模板（不要使用 --headless，否则不能验证真实 GPU）：

```powershell
$evidence = 'E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials'
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --audio-driver Dummy --rendering-method custom_forward --rendering-driver vulkan --script res://hair_replay.gd --quit-after 600 -- --evidence=$evidence
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_hair_replay.py $evidence
```

依次替换为 skin_replay、material_replay、face_replay、clothes_replay、clothes_surface_replay；最后一个 Python 名称是 `compare_clothes_surface.py`。
`post_process.gd` / `compare_post.py` 使用父目录 `.renderdoc-analysis/endfield-frame37917`。
`smoke.gd` 分别用 `--rendering-method custom_forward` 和 `forward_plus`。
检查成功 marker 和日志无 ERROR，不只看退出码：一些旧 GDScript helper 的 assert 可能没有使整个进程返回非零。

## 抓帧与 MCP

- 原文件：`D:\Download\EndField-frame37917.rdc`，已确认仍存在。
- SHA256：`DEF7B7A19BAED8B9DC89AADA3B84C396897B78BB483BFB220CAFCF85901D8143`。
- 本地证据目录：`E:\ZcxCode\godot\.renderdoc-analysis\endfield-frame37917\gbuffer-materials`。
- RenderDoc MCP 在之前会话已可用，RenderDoc 1.46。新会话先 discover 工具、get_server_status，再 open_capture/get_analysis_worklist；不要复用旧 capture_id/debug_id。
- 模型是 post-VS posed mesh，不是恢复的骨骼动画。贴图保留压缩 BC blocks/mips；素材与原始抓帧没有提交到 Git。
- 新鲜 HDR before/after 导出已有 hash 固定，不随意覆盖。MCP 缓存的事件查询不一定切换真实当前事件；重导出时用新 capture 并明确选事件。

## 坑与范围

- E704 无 discard，base alpha 不能当作透明裁剪。
- 捕获深度必须 point/nearest 采样；线性过滤会引入背景深度，制造过亮边缘。
- Godot RD 投影翻转 Y：实时 rim 的 view-normal Y 要取反再偏移 SCREEN_UV。向上法线测试已覆盖，勿删。
- `hint_depth_texture` 会使颜色 pass 排到 opaque 之后；实时材质用 depth_prepass_alpha 保留自身深度，alpha 仍为 1。普通透明遮挡物不在此深度中。
- E704 保留头部 object basis 和 tangent handedness；第二组法线不随背面翻转。
- Shader Debug 必须指定最终可见 primitive；E704 (1220,1190) 是 4519。默认首个重叠三角形可能被遮挡。
- captured HDR 回放的 mask/depth rejection 只是隔离可见像素，不代表完整 visibility 管线已还原。
- 无 TAA/FSR2/multiview 阴影精度或性能承诺。其他三种材质仍未完成。

## 入口文件

以下路径相对仓库根目录，按需阅读，避免一次加载全部抓帧日志：

- `servers/rendering/renderer_rd/custom_forward/README.md`
- 同目录 `ENGINE_CHARACTER_SHADOWS.md`、`LIVE_CHARACTER.md`、`CAPTURE_E669_SKIN.md`、`CAPTURE_E704_HAIR.md`、`CAPTURE_E694_SURFACE.md`
- 同目录 `materials/hair.gdshader`、`hair_lighting.gdshaderinc`、`character_light_binding.gd`、`face*.gdshader*`、`clothes*.gdshader*`
- `servers/rendering/renderer_rd/shaders/custom_forward/character_shadow_inc.glsl`、`scene_custom_forward.glsl`
- `servers/rendering/renderer_rd/custom_forward/scene_shader_custom_forward.cpp`
- `servers/rendering/renderer_rd/storage_rd/light_storage.cpp`、`light_storage.h`
- `servers/rendering/shader_types.cpp`、`scene/3d/light_3d.{h,cpp}`、`doc/classes/Light3D.xml`
- `tests/rendering/custom_forward/live_character.gd`、`live_material_shadows.gd`、`live_character_ao.gd`、`full_character.gd`、`prepare_character.py`、各 replay/compare

每个后续里程碑更新此文件，保持它是新对话的单一交接入口。
