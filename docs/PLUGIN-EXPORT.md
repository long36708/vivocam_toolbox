# 插件导出分享（Plugin Export）设计

> 目标：把**已安装**的相机插件打成可分发的自包含 zip，放 `/sdcard/Download/vivocam/`，
> 发给其他 vivo 用户 `plugin install` 即用——**不需要解包镜像、不需要重跑 `plugin build`**。
> 本文是 2026-11 设计评审的定稿记录；实现与本文一一对应。

## 范围划分

**已全部落地（2026-11-14，6.0.0）**：自包含导出、legacy 合成、`--verified` 背书、CLI + WebUI、
busybox zip 探测 + 内置 store-only zip 兜底、同名原子覆盖、
**SCHEMA=2 profile 随包**（导出自动附带）、**`--ver` 归档导出**。

原二阶段两项随 6.0.0 提前完成，无遗留搁置项；后续新想法请开 issue 讨论，勿直接扩 schema。

## 接口

```
cam.sh plugin export [family] [--verified] [--ver <归档版本>]
```

- family 缺省取 `state_get port`；`cam.sh stock` 会清空该字段（cam.sh `state_set stock "" …`），
  所以原厂态下必须显式给 family——**导出与切换态解耦**：导的是"已安装的插件"，
  不是"正在运行的相机"，stock 态照样可导。
- `--verified`：把**本机 profile id** 追加进导出副本的 `TARGETS`（幂等，已在则跳过）。
  本机 profile 为 `_generic`/空时**拒绝该 flag**（没有诚实可背书的目标机，不写 `unknown`）；
  不带 `--verified` 的普通导出不受影响。
- **随包 profile（自动）**：本机**用户** profile（`plugins/profiles/<id>.profile`）存在时，
  自动打进 zip 的 `profiles/` 并把 `SCHEMA` 升为 2——接收方未收录该机型时开箱即用。
  本机 profile 为内置版（模块自带）时自动跳过：内置随包会在接收方用户目录形成旧副本、
  遮蔽未来内置更新。安装端语义见下。
- `--ver <版本>`：从 `.versions/<family>/<版本>/` 归档直接导出历史版本，
  不必先 `plugin use` 切回。归档总带 port.conf，走用户插件同一条组装管线。

## 导出流水线

| # | 步骤 | 失败处置 |
|---|---|---|
| 1 | family 解析（显式参数 > state port > 报错） | 报错要求显式指定 |
| 2 | 来源解析：用户插件（有 port.conf）直用；legacy `$VIVODIR/ports/<fam>/`（仅 APK+lst+.verified）走合成；都无 → "未安装" | 报错 |
| 3 | legacy 合成 conf：从描述符（`$MODDIR/ports/<fam>.port`）继承 `SCHEMA/TARGET_PROJECT/TARGETS/ALIASES/PORT_NAME/SRC_PROJECT/MODULE_MIN` 等声明字段，现算 `APK_SHA256/APK_SIZE`，`plugin_meat_scan` 复核 TARGET_PROJECT ∈ MEAT 集 | 复核失败拒绝 |
| 4 | 池命中校验：names.lst 逐名 `pool_path`，缺一个都拒绝 | 拒绝并列缺失名 |
| 5 | staging 组装（`$VIVODIR/plugins/ports/.export.$$`）：APK `ln -f`、库从池物化；`--verified` 只改 staging 的 port.conf **副本**——**源插件文件永不改动**；跑 `plugin_validate` 自检 | 自检失败清 staging 拒绝 |
| 6 | 打包前空间检查：staging 按 `du` 实测 ×1.2 对比 `df -P -k /sdcard` 剩余（组装后才知道库集真实体积） | 拒绝 |
| 7 | 打包：优先 `busybox zip -q -r`；无 zip applet 时落到**内置 store-only 打包器**（`lib/zip.sh`）→ `/sdcard/Download/vivocam/<fam>-<ver>.plugin.zip.part` → 同分区 `mv -f` 原子覆盖 | 两路都失败才报错 |
| 8 | 输出：zip 路径、sha256、大小、接收方三行安装指引 | — |

### 设计前提（评审中直接采纳，事实依据）

