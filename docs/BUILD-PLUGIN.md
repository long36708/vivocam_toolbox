# 打包移植包插件（Building a port plugin）

> 适用场景：你手上有一台**源机型**的固件解包（如 X500 的 system 分区），想把它的相机
> 做成 vivocam-toolbox 插件——装到自己手机上，或打包 zip 分享给别人。
> 全程**不需要改模块代码**；本文与 `cam.sh` / `lib/plugin.sh` / `lib/libpool.sh` 的实际
> 实现一一对应。本仓库不分发固件，解包镜像请从你自己合法获取的固件生成。

## 0. 路径怎么选

| 你想做的事 | 命令 | 产物 |
|---|---|---|
| 装到**自己手机**上用（有解包镜像） | `cam.sh addport <镜像根> <family>` | 建池 + 产插件 + 安装一步完成；`out/` 临时产物自动清理 |
| 做成 zip **分享给别人**（有解包镜像） | `cam.sh plugin build <镜像根> <family>` | `/data/adb/vivocam/plugins/ports/out/<family>-<ver>/` 目录，自己打 zip |
| 分享**本机已装**的插件（不需要解包镜像） | `cam.sh plugin export <family> [--verified] [--ver <版本>]` | 自包含 zip 直接落 `/sdcard/Download/vivocam/`；自动随包本机用户 profile（SCHEMA=2，接收方未收录该机型时开箱即用，内置 profile 自动跳过）；定稿见 [PLUGIN-EXPORT.md](PLUGIN-EXPORT.md) |

前两条路径共用同一套扫描与构建逻辑（`plugin_build`）；区别只是 build 产物装不装、留不留。
`export` 是第三条路：从已安装的插件（或 legacy 注册目录）反向打包，适合"插件在我手机上
跑得好好的，想发给同机型朋友"——没有固件镜像也能分享。

## 1. 前置条件

- 已装好本模块的 vivo 目标机（KernelSU 系，root 可用）；
- **构建必须在设备上跑**，不能在 PC 上：脚本依赖设备上的 busybox/toybox
  （`unzip -p`、`md5sum`、`stat -c`），产物写入 `/data/adb/vivocam/`；
- `/data` 余量充足：解包镜像 + APK（约 0.5GB）+ 库池；
- 源机型固件的**解包镜像**（见 §2）。

## 2. 镜像根结构（最容易错的一步）

`plugin_build` 与 `pool_build_from_image` 要求的目录布局：

```
<镜像根>/
└── system/
    └── system/                      ← 双层 system：payload.bin / super.img 解包的典型布局
        ├── app/VivoCamera/
        │   ├── VivoCamera.apk       ← 必需（也兼容单层 <镜像根>/system/app/VivoCamera/）
        │   └── lib/arm64/*.so       ← 必需；多为指向 /system/lib64 的符号链接
        ├── build.prop               ← 读 ro.vivo.system.product.model 作 SRC_PROJECT
        └── lib64/                   ← 符号链接的解析目标，缺失会静默缺库
```

⚠️ **符号链接是这个环节唯一的深坑**（FINDINGS §12/§13 的教训）：镜像里
`lib/arm64/*.so` 大多是指向 `/system/lib64/xxx_nN.so` 的**绝对路径符号链接**，且在
设备上是悬空的。构建器把链接目标**重映射进镜像内部**解析
（`/system/lib64/X` → `<镜像根>/system/system/lib64/X`）——绝不会解析到手机自己的
`/system`（那读到的是目标机的库，甚至是被模块覆盖过的库）。

自检清单：

```sh
ls <镜像根>/system/system/app/VivoCamera/VivoCamera.apk    # APK 在不在
ls <镜像根>/system/system/lib64 | wc -l                    # 链接目标在不在（应有一批 *_n*.so）
```

构建时若输出 `WARN unresolved-link <名字>`，说明该库在镜像里找不到目标——**库清单会
少这条，装出来就是缺库的插件**。出现多条 WARN 时先补全镜像再继续，不要硬装。

## 3. 构建

```sh
M=/data/adb/modules/vivocam-toolbox

# 自装：建池 + 产插件 + 校验安装，一条命令
sh $M/cam.sh addport /data/RNA/RNA_x500 x500

# 分享用：只产出可分发目录
sh $M/cam.sh plugin build /data/RNA/RNA_x500 x500
```

参数：

| 参数 | 含义 |
|---|---|
| `<镜像根>` | §2 的解包根目录 |
| `<family>` | 插件名（= `PORT_ID`，也是安装目录名与切换命令名 `cam.sh port <family>`）；只能用**字母、数字、`-`、`_`**（不含点——版本号由 `ALIASES` 承载，装时校验会拒绝） |
| `[伪装码]` | 可选，写入 `TARGET_PROJECT`；**不传则自动取扫描到的第一个 `$$MEAT` 码** |
| `[TARGETS]` | 可选，已在哪些目标机实测过（逗号分隔项目码）；**默认留空**——构建器不许替人背书"已验证"，出片实测后人工补 |

构建过程（自动，全部扫出来，不允许手填）：

