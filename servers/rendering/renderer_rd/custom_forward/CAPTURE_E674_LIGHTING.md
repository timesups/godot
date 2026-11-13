# E674：皮肤细节材质的主光照公式

本轮继续分析已由 RenderDoc MCP 导出的 shader、资源绑定与二进制常量。
本文恢复的是 **E674 主光照阶段、局部光源循环之前** 的计算；没有修改引擎。
证据位于 `.renderdoc-analysis/endfield-frame37917/gbuffer-materials`。

后续重验修正了事件覆盖：E674 新增 683 个面部细节像素，早期 2555 个像素混入 E669。
“887 个无局部光像素可验证 E674”的结论撤回，首次近似比较 MAE 0.18666 也不再作为 E674 误差。
shader 静态公式与常量推导不依赖这份错误覆盖，但所有像素统计须使用下面更新后的数据。

## 本帧实际生效的分支

从 `e674-cb2.bin`、`e674-cb5.bin`、`e674-cb0.bin` 按反射 offset 读出：

| 条件/数据 | 本帧值 | 结果 |
|---|---|---|
| CharacterParams1.y | 1 | `_512` 为 false，跳过环境探针分支，采用指定环境色 |
| CharacterParams1.w | 1 | 主光方向取 CharacterParams11.xyz |
| CharacterParams12.y | 1 | 主光颜色取 CharacterParams5.rgb，即白色 |
| 主光强度，光源常量 offset60 | 1.6243867874 | 白色主光仍乘此强度，不是单位亮度 |
| CharacterParams1.z | 0 | 第一级阴影覆盖不改变采样值 |
| CharacterParams12.x | 1 | 此处控制 Ramp 偏移及额外边缘光，不是屏幕阴影开关 |
| 材质 offset8 | 0 | 金属度为零，漫反射系数为 0.96 |
| 材质 offset24 | 0 | 贴图 Alpha 不调制光照强度 |
| 材质 offset48 | 0 | 跳过末尾材质饱和度/对比度/染色调整 |
| ExposureParams.x | 1 | 输出除曝光在本帧不改变数值 |
| CharacterParams12.w | 0 | 雾分支仍会执行 |

**更正：屏幕阴影没有被这些参数强制关闭。**
`_1210 = mix(mix(1, screen.r, shadowWeight), 1, CharacterParams1.z)`，
本帧 shadowWeight=1、CharacterParams1.z=0，因此 `_1210=screen.r`。
不能把 CharacterParams12.z=1 错当成此处的阴影覆盖参数。

## LUT 与 Ramp

基色纹理采样乘 tint 后先做 linear→sRGB 并 saturate，再查 32³ strip LUT。
对输入 RGB，z=31*B，取 floor(z) 与相邻蓝色切片，沿 fract(z) 混合；
片内 RG 坐标为 `(31*RG+0.5)/(1024,32)`，每个蓝色切片在 U 上偏移 1/32。
反汇编把常量显示到有限小数位；上述尺寸解释与 1024×32 资源一致，
要做逐像素误差验证仍需保留原 SPIR-V 的精确常量和采样器状态。

Ramp 的两次采样分别使用投影后的主光方向和相机轴：

```text
r = ramp(0.5 + 0.5 * clamp(dot(N, projectedLight) + C11.w*C12.x, -1, 1), 0.5)
v = ramp(0.5 + 0.5 * dot(N, cameraAxis), 0.5)
```

`projectedLight` 来自实例矩阵方向变换、将中间方向 Y 置零、变换回去并归一化。
不能直接用未投影的主光方向代替。

## 主光照组合（反汇编变量对照）

以下 `mix` 不隐式 clamp；Y(x) 为亮度点乘，显示权重约 (0.2127,0.7152,0.0722)。
保留 screen visibility `s=_1210`，不假定其为 1。

```text
d = base * 0.96                         // _1118
k = materialLUT * 0.96 * C0.z          // _1218，C0.z≈0.55
a = min(1, r.a)                       // _1264

dark = mix(Y(k*0.65), k*0.65, 1.2)
dark = mix(dark, k, saturate(v.a+r.a))  // _1262
surface = mix(dark, d, a)              // _1295
spread = max(r.rgb)-min(r.rgb)
tinted = surface * (1-spread+r.rgb*spread)
litColor = tinted * clamp(Y(surface)/max(Y(tinted),0.001),0,1.5)
shadowColor = mix(k, mix(Y(d),d,1.2), v.a)
color = mix(shadowColor, litColor, s)   // _1310
```