| 前提 | 依据 |
|---|---|
| 自包含（不提供 thin 导出） | 分享对端库池可能为空；thin 只适合同机迭代，是陷阱不是功能 |
| 导出后 `plugin_validate` 自检 | legacy 合成是新代码路径，MEAT 复扫 + sha256 秒级开销值得 |
| legacy TARGET_PROJECT 取自描述符 | `x500.port` 实证描述符字段齐全；伪装值无独立运行态存储（props.sh 只有原厂快照），conf/描述符的 TARGET_PROJECT 就是实际在跑的码 |
| WebUI 导入扫描捞到刚导出的包、可重装 = 往返验证 | 不做排除处理；重装有六步闸门 + 原子换位兜底 |
| 同名覆盖用 `.part` + 同分区 `mv -f` | 跨文件系统 mv 不原子，故 .part 落在 /sdcard 同分区 |
| 文件名沿用 `<family>-<ver>.plugin.zip` | 与 WebUI 导入扫描 `*.plugin.zip` 对齐 |
| **内置 store-only zip 打包器**（`lib/zip.sh`） | 真机实测：KSU 的 busybox 是 Magisk 构建（v1.36.1.1，358 applets），zip 系只有解包三件套，无打包 applet；toybox 亦无 zip/crc32。CRC-32 取自 **gzip 尾部 8 字节**（RFC 1952 的 CRC32+ISIZE，恰为 zip 头所需字段），头部以 hex 拼好后经 `xxd -r -p` 还原，正文 `cat` 直通；store 模式对已是压缩内容的 APK/.so 体积几乎无损 |
| awk 的 `print` 必须单行 | 字符串拼接靠紧邻，裸换行终止 print，后续行被当"裸表达式语句"静默丢弃（本文件配套 zip.sh 初版踩过：CD/EOCD 截断） |

## WebUI

- 每张**已就绪** port 版本卡加「导出」按钮（不只激活卡——与 CLI 语义对齐，
  诚实性责任由确认动作承担，不靠藏按钮）；
- 点击 → 确认框（勾选「我已在本机实机出片确认」→ 命令追加 `--verified`）→
  `exec("sh …/cam.sh plugin export <fam> [--verified]", 300)`（`ksu.exec` 默认 300s 超时
  足够 0.5GB 拷贝；`setBusy`/`appendLog` 既有模式）；
- busybox zip 缺失等错误走 appendLog 展示，不做按钮预灰。

## 触及文件

| 文件 | 改动 |
|---|---|
| `module/lib/plugin.sh` | +`plugin_export`（family 解析/来源解析/合成/校验/打包，~90 行） |
| `module/cam.sh` | `plugin` 用法块 + `export)` dispatch（take_lock/drop_lock，同其余子命令） |
| `module/webroot/index.html` | 版本卡导出按钮 + 确认框 + handler |
| `module/README.md` `README.md` | 命令速查加 export |
| `docs/BUILD-PLUGIN.md` | §0 路径表加"从已安装插件导出"，并交叉引用本文 |
| `CHANGELOG.md` | 版本条目 |

## 设计不变量对照（ARCHITECTURE §13）

1. **不碰 `/vendor`** ✓——全程用户数据区操作；
2. **可变数据在 `/data/adb/vivocam/`** ✓——staging 与产物均不写模块目录；
3. **插件纯数据** ✓——`TARGETS` 是 conf 白名单内既有字段，零新字段零新注入面；
4. **背书必须实机确认** ✓——`--verified` 是显式人工确认，工具不替人背书；`_generic` 拒绝；
5. **向后兼容** ✓——零新状态、零 schema 变化，纯新增只读操作。

## 验收清单

1. 活跃 family `plugin export` → zip 落 `/sdcard/Download/vivocam/`，validate 自检过；
2. WebUI「导入插件」往返安装同一 zip → 六步闸门过（版本归档路径正确）；
3. stock 态显式 family 导出成功；
4. legacy 注册目录（构造：删 port.conf 留 APK+lst+.verified）导出 → 合成 conf 继承描述符字段、MEAT 复核过；
5. 池缺库 → 拒绝并列名；
6. 无 `busybox zip` 环境 → 报错含 staging 路径 + PC 打包指引；
7. `--verified` + `_generic` → 拒绝该 flag；正常 profile → TARGETS 幂等追加；
8. 同名重复导出 → `.part` 原子覆盖；
9. `bash build.sh` 的 mksh + ash 语法检查过。
