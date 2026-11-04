# 架构设计（Architecture）

> 代码注释中 `docs/ARCHITECTURE.md §x` 的落点。技术结论的取证见
> [FINDINGS.md](FINDINGS.md)；配套架构图见
> [plugin-architecture.html](plugin-architecture.html)（浏览器直接打开）。

---

## §1 资源三分离

可移植性的真正边界不是"机型"，而是
**目标机 stock HAL 能否供给移植包 App 所请求的 scene / 流**（HAL 二进制不可换，
见 FINDINGS §9/§10——移植只发生在 App 层）。所以"机型"在本设计里被降级为
**探测结果**，资源分三类：

| 类别 | 内容 | 归属与分发 |
|---|---|---|
| **主模块** | 脚本 + lib + profiles + 内置描述 + WebUI（**无任何固件二进制**） | 本仓库，<100KB zip |
| **移植包插件（port）** | 源机型相机：`port.conf` + `names.lst` + `VivoCamera.apk` [+ `lib/`] | 用户从**自己获取的固件解包**生成；仓库不分发 APK |
| **目标机 profile** | 真实项目码、SoC、原厂相机路径、HAL 格式、原厂库清单、已知模式矩阵 | 内置 + 用户插件目录可覆盖 |

## §2 配置格式：shell-sourceable，不用 JSON

设备侧无 `jq`、无 python3。所有配置是 `KEY=VALUE`，由 `lib/conf.sh` 的
**非执行解析器**读取（见 §6）。新增机型 / 新增移植包 = 加一个数据文件，
**不改任何脚本**。

## §3 profile 匹配：多键任意命中

同一台 vivo 机器上，项目码在不同属性里取值不同（本机实测：
`ro.product.name=PD2419`、`ro.product.vendor.device=PD2415`、
`ro.vivo.oem.model=PD2419B`），且固件本身"一包多机型"
（`/odm/etc/camera/` 同时带 PD2419/PD2458/DPD2429… 配置）。
因此：

1. 匹配只用**未被伪装污染**的属性（FINDINGS §5：被伪装的 4 个属性绝不能用于识别）；
2. `MATCH_KEYS` 任一键相等即命中（多键容错）；
3. 全不命中 → `_generic.profile`：**不伪装、不铺库、拒绝移植**，
   仅保留原厂库备份 + 诊断 + 切回原厂。未知机型"装不坏"是硬要求。

## §4 目录布局与发现优先级

```
/data/adb/modules/vivocam-toolbox/     # 主模块（KSU 更新 = 整目录替换）
├── cam.sh / service.sh / post-fs-data.sh / uninstall.sh / module.prop
├── lib/       conf profile port plugin libpool backup probe props.sh + xor.awk
├── profiles/  <id>.profile
├── ports/     <family>.port（内置描述：仅元数据+清单引用，无 APK）
├── lib/<id>.lst（内置清单）
└── webroot/index.html

/data/adb/vivocam/                     # 运行期数据（模块升级/重装不丢）
├── plugins/ports/<family>/            # ★ 用户插件：port.conf names.lst VivoCamera.apk [lib/]
├── plugins/ports/.versions/<family>/<ver>/   # 升级归档（最多 2 版，可 rollback/use）
├── plugins/profiles/  plugins/sigs/   # profile / 崩溃签名 扩展位
├── plugins/repo.conf                  # REPO_URL=<index.conf 地址>（可选，在线更新源）
├── libpool/<md5>.so  +  .names 索引   # 内容寻址库池（跨插件共享去重）
├── stock/<profile>/  +  .manifest     # 原厂库首启自备份（cp -L 解引用）
├── original_props                     # 原厂属性快照（还原依据）
└── state                              # mode=stock|port / port=<family> / profile=<id>
```

**发现优先级：用户插件 > 模块内置**（同 family 覆盖）——
这是"不更新模块就能更新/新增插件"的机制本体，也是可变数据必须放
`/data/adb/vivocam/` 的原因（KSU 更新会整目录替换模块）。

## §5 移植包不携带库集（内容寻址池）

依据 FINDINGS §12/§13：跨源库内容高度重合（两源并集 109 名字 = 78 唯一内容），
铺库统一按「名字清单 → 池内 `<md5>.so` 物化」。插件 zip 默认**自包含**
（带 `lib/`，安装时合并入池）；`--thin` 模式只带清单（要求池已有内容）。
新增同代源机型时，插件体积 ≈ 只有 APK。

## §6 安全边界：插件是纯数据

`conf_read`：**键必须命中字段白名单正则**（`PATH`/`LD_PRELOAD` 这类危险名进不来），
**值做单引号转义后受控求值**——文件内容永远是字面量。四项注入实测
（值内 `$()`、单引号逃逸、危险键名、键内代码）全部保持字面量。
插件 APK 另有 sha256 钉死 + 安装时 `$$MEAT` 复核；APK 本身走 `pm install` 验 vivo 签名。
→ 装恶意插件的最坏结果 = 装了个不工作的插件，不是代码执行。

## §7 生命周期与并发

- **切换 = 免重启**：resetprop 属性（快照回放/目标码）→ `force-stop` 相机 →
  `pm install -r -d`（换 APK）→ 铺库（清单→池物化 / 原厂备份）→ `chown/chmod/restorecon`。
- **守护**（`service.sh`，15s 轮询）：相机安装/更新会重建 `/data/app/<hash>/lib`
  （清空），守护按 state 复检重铺。`cam.sh` 与守护用 `mkdir` 原子锁串行化
  （并发 `rm -rf` 目标 lib 目录会互删对方刚写的文件，实测出现过 106/108 假数量；
  本机 toybox `flock` 不支持 `exec fd` 用法）。
