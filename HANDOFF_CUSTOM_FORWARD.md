# 交接：Custom Forward 抓帧还原

更新：2026-11-16。工作目录 `E:\ZcxCode\godot`，分支 `4.7_custom_render_pipeline`；近接触修复 `e53eb25730`，斜面 PCSS 修复 `7b8ce796b2`；本轮主光阴影来源/过滤回放提交号以 git log 为准。
本文件写入前已核对 git status/log/diff、构建日志及本地 GPU 验证报告。

## 新会话先读：当前状态摘要

- **目标**：分阶段还原原抓帧角色主光阴影，保留实时质量修复、原始 Forward+ 和全部已有回归。
- **本轮完成**：追踪 E269–334 角色 D16 atlas → E637/E641 模板分区 RG8 → 角色材质合成。独立 GPU 回放 E641 有效过滤：249573 个角色像素中 249572 个完全一致，仅 (1306,542) 差 1 个 RG8 编码值。详见 `servers/rendering/renderer_rd/custom_forward/CAPTURE_MAIN_SHADOW.md`。
- **关键纠正**：捕获 `173767.G` 来自角色 shadow atlas，并非 SSAO；旧 helper 的 `ao` 命名不能代表来源。R 来自全局方向阴影，本帧被常量旁路为 1。G 为固定半径 16 gather/64 比较及覆盖率/深度差重映射，不是 Godot PCSS。现有材质/live SSAO 行为未改。
- **近接触/PCSS 修复保留**：`e53eb25730`、`7b8ce796b2` 的代码和全部测试不变。
- **验证**：新鲜原生重导出 hash 一致，新过滤 GPU 回放/比较通过；九项材质 GPU 回放、后处理、默认/live 完整角色、AO/阴影独立性和双管线 smoke 重跑通过。329、160/36、历史193/249 组在保留捕获上重跑比较通过；本轮未重新采集这些阴影矩阵，未重编引擎。日志 `.renderdoc-analysis/main-shadow/regression-*`。
- **下一步**：独立重建角色 atlas，再串接现有材质回放，最后设计可选 live 接入。E321 是额外的 54378 索引抖动裁剪 caster；E301 有 alpha 阈值裁剪，不能只重画八个部件。全局非旁路分支需其他抓帧；之后追踪真正 AO 和剩余后处理。
- **范围限制**：本轮使用捕获 atlas/G-buffer/stencil，尚未重建其生成；非旁路全局阴影、动画、其他 atlas、TAA/FSR2、多视图及性能未验证。
- **工作区/构建**：本轮开始干净、基线 HEAD `7b8ce796b2`，运行时代码未改。保留 `.renderdoc-analysis/shadow-bias/character`（193）和 `contact-coherent`（249）两个历史基线。最新提交见 git log。
- **授权**：按 AGENTS.md 自动本地提交，不 push。

### 为什么保留原始 Forward+

用于同场景对照、定位自定义管线回归、保留普通渲染路径与回退能力，并减少同步上游时的混淆。它不是绝对正确的视觉标准：此前无效级联采样缺陷也存在于原始 Forward+。必须同时保留独立的遮挡/连续性/朝向断言，而非只要求两条管线相同。前轮绕序和预览范围问题在两条管线都可复现，根因在 fixture；本轮接触修复只改 Custom Forward 角色 helper。

### 可直接粘贴到新会话

> 请先阅读 E:\ZcxCode\godot\HANDOFF_CUSTOM_FORWARD.md 和 AGENTS.md，核对工作区，简述目标与下一步。主光阴影来源及 E641 角色过滤已独立回放验证，详见 CAPTURE_MAIN_SHADOW.md。请继续重建 E269–334 的角色 atlas，先确认额外 caster E321、附件 E301 裁剪及深度 bias，再比较 atlas 与屏幕输出。保留近接触/PCSS 修复、原始 Forward+、全部回归及未提交修改；区分全局阴影、角色阴影、真正 AO 与脸部 SDF。里程碑验证通过后更新同一交接文档并本地提交，不要 push。

