#!/system/bin/sh
# ============================================================
# post-fs-data.sh — 开机：采集原厂属性快照 + 按状态伪装
#
# ★ 顺序很重要：
#   1. 先采集原厂属性快照（此刻 resetprop 尚未生效，读到的就是真值）
#   2. 再按 $VIVODIR/state 决定伪装或还原
#
# ★ 为什么不能用「原厂 = PD2419」这种写法：
#   真实值（ro.product.device / model.bbk / oem.model / hardware.bbk）
#   是 bootloader/device-tree 注入的，镜像 build.prop 里查不到，
#   每台机都不一样。装到 X100 上原厂就是 X100 的码。
#   所以统一走 lib/props.sh 的「快照 + 回放」。
#
# 属性改动是 resetprop 写内存，重启即失效 → 每次开机都能拿到未伪装真值，
# 快照是跨重启记住它的唯一可靠手段。
# ============================================================

MODDIR=${0%/*}
case "$MODDIR" in
  ""|"."|"$0") MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
VIVODIR=${VIVODIR:-/data/adb/vivocam}
export MODDIR VIVODIR

RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=$(ls /data/adb/*/bin/resetprop 2>/dev/null | head -1)
[ -n "$RP" ] && [ -x "$RP" ] || exit 0

. "$MODDIR/lib/conf.sh"
. "$MODDIR/lib/profile.sh"
. "$MODDIR/lib/props.sh"

# 1) 采集原厂快照（已有则跳过；当前值疑似伪装态时也不会误存）
props_snapshot_capture 0

# 2) 读状态
STATE=$VIVODIR/state
LEGACY=$MODDIR/cam_state
mode=""; pid=""
if [ -f "$STATE" ]; then
  mode=$(awk -F= '$1=="mode"{print $2; exit}' "$STATE")
  pid=$(awk -F= '$1=="port"{print $2; exit}' "$STATE")
elif [ -f "$LEGACY" ]; then
  # 旧版兼容：还没迁移时按老语义处理
  old=$(tr -d ' \r\n' < "$LEGACY")
  case "$old" in
    PD2609) mode=port; pid=x500 ;;
    PD2608) mode=port; pid=x500pm ;;
    *)      mode=stock ;;
  esac
fi

# 3) 非 port 模式：还原原厂（回放快照，不猜机型）
if [ "$mode" != "port" ] || [ -z "$pid" ]; then
  props_restore
  exit 0
fi

# 4) port 模式：取该 port 的目标伪装码
port_find "$pid" >/dev/null 2>&1 || { props_restore; exit 0; }
code=${TARGET_PROJECT:-$SRC_PROJECT}
[ -n "$code" ] || { props_restore; exit 0; }

props_spoof "$code"
