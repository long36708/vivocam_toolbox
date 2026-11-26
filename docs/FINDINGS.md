# 技术发现记录（Findings）

> 本文件是代码注释里 `docs/FINDINGS.md §x` 引用的落点。
> 全部结论来自对 vivo 相机 APK / 解包固件 / 运行设备的逆向分析，
> 主要验证机型：vivo X200 Pro mini（PD2419，MT6991，OriginOS 6 / Android 16）。
> 阅读顺序：§1–§5 是"能做什么"的判据，§6–§12 是"不能做什么"的证伪记录——
> 后者同样重要，它解释了架构为什么长成这样。

---

## §1 `.dat` HAL 配置 = 循环 XOR 明文 XML

OriginOS 7 系机型的 `/odm/etc/camera/*.dat` 是 **11 字节 ASCII 密钥循环 XOR 的明文 XML**，
密钥即字符串 `mysecretkey`（可从文件头反推：`51 46 0b 08 0f 52 13 11` XOR `mysecretkey` = `<?xml ver`）。
解密后 schema 与 OS6 的 `.xml` 完全一致（同 DTD、同标签）。
对应库：`libvcf_settings_parser.so`（导出 `vcf::xorEncryptDecrypt…`）。

本仓库 `module/lib/xor.awk` 用 `od + busybox awk` 实现解密（设备无 python3；
注意 busybox awk 有内置 `xor()`，自定义函数必须改名，本仓库用 `bxor`）。

**含义**：OS6（`.xml`）与 OS7（`.dat`）的 HAL 配置是**同一份数据的两种封装**，
两侧解析器互不认识对方格式——这决定了 App 层移植的兼容判定必须先把两侧归一化。

## §2 双解析器互斥

- PD2419（OS6）：`libvcf_platform_utils.so` 硬编码 `*.xml` 文件名，无 `.dat` 路径
- X500PM（OS7）：`libvcf_settings_parser.so` 硬编码 `*.dat`

把 `.dat` 丢给 stock HAL 机制上不可能生效；反之亦然。

## §3 相机场景码是位域

`scene:255744 = 999<<8`——低 8 位是子类型。且 `999` 在库里是**编译期固化的 8 字节
结构体表项**（`e7 03 00 00 00 00 00 00`），**改 XML 补不出枚举**。
任何"改 HAL 配置补 scene"的路线从根上不成立。

## §4 `$$MEAT` 才是 App 层入场券（决定性判据）

OriginOS 6+ 的 16.x/13.x 相机在启动时反射加载
`com.android.camera.featureconfig.FeatureConfig_meat_<项目码>$$MEAT`。
**缺失即启动崩** `configMeatZoomSceneConfig: moduleZoomConfig is null`。

| 事实 | 数据（dex class 描述符级实测） |
|---|---|
| 普通 `FeatureConfig_meat_PDxxxx` 类 | 每个 APK 内置 112~152 个 |
| 带 `$$MEAT` 的**可用伪装码** | **每个 APK 仅 1 个** |
| X500 16.1.4.203 | `PD2609$$MEAT` |
| X500PM 16.1.4.210 | `PD2602$$MEAT` |
| X200PM OS7 13.0.55.11 | `PD2415$$MEAT`（= 本机基座项目码） |
| Neo10 13.0.55.9 | `PD2425$$MEAT` |
| 原厂 13.0.47.271 | PD2415 / PD2417 / PD2419 / PD2415F_EX / PD2415F_EX_SC |

**⚠ 判据陷阱**：`grep "FeatureConfig_meat_PD2419"` 在所有 16.x 包里都能命中——
那是普通配置类，**假阳性**。必须匹配 `FeatureConfig_meat_PDxxxx$$MEAT;` 类描述符。
本仓库 `plugin_build` / `addport` 的扫描用的是后者；安装校验会**复核**声明的
`TARGET_PROJECT` 是否真实存在于 APK 的 `$$MEAT` 集合里，防呆。

**未闭环**：X500PM-163 只有 `PD2602$$MEAT`，但伪装 PD2608 实测可用——
MEAT 解析存在别名/同族回退，机制未明。所以本仓库把"可伪装码"作为 port 描述里
的**数据**（`TARGET_PROJECT`）而非算法推导，运行时靠 `diagnose` 的
`moduleZoomConfig is null` 签名自动提示改码。

## §5 机型真值不在 build.prop，在 `/proc/cmdline`