这说明 Ramp 不只是乘在基色上的一条亮度曲线：其 Alpha 控制基色与 LUT 色的混合，
RGB 改变颜色后还有亮度归一化；另一次相机 Ramp 采样参与阴影颜色。

环境项与光强：

```text
flatN = normalize(vec3(N.x,0.0001,N.z))
h = saturate(dot(flatN,C6.xyz)+C7.x)*C7.y+C7.z
env = h * mix(C2.rgb,1,a)              // _1268
e = EnvironmentGlobalParams0.x * ExposureParams.x  // ≈0.2877224684
main = C5.rgb * mainIntensity          // (1,1,1)*1.6243867874
lit = (mix(Y(main),main,a)+env*clamp(e,0,1.5)*C5.rgb)*C0.y
shadow = env * min(mix(0.65,1,e),1.5)*C0.w  // C1.x=0
irradiance = mix(shadow,lit,s)          // _1294
rgb = irradiance * color               // _1321；材质 Alpha 权重为零
rgb = mix(Y(rgb),rgb,1+clamp(Y(rgb)-0.5,0,0.5)^2) // _1329
```

此后的附加边缘光包含 `(1-C12.x)`，本帧该因子为零，因此 `_1373=_1329`。
不能据此认为其他角色 shader 的边缘光也关闭。

## 其余分支

- 三平面覆盖分支的最终混合权重包含 `smoothstep(1.375-0.3*t,1.725-0.3*t,0)`，
  t 被限制到 [0,1]，因此对有限正常输入权重恒为零。它可能执行采样，但不改变此处基色/法线结果。
- 局部光循环按 32×32 像素 tile 和深度 bin，读取 8 组 32 位掩码并求交，
  用 FindILsb 遍历置位光源。仅凭常量还不能断言本帧局部光贡献为零。
- 循环中按 `_1548` 区分多种光照模式（0、1、3 等），不能统一替换为标准 Lambert。
- 雾分支开启。完整输出对比必须覆盖局部光、雾和实际 screen.r。

## 可运行参考与验证范围

`analyze_e674_active.py` 从二进制常量生成 `e674-active-branches.json`，
并提供主光照的 CPU 参考函数。1000 组随机有限输入通过数值健全性检查。
这些检查不是 GPU 图像匹配，也不证明 shader 整体已还原。

后续补充如下：已导出实际遮蔽、深度与光源列表，HDR 对比尚未进行。

## 实际像素的阴影、局部光与雾

通过独立新 MCP 会话在 E674 导出 `fresh-e674-173767.dds`（屏幕遮蔽）、
`fresh-e674-173794.dds`（深度）、`fresh-e674-173764.dds`（深度副本）。
光源列表为 `e674-light-binning.bin`。
后者对应 Resource173791，199232 字节，分块读取并验证长度。
当前深度与副本的深度值逐像素一致。

分析脚本为证据目录下的 `analyze_e674_visibility.py`；
结果为 `e674-visibility-light-fog.json`，像素数据为 `e674-validation-pixels.npz`。

### 屏幕阴影

E669 → E674 HDR 颜色变化的 683 个像素，其 screen.r 全部为 255/255，故 s=1。
这是纹理实测结论，不是参数强制关闭阴影，不能推广到其他 Draw 或场景。
颜色变化集合也不等于完整光栅覆盖集合。

### 深度重建和光源筛选

shader 用 `1/FragCoord.w` 分箱。使用捕获的逆投影和深度重建，
范围约 3.034365–3.076934，全部落入 depth bin 2，共覆盖 8 个 tile。
E674 vertex 在写 Position 前额外对 clip.y 取负（`_528`），
世界坐标重建必须先撤销这次取负，再应用逆投影/逆视图。
重建世界 Y 范围约 301.467–301.526。这仍是深度推导，不是像素寄存器跟踪。

