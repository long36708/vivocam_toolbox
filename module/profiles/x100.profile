# ============================================================
# profiles/x100.profile — 新目标机填空模板（以 vivo X100 为例）
#
# ⚠ 这是「模板」：MATCH_KEYS 里的尖括号占位符不可能等于任何真实属性值，
#   所以**填完之前它永远不会生效**——不影响现有功能，也绝弄不坏相机。
#   任何 vivo 机型都可以复制本文件改名使用（见 docs/ADD-NEW-DEVICE.md §2）。
#
# 使用步骤（在目标机的 root shell 里）：
#   1) 先跑体检，把打印的属性值抄下来：
#        sh /data/adb/modules/vivocam-toolbox/cam.sh selfcheck
#   2) 复制到自己插件目录再编辑（模块升级不丢、同名优先于内置）：
#        mkdir -p /data/adb/vivocam/plugins/profiles
#        cp /data/adb/modules/vivocam-toolbox/profiles/x100.profile \
#           /data/adb/vivocam/plugins/profiles/x100.profile
#   3) 填完下面的占位符后验证识别：
#        sh .../cam.sh detect          # 期望输出 profile: x100（或你改的 ID）
#   4) 再跑 selfcheck，确认「原厂相机 APK [存在]」与库目录条目数；
#   5) 采本机原厂库（数量与 STOCK_LIB_EXPECT 不符会明确报错）：
#        sh .../cam.sh backup
#   6) 就绪后再接移植包与试切（ADD-NEW-DEVICE §3–§4）。
#
# 语法约束（conf_read 是非执行解析器，docs/ARCHITECTURE.md §6）：
#   - 只能写 KEY=VALUE；**不要**用 $( )、反引号等 shell 构造（不会执行，
#     只会把字面量当值，反而更难排查）
#   - 值含空格请用双引号包住；行尾 " #…" 会被当注释剥掉
#   - MATCH_KEYS 内各项以空格分隔，单个 "键=值" 内部不能再有空格
# ============================================================
PROFILE_ID=x100
PROFILE_NAME="vivo X100"          # ← 改成实际市场名

# --- 必填 ①：身份匹配（任一键相等即命中）---------------------------
# 必须用「不会被伪装污染」的属性！本模块只改这四个：
#   ro.product.device / ro.product.model.bbk / ro.vivo.oem.model /
#   ro.hardware.bbk
# 所以下面三行采集出的值才是干净的（FINDINGS.md §5）：
#   getprop ro.product.name             # 例：PD2419
#   getprop ro.product.vendor.device    # 例：PD2415（基座项目码，可与上不同！）
#   getprop ro.boot.product.hardware.sku
# 多填几个键更稳（同一型号不同固件变体可能只改其中一个）。
MATCH_KEYS="ro.product.name=<填ro.product.name值> ro.product.vendor.device=<填vendor.device值>"

# --- 必填 ②：平台信息（selfcheck 会打印，照抄）---------------------
SOC=<getprop ro.boot.hardware 的值>      # 例：mt6991（联发科）/ 高通另写
OS_GEN=<OriginOS大版本数字>               # 例：6；未知就填 getprop ro.vivo.os.version 的主号
CAM_COUNT=<dumpsys media.camera 的 devices 数>

# --- 必填 ③：原厂相机路径（vivo 系通常同构，但务必核实）-------------
# 注意：换过相机的机器上 `pm path` 会指向 /data/app，那**不是**原厂件；
# 原厂 APK 在只读分区，用下面命令找（并记下你找到的实际路径）：
#   ls /system/app/VivoCamera /system/priv-app/VivoCamera \
#      /product/app/VivoCamera /system_ext/app/VivoCamera 2>/dev/null
STOCK_PKG=com.android.camera
STOCK_APK=/system/app/VivoCamera/VivoCamera.apk
STOCK_LIB_DIR=/system/app/VivoCamera/lib/arm64
STOCK_LIB_EXPECT=0     # 先留 0（不校验）；`cam.sh backup` 成功后把实际数量填这里
STOCK_ACTIVITY=.CameraActivity

# --- 必填 ④：HAL 配置格式（决定 probe 能否读目标机能力表）-----------
# 判定：ls /odm/etc/camera/StreamConfigInfo*
#   *.xml → xml（OriginOS 6 及更早）
#   *.dat → dat （OriginOS 7：循环 XOR 明文 XML，密钥 mysecretkey，
#                本仓库 lib/xor.awk 已实现解密，见 FINDINGS.md §1–§2）
HAL_CFG_DIR=/odm/etc/camera
HAL_CFG_FMT=<xml或dat>
HAL_CORE_LIB=/vendor/lib64/libvcf_core.so

# --- 选填：hardware.bbk 后缀映射 ------------------------------------
# 仅「无快照时」的兜底还原用（正常走 original_props 快照回放，见 props.sh）。
# 若本机 ro.hardware.bbk 不是 项目码+MA（对比 getprop 两项输出），在这里写：
#   HWBBK_MAP="PDxxxx=PDxxxxMA PDyyyy=PDyyyy"
HWBBK_MAP=""

# --- 选填：已验证可用性 ---------------------------------------------
# ⚠ **只填实机出片验证过的结果，不要填预测**。
# 探针给的是「可疑上界」（含 App 侧状态机常量误报），且 HAL 二进制缺陷
# 会让 scene 齐全的包照样崩（FINDINGS.md §7/§9/§11）。未实测请保持空。
KNOWN_GOOD_MODES=""
KNOWN_BAD_MODES=""

# 0 = 真实 profile（有伪装/铺库权）；_generic.profile 才用 1
GENERIC=0