## 目标与约束

在独立 `custom_forward` 管线中逐步还原 EndField 抓帧的后处理和角色渲染。
用户要求保留原始 Forward+、保留已有回归，允许从本机抓帧提取测试模型/纹理。
按阶段实现、编译、GPU 验证，不把近似结果称为逐像素一致。

- **保留工作区全部未提交修改和未跟踪源码，不要 reset/clean。** 先前 E669 与实时 AO 修改完整保留，并按新授权形成独立本地提交 `90d1af44ae`；E679 已提交为 `e4d1b1d96b`；E684 已提交为 `4954a9d6c4`；E699 已提交为 `bd5e603e20`；级联修复已提交为 `86da77307e`；曲面/薄片阴影修复已提交为 `52872eadfb`，均为本地提交，未 push。
- 优先继续使用此工作目录。仅 checkout HEAD 或创建新 worktree 不会带上未提交/未跟踪文件，也不会带上忽略的抓帧素材。
- 前轮绕序与预览范围修复保留；Custom Forward 角色方向光的接收面近接触查询保留，本轮增加 PCSS 接收面排除，原始 Forward+、独立材质回放及现有回归保留。
- 按 AGENTS.md 在完成验证的节点自动本地提交，无需再次确认；不自动 push。没有必要重新安装 RenderDoc MCP 或重新提取全部资源。

## 已完成

1. 独立 Custom Forward、Bloom/LUT、E674 角色路径。
2. E689 脸部 SDF 材质与捕获阴影图；E694 衣服法线/高光/环境反射/自发光；E704 头发双法线、双层各向异性高光、条纹。
3. 完整静态角色 fixture：8 个 draw、52,489 顶点、61,618 三角形。E669/E674/E679/E684/E689/E694/E699/E704 全部使用还原材质；基础色诊断开关保留。
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

## 最新完成：E679 虹膜

- 新增 `iris.gdshader` / `iris_lighting.gdshaderinc`：视角相关 UV 偏移、程序球面双法线、虹膜/外围颜色、ramp 和 MatCap 高光。保留原有 posed mesh、切线手性、头部 object basis。
- 有效路径使用白色主光槽 g194（不是皮肤 g193）、无 LUT 的亮度/饱和度 alternate。Base 与 MatCap 均需各向异性 repeat；MatCap 改 clamp 会造成边缘采样差异。
- 新增独立 `iris_replay` / `compare_iris_replay.py`：E674→E679 导出 hash 固定，513/513 可见像素 HDR 编码完全一致，MAE/max=0，无漏像素；独立 Shader Debug (1255,1152)、primitive 54 的 RGB/法线也有断言。仅代表捕获可见子集，不代表完整可见性系统或所有变体。
- 完整角色默认使用虹膜材质；UV 偏移、曲率、MatCap 参数响应通过。live 接入 16 灯桥接和方向光/Omni/Spot 引擎阴影；主光 visible/blocked RGB 和 22322.726/0，Omni/Spot 模式 1 为 34453.314/0、34003.891/0。
- E679 **不使用 screen AO / 脸部 SDF**，保留原分支行为并测试 AO 输入不影响结果；模式 3 原始最终贡献为 0，模式 0/4 维持不受阴影影响/替换行为，模式 1 完整贡献只乘一次引擎可见度。不要为了统一材质而添加 AO 或 mode-3 高光。
- 既有 live 测试原样保留，额外覆盖虹膜阴影、同位置灯 RID、16 灯上限与删除清理。默认/live 完整角色与全部旧回归通过，live 三分之四视图已目检。
- 详细资源、限制、命令见 `CAPTURE_E679_IRIS.md`；证据 `e679-gpu-validation.json`、`e679-debug-validation.json`，日志 `iris-iris_replay-regression.log` / `live-iris-test.log`。

## 最新完成：E684 附件