| tile 与深度掩码相交后的候选光集合 | 像素数 |
|---|---:|
| 0,1,2,3,5 | 12 |
| 0,1,2,4,5 | 419 |
| 0,1,2,3,4,5 | 252 |

进一步按 `_1568`、`_1592`、`_1662`、`_1669`、`_1782` 重建距离与锥形衰减。
设 d² 为距离平方、k 为逆范围、p 为衰减指数：

```text
p < 0: attenuation = saturate(1-(d²*k²)²)² / (d²+1)
p >= 0: attenuation = (1-saturate(d²*k²))^p
spot: attenuation *= saturate((dot(L,-axis)-coneStart)*coneScale)²
```

mode 4 使用 `p=max(2*record4.y,0.1)`。
本帧这些灯未启用 volume box / capsule / profile 变体，脚本对这些前提作断言。

| 光索引 | shader mode | 候选像素 | 衰减 > 0.0001 的像素 |
|---|---:|---:|---:|
| 0 | 0 | 683 | 0 |
| 1 | 0 | 683 | 683 |
| 2 | 3 | 683 | 0 |
| 3 | 0 | 264 | 113 |
| 4 | 1 | 671 | 217 |
| 5 | 3 | 683 | 683 |

这是 CPU 重建的衰减门槛统计，不等于最终有颜色贡献的像素数。
mode 的法线响应和局部阴影仍可能消除贡献。
灯记录中有 float 位模式承载 uint/half 的字段，报告保留完整十六进制 word，
不能把这些字段显示为 NaN 视为数据损坏。

### 雾分支的实际效果

- VolumetricFogParams0.z=0，体积雾采样不执行。
- 两层指数雾密度为零，最小透射率为 1，雾色为零。
- 大气密度包含 `exp(-worldY-65535)`，这些位置的指数约 -65836，浮点下溢为零。
  大气透射率为 1，散射项为零。
- 最终 `_2589=inputRGB*atmosphereTransmission*fogTransmission+scattering`，
  在本帧这些位置化简为 inputRGB。

所有 E674 可见变化像素都包含局部光候选，灯 1 和灯 5 在所有这些像素上通过衰减门槛。
必须先补齐 mode 0/1/3 的局部光，才能对 E674 做完整 HDR 对比。
更新后的像素坐标及掩码已保存；比较脚本检测到无独立主光样本时会输出 not_applicable。

### MCP 事件定位问题与证据修正

检查安装的 bridge 源码发现 `_get_pipeline_bundle` 和 `_get_shader_code_chunk`
在命中缓存时直接返回，不一定调用 `_set_event`。
纹理导出接口没有 event_id，不能靠调用一次已缓存的 dossier 来保证当前回放事件。
此前 `color-e669.dds` 与 E658 实际输出完全一致，导致差分包含了两个 Draw。

重验流程：每个目标事件独立打开新 capture session，第一次查询该事件 shader，
立即导出，再关闭会话。9 个相关事件的颜色已按此流程重新导出，
统一命名为 `fresh-e<EID>-133342.dds`。旧 `color-e*.dds` 不能作为可靠的逐事件证据。
重验确认 E669 新增 1872 个手部等皮肤像素，E674 新增 683 个面部细节像素，
其余六组角色 Draw 的颜色变化计数保持不变。

首次比较使用了错误像素集合，误差不能归因于公式或量化。
`e674-main-comparison.json` 已明确标记失效原因，不再报告“匹配精度”。
采样器过滤状态和 firstInstance 仍未由现有 MCP schema 完整提供，
下一步还需要补齐这些状态以及局部光公式，而不是通过调参拟合错误数据。

## 局部光 mode 0/1/3 与首轮有效对比

已新增证据目录下的 `compare_e674_local.py`，使用独立会话导出的
`fresh-e674-*` 输入、修正后的 683 个像素和捕获的光源常量。
结果存入 `e674-local-comparison.json` / `.npz`，后者逐像素保存主光与每盏局部光贡献。
它是 CPU 近似诊断，尚未通过 GPU 等价验证。

令 A 为距离/锥形衰减，C 为光源 RGB，N·L 为光法线点积，
w=record4.y，b=record4.x，s 为屏幕可见性（本组像素实测为 1），
S 为主光阶段得到的 `_1310` 材质颜色，D=base*0.96，K=materialLUT*0.96。

