# ============================================================
# profiles/_generic.profile — 兜底 profile（未匹配任何已知机型）
#
# 设计目标：未知机型不崩、不误伤。
# 能力限定为：原厂库自备份 + 诊断 + 切回原厂。
# 不提供任何移植包入口——HAL 兼容性未知，盲装可能"能开能预览、
# 一按快门就崩"，反而更难排查。
#
# ⚠ 这里不写任何机型码。原厂值的还原走 lib/props.sh 的快照回放，
#   所以本模块装到任何 vivo 机型上，"原厂"就是那台机自己的原厂。
# ============================================================
PROFILE_ID=_generic
PROFILE_NAME="未识别机型"

MATCH_KEYS=""                  # 永不主动命中；只作兜底

# 注意：本文件由 conf_read 非执行解析器加载，不能写 shell 构造；
# SoC/OS 版本等信息由 detect/selfcheck 在显示时动态补。
SOC=
OS_GEN=
CAM_COUNT=0

# 原厂相机路径按 vivo 系常见布局猜，实际以 pm path / 探测结果为准
STOCK_PKG=com.android.camera
STOCK_APK=/system/app/VivoCamera/VivoCamera.apk
STOCK_LIB_DIR=/system/app/VivoCamera/lib/arm64
STOCK_LIB_EXPECT=0             # 0 = 不校验数量（未知机型库数不同）
STOCK_ACTIVITY=.CameraActivity

HAL_CFG_DIR=/odm/etc/camera
HAL_CFG_FMT=auto               # 探测时自动识别 .xml / .dat
HAL_CORE_LIB=/vendor/lib64/libvcf_core.so

# 未知机型不猜 hardware.bbk 后缀，直接用同码（还原仍优先走快照）
HWBBK_MAP=""

KNOWN_GOOD_MODES=""
KNOWN_BAD_MODES=""

GENERIC=1