`ro.product.device` / `ro.product.model.bbk` / `ro.vivo.oem.model` / `ro.hardware.bbk`
由 bootloader/device-tree 注入，**镜像 build.prop 里查不到**（只有
`ro.build.expect.hardware=PD2415MA|PD2419MA|...` 这类期望列表）。

可靠来源（bootloader 写入，`resetprop` 改不到、重启不变）：

```
vivooemboot.oem_name=PD2419B_CN-ZH_FULL_SC_NULL   → 取前导 PD+数字 → PD2419
product.version=PD2415_A_16.1.12.28.W10           → 底层基座项目码
```

**含义**：任何"原厂=某固定机型码"的硬编码都不可移植。本仓库的还原策略是
**快照 + 三级降级**（快照文件 → cmdline → `ro.product.name` 推断），
见 `module/lib/props.sh`。

## §6 原厂相机被伪装属性破坏的机制

模块把属性伪装成 PD260x 后，**原厂 13.x 相机**按 `model.bbk` 反射选
`FeatureConfig_meat_PDxxxx`，原厂包有 PD2419$$MEAT 但其它码没有 → 初始化链断裂
→ `ShareStorage.updateToneQrcode` NPE。这解释了"装了模块原厂相机就闪退"，
也是三向切换必须连属性一起切、且重启后要 `apply` 的原因。

## §7 「改 HAL 配置补 scene」路线证伪

三条硬证据：
1. 解析器互斥（§2）——`.dat` 喂不进 OS6 HAL；
2. X500PM 配置用到而 PD2419 库不认识的 scene 有 **38 个**，scene 枚举编译期固化（§3），补不出；
3. 崩溃流名 `REAL_Y2Y2_INPLACE_WIDE_WPE_IN` 是 **PD2419 自己的 `_base` 配置里独有**，
   X500PM 侧 0 命中——不是移植包"带来"的，是目标机 HAL 的新增项。

## §8 ExtendCap 崩溃点精确定位

反编译 PD2419 stock `libvcf_core.so` 的
`ExtendCapMainBuilderDecisionRule::process`（`0x1722d0`，size `0x4380`，
源文件 `DecisionRuleCustomizedCapture.cpp`）：
- 崩溃点 `0x17330c`：`getOutputHALNodeBufferInfos` 返回空 vector 时 `s[0]==nullptr`，
  外层只判了 node 存在、**未判 buffer 列表非空**，且被水印开关 `a1+481` 门控
  → 空指针取 vtable，`fault addr 0x0`。
- 对照 X500PM 版同函数（`0x148e18` 起有两次 `CBZ x8` 判空）——
  **PD2419 版是代码缺陷（丢了空指针防护），不是配置问题**。

## §9 单指令 patch 有效但路线证伪（打地鼠）

把 `0x173308` 的 `CBZ w8` 改成 `CBZ x23`（仅 2 字节，天然安全——跳转目标处
本就有 x23 判空）：bind mount 实测**原崩溃点消失**，但崩溃**转移到另外三处同类空指针**
（`findMatchedActiveHwDevice+204`、`getOutputHALNodeBufferInfos+44` ×2，
caller `JpgPackDecisionRule::process` 同样无判空）。
node 18 在当前配置下无输出 buffer，多个调用点都假设非空 →
**"改 HAL 二进制"整类路线排除**。本仓库因此把可移植性严格限定在 **App 层**。

## §10 vendor 库移植证伪（拓扑编译期绑定）

- 阶段1（只装 6 个 X500PM 独有 vcf 库）：PD2419 原厂 core 的 `DT_NEEDED` 不含它们，
  **一个都没被加载**，崩溃点分毫不差。
- 阶段2（+X500PM core 全套 7 库）：依赖预检全满足、HAL 存活 37 线程，但
  **cameras=0**、provider 不注册。
- 根因：**vcf 框架与 5 摄 sensor 拓扑编译期绑定**（`vendor/etc/camera/camera_config.xml`
  的 5 摄组合），装到 4 摄机连 provider 都注册不了。
- 全量复制更不可行：X500PM `/vendor/lib64` 独有 514 文件里混着 keymint/libc 等
  系统 HAL，换上去直接无法开机。

## §11 同一机型不同模式可用性差异巨大 → 只有出片算数

X500PM 在 PD2419 上：默认「拍照」模式按快门必崩（§8），
但「原生光影」模式实测连续出片 4 张（777KB–1607KB，HAL 存活）。
**结论**：任何工具只能给"模式矩阵预测"，**可用 = 实机出片 + 手动快门**。
这是本仓库把插件 `TARGETS`（已验证机型）做成人工声明字段的原因。