### mode 0

```text
compression = 1 / max(1, max(C*A) * (0.5+0.25*s))
Cprime = C * mix(1, compression, w)
wrap = mix(0.25*b, 1, saturate(NdotL+0.5))
contribution = Cprime * wrap * A * S
```

对应 `_2091.._2111`、`_2142.._2152`。
更正：最终不额外乘 saturate(N·L)。mode 0 的 `_2145` 和 `_2146` 都为 S，
所以 `_2148=mix(S,S,saturate(NdotL))` 仍然是 S。
早期 CPU 版本错误地多乘一次，已由像素调试定位并修复。
灯 1/3 的 w=0，因此本帧不会应用颜色强度压缩；它们的 b=0。

### mode 1

```text
t = saturate(NdotL+b) * localShadow
contribution = C * A * mix(K*w, D, t)
```

对应 `_2128.._2133` 及最终累加。
灯 4 为点光源，打包的六个 shadow face 索引均为 255，经 shader 转换为 -1，
所以不采样阴影 atlas；转入 `_2084` 的角色径向回退：

```text
radial = normalize(vec3(world.x-origin.x, 0.0001, world.z-origin.z))
localShadow = saturate(dot(radial,L)+1)
```

无阴影索引不等于直接取 localShadow=1。
本帧灯 4 的 w=0，且近似重建的有效范围内法线响应为零，因此最终贡献为零。

### mode 3：在 E674 变体中加法贡献为零

该分支计算相机平面上的投影光方向及材质混合，但 `_2141` 明确执行
`Select(mode==3, 0, attenuation)`。之后 `_2142`、`_2149`、`_2150` 使用这个零权重。
所以本 shader 的 mode 3 加法颜色贡献为零，包括灯 5。
不能把“距离衰减通过”理解成“最终有光照贡献”，也不能把此结论推广到其他材质变体。

### 比较结果

同一组 683 个像素、同一套 G-buffer 近似输入，未调参拟合：

| 指标 | 结果（线性 HDR 单位） |
|---|---:|
| 仅主光的 RGB 平均绝对误差 | 0.0430121 |
| 主光 + 局部光的 RGB 平均绝对误差 | 0.0148029 |
| 主光 + 局部光的最大分量误差 | 0.0926211 |

逐灯近似结果：灯 1 在 675 个像素产生非零贡献，灯 3 在 91 个像素产生非零贡献；
灯 0/2/4/5 为零。该结果来自 CPU 重建，并非 shader debug 直接观测。

这些误差不能转换成“百分之多少还原度”。目前仍有以下边界：

- 采用 G-buffer 的 8 位 sRGB 基色、10 位八面体法线，替代前向 shader 的精确输入。
- 实例记录 0 尚未通过 firstInstance 验证；该记录的 Buffer229 变换已导出，但不能保证选择正确。
- 使用 bilinear/clamp 采样假设，MCP 没有完整序列化采样器状态。
- 使用深度重建位置、反汇编显示的舍入常量和 CPU 浮点计算。

下一步应优先补齐实例索引与采样器状态、获取精确 UV/法线等插值输入，
然后判断剩余误差来自输入量化、公式还是输出精度。当前没有修改引擎代码。

## 实例、采样器与 post-VS 输入核验

已给本机 RenderDoc MCP bridge 增补只读序列化字段，原文件备份于证据目录
`mcp-backup`。补丁与最终文件快照保存在 `mcp-patched`，不是上游正式版本。
未修改 Godot 引擎。新增状态记录为 `e674-precise-sampling.json`、`e674-postvs-state.json`。

实际 Draw 参数：1356 个索引、1 个实例，indexOffset=0、vertexOffset=0、instanceOffset=0。
因此此前使用实例记录 0 的假设得到确认。

| 资源 | 实际 sampler | 寻址 | shader LOD |
|---|---|---|---|
| Ramp 186593 | set0 binding5：min/mag Linear，mip Point | ClampEdge | 显式 0 |
| 材质 LUT 172496 | set1 binding1：Anisotropic，max8 | ClampEdge | 显式 0 |
| 基色 185716 | set1 binding2：Anisotropic，max8 | Wrap | 隐式导数与 GlobalMipBias |
| 阴影比较 | set0 binding6：Linear comparison | ClampEdge | compare Greater |