- 新增 `accessory.gdshader` / `accessory_lighting.gdshaderinc`，还原捕获有效干燥分支的 BC5 法线、ramp、解析高光与环境反射。复用 E694 已有纹理、cube 和 BRDF/local helpers；附件不绑定衣服 specular lookup，自发光为零，不套用衣服的 lookup/自发光路径。
- 独立 `accessory_replay` / `compare_accessory_replay.py` 固定 E679→E684 before/after hash，503 个可见像素中 502 个 HDR 编码完全一致，MAE 6.4715871438e-7，最大 .0009765625；唯一差异 (1295,1050) 的绿色通道为一个编码步长，无漏像素。独立 Shader Debug (1385,251)、primitive 53 的最终 RGB/surface/specular/reflection 断言通过。
- 完整角色默认/live 已使用附件材质；法线、高光、反射和 shadow/AO 参数响应通过，1547 个轮廓像素、779 种纹理颜色。live 三分之四视图已目检。
- 接入现有 16 灯绑定、方向光级联与 Omni/Spot 阴影；主光可见 RGB 和 20964.2281、完全遮挡 0，局部模式 1/3 完全遮挡也为 0；0/4 保留原行为。未遮挡与默认捕获材质一致，移动/禁用/零 opacity、同位置灯 RID、上限及删除清理通过。
- screen AO 沿用 min(manual AO, engine AO)，主光阴影单独计算，无脸部 SDF。正交/透视/MSAA4/尺寸及相机移动/0.75 缩放五种配置、手动 min 与阴影/SDF 独立诊断通过，原有测试全部保留。
- 仅恢复捕获有效分支与可见子集，不宣称完整湿润/积雪/探针或逐像素一致。资源与命令见 `CAPTURE_E684_ACCESSORIES.md`；证据 `e684-gpu-validation.json`、`e684-debug-validation.json`，日志 `accessory-accessory_replay-regression.log` / `live-accessory-test.log`。

## 最新完成：E699 耳朵

- 新增 `ear.gdshader` / `ear_lighting.gdshaderinc`，按 E699 自身 shader 还原几何法线、参数贴图、ramp、解析高光 lookup 和环境反射；不是头发双法线/各向异性分支。Alternate 为 value 0.55、saturation 1.1，高光 lookup 用于主光与局部灯，反射用原 F0。
- 复用 E704 base/parameters 与 E694 cube/global buffers；仅补取缺少的 lookup 和材质常量。原始 Forward+、公共材质函数和所有已有回归保留，无新增引擎 C++ 修改。
- 独立 `ear_replay` / `compare_ear_replay.py` 固定 E694→E699 before/after hash，2522/2522 可见像素 HDR 编码全部一致，MAE/max=0、无漏像素；独立 Shader Debug (1250,1274)、primitive 783 的 final/surface/specular/reflection 断言通过。只代表本帧有效干燥分支与可见子集。
- 径向回退使用耳朵自身原点，平移后为 (0.02294921875, *, 0.04833984375)；竖直 epsilon 精确为 2^-14。反汇编显示的 0.0001 已舍入，不能直接抄用，也不能复用衣服原点。
- 完整角色八个 draw 已全部使用还原材质；默认耳朵 4906 轮廓像素、3360 种纹理颜色，高光/反射/shadow-AO 参数响应通过。live 使用现有 16 灯桥接、方向光级联、Omni/Spot 阴影与 min screen AO；主光阴影与 AO 分开，耳朵无脸部 SDF。
- live 主光可见/完全遮挡 RGB 和 15744.0553/0，Omni/Spot 模式 1、3 均完全归零；模式 0/4、禁用/零 opacity、同位置 RID、16 灯上限及删除清理通过。五种 AO 配置、手动 min 与主光阴影/SDF 独立性诊断通过。live 三分之四视图已目检。
- 详细资源、限制与复现命令见 `CAPTURE_E699_EARS.md`；证据 `e699-gpu-validation.json`、`e699-debug-validation.json`；日志 `ear-ear_replay-regression.log`、`live-ear-test.log`。

## 最新完成：方向光级联边缘与软阴影质量