## §12 测量假象：符号链接必须按"镜像内"解析

`md5sum` 跟随符号链接读取设备当前 `/system/lib64`（可能已被本模块铺过的副本覆盖），
会得出"两镜像库内容不同"的**假差异**。正确做法：解析链接到**该镜像自己的**
`system/system/lib64` 目标再比内容。

实测（按镜像内解析）：X500 与 X500PM 的 `lib/arm64` 逐名内容 **100% 一致**
（78 个加载名）。→ §13 的内容寻址池成立的前提。

## §13 库集可合并：名字数 ≠ 内容数

- X500 库集 107 名字、X500PM 106 名字，**并集 109 个名字**；
- 按内容 md5 去重只有 **78 个唯一文件 / 85MB**（X200PM/Neo10 接入后并池 80）；
- 4 个"仅一侧出现"的名字（`libmmkv_n6/n7`、`libVideoEditorSDK_jni_n1/n2`、
  `libpatcherV2_n1`）与另一侧基名**内容相同**，都是原厂符号链接的目标名；
- 全库扫描 **无任何 .so 的 `DT_NEEDED` 引用 `_nX` 名字**（0 命中）。

**含义**：移植包不需要各带一套库。本仓库采用
「**内容寻址库池**（`libpool/<md5>.so`）+ 每包一份**文件名清单**」；
铺库 = 按清单从池物化。清单同时保留加载名与目标名（与原厂布局逐字节一致，
防按名 `dlopen` 的边缘情况）。

## §14 App 层库布局（为什么实体+链接都要）

vivo 原厂相机 APK 自带 `lib/arm64/`，其中约 1/3 是指向
`/system/lib64/<name>_nX.so` 的符号链接。相机加载的是**链接名**（如 `libmmkv.so`），
所以备份/铺设必须按链接名落成实体文件——只存 `_nX` 目标名照样崩。
（历史教训：早期用错 `_nN` 版本的同名库 → `JNI_OnLoad -4`；
必须按各自镜像解析。）

## §15 部署与守护的工程事实

- `pm install` 必须 `cp` 到 `/data/local/tmp` + `chcon u:object_r:shell_data_file:s0`
  （system_server 读不了 `adb_data_file` 标签）；
- **改脚本不影响内存中运行的守护循环**——必须 kill 旧循环 + 重拉；
- 系统更新/重装相机会重建 `/data/app/~~<hash>/` 目录（lib 清空），
  所以守护必须常驻复检（实测删除后 25s 自愈）；
- 磁盘余量必须 >10G：满盘时多帧合成缓冲落盘失败 → HAL 崩溃循环（曾表现为"卡死"）；
- WebUI `ksu.exec` 同步占死 WebView 主线程：长命令前必须 `await nextPaint()`
  强制提交一帧，否则页面假死；转圈动画必须用 GPU 合成器驱动的 `transform`。

## §16 水印模板缓存是机型键控的：跨机型残留 → getCurrentTmpl null → 崩溃循环

**现象**（PD2419，2026-11-16，iqoo16 移植包 16.1.5.229）：x500 用过之后切到 iqoo16，
拍照正常；一旦进「水印」设置页或切到录像模式，相机开始 2 秒一次的崩溃循环：

```
NullPointerException: ... 'java.lang.String ...watermark.WMTemplate.getId()' on a null object reference
  at WatermarkUtils.getTemplateId(WatermarkUtils.java:14)
  at WatermarkAddition.onStateSessionCreated(WatermarkAddition.java:109)   ← 每次开相机都会走到
```

**机制**（jadx 反编译 16.1.5.229 dex 实证）：

- 相机把水印模板表缓存进 MMKV（`files/mmkv/camera`，键
  `global_pref_camera_watermark_tmpl_online_state`，值是一个模板 ID → 元数据的 JSON map）；
- 「当前模板」不是按 JSON 里的 `selected` 标志确定的：构造 `WatermarkOnlineJSON` 时，
  photo 默认项要求 `FeatureConfig.instance.setDefaultWatermark(templateId)` 为真，而
  `FeatureConfig_meat_PD2606.setDefaultWatermark()` **只认 `DEFAULT_PHOTO_IQOO`**
  （`FeatureConfig_common` 的实现是恒真，机型的 MEAT 类覆写收紧）；
- 缓存没有「本机型默认模板」时 `getCurrentTmpl()` 返回 **null**，而
  `WatermarkAddition.onStateSessionCreated` / `findCurrentTmplIndex` 都不判空 → NPE；