- **重启后**：`post-fs-data.sh` 先采原厂属性快照（此刻尚未伪装，读到的就是真值），
  再按 state 伪装/还原；WebUI「重新应用属性」执行 `cam.sh apply`。
- **铺库校验**：以「铺完数实际文件」为准（初版数循环次数在并发/cp 失败时虚高）。

## §8 插件生命周期

```
plugin list | info <f> | install <zip|dir> [--thin] | check
plugin update <family|all> | use <family> <ver> | rollback <family> | remove <family>
plugin build <镜像根> <family> [伪装码] [TARGETS]     # addport = build + install
migrate                                               # 旧布局一次性迁移
```

安装校验序（任一失败拒绝安装、不留半套、原子换位）：
结构（根 `port.conf` / `names.lst` / APK）→ `SCHEMA` → `MODULE_MIN ≤ 模块版本` →
APK sha256 → **MEAT 复核**（解包 dex 扫 `$$MEAT`，`TARGET_PROJECT` 必须真实存在）→
清单数量 == `LIB_EXPECT`。

## §9 多机型要求（为什么没有随包的原厂库/固定机型码）

1. **原厂库随包分发是错的**（每台机不同），且根本不必：原厂 `lib/arm64` =
   实体 + 指向 `/system/lib64` 的符号链接，`cp -L` 实测全部可解析
   → **首启自备份本机原厂库**（带清单+md5，原厂被 OTA 更新后数量校验会触发重采）；
2. **原厂属性不能硬编码**（FINDINGS §5）：真实值在 bootloader 注入的
   `/proc/cmdline`，本仓库快照回放；
3. 新增一个可移植目标机 = 加一个 profile 数据文件；
   新增一个源机型 = `addport` 产一个插件，**零代码改动**。

## §10 诊断工具化

| 命令 | 作用 |
|---|---|
| `selfcheck` | 身份 / profile 匹配 / 原厂相机 / 快照 / 库池 / 备份 / 插件 全量体检 |
| `probe [family]` | 目标机 HAL scene/流名 vs 移植包请求差集（**可疑上界，非预测**——FINDINGS §7/§9 证明 scene 齐全仍可能因二进制缺陷崩） |
| `diagnose` | 最新 tombstone 自动归因到已知缺陷（FINDINGS §8/§9/§10 的签名表），支持 sigs 插件扩展 |
| `detect` / `snapshot` | 机型识别 / 原厂属性快照查看与重采 |

## §11 分发模型

| 件 | 体积 | 渠道 |
|---|---|---|
| 主模块 zip | <100KB | GitHub Releases |
| 插件 zip（APK+清单+库） | ≈480–560MB | **用户从自己固件解包生成**；仓库不分发 |
| 库池 | 86MB 起 | 由插件安装自动合并 |

在线更新（可选）：`repo.conf` 配 `REPO_URL` 指向一份 `index.conf`
（一行一个发布：`port|family|ver|url|zip_sha256|min_module`），
`plugin check/update` 拉取比对。**信任模型如实声明**：sha256 只保完整性，
源可信度=宿主可信度；本地导入（`/sdcard/Download/vivocam/` + WebUI 导入按钮）
是一等公民，网盘分享场景直链本就不可靠。

## §12 已验证范围与版本演进

### §12.1 验证矩阵（截至本版）

| 目标机 | 移植包 | 状态 |
|---|---|---|
| PD2419（X200 Pro mini, MT6991, OS6） | x500 16.1.4.203 / x500pm 16.1.4.210 | 启动+库+HAL 实测通过；**快门出片待用户验证** |
| 同上 | x200pm 13.0.55.11（OS7 同机固件） | 同硬件同基座，启动实测通过；前景最好，待出片 |
| 同上 | neo10 13.0.55.9（QCOM 平台） | 实验品：App 能起，HAL 异平台风险高 |
| 其他 vivo 机型 | — | 未匹配 profile → 仅诊断模式（架构就位，欢迎实测回帖补 profile） |

### §12.2 已知限制（不可修，勿提 issue）

- X500PM 系默认「拍照」模式快门崩 HAL：`ExtendCapMainBuilderDecisionRule`
  缺判空（FINDINGS §8），二进制缺陷整类路线已证伪（§9）；
- 录像/电影人像（杜比编码器缺失）、实况（必崩）、LUT/超微距（HAL 无 tag）不可用；
- 「原生光影」等模式实测可出片（FINDINGS §11）——用前先读插件 `KNOWN_LIMITS`。

### §12.3 版本演进

16.x 相机源随版本走（177→203、163→210）：插件 family（x500/x500pm）与
`cam.sh x500|x500pm` 命令保持稳定，`ALIASES` 兼容旧版本式 id，
`port_find` 支持「前缀唯一匹配」。旧描述随版本下线，知识沉淀在 `TARGETS`/
`KNOWN_LIMITS` 字段。

## §13 设计不变量（贡献者请守）

1. **永远不碰 `/vendor`、不 patch HAL 二进制**（§9/§10 双重证伪）；
2. 可变数据一律 `/data/adb/vivocam/`，模块目录只读优先；
3. 插件是纯数据；新配置字段必须进白名单正则，过注入测试；
4. 任何"机型 X 可用"的声明必须来自**实机出片**，写进该包 `TARGETS`，
   工具输出只给"预测/可疑上界"；
5. 三向切换的向后兼容（旧命令、`cam_state` 单行码）是硬要求。