- 新增 `directional_shadow_quality.gd` / `compare_directional_shadow_quality.py`。角色 helper 与原始 Forward+ 的普通 `light()` ATTENUATION 使用相同部分遮挡场景：每管线 160 组，覆盖 1/2/4 级联、blend、PCF/PCSS、4/8/12 边界两侧相机移动、18/19 淡出及 21 距离外、低/高质量、角度/遮挡距离、静止重复、半 opacity、normal bias。
- 发现并修复：两级级联开启 PCSS/blend 后仍采样不存在的第三级，完全遮挡区域在深度 8/12 处错误变为 0.152926/0.496933。PCF 在末级淡出附近也可能混入无效级联。只改 `custom_forward/character_shadow_inc.glsl`：按 split distance 是否递增判断下一层有效性，超过最后距离直接返回 1；缓冲结构、原始 Forward+ 和普通材质求值均未改。
- 新回归在修复前图像上明确失败，修复后两处均为 0，160 组和 36 组边界比较通过。原始 Forward+ 同样存在该缺陷并保留原样；参考比较仅对已知受影响配置记录有意差异，物理明暗区域、淡出及连续性断言始终启用。
- 跨边界 4 cm 相机移动的最大平均变化 0.000530231、最大单像素变化 0.036248。其余场景对 Forward+ 最大均值误差 0.00403711、单像素误差 0.00889791（原管线阴影 8-bit 量化及 PNG/sRGB 量化），不宣称 HDR 逐像素一致。
- 高质量、2 单位遮挡距离的 10–90% 半影：PCF 4 像素、2° PCSS 8 像素、5° PCSS 20 像素；0.5 距离的 5° PCSS 为 3 像素。低/高质量半影空间噪声 RMS 0.0597792/0.0226380，静止重复完全一致，half opacity 线性组合通过。
- 证据 `.renderdoc-analysis/shadow-quality/{character,character-fixed,forward_plus}`；修复前后报告/日志保留。具体约束、阈值和复现命令见 `DIRECTIONAL_SHADOW_QUALITY.md`。本测试固定透视、2048/32-bit atlas、无 MSAA/TAA；不代表动画角色自阴影、多视图、TAA/FSR2 或性能验证。

## 前轮基线：角色自阴影 bias / 薄片与近接触遮挡

- 新增 `character_shadow_bias.gd` / `compare_character_shadow_bias.py`，每条管线 193 组：球面、非均匀缩放椭球、双面零厚度薄片、0.002/0.01/0.05 单位间隙、五档 bias、PCF/PCSS、八部件角色和静止重复。
- **修复完整角色导入绕序**：捕获 post-VS 世界坐标三角形与 Godot clockwise front face 相反；双面材质掩盖了绕序错误，但 FRONT_FACING 翻转外侧法线，使 normal bias 朝内部偏移，脸部产生自阴影条纹。`character_mesh.gd` 在完整角色导入边界交换第二/第三索引，默认/live 预览共用。独立 clip-space 捕获回放的投影、索引及数值回归不变。
- GPU 朝向检查要求 >95% 可见法线面向相机，修复后 98.84%；旧绕序对照只有 1.16%，明确不通过。真实材质开关主光阴影/转换绕序前后截图确认条纹消除。不能只凭球面通过或与原始 Forward+ 一致判断角色没有 acne。
- **修复 live 预览范围**：正交相机原 far=4000，directional_shadow_max_distance 对此无效。`character_shadow_preview.gd` 在既有回归完成后应用 far/max distance=6、pancake=2、bias=.05、normal bias=1、2° PCSS、高质量 2048/32-bit atlas。仅适用于当前约两单位角色及固定相机，不是任意场景的引擎默认值。
- 最终配置球面/椭球受光区可见度 0.996888/0.998390，背光区为 0；1 cm 间隙为 0.000857，5 cm 为 0。薄片正反绕序和静止重复一致。旧 far=4000/default bias 对照即使 5 cm 也完全漏光。
- **前轮限制（已由下述本轮修复解决）：2 mm 间隙可见度为 0.817231。** 降低 bias 会恢复接触但引入曲面 acne；后续需评估接收面深度修正或独立 contact shadow，不通过重复乘 AO/SDF 掩盖。本轮未改动 SDF、主光阴影与 screen AO 的组合。
- 193 组双管线诊断、160 组级联/36 组跨边界、默认/live 完整角色和双管线 smoke 全部重跑通过。成功 marker 与无 ERROR 已核对。独立 HDR/后处理回放未在本轮重跑，源码和基线保持不变。
- 证据 `.renderdoc-analysis/shadow-bias/`，正式报告 `character/validation.json`；日志前缀 `shadow-bias-`，实际材质隔离图 `material-{b,flipped-b}*.png`，旧绕序证据 `legacy/legacy_orientation.png`。复现见 `servers/rendering/renderer_rd/custom_forward/CHARACTER_SHADOW_BIAS.md`。仅脚本/文档变化，无需重编引擎。