1. 定位 VivoCamera.apk（双层/单层布局都试），从 AndroidManifest 抓 `X.Y.Z.W` 版本号；
2. 解包 dex 扫 `FeatureConfig_meat_PD*$$MEAT` 类，列出**全部**可用伪装码；
3. 扫 `lib/arm64`（符号链接按 §2 重映射）建 `names.lst`（加载名 + `_nN` 目标名都收），
   库体按 md5 合并进内容寻址库池；
4. 生成 `port.conf`（版本 / sha256 / MEAT / LIB_EXPECT 全部实测值）；
5. 拷 APK + 从池物化库集到产出目录。

产出目录：

```
/data/adb/vivocam/plugins/ports/out/x500-16.1.4.203/
├── port.conf       ← 元数据（自动生成，别手改除 TARGET_PROJECT/TARGETS）
├── names.lst       ← 库文件名清单
├── VivoCamera.apk  ← ~0.5GB
└── lib/*.so        ← 自包含库集
```

伪装码选错不会装失败（只要在 MEAT 集合里），但相机启动即崩
（`configMeatZoomSceneConfig is null`）→ `cam.sh diagnose` 归因后，改产出目录
`port.conf` 的 `TARGET_PROJECT` 重装重切即可，可逐个试。

## 4. 打 zip 与分发

```sh
# 规范：port.conf 在 zip 根（多包一层目录也能装，但不规范）
cd /data/adb/vivocam/plugins/ports/out/x500-16.1.4.203
zip -r ../x500-16.1.4.203.plugin.zip .
```

产物体积：插件 zip ≈ 480–560MB（APK 占绝对大头）；第二个同代插件再打包时，
库已在池里去重，增量 ≈ 只有 APK。

> 设备上没有 `zip` 命令时（toybox 不带），把 `out/<family>-<ver>/` 整目录拉到 PC
> 打包即可——保持 port.conf 在 zip 根（多包一层目录安装时也能自动下探兼容）。

分发到目标手机的三种方式：

| 方式 | 操作 |
|---|---|
| 本地导入（一等公民） | zip 放 `/sdcard/Download/vivocam/*.plugin.zip` → WebUI 点「导入插件」 |
| CLI | `sh $M/cam.sh plugin install <zip 或目录>` |
| 在线源（可选） | 仓库维护者配 `repo.conf` 的 `REPO_URL` 指向 `index.conf`，用户 `plugin check/update` |

## 5. 对端安装时的校验闸门

`plugin_validate` 按序检查，**任一失败即拒绝安装、不留半套**（原子换位，旧版本自动
归档可 `rollback`）：

1. 结构三件套（根 `port.conf` / `names.lst` / `VivoCamera.apk`）；
2. `SCHEMA` 版本受支持；
3. `MODULE_MIN ≤ 当前模块版本`；
4. APK sha256 与声明一致；
5. **`$$MEAT` 复核**：重扫 dex，`TARGET_PROJECT` 必须真实存在；
6. `names.lst` 行数 == 声明的 `LIB_EXPECT`。

→ 坏包在安装时就被拦下，不会等到切换相机才炸。安全模型见
[ARCHITECTURE.md §6](ARCHITECTURE.md)：插件是纯数据，装恶意插件的最坏结果是
"装了个不工作的插件"。

## 6. 装完之后

```sh
sh $M/cam.sh ports            # 插件就绪状态
sh $M/cam.sh probe x500       # HAL scene 差集（⚠ 可疑上界，非崩溃预测）
sh $M/cam.sh port x500        # 切换（约 15–20s，免重启）
sh $M/cam.sh selfcheck        # 版本/库数/属性一致性
am start -n com.android.camera/.CameraActivity   # 逐模式实测：预览 → 快门
```

实测出片后：

- 把目标机项目码补进产出插件 `port.conf` 的 `TARGETS`；
- 把可用/必崩模式写进目标机 profile 的 `KNOWN_GOOD_MODES` / `KNOWN_BAD_MODES`；
- 提 PR（profile + 一句话验证说明）。判定与试切的完整流程、diagnose 归因表见
  [ADD-NEW-DEVICE.md §4–§5](ADD-NEW-DEVICE.md)。

## 7. 自包含 vs thin

| 模式 | 内容 | 适用 |
|---|---|---|
| 自包含（默认） | 带 `lib/`，安装时合并入库池 | 分发给别人、新目标机 |
| `plugin install <zip> --thin` | 只装清单，不带库 | 同一台机迭代升级 APK、确认对端库池已有该代库集 |

## 红线（不要做）

- **不在 PC 上构建**——脚本与库池都在设备侧；
- **不用半份镜像**——只解出 `app/` 没有 `system/system/lib64/` 会静默缺库
  （唯一线索是构建期的 `WARN unresolved-link`）；
- 不要手改自动生成的 `port.conf` 字段（sha256/LIB_EXPECT/MEAT）——装时会复核，
  改了只会换来校验失败；只有 `TARGET_PROJECT`（换伪装码）与 `TARGETS`（实测背书）
  是给人改的；
- 不删 `/data/adb/vivocam/stock/` 与 `original_props`——那是回原厂的路；
- 只从可信来源拿别人的插件 zip：sha256 只保完整性，不保可信度（ARCHITECTURE §11）。