- 崩溃循环的放大器：App 记住了崩溃时的模式（如录像），重启后仍进该模式 → 再崩。

**为什么拍照先正常**：x500 时代的缓存里 photo 选中项能解析出来；解析不出的是
video 模板 / 设置页遍历 video 列表的路径——所以只在「水印」页和录像模式炸。

**处置**：`cam.sh clear`（`pm clear`）后相机重建缓存——重建值必含本机型默认模板
（photo `TEN_YEARS_KPL`、video `DEFAULT_VIDEO_IQOO`，已从重建后的 MMKV 解出验证），
水印功能保留。无法手术式只删这一个键：MMKV 记录链带 CRC、部分记录解析不稳定，
写坏整个文件的最坏后果恰好等于清设置，不值得冒险（diagnose 已按 §16 归因并给处置）。

## §17 S60(PD2572) 移植双坑：series 属性双源判定 + 库池 first-wins 污染

**背景**（2026-11-21，PD2419）：`/data/RNA/RNA_S60`（PD2572=vivo S60/V2572A，MTK mt6881，
OriginOS 6/Android 16）`cam.sh addport` 一步成插件（16.1.1.385，96 库零缺库），但启动即崩；
修好启动后又发现库内容错代。

### §17.1 启动崩 `IllegalArgumentException: the entries is not match the entryValues`

栈：`UIListPreference.setLocalData` ← `SettingSupportManager.resetFlash`（一拍得分支），
`pm clear` 后依旧 → 不是数据残留。

机制（jadx classes7.dex + aapt2 全资源表 + LSPosed eval_js 读运行时数组实证）：

- 一拍得闪光灯配对逻辑：`getPolaroidVersion()<3 && (isSSeries||isVSeries) && isUseNewFlashTorchUI()`
  选 `pref_camera_polaroid_v3_specia_flashmode_entries/entryvalues`（3/3，配对正确）；
  随后 `else if (DeviceUtil.isXSeries())` 把 entryValues **覆盖**成
  `pref_camera_polaroid_flashmode_entryvalues_x_series`（**2 项**）→ 3/2 错配 throw；
- `DeviceUtil.isSSeries/isXSeries` 是**双源 OR**：系统属性 `ro.vivo.product.series`
  **或** `FeatureConfig.productSeries()`（MEAT）。本机真值 series=X（PD2419=X200，模块
  原伪装只覆盖 4 个项目码属性），MEAT(PD2572) series=S → 两个判定**同时为真** → 错配。
  真 S60 上 prop=S，isXSeries()=false，永不触发；
- APK 内全部 flash 数组对静态长度一致（aapt2 全量核对），无 RRO 针对 com.android.camera，
  vivo 动态资源（VCodeImpl.apk）两机逐字节相同 → 运行时错配必是**代码配对 bug**，
  根因在伪装属性不全而非资源覆盖。

**修复（数据级）**：伪装 `ro.vivo.product.series=S`。固化为 `port.conf` 新字段
`SPOOF_PROPS="key=value ..."`（构建器从镜像 build.prop 自动推导）+ props.sh 快照/还原
覆盖附加键（`SNAP_EXTRA_KEYS`，防伪装值污染快照 + 旧快照迁移 + restore 回放）。
stock↔s60 往返 series X↔S 验证正确。

### §17.2 库池 first-wins 污染：新插件同名库拿到旧代内容

`pool_build_from_image` 写 `.names` 后 `awk '!seen[$1]++'` 去重是 first-wins；
`plugin_build`/`pool_fill`/`plugin_export` 按**名字**反查池 → S60 初版插件
libmmkv/libeglImageRender/libvivolog 等为 s30promini(13.x 代) 内容（另一会话实测 14/48 错）。

**修复**：names.lst 升级两列（`name md5`，构建时记录镜像真值——重映射进镜像内 lib64
解析），三处物化按插件自带 md5 直取内容寻址池体；单列老清单走老路径兼容。s60 重建后
96/96 对账全过。

**⚠ 对账方法坑**：直接 `md5sum /data/RNA/<镜像>/…/app/VivoCamera/lib/arm64/X.so` 会跟随
悬空链接读到**设备自己的** /system/lib64 同名库（§13.1 同源），不是镜像真值；镜像真值
只能取重映射路径或构建记录值。本次调查中该坑一度把"设备库"误判为"镜像真值"，导致
误报"修复后 libmmkv 仍旧值"。