## 前轮完成：接收面近接触遮挡（e53eb25730）

- 只修改 `custom_forward/character_shadow_inc.glsl`：保留原 PCF/PCSS，补充几何接收面上的四纹素深度查询，要求四个纹素都支持遮挡，再与原阴影取 min。各级联合并后统一混合、距离淡出与 opacity，不重复乘阴影/AO/SDF。不依赖屏幕深度，shadows-only 薄片也参与。
- 补充容差为 min(原 depth bias, 0.25 纹素)，原过滤 bias 不变；作用距离为沿接收面法线的八个阴影纹素，外半段淡出。零 bias/退化导数回退，|N.L| 从 .2 到 .1 平滑关闭。仅支持方向光，属于有限范围近似。
- 249 组双管线捕获/比较通过：原 193 组保留，新增 40 组间隙、8 组无遮挡自投影平面、6 组掠射角连续性、2 组独立脸部。新比较模式要求旧 Custom Forward 基线对 Forward+ 的原误差门槛，并检查补充查询不提亮、不增加曲面 acne、2 mm 遮挡、双面性及静止一致性；旧模式仍通过。过大 bias/far=4000 的负例继续在修复前基线上断言。
- 原预览 2 mm/1 cm/5 cm 全为 0；球面 .996888/0，椭球 .998390/0。40 个新增间隙最大可见度 <.000035；角色正面/侧面遮挡覆盖 29.36%/11.12%，朝向 98.84%；独立脸部受光区相对原始管线平均损失 .003908/.003784，低于 .01 门槛。
- 被拒绝的实验：只修 normal bias 位移增加曲面 acne；全量替换过滤改变远处 PCSS 半影；双线性接收面查询在真实脸部产生斑点。最终采用四纹素一致遮挡，真实材质隔离图与最终 live 三分之四图已目检。不要恢复这些实验版本。
- 独立复查提出的掠射角硬切换已改平滑淡出，并补充阈值两侧测试；距离注释已修正。83.9–84.6° 相邻测试最大平均变化 .0271，小于 .05 门槛；不代表极掠射接触精度。
- 未修改的级联比较仍通过 160 组/36 组跨界，未放宽其门槛；默认/live 完整角色、实时材质阴影/AO 独立性及双管线 smoke 通过。独立 HDR/后处理回放本轮未重跑。
- **当时剩余限制（斜面 acne 已由下述本轮修复解决）**：无遮挡 PCSS 斜面 60°/75° 可见度 .972686/.809968，Forward+ 为 .971231/.808106，属于原过滤已有 acne；补充查询未加重。保守条件会错过亚纹素薄遮挡物及接触边缘。其他 atlas、动画、TAA/FSR2、多视图与性能未验证；每个查询级联增加最多四次点采样。
- 证据：`.renderdoc-analysis/contact-coherent/validation.json`、`contact-coherent-reference/`、`contact-verified-quality/validation.json`；日志 `contact-coherent{-reference,-compare}.log`、`contact-legacy-compare.log`、`contact-verified-{quality,quality-compare,default,live,smoke-custom_forward,smoke-forward_plus}.log`。真实材质隔离为 `contact-real-coherent.log` / `contact-real-b*.png`。命令见 `CHARACTER_SHADOW_BIAS.md` 的接收面章节，保留旧 `shadow-bias/character` 基线。

