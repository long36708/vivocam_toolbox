# vivocam-toolbox

> vivo 相机移植工具箱 —— KernelSU 模块。免重启在「原厂相机」与「其他 vivo 机型的新一代相机」之间切换，
> 支持 profile / 移植包插件化扩展，换机型、升版本都不用改代码。

**这是什么问题**：vivo 新机型（如 X500/X500PM，OriginOS 7）的 16.x 相机比旧机型原厂 13.x 多了不少能力
（新管线、新 UI、部分独占算法）。本模块把新机型相机固件以 **App 层移植**的方式装到旧机型上跑——
**只动 App 层，永不修改 `/vendor` HAL 二进制**（这条路我们已经系统性证伪过，见
[FINDINGS.md §9/§10](docs/FINDINGS.md)）。

```
一句话原理：resetprop 伪装项目码 → pm install 换相机 APK → 从内容寻址库池按清单铺 native 库。
全程免重启（约 15–20 秒）、不清数据；守护进程兜底相机更新后的目录重建；原厂状态随时可回。
```

---

## ⚠️ 先说边界（避免误用与法律风险）

- **本仓库不含任何 vivo 固件文件**。相机 APK / native 库是 vivo 专有固件，本仓库不下载、不分发、
  不提供其镜像链接——仓库里只有**工具**。
- 移植包请从**你自己设备上或你合法获取的固件解包**生成，一条命令：
  ```sh
  sh cam.sh addport /data/RNA/RNA_x500 x500      # 自动扫版本/$$MEAT、建库池、产插件并安装
  ```
  或走插件 zip：`cam.sh plugin install <本地 zip>`（WebUI 也有「导入插件」按钮）。
- 刷写涉及系统分区属性与系统应用替换，**root 风险自负**；任何时刻可用
  `cam.sh stock` / WebUI 一键回原厂，模块不残留对 `/vendor`、`/system` 的修改。

## 支持状态（如实声明）

| 目标机 | 移植包 | 状态 |
|---|---|---|
| X200 Pro mini（PD2419 · MT6991 · OriginOS 6） | X500 16.1.4.203 ／ X500PM 16.1.4.210 ／ X200PM-OS7 13.0.55.11 | 架构+切换+HAL 实测通过；**快门出片以用户实测为准** |
| 其他 vivo 机型 | — | 未匹配 profile 时安全降级为「仅原厂备份+诊断」模式，不伪装不铺库 |

> 判据铁律：**"可用" = 实机出片**，不是 App 能启动。各移植包已知限制见
> `cam.sh plugin info <family>` 的 `KNOWN_LIMITS`；已知模式差异（如 X500PM 默认拍照模式
> 必崩 HAL、而「原生光影」可出片）说明见 [FINDINGS.md §8/§11](docs/FINDINGS.md)。
>
> **回原厂后录像等功能闪退**？= 高→低版本相机数据残留（16.x 已升级库表，原厂相机迁移
> 失败），`cam.sh clear` 重置相机数据即可（设置与草稿会清，DCIM 媒体不受影响）；
> `cam.sh diagnose` 会自动归因。

## 环境要求

- **KernelSU 系管理器**（KernelSU / KernelSU-Next / BakaSU 等，`resetprop` 可用即可）并授予 root
- Android 机型系统应用为 `com.android.camera`（vivo 系通用）
- `/data` 余量 **> 10GB**（多帧合成缓冲落盘需要；满盘会表现为相机"卡死"/HAL 崩溃循环）
- 每个移植包约需 0.5GB（APK），库池共享后增量很小（跨包去重实测 ~86MB 全库）

## 安装

1. [Releases](../../releases) 下载 `vivocam-toolbox-vX.zip`（<100KB）；
2. KernelSU 管理器 → 模块 → 从本地存储安装 → **重启**；
3. 打开模块卡片上的 **WebUI** 按钮 → 按提示采集原厂属性快照（`cam.sh snapshot`）。

## 使用

### WebUI

状态卡 + 动态版本卡（原厂 / 每个已就绪的移植包）、可更新徽标、插件卡的「导出/卸载」、
「导入插件」（扫 `/sdcard/Download/vivocam/*.plugin.zip`）、重新应用属性、自检、崩溃归因。

### CLI

```sh
M=/data/adb/modules/vivocam-toolbox

sh $M/cam.sh stock                 # 回原厂（属性回放原厂快照 + 铺本机原厂库）
sh $M/cam.sh x500                  # 切到 X500 系（命令与版本解耦：自动指最新 x500-*）
sh $M/cam.sh x500pm
sh $M/cam.sh status / apply / clear

sh $M/cam.sh detect                # 机型识别与 profile 匹配结果
sh $M/cam.sh ports                 # 插件清单（就绪/未下载/校验状态）
sh $M/cam.sh snapshot              # 查看/重采原厂属性快照
sh $M/cam.sh selfcheck             # 全量体检
sh $M/cam.sh diagnose              # 最新 tombstone → 已知缺陷自动归因
sh $M/cam.sh probe [family]        # HAL scene 差集（注意：可疑上界，非崩溃预测）

sh $M/cam.sh plugin list|info|install|check|update|use|rollback|remove|build
sh $M/cam.sh plugin export <family> [--verified] [--with-profile] [--ver <版本>]
                                                   # 导出已装插件为分享 zip（WebUI 版本卡也有「导出」）
sh $M/cam.sh addport <固件解包根> <family> [伪装码]
```

## 架构一览（细节在文档里）

