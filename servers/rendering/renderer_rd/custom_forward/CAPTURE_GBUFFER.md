# EndField frame 37917：G-buffer 与角色材质分析

本阶段完成抓帧接口与首个材质的分析，尚未把新的 G-buffer 或角色光照接入引擎。
现有 Bloom / 最终 LUT 的验证结果仍以 README 为准。

## 证据来源

- 输入：`D:\Download\EndField-frame37917.rdc`，Vulkan，2560 × 1440。
- SHA256：`DEF7B7A19BAED8B9DC89AADA3B84C396897B78BB483BFB220CAFCF85901D8143`。
- 通过 RenderDoc MCP 获取事件、完整 shader 反汇编、资源绑定、常量、纹理和 pixel history。
- 本机证据目录：`E:\ZcxCode\godot\.renderdoc-analysis\endfield-frame37917\gbuffer-materials`。
- `e<EID>-pixel.txt` / `e<EID>-vertex.txt` 是反汇编，不是原始源码；
  `e<EID>-dossier.json` 是绑定记录；`constants-index.json` 记录完整常量导出的范围。
- 本文的材质名称来自逐 Draw 的颜色变化位置和贴图内容，是语义识别；事件、绑定与编码公式是直接证据。

## 已确认的渲染组织

角色几何先写入 G-buffer，再通过独立前向 Draw 写 HDR 颜色。
角色采样点在 E650、E654、E658 的延迟光照中出现 stencil test failed。
因此实现时需要保留“环境延迟光照 / 角色前向光照”的分流，不能对角色再无条件叠加环境延迟光照。
当前接口没有提供足够的深度模板状态信息，具体 stencil reference / mask 尚未恢复。

下列对应关系已通过相同 index count、完整顶点缓冲绑定（含 offset / stride）验证。
可见部位通过 `draw-coverage.png`、贴图及像素历史交叉判断：

| G-buffer EID | 前向 EID | 部位 | 本帧前向颜色改变像素数 |
|---|---|---|---:|
| 468 | 669 | 手部等皮肤几何 | 1872 |
| 457 | 674 | 面部小块细节 | 683 |
| 462 | 679 | 虹膜 | 513 |
| 473 | 684 | 小块服装/配件 | 503 |
| 478 | 689 | 面部 | 5390 |
| 483 | 694 | 主体服装 | 215604 |
| 488 | 699 | 耳部 | 2522 |
| 493 | 704 | 头发 | 20660 |

计数是相邻事件的 HDR 缓冲差异，不能等同于全部光栅覆盖面积。
例如 face_center (1270,1150) 的 G-buffer E478 与前向 E689 都命中 primitive 2137；
torso (1280,850) 的 E483 / E694 命中 primitive 15031。
`pixel-probes.json` 中早期名为 hair_top 的点实际落在背景，不用于证明头发材质。

## G-buffer 数据契约

| MRT | ResourceId | 格式 | 已确认含义 |
|---|---|---|---|
| 0 | 133342 | R11G11B10_FLOAT | HDR 场景颜色；E457 先写零，后续前向写光照 |
| 1 | 173785 | R10G10B10A2_UNORM | RG 压缩运动矢量；BA 材质相关辅助标志，完整语义待定 |
| 2 | 173782 | R10G10B10A2_UNORM | R 金属度；G 材质 AO/间接光遮蔽；B 屏幕空间粗糙度/遮蔽相关控制；A 材质编号高 2 位 |
| 3 | 173776 | R10G10B10A2_UNORM | RG 世界法线八面体编码；B 感知粗糙度；A 材质编号低 2 位 |
| 4 | 173779 | RGBA8 sRGB | 基色；Alpha 随材质变化，不能直接认定为透明度 |
| Depth | 173794 | D32S8 | 深度与模板 |

MRT2.B 的确切业务名称未恢复，不能直接当作标准 Godot ORM 通道。
E650 的 F0 / diffuse 分支支持金属度识别；G 参与间接光并与屏幕 AO 组合。
MRT3.B 在 BRDF 中平方用于粗糙度计算。

### 运动矢量

从当前/上一帧 clip.xy / clip.w 得到 NDC 差值：

```text
velocity_uv = 0.5 * (current_ndc - previous_ndc) * vec2(1, -1)
encoded = 0.5 + 0.5 * sign(velocity_uv) * abs(velocity_uv)^(1/4)
t = 2 * encoded - 1
velocity_uv = sign(t) * abs(t)^4
```

E457 等生产者与 E879 消费者（约 303–327 行）互相印证。
接入 Godot 时仍需单独处理投影、抖动和屏幕 Y 方向，不能把纹理直接接到 Godot velocity 输入。
10 位量化下中性值 0.5 无法精确表示，解码后存在极小的非零值。

### 世界法线：Y 轴八面体编码

```text
p = normal.xz / (abs(normal.x) + abs(normal.y) + abs(normal.z))
if normal.y <= 0:
    p = (1 - abs(p.yx)) * sign_not_zero(p)
encoded = p * 0.5 + 0.5

p = encoded * 2 - 1
n = vec3(p.x, 1 - abs(p.x) - abs(p.y), p.y)
if n.y < 0:
    n.xz = (1 - abs(n.zx)) * sign_not_zero(n.xz)
normal = normalize(n)
```

`sign_not_zero(x)` 在 x >= 0 时取 1，否则取 -1。
这里折叠的是 Y 半球，不能直接套用以 Z 为轴的八面体编码。