不能再笼统说所有贴图都是 bilinear/clamp；CPU 对 LUT 的 bilinear 计算仍需要 GPU 验证。

### 直接提取顶点着色器输出

RenderDoc GetPostVSData 返回 398 个顶点、1356 个索引（452 个三角形），stride128。
保存为 `e674-postvs-vertex.bin`、`e674-postvs-index.bin`。
位置、UV、世界位置、法线等输出按 vec4 对齐，flat 实例索引已由 Draw 参数确认。
这些是抓帧 shader 的执行输出，不是重新实现蒙皮得到的近似顶点。

`interpolate_e674.py` 在 683 个变化像素处按透视校正重建插值，
以捕获深度选择重叠三角形。边缘允许 1/256 像素的固定精度光栅化位移，
不宣称与硬件覆盖和导数逐位相同。

验证结果：

- 最大深度差 4.41092×10⁻⁸，99 分位深度差 2.96535×10⁻⁸。
- 插值法线与 G-buffer 解码法线的点积最小值 0.9999896，平均值 0.9999986。
- 插值世界位置与深度重建位置的最大分量差 2.20607×10⁻⁵。
- UV、法线、世界位置与 primitive ID 保存于 `e674-interpolants.npz`。

### 替换法线和位置后的对比

运行 `compare_e674_local.py --interpolants`，保持材质输入和公式不变，仅替换位置和法线。
683 个像素的线性 HDR MAE 从 0.01480295 变为 **0.01479570**；最大分量误差约 0.0928436。
因此该实验不支持“法线量化或深度重建是当前主要误差来源”的判断。

目前仍使用 G-buffer 基色，尚未按精确 UV、导数、mip 和各向异性采样重建前向基色。
下一步应检查该纹理输入、LUT 实际 GPU 采样和主光公式；不能仅通过放大光强消除残差。

## 像素调试成功：修正 mode 0，验证公式

在已确认属于 E674 的像素 (1300,1194) 上，RenderDoc MCP shader debug 成功返回
2018 个执行状态。此前尝试的手部像素实际属于 E669，不能据其失败认定 E674 不可调试。
另对 (1299,1189)、(1322,1174) 取得完整轨迹，分别交叉检查明亮和暗部。
文件为 `e674-debug-steps.json`、`e674-debug-selected.json`、`e674-debug-values*.json`。

调试值证明 mode 0 的 `_2148` 是完整材质色，未再次乘 N·L。
修正 CPU 公式后，对同一组 683 个像素、同一组输入：

| 指标 | 修正前 | 修正后 |
|---|---:|---:|
| 线性 HDR RGB MAE | 0.01479570 | 0.00335589 |
| 最大分量误差 | 0.09284357 | 0.03187742 |

这仍是用量化 G-buffer 基色进行的近似全组对比；不能把全部残差归为公式错误。

### 用真实调试输入检验公式

`validate_e674_debug.py` 将调试器采样出的基色/LUT/Ramp、实际法线、世界位置
送入 CPU 公式，和同一条调试轨迹最终输出比较，避免混入替代输入差异。

| 像素 | CPU 与调试器输出最大分量差 |
|---|---:|
| (1300,1194) | 8.65365×10⁻⁶ |
| (1299,1189) | 1.63483×10⁻⁵ |
| (1322,1174) | 7.22735×10⁻⁷ |

三个断言均通过（阈值 2×10⁻⁵）。它证明这些执行路径上的公式接近调试器解释执行结果，
不等于全帧 GPU 等价；舍入后的反汇编常量与 CPU 运算仍有差异。

三点真实采样基色与 G-buffer 解码基色的最大分量差分别为
0.00187985、0.00234736、0.000153865，直接确认 G-buffer 只能提供近似材质输入。
例如亮部调试输出 (1.32144260,1.18359149,1.15551734)，实际 HDR 存储为
(1.3125,1.171875,1.125)。三点的调试输出按 R11/G11/B10 尾数向下截断后均与抓帧值一致。
这支持输出量化解释，但不足以认定所有 GPU/所有像素都采用同样的舍入行为。