## 最新完成：斜面 PCSS acne

- 根因：PCSS 搜索所有偏移样本时都用中心深度比较，斜面自身朝光一侧会被计入 blocker，生成虚假半影。新增 `custom_directional_soft_shadow()`，以几何位置导数重建接收面，保留原 depth bias，排除接收面自身。
- 只排除原比较已接受、且四个纹素都与接收面深度一致的候选；含空深度的轮廓混合不排除。被接受 blocker 的原始深度平均及后续 PCF 比较不变。零 bias/退化导数保持原路径，掠射角平滑淡出。前轮 contact helper、原始 Forward+、AO/SDF、局部灯和级联/opacity 合成均未修改。
- 首轮仅按双线性深度排除会改变少量远处半影，最大误差 .037719，未通过旧门槛；最终四纹素条件通过，未放宽原 160 组/36 跨界的比较门槛。
- 329 组双管线验证：原 249 保留；新增 32 组无遮挡斜面与 32 组 2 mm 遮挡，覆盖低/高质量、2°/5°、正交/透视及双轴倾斜；新增 16 组 60°/75°、25/50 cm 远遮挡边缘，防止 contact 查询掩盖 PCSS 真实 blocker 回归。新增 clear 全部 1、近 blocked 全部 0。
- 原 60°/75° clear 从 .972686/.809968 到 1/1；球面/椭球 1/0；2 mm/1 cm/5 cm 仍为 0。远边缘整图最大均值误差 .000739、最大像素 .008898（仍要求 .005/.015）；同时验证明暗对照、窄半影本影及随角度/距离增大的半影面积。宽半影可在有限薄片中心相互重叠，不错误要求所有场景中心全黑。
- 新 PCSS 验收模式允许消除错误自阴影所需的提亮，但要求 PCF 相对前轮接触基线逐像素相同，零 bias 不变，保留曲面、薄片双面性、接触、朝向、静止重复和独立脸部门槛；旧 60°/75° 数据明确不满足新增 clear >.99 门槛。原 193/249 比较模式仍通过历史基线。
- 默认/live 完整角色、实时材质阴影/AO 独立性、实际材质隔离与双管线 smoke 通过，成功 marker 和无 ERROR 已核对；实际材质与 live 三分之四图已目检。独立复查提出的远斜角 PCSS 测试缺口已补齐，复查无剩余发现。
- 最新证据 `.renderdoc-analysis/pcss-final/validation.json`、`pcss-final-reference/`、`pcss-coherent-quality/validation.json`。日志 `build-pcss-coherent.log`、`pcss-final{-reference,-compare}.log`、`pcss-coherent-quality{-compare}.log`、`pcss-{legacy,contact}-baseline-compare.log`、`pcss-verified-{default,live,smoke-custom_forward,smoke-forward_plus}.log`、`pcss-real.log`；隔离图 `pcss-real-b*.png`。命令见 `CHARACTER_SHADOW_BIAS.md` 新 PCSS 章节。
- 性能未测：每个可疑搜索样本最多增加四次点采样。其他 atlas、动画/变形、TAA/FSR2、多视图尚未验证；接收面近似不代表任意曲面遮挡或原游戏软阴影的逐像素还原。独立 HDR/后处理本轮未重跑。

## 最新完成：原抓帧主光阴影来源与 E641 回放

