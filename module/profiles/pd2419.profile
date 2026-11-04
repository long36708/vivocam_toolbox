# ============================================================
# profiles/pd2419.profile — vivo X200 Pro mini
#
# 匹配用「多键任意命中」（lib/profile.sh profile_match）：
#   本机实测 ro.product.name=PD2419 而 ro.product.vendor.device=PD2415，
#   单键会漏；且 post-fs-data.sh 会改 ro.product.device，绝不能用它。
#
# ⚠ 本文件里的 PD2419 只用于「识别本机是哪台机」，不用于伪装/还原。
#   伪装与还原都走 lib/props.sh 的快照回放，与本机型号无关——
#   这样同一份模块装到 X100 上，原厂值自动是 X100 的。
# ============================================================
PROFILE_ID=pd2419
PROFILE_NAME="X200 Pro mini"

# 任一键相等即匹配（值全部为实测真值，未被伪装污染）
MATCH_KEYS="ro.product.name=PD2419 ro.product.vendor.device=PD2415 ro.boot.product.hardware.sku=10111010111"

# --- 平台 ---
SOC=mt6991
OS_GEN=6
CAM_COUNT=5                    # dumpsys media.camera "Number of camera devices: 5"

# --- 原厂相机 ---
STOCK_PKG=com.android.camera
STOCK_APK=/system/app/VivoCamera/VivoCamera.apk
STOCK_LIB_DIR=/system/app/VivoCamera/lib/arm64
STOCK_LIB_EXPECT=76            # 53 实体 + 23 符号链接，cp -L 解析后 76
STOCK_ACTIVITY=.CameraActivity

# --- HAL ---
HAL_CFG_DIR=/odm/etc/camera
HAL_CFG_FMT=xml                # 本机全 .xml；OS7 系为 .dat(XOR mysecretkey)
HAL_CORE_LIB=/vendor/lib64/libvcf_core.so

# --- hardware.bbk 映射 ---
# 仅用于「无快照时的兜底还原」与「伪装码恰好等于项目码」的情形。
# 正常路径不依赖它：还原走 lib/props.sh 的快照回放。
# 依据：vendor/build.prop 的 ro.build.expect.hardware=PD2415MA|PD2419MA|PD2458MA
HWBBK_MAP="PD2415=PD2415MA PD2419=PD2419MA PD2458=PD2458MA"

# --- 已验证可用性（人工实机出片确认，探针预测不算） ---
KNOWN_GOOD_MODES="原生光影(X500PM 163 实测出片 4 张)"
KNOWN_BAD_MODES="拍照:X500PM下 ExtendCap空指针(0x17330c,不可修) 实况:必崩 录像:缺dolby编码器 LUT/超微距:缺HAL tag"

GENERIC=0
