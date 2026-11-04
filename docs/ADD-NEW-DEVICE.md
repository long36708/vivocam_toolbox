# 接入一台新的目标机（Onboarding a new target device）

> 适用场景：你手上有一台新的 vivo 手机（如 X100），想用它跑本模块、或测试某个移植包。
> 全程**不需要改模块代码**；如果一切走通，欢迎把 profile 和实测结果提 PR。

## 0. 先理解三个门槛（为什么"能装"≠"能用"）

| 门槛 | 判据 | 卡住的表现 |
|---|---|---|
| ① App 入场券 | 移植包 APK 内带 `FeatureConfig_meat_<码>$$MEAT` | 启动即崩 `configMeatZoomSceneConfig is null` → 改 `TARGET_PROJECT` |
| ② HAL 供给（**真瓶颈**） | 目标机 stock HAL 能否供给移植包请求的 scene/流 | 预览/快门时 HAL SIGSEGV，**按模式分布**（同包 A 模式崩 B 模式好） |
| ③ 出片验证 | 实机拍照 + 手动快门 | 唯一有效判据；探针只给"可疑上界" |

经验规律：**目标机与移植源同 SoC 平台（联发科↔联发科）+ OS 代际相近** → ② 通过率高；
异平台（如高通 App 上 MTK HAL）历史上失败率高。本仓库已知反例见 FINDINGS §9–§12。

## 1. 装机与降级确认（任何 vivo 都安全）

1. Releases 下载模块 zip → KernelSU 安装 → 重启；
2. 打开模块目录 shell，跑：
   ```sh
   M=/data/adb/modules/vivocam-toolbox
   sh $M/cam.sh selfcheck      # 身份/路径/库池体检
   sh $M/cam.sh snapshot       # 采集本机原厂属性快照（还原依据，必须做）
   sh $M/cam.sh backup         # 本机原厂相机库自备份
   ```
3. 未匹配 profile 时 `detect` 显示 `_generic`，模块只会备份+诊断，
   **不会伪装、不会铺库**——此时切换命令会被拒绝，属预期行为。

`selfcheck` 输出里有三样东西决定后面怎么写 profile，抄下来：
`ro.product.name` / `ro.product.vendor.device` / `ro.boot.hardware`（SoC）。

## 2. 写第一个 profile

在 `/data/adb/vivocam/plugins/profiles/` 放一个 `<机型代号>.profile`
（用户插件目录，模块升级不丢；验证无误后再进仓库 `profiles/`）：

```sh
PROFILE_ID=<代号小写，如 pdXXXX 或型号名>
PROFILE_NAME="<市场名>"
# 多键任意命中；只用不会被伪装脚本改的属性（ARCHITECTURE §3）
MATCH_KEYS="ro.product.name=<代号> ro.product.vendor.device=<基座代号>"

SOC=<ro.boot.hardware 的值，如 mt69XX>
OS_GEN=<OriginOS 大版本数字>
CAM_COUNT=<dumpsys media.camera 的 devices 数>

STOCK_PKG=com.android.camera
# 原厂相机 APK / lib 路径：vivo 系通常在 /system/app/VivoCamera/，
# 少数新固件在 /product 或 /system_ext —— 用 `pm path` 与 ls 核实
STOCK_APK=/system/app/VivoCamera/VivoCamera.apk
STOCK_LIB_DIR=/system/app/VivoCamera/lib/arm64
STOCK_LIB_EXPECT=0        # 先填 0 不校验；跑通 `backup` 看实际数量后补上
STOCK_ACTIVITY=.CameraActivity

# HAL 配置格式：ODM 目录里有 *.dat → dat（XOR mysecretkey）；只有 *.xml → xml
HAL_CFG_DIR=/odm/etc/camera
HAL_CFG_FMT=<xml|dat>
HAL_CORE_LIB=/vendor/lib64/libvcf_core.so

HWBBK_MAP=""              # 若 ro.hardware.bbk 不是 项目码+MA，实测后补（仅无快照兜底用）
KNOWN_GOOD_MODES=""       # 出片验证后才填，别提前"预测"
KNOWN_BAD_MODES=""
GENERIC=0
```

> 约束：本文件由非执行解析器读取——**纯 `KEY=VALUE`**，不要写 `$( )` 等 shell 构造；
> 注释 `#` 可放行首或值后（值不带引号时 ` #` 后视为注释）。

## 3. 获取移植包（本仓库不分发固件）

两条路任选：

**A. 插件 zip（推荐给分享）**：由持有源机型固件解包的人生成——

```sh
# 在有解包镜像的机器上：
sh cam.sh plugin build <镜像根> <family> [伪装码]
# 产出 /data/adb/vivocam/plugins/ports/out/<family>-<ver>/
#   含 port.conf + names.lst + VivoCamera.apk + lib/*.so（自包含）
# 打 zip（port.conf 必须在 zip 根）分享 → 新机：
sh cam.sh plugin install <本地路径>/<family>-<ver>.plugin.zip
```

**B. addport 直连镜像**：目标机上就有解包镜像时
`sh cam.sh addport <镜像根> <family>`（建池+产插件+安装一步完成）。

## 4. 判定与试切（可逆，崩了能回）

```sh
sh cam.sh ports                # 插件就绪状态
sh cam.sh probe <family>       # HAL scene 差集（⚠ 可疑上界，含 App 侧常量误报）
sh cam.sh port <family>        # 切换（约 15–20s，免重启）
sh cam.sh selfcheck            # 版本/库数/属性一致性
am start -n com.android.camera/.CameraActivity
#   逐个模式测：预览 → 快门。崩了就：
sh cam.sh diagnose             # 自动归因到已知缺陷，给处置建议
sh cam.sh stock                # 一键回原厂（属性回放快照 + 原厂备份库）
```

常见归因 → 处置：

| diagnose 结果 | 下一步 |
|---|---|
| `moduleZoomConfig is null` | 把插件 `port.conf` 的 `TARGET_PROJECT` 改为 `plugin info` 里 "MEAT" 列表中的码（可多试几个），重装/重切 |
| `ExtendCap`/`getOutputHALNodeBufferInfos` | HAL 侧缺陷，换拍摄模式逐个测；记录可用模式矩阵 |
| `Cannot get correct stream id` | HAL 代际不匹配，该包大概率不可用，换包 |

## 5. 成功之后

- 把实测写进 profile：`KNOWN_GOOD_MODES` / `KNOWN_BAD_MODES`；
- 把验证结论写进插件声明：编辑 `port.conf` 的 `TARGETS=pdXXXX`（逗号分隔多个目标机）；
- **提 PR**：profile 文件 + 一句话验证说明（机型/固件版本/插件版本/哪些模式出片成功）。
  这才是本仓库真正需要的贡献——工具已经通用，缺的是各机型的实测矩阵。

## 红线（不要做）

- 不 patch `/vendor` HAL 二进制、不往 `/vendor` 塞库（FINDINGS §9/§10 双重证伪，只会换来更难的排查）；
- 不删 `/data/adb/vivocam/stock/` 与 `original_props`——那是你回原厂的路；
- 磁盘余量保持 >10GB。