- 具体 pass、资源、常量、sampler、模板状态和九个 atlas draw 对应见 `CAPTURE_MAIN_SHADOW.md`。原生导出脚本 `export_main_shadow.py` 可复现，素材不提交，未修改已安装 MCP bridge。
- 新增 `main_shadow_replay.gd/.glsl`、`compare_main_shadow.py` 和固定输入 hash。独立 GPU 实现过滤，不执行原 SPIR-V；不把原 atlas 生成称为已还原。
- 249573 个角色像素中 249572 个 RG8 完全一致，唯一差异 G=255 对 254；归一化 G MAE 1.571311250596411e-8。全局 R 和所有非角色像素完全一致。覆盖 8196 全黑、20164 半影、221213 全白。只允许已记录单点 1 编码差，不设置宽泛的全图误差容差。
- 新鲜原生重导出全部固定 hash 一致；对比图已目检。证据 `.renderdoc-analysis/main-shadow/reexport/{pipeline-evidence.json,main-shadow-validation.json,gpu.log}`。旧材质回放仍用原捕获输入，尚未串接新屏幕输出。
- 九项材质与后处理 GPU/比较、默认/live 完整角色、AO/阴影独立性及双管线 smoke 重跑通过；日志 `main-shadow/regression-*`。329、160/36、历史193/249 用保留捕获重跑比较通过，测试与门槛均未改。
- 独立复查无可操作发现；复查单独重跑新比较器和暂存 diff 空白检查通过。atlas 生成、材质串接与 live 接入明确留在下一阶段。

## 下一步（分阶段继续）

1. 重建 E269–334 atlas：提取 shadow post-VS/变换、确认 E321 额外几何，恢复 E301 阈值/E321 抖动裁剪和 D16 -8 bias。先比较 atlas 深度，再输入已验证 E641 回放。
2. 串接新屏幕结果与八个材质回放，设计可选 live 接入，保留 engine contact/PCSS 路径。全局级联/cloud 有效分支需要其他抓帧，当前帧不能证明它们正确。
3. 追踪真正 AO，最后核对剩余后处理；捕获 G 不是 SSAO，旧材质变量名不能作为依据。Bloom/LUT 与八个 draw 已完成部分不要重复。
4. 动画/其他 atlas/TAA/FSR2/多视图/性能作为独立扩展；当前素材仍是静态 post-VS posed mesh。保留 329 组和全部历史门槛。

## 已验证基线

最新构建：`.renderdoc-analysis/build-pcss-coherent.log`，成功，32.72 秒；重新生成 shader 并链接，修复仅涉及 Custom Forward 角色阴影 helper。运行环境 Windows / Vulkan / RTX 3050。
最新 live 日志：`.renderdoc-analysis/main-shadow/regression-live.log`，含 `CHARACTER_SCREEN_AO_OK`、`FACE_CLOTHES_ENGINE_SHADOWS_OK`、`CHARACTER_LIVE_OK`、`FULL_CHARACTER_OK`，无 shader/runtime 错误。

| 检查 | 最新结果 |
| --- | --- |
| 曲面/薄片/bias/contact/PCSS | 329 组通过；2 mm 为 0，斜面 PCSS acne 消除，曲面受光区为 1；旧 193/249 基线检查保留 |
| 方向光边缘/软阴影 | 160 组、36 组跨边界比较通过；两级无效级联采样已修复 |
| E699 HDR | 2522/2522 编码完全一致，MAE/max=0；独立 debug 通过 |
| E684 HDR | 502/503 编码完全一致，MAE 6.4715871438e-7，唯一差异为一个编码步长；独立 debug 通过 |
| E679 HDR | 513/513 编码完全一致，MAE/max=0；独立 debug RGB/法线通过 |
| E669 HDR | 1866/1872 完全一致，MAE 1.0085581375e-5，所有误差 <=1 编码步长 |
| E689 HDR | 5266/5390 完全一致，MAE 8.889919604e-5，最大 0.015625 |
| E694 HDR | 215051/215604 完全一致，MAE 2.05975676e-6，12 像素超过一个编码步长，最大 19 步 |
| E694 原有 surface 回归 | base/normal 各 215599/215604 一致，固定 5 个差异点仍保留 |
| E704 HDR | 20634/20660 完全一致，MAE 1.87497479e-6，全部通道误差 <=1 编码步长 |
| E674 / Bloom/LUT | 独立回放和比较通过；最终 SDR 最大差 1/255 |
| 引擎局部阴影 | Omni/Spot 模式 1、3 完全遮挡时 RGB 总和为 0；移开/禁用/零 opacity 恢复；同位置双灯和重排通过 |
| 原始 Forward+ / Custom Forward | baseline smoke 均通过 |
| 默认完整角色 / live 完整角色 | 均通过 |