### 材质编号

E505 写入，E658 第 455–464 行读回：

```text
MRT2.a = floor(material_code / 4) / 3
MRT3.a = (material_code % 4) / 3
material_code = roundEven(MRT2.a * 3) * 4 + roundEven(MRT3.a * 3)
```

shader 写入的 0.4 / 0.7 在 2 位 UNORM 中分别存成 1/3 / 2/3。
编号的完整枚举名称尚未知，且该编号与模板测试不是同一份状态。

## 首个材质：E457 / E674

选择此材质是因为 G-buffer shader 简单、存在可见输出且输入可提取。
更正：E669 有 1872 个颜色变化像素；早期零变化结论来自 MCP 事件缓存导致的错误前态。
角色覆盖已用每个事件独立新会话导出重验，`fresh-e<EID>-133342.dds` 为有效证据。

### 已恢复的 G-buffer 写入

- 基色：纹理 185716（包含皮肤/面部细节的 atlas）采样乘材质 tint；本 Draw 可见区域为面部细节。
- 世界法线：顶点输出归一化后按 front-facing / 材质双面参数处理，再进行上述编码。
- MRT0：零。
- MRT1：`vec4(encoded_velocity, 1, 0.4)`。
- MRT2：实例记录中 offset 88 的 uint 位模式，按 10/10/10/2 解包并归一化。
- MRT3：`vec4(encoded_normal, 0, 0.7)`。
- MRT4：`vec4(base_color, 1)`。

实例记录 stride 为 256 字节；不能把整个缓冲第一条记录默认当成任意 Draw 的实例。
E457 材质常量位于 Buffer630 offset406912，288 字节；
E674 材质常量位于 Buffer630 offset992448，336 字节。
两者及相关全局/实例数据都完整保存在 `e<EID>-cb<index>.bin`。

### 已识别的前向光照输入与核心流程

E674 有 2690 行完整 pixel 反汇编。当前已确认以下部分，整体光照尚未逐像素复现：

1. 基色贴图 185716 乘 tint。
2. 基色转 sRGB 后查材质 LUT 172496（1024×32，对应 32³ strip）。
   这是角色材质 LUT，区别于已实现的最终 LogC 调色 LUT。
3. Ramp 186593（256×1）根据投影后的主光方向与法线的 half-Lambert 坐标采样，
   另有基于相机方向的 ramp 采样；RGB 和 Alpha 都参与后续计算。
4. 屏幕遮蔽 173767、阴影 atlas 7624、多个 3D 光照资源及逐光源循环参与光照。
5. 输出还经过曝光与雾相关处理；不能只用 ramp × base 替代完整结果。

相关资源绑定：set1 binding3 为材质 LUT，binding4 为 ramp，binding5 为基色；
set0 binding18 为屏幕遮蔽，binding20 为阴影；其余绑定见 E674 dossier。

通过与保留名称的全局常量布局按 offset 对齐，识别了 `_CharacterParams0..16`。
`global-layout-map.json` 和 `e674-pixel-annotated.txt` 保存映射。
本帧 CharacterParams1.w=1，主光方向覆盖取 CharacterParams11.xyz；
CharacterParams11.xyz 约为 (-0.14726211, 0.52991927, 0.83516431)。
这些是本帧取值，不能硬编码成引擎固定规则。

## 描边

E721 vertex shader 已确认：将法线投影到屏幕，归一化 XY，进行宽高比、FOV、
最小像素宽度处理，再偏移当前及上一帧 clip.xy，另加深度偏置。
E726 / E731 / E737 的几何数量分别对应面部 / 服装 / 头发，完整 shader 已导出；
这些变体仍需逐项核对，具体 cull / depth / stencil 状态未恢复。

## 本阶段验证与边界

运行：

```powershell
.\.venv\Scripts\python.exe .renderdoc-analysis/endfield-frame37917/gbuffer-materials/verify_contract.py
```

使用 E511 后导出的 2560×1440 纹理：运动编码解码往返误差为 0 个分量；
法线八面体内部的量化编码往返误差为 0 个分量。
1442 个位于编码边界的像素单独计数，不纳入该法线误差断言，因为边界存在方向等价的编码。
8 组 G-buffer / 前向 Draw 的 index count 与顶点绑定全部一致。
结果保存在 `contract-validation.json`。

这是编码一致性和几何绑定验证，不是光照图像误差验证。
MCP pixel shader debug 在已确认可见像素上仍不可用；pixel history 的数值字段
返回 SWIG 占位文本，因此本报告没有声称取得逐步寄存器值或数字化 shader_output。

## 后续实现顺序

1. 在 custom_forward 内增加独立的材质数据输出与调试视图，先验证法线、运动、材质编号；
   保持原 Forward+ 不变，并将新路径放在显式开关后。
2. 为 E457 / E674 建立单材质回放验证：固定几何、相机、贴图、常量和输入光照资源，
   完成角色 LUT / ramp / 遮蔽 / 光照计算，对比 E674 的 HDR 输出，再扩展面部、头发和服装。
3. 明确深度模板分流后接入环境延迟光照，避免角色被重复照明。
4. 接描边，再接已完成的 Bloom / 最终 LUT；分阶段输出参考图和误差。

只有逐材质 HDR 对比通过后，才适合宣称对应光照已还原。
