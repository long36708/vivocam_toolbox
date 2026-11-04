#!/system/bin/sh
# ============================================================
# uninstall.sh — 模块卸载时恢复真实机型属性
#
# 为什么需要：post-fs-data.sh 会 resetprop 伪装机型码。若不恢复，
# 卸载模块后属性残留到下次重启，原厂相机会因"属性=PD260x 但 APK 是
# 原厂 13.x"而崩（docs/FINDINGS.md §6 的机制）。
#
# 运行期数据 /data/adb/vivocam（库池 85MB + 移植包 ~1GB）默认保留，
# 便于重装后免重下；要彻底清理见下方注释。
# ============================================================

MODDIR=${0%/*}
case "$MODDIR" in
  ""|"."|"$0") MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
VIVODIR=${VIVODIR:-/data/adb/vivocam}
export MODDIR VIVODIR

RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=$(ls /data/adb/*/bin/resetprop 2>/dev/null | head -1)

# 还原走快照回放（与本机是什么机型无关）。快照缺失时退回 ro.product.name 推断。
if [ -n "$RP" ] && [ -x "$RP" ]; then
  . "$MODDIR/lib/profile.sh" 2>/dev/null
  . "$MODDIR/lib/props.sh" 2>/dev/null
  if command -v props_restore >/dev/null 2>&1; then
    props_restore
  else
    real=$(getprop ro.product.name)
    [ -n "$real" ] && {
      $RP ro.product.device    "$real"
      $RP ro.product.model.bbk "$real"
      $RP ro.vivo.oem.model    "$real"
      $RP ro.hardware.bbk      "$real"
    }
  fi
fi

# 彻底清理运行期数据（默认不执行，保留以便重装）：
#   rm -rf /data/adb/vivocam