现在已找到并修复主要公式偏差。下一步可建立 GPU 材质回放：使用原始贴图、实际采样器、
post-VS UV/法线/位置和恢复的光照公式，让 GPU 完成采样及 R11G11B10 写入，再比较误差。

## GPU 光栅回放验证

已实现独立测试 `tests/rendering/custom_forward/material_replay.gd`，配套
`material_replay.vert`、`material_replay.frag`、`compare_material_replay.py`。
这是捕获材质的验证工具，尚未接入 custom_forward 正式渲染流程。

GPU 输入与执行：

- 直接使用捕获的 post-VS 输出和索引，光栅化 452 个三角形，GPU 进行透视插值和导数计算。
- 基色使用原始 BC7 sRGB 压缩数据，额外通过 MCP 导出 mip1–10，合成完整 11 级 mip 链。
- 材质 LUT 使用原始 BC7 sRGB 数据，显式 LOD0；Ramp 使用原始 RGBA8。
- 采样器采用已核实的 8× 各向异性 Wrap/ClampEdge、线性 ClampEdge 配置。
- 光源列表、光照常量、实例方向变换来自捕获，shader 使用 E674 本帧有效分支。
- 同时写 R11G11B10、未量化 RGBA32F HDR 和 RGBA32F 基色采样诊断目标。

测试用捕获的 683 像素掩码及深度误差 ≤5×10⁻⁸ 筛选可见片元，
禁用背面剔除；**没有还原原始完整 depth/stencil/cull 管线**。
隐式纹理采样放在测试筛选 discard 前，避免该筛选人为改变纹理导数。
本次将采样移动到 discard 前后，统计结果相同。

运行命令（仓库根目录）：

```powershell
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_material_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials --prepare
.\bin\godot.windows.editor.x86_64.console.exe --path tests/rendering/custom_forward --rendering-method custom_forward --rendering-driver vulkan --script res://material_replay.gd -- --evidence=E:/ZcxCode/godot/.renderdoc-analysis/endfield-frame37917/gbuffer-materials
.\.venv\Scripts\python.exe tests/rendering/custom_forward/compare_material_replay.py .renderdoc-analysis/endfield-frame37917/gbuffer-materials
```

RTX 3050 / Vulkan 上运行成功，输出 `E674_GPU_REPLAY_OK`，无缺失像素、无非有限值：

| 指标 | GPU 回放结果 |
|---|---:|
| 验证像素 | 683 |
| HDR packed 值完全一致的像素 | 407（59.59%） |
| RGB 分量完全一致比例 | 65.89% |
| RGB 分量差 ≤1 个编码步进比例 | 75.40% |
| 线性 HDR RGB 平均绝对误差 | 0.000892574 |
| 最大分量误差 | 0.0390625 |

报告为 `e674-gpu-validation.json`，逐像素结果为 `e674-gpu-hdr.bin`、
`e674-gpu-float.bin`、`e674-gpu-base.bin`。
最大误差点为 (1301,1174)，参考 RGB=(0.953125,0.44921875,0.375)，
回放 RGB=(0.9921875,0.47265625,0.390625)。

两个明亮调试点的 GPU 基色与此前 RenderDoc shader debug 采样值完全相同；
暗部 (1322,1174) 的采样仍有差异，不能把全部剩余误差归于输出量化。
主光中反汇编舍入常量、采样/导数和原始 shader 精度/编译差异仍需进一步分离。

**验证结论：回放测试运行通过并取得明显更小的误差，但逐像素一致性未通过。**
当前结果只覆盖本帧 E674 可见子集，不能代表其他角色材质或整条渲染管线已经还原。

## 最大误差定位：mip 过滤配置已修正

调试 (1301,1174) 后确认：GPU 回放 UV 与原始 shader debug 的 UV 完全相同，
均为 (0.7724114656,0.0123308953)，命中 primitive 10。
但原始基色采样约为 (0.41699219,0.22094727,0.19067383)，
错误配置的回放约为 (0.43457031,0.23205566,0.19921875)。
因此该点主要差异不是 UV 或光照，而是采样。

早期把统一 sampler 报告中的 `Anisotropic` 推断成 mip Linear，这是错误的。
通过捕获 structured file 导出原始 `vkCreateSampler` 创建参数，确认两个 8× sampler：