```
主模块（本仓库，只读为主）              /data/adb/vivocam（运行期，升级不丢）
├── cam.sh / 守护 / 开机脚本            ├── plugins/ports/<family>/   ← 移植包插件
├── profiles/<id>.profile  目标机       │     port.conf · names.lst · APK [· lib/]
└── ports/<family>.port    内置描述     ├── .versions/…               ← 可回滚归档
                                        ├── libpool/<md5>.so          ← 内容寻址库池
                                        ├── stock/<profile>/            ← 原厂库自备份
                                        └── original_props / state
```

四条支柱，都有取证编号可查：

1. **`$$MEAT` 是 App 层入场券**（[FINDINGS §4](docs/FINDINGS.md)）：可用伪装码 = APK 里
   带 `FeatureConfig_meat_PDxxxx$$MEAT` 类的码，通常**每包只有一个**。插件安装会扫 dex
   复核声明的伪装码，防呆。
2. **内容寻址库池**（[FINDINGS §12/§13](docs/FINDINGS.md)）：原厂 `lib/arm64` 是"实体+
   符号链接"混合，且跨机型库内容高度重合——两源并集 109 个**名字**只有 78 个唯一
   **内容**。移植包因此只需带"文件名清单"，库体共享，体积从 ×N 降到 ≈1 份。
3. **原厂属性快照回放**（[FINDINGS §5](docs/FINDINGS.md)）：`ro.product.*` 真值不在
   build.prop 而在 bootloader 注入的 `/proc/cmdline`；开机第一件事采快照，
   回原厂时**回放快照**——装到任何 vivo 机型，"原厂"都是那台机自己的原厂，零硬编码。
4. **插件发现优先级：用户目录 > 模块内置**（[ARCHITECTURE §4](docs/ARCHITECTURE.md)）：
   模块被 KSU 更新替换的是只读的代码；插件/库池/备份都在 `/data/adb/vivocam/`，升级不丢。

- 📄 完整架构：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)（含 §13 贡献者必守的设计不变量）
- 📄 技术发现取证集：[docs/FINDINGS.md](docs/FINDINGS.md)（§1–§15，含证伪记录）
- 📄 从固件解包打包移植包插件：[docs/BUILD-PLUGIN.md](docs/BUILD-PLUGIN.md)（镜像结构、构建、打 zip 分发）
- 🖼 架构图（浏览器打开）：[docs/plugin-architecture.html](docs/plugin-architecture.html)

## 安全性

- **插件 = 纯数据**。所有外部配置经非执行解析器读取（键白名单 + 值转义），
  `$( )` / 单引号逃逸 / `PATH=` 等注入路径实测全部落为字面量；最坏情况是装了个不能用的插件。
- APK sha256 钉死 + 安装时 `$$MEAT` 复核 + `pm install` 走 vivo 官方签名验证。
- 与守护进程用 `mkdir` 原子锁串行化；铺库以「铺完实数」校验，不信任计数。

## 扩展：不改代码的两类新增

| 想做的事 | 做法 |
|---|---|
| **新增目标机型**（别人/自己的另一台 vivo） | 复制仓库内置的填空模板 `profiles/x100.profile`（占位符填完前永不匹配，惰性安全），改几行即可，零代码改动。完整步骤见 [docs/ADD-NEW-DEVICE.md](docs/ADD-NEW-DEVICE.md) |
| **新增/升级源机型相机** | `cam.sh addport <解包镜像> <family>`；或打包成插件 zip 分享，用户 `plugin install`；在线可配 `repo.conf` + `index.conf`。完整步骤见 [docs/BUILD-PLUGIN.md](docs/BUILD-PLUGIN.md) |

> **别的 vivo 机型能用吗？** 能装——未识别机型自动降级为「仅备份+诊断」，绝不弄坏原厂相机。
> 能否**切换成功**取决于三层门槛：App 入场券（`$$MEAT`，通常不卡）、目标机 HAL 能否供给
> 移植包请求的 scene/流（真瓶颈，同 SoC 平台成功率高）、实机出片验证。逐机判定流程见
> [docs/ADD-NEW-DEVICE.md](docs/ADD-NEW-DEVICE.md)。

## 开发

```
vivocam_toolbox/
├── module/      模块全部文件（打包即 zip 根）
├── build.sh     打包 dist/*.zip（含语法检查、必需文件清单、防误含 APK 的自检）
└── docs/        架构 + 取证 + 架构图
```

`bash build.sh` → `dist/vivocam-toolbox-vX.zip`。脚本必须兼容
`/system/bin/sh`（Android mksh）与 busybox ash，语法检查已在 build.sh 内置。

## 免责声明 / Disclaimer

本项目为**互操作研究工具**，仅供在你自己拥有处置权的设备上使用。不绕过任何安全机制，
不修改受保护分区，不分发专有固件。因使用本项目造成的数据丢失、变砖等后果自负。
使用前建议备份重要数据。

**License: MIT**（仅覆盖本仓库代码与文档；vivo 固件版权与分发权利归 vivo，见
[LICENSE](LICENSE) 附注）。

---

### English (summary)

vivocam-toolbox is a **KernelSU module** for vivo devices: it switches the system camera app
between the stock build and camera firmwares ported from other vivo models **without rebooting**.
Porting happens strictly at the app layer — HAL/vendor binaries are never modified (that route
was systematically falsified; see `docs/FINDINGS.md` §9–§10).

Key design: target-device **profiles** (auto-detected via unspoofable props + bootloader cmdline),
**plugin packages** (metadata + filename manifest + APK, self-served by users from their own
firmware extracts — *this repo ships no proprietary firmware*), and a **content-addressed native
library pool** that dedupes shared libs across ports. Original stock state is always
restorable; unknown devices degrade to a diagnostics-only mode.

Status: verified end-to-end on PD2419 (X200 Pro mini). Other vivo models: architecture ready,
field reports welcome. License: MIT (code/docs only).
