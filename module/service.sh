#!/system/bin/sh
# ============================================================
# service.sh — 常驻守护，自动补齐相机 native so（profile 驱动）
#
# 读取 $VIVODIR/state:
#   mode=stock          → 铺 profile 对应的「原厂库自备份」
#   mode=port port=<id> → 按该 port 的名字清单从公共库池铺
#
# 为什么常驻：系统安装/更新相机会重建 /data/app 目录（哈希路径变化），
# 新目录 lib/ 是空的；只跑一次会错过重装时机。
#
# 为什么不再用 cam_state 单行机型码：多机型后"机型码"不足以表达
# "用哪个移植包"，且库集已合并为公共池（设计文档 §1.2/§3.2）。
# ============================================================

MODDIR=${0%/*}
case "$MODDIR" in
  ""|"."|"$0") MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
VIVODIR=${VIVODIR:-/data/adb/vivocam}
export MODDIR VIVODIR

LOG=/data/local/tmp/vc/service.log
mkdir -p /data/local/tmp/vc
: > $LOG
log(){ echo "[svc] $*" >> $LOG; }

. "$MODDIR/lib/conf.sh"
. "$MODDIR/lib/profile.sh"
. "$MODDIR/lib/libpool.sh"
. "$MODDIR/lib/backup.sh"
. "$MODDIR/lib/port.sh"

STATE=$VIVODIR/state
state_get(){ awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE" 2>/dev/null; }

cur_dir(){ dumpsys package com.android.camera 2>/dev/null | grep -m1 "codePath=/data/app" | sed 's/.*codePath=//' | tr -d ' \r'; }

# 解析当前应铺的「来源」：输出 "stock <dir> <want>" 或 "port <lst> <want>"
desired(){
  local mode=$(state_get mode) pid=$(state_get port) want src
  if [ "$mode" = "port" ] && [ -n "$pid" ]; then
    src="$VIVODIR/ports/$pid/names.lst"
    want=$(port_expect "$pid")
    echo "port $src $want"
  else
    local pf=$(state_get profile)
    [ -n "$pf" ] || { profile_select 2>/dev/null; pf=$PROFILE_ID; }
    src="$VIVODIR/stock/$pf"
    want=0
    if profile_load "$MODDIR/profiles/$pf.profile" 2>/dev/null; then
      want=${STOCK_LIB_EXPECT:-0}
    fi
    echo "stock $src $want"
  fi
}

LAST_LIB=""
LAST_SIG=""

# 与 cam.sh 串行化：两边都会 rm -rf 目标 lib 目录再重铺，并发会互相
# 删掉对方刚写的文件（实测出现过 106/108 这种非期望值）。
# 用 mkdir 原子锁（本机 toybox flock 只接受已打开的 fd 号，不能用 exec 9>）。
LOCKD=$VIVODIR/.lib.lock.d
take_lock(){
  mkdir -p "$VIVODIR" 2>/dev/null
  if mkdir "$LOCKD" 2>/dev/null; then
    echo $$ > "$LOCKD/pid" 2>/dev/null
    return 0
  fi
  # 陈旧锁清理（持有者已死）
  local op=$(cat "$LOCKD/pid" 2>/dev/null)
  if [ -n "$op" ] && ! kill -0 "$op" 2>/dev/null; then
    rm -rf "$LOCKD" 2>/dev/null
  fi
  return 1
}
drop_lock(){ rm -rf "$LOCKD" 2>/dev/null; return 0; }

restore_lib(){
  local kind src want
  set -- $(desired); kind=$1; src=$2; want=$3

  if [ "$kind" = "stock" ]; then
    [ -d "$src" ] || { log "no stock backup yet: $src"; return 1; }
  else
    [ -f "$src" ] || { log "no port list yet: $src"; return 1; }
  fi

  local D=$(cur_dir)
  [ -z "$D" ] && { log "no /data/app camera yet"; return 1; }

  local LIB="$D/lib/arm64"
  local CNT=$(ls "$LIB"/*.so 2>/dev/null | wc -l)

  # 目录变了 或 数量不足 → 重建
  # 注意：必须同时比较「来源种类+期望数」，否则 cam.sh 切换后若目标目录
  # 恰好还是同一个（版本没变、只是换了 port），会漏重建。
  local SIG="$kind:$want"
  local need=0
  [ "$LIB" != "$LAST_LIB" ] && need=1
  [ "$SIG" != "$LAST_SIG" ] && need=1
  [ "${want:-0}" != "0" ] && [ "$CNT" -lt "$want" ] && need=1
  if [ "$need" = "1" ]; then
    log "rebuild: kind=$kind want=$want current=$CNT"
    if [ "$kind" = "stock" ]; then
      stock_fill "$(state_get profile)" "$LIB" "$want" 2>&1 | while read -r l; do log "$l"; done
    else
      pool_fill "$src" "$LIB" "$want" 2>&1 | while read -r l; do log "$l"; done
    fi
    chown -R system:system "$D/lib" 2>/dev/null
    chmod 755 "$D/lib" "$LIB"
    find "$D/lib" -type f -name "*.so" -exec chmod 755 {} \; 2>/dev/null
    restorecon -R "$D/lib" 2>/dev/null
    # 记录「实际铺成」的结果：只有数量达标才算稳定，否则下轮继续修
    local got=$(ls "$LIB"/*.so 2>/dev/null | wc -l)
    log "restored=$got"
    if [ "${want:-0}" = "0" ] || [ "$got" = "$want" ]; then
      LAST_LIB="$LIB"
      LAST_SIG="$SIG"
    fi
  fi
  return 0
}

# 等 /data/app 就绪
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -d /data/app ] && break
  sleep 3
done
sleep 10

# 首启自备份（docs/ARCHITECTURE.md §9 多机型要求）：原厂库来自 /system 分区（不可变），
# 任何时刻快照都安全。没有备份就先做一份——装到任何机型上，原厂都是
# 那台机自己的原厂，这是"误伤防护"的根基。
pf=""
profile_select >/dev/null 2>&1
pf=$PROFILE_ID
if ! stock_ready "$pf" 0; then
  if take_lock; then
    slib="${STOCK_LIB_DIR:-}"
    [ -d "$slib" ] || slib=$(stock_libdir_resolve)
    if [ -n "$slib" ]; then
      log "首启自备份: $pf <- $slib"
      stock_backup "$pf" "$slib" 0 2>&1 | while read -r l; do log "$l"; done
    else
      log "!! 首启自备份失败：找不到原厂 lib 目录"
    fi
    drop_lock
  fi
fi

# 常驻监测（每 15s）。cam.sh 切换后会改写 state，本进程每轮重读，
# 所以切换后下一轮即生效（cam.sh 自己也铺一次，这里只兜底）。
while true; do
  if take_lock; then
    restore_lib
    drop_lock
  fi
  sleep 15
done