| sampler ResourceId | 寻址 | min/mag | mipmapMode | anisotropy |
|---|---|---|---|---|
| 4731 | Repeat | Linear | Nearest（0） | enabled，max8 |
| 4902 | ClampEdge | Linear | Nearest（0） | enabled，max8 |

两者对应已确认的基色 Wrap / 材质 LUT ClampEdge 配置。
原始完整结构与摘要保存在 `sampler-creation-chunks.json`、`sampler-creation-summary.json`。
最初的 mip Nearest 对照实验文件使用 `-mip-nearest.bin` 后缀；确认原始配置后，
`material_replay.gd` 已正式修正默认 sampler 并重新生成标准输出。

同时导出了 `e674-fragment.spv`，恢复主光亮度权重的精确浮点值：
(0.2126729041337967,0.7151522040367126,0.07217500358819962)，
对应 composite 179 / scalar 176、177、178。替换显示舍入常量本身未改变当时的 packed HDR 统计。
新增 GPU UV/导数/primitive 诊断目标 `e674-gpu-uv-dx.bin`、`e674-gpu-dy-primitive.bin`。

### 修正后的最终重跑结果

| 指标 | mip Linear（旧） | mip Nearest（原配置） |
|---|---:|---:|
| 完全匹配像素 | 407/683 | **680/683（99.56%）** |
| RGB 分量完全匹配 | 65.89% | **99.85%** |
| RGB 分量差 ≤1 个编码步进 | 75.40% | **100%** |
| 线性 HDR RGB MAE | 0.000892574 | **0.00000250217** |
| 最大分量误差 | 0.0390625 | **0.00390625** |
| 缺失像素 | 0 | 0 |

剩余 3 个像素各有一个 RGB 分量相差 1 个编码步进，没有更大的偏差。
验证状态仍标记 `measured_not_pixel_identical`，未把接近一致表述为逐位一致。
这是本帧 E674 可见子集的结果；原始完整可见性状态及其他角色材质尚未复现。
当时的下一阶段是保留该回归测试并接入独立材质路径；接入结果见下。

## 独立角色材质路径（2026-11-13）

新增 `render_mode custom_character`，仅由 Custom Forward 实现，其他渲染器
编译时明确拒绝。角色材质通过 `EMISSION` 提供线性 HDR 光照结果，不叠加标准
PBR 光照；普通合成及分离高光输出均已接入。原 Forward+ 文件未改动。

`materials/character.gdshader` 提供基础贴图、材质 LUT、ramp、主光、环境光以及
模式 0/1 的显式点光参数。光照数学提取到 `character_lighting.gdshaderinc`，
原 `material_replay.gd` 也使用同一份函数，抓帧对照仍独立读取原 HDR 目标。
比较脚本增加 680/683、单分量最多 1 编码步长和 MAE≤2.51e-6 的失败门槛。

`character_scene.gd` 将源抓帧的 E674 post-VS 网格转换为 ArrayMesh：398 个顶点、
452 个三角形，使用原 BC7 基础贴图/mip 链、LUT 和 ramp。不使用捕获像素 mask
或深度贴图，验证真实 MeshInstance3D 绘制。当前只包含脸部细节子网格，非完整角色。

验证结果：

- Windows editor 编译成功，Vulkan RTX 3050 场景测试通过。
- 主光/环境光关闭后全黑，局部光模式 0/1 各自生效且结果不同。
- 分离高光目标确实分配，合成结果与普通输出逐像素一致。
- E674 回归保持 680/683 完全匹配、其余 3 像素差一个编码步长、缺失 0。
- Bloom/LUT 回归通过，最终 SDR MAE 0.0398046875/255、最大误差 1/255。
- baseline/MSAA/TAA/FSR2 回退 smoke 通过；关闭自定义后处理时，普通材质
  Custom Forward 与原 Forward+ 输出逐像素一致。
- 在 Forward+ 下提交角色材质，收到明确的渲染器不支持错误。
- 独立审查未发现缺陷；补充了分离高光和不支持渲染器的验证。

当前边界：点光参数仍显式提供，未映射 Godot Light3D/阴影；完整角色、其他 Draw
变体、原 stencil 可见性和动画/蒙皮尚未验证。使用方法见同目录 README。