最新材质/后处理日志：`.renderdoc-analysis/main-shadow/regression-{ear_replay,accessory_replay,iris_replay,skin_replay,material_replay,face_replay,clothes_surface_replay,clothes_replay,hair_replay,post}-{gpu,compare}.log`。
上述独立 HDR/后处理本轮已重跑 GPU 与比较，源码与门槛不变。两管线 baseline smoke：`main-shadow/regression-smoke-{custom_forward,forward_plus}.log`；默认完整角色：`main-shadow/regression-default.log`；live：`main-shadow/regression-live.log`。成功 marker 和无 ERROR 已核对。阴影矩阵本轮仅重跑保留捕获的比较；基础色诊断维持前轮 `ear-albedo-character.log`。
方向光证据另见 `hair-live-validation.json`、`hair-shadow-directional-{visible,blocked}.png`。
前轮日志：`shadow-bias-{character,forward_plus,compare,quality,quality-compare,default,live,smoke-custom_forward,smoke-forward_plus}.log`。静态角色自阴影已覆盖上述场景；动画、多视图和大 cluster 性能未验证。

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

依次替换为 ear_replay、accessory_replay、iris_replay、skin_replay、material_replay、face_replay、clothes_replay、clothes_surface_replay；最后一个 Python 名称是 `compare_clothes_surface.py`。
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
- 无 TAA/FSR2/multiview 阴影精度或性能承诺。八个 draw 已还原当前捕获有效分支，其他天气/材质变体未验证。

## 入口文件

以下路径相对仓库根目录，按需阅读，避免一次加载全部抓帧日志：

- `servers/rendering/renderer_rd/custom_forward/CAPTURE_MAIN_SHADOW.md`（本轮新入口）
- `tests/rendering/custom_forward/{export_main_shadow.py,main_shadow_replay.gd,main_shadow_replay.glsl,compare_main_shadow.py,main_shadow_inputs.json}`
- `servers/rendering/renderer_rd/custom_forward/README.md`
- 同目录 `CHARACTER_SHADOW_BIAS.md`、`ENGINE_CHARACTER_SHADOWS.md`、`DIRECTIONAL_SHADOW_QUALITY.md`、`LIVE_CHARACTER.md`、`CAPTURE_E699_EARS.md`、`CAPTURE_E684_ACCESSORIES.md`、`CAPTURE_E679_IRIS.md`、`CAPTURE_E669_SKIN.md`、`CAPTURE_E704_HAIR.md`、`CAPTURE_E694_SURFACE.md`
- 同目录 `materials/hair.gdshader`、`hair_lighting.gdshaderinc`、`character_light_binding.gd`、`face*.gdshader*`、`clothes*.gdshader*`
- `servers/rendering/renderer_rd/shaders/custom_forward/character_shadow_inc.glsl`、`scene_custom_forward.glsl`
- `servers/rendering/renderer_rd/custom_forward/scene_shader_custom_forward.cpp`
- `servers/rendering/renderer_rd/storage_rd/light_storage.cpp`、`light_storage.h`
- `servers/rendering/shader_types.cpp`、`scene/3d/light_3d.{h,cpp}`、`doc/classes/Light3D.xml`
- `tests/rendering/custom_forward/character_mesh.gd`、`character_shadow_preview.gd`、`character_shadow_bias.gd`、`compare_character_shadow_bias.py`
- `tests/rendering/custom_forward/live_character.gd`、`live_material_shadows.gd`、`live_character_ao.gd`、`full_character.gd`、`prepare_character.py`、各 replay/compare

每个后续里程碑更新此文件，保持它是新对话的单一交接入口。
