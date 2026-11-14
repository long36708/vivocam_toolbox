#!/system/bin/sh
# ============================================================
# cam.sh — vivo 相机免重启切换（多机型版）
#
# 用法:
#   sh cam.sh stock              原厂相机（按 profile 的 STOCK_APK）
#   sh cam.sh x500               最新的 X500 移植包（当前 16.1.4.203）
#   sh cam.sh x500pm             X500PM 16.1.4.163 (别名 → port x500pm-163)
#   sh cam.sh port <port-id>     按 port id 切换（新机型/新移植包）
#   sh cam.sh status             查看当前状态
#   sh cam.sh apply              重启后重新应用当前配置
#   sh cam.sh clear              清除相机数据（不自动清，出问题再清）
#   sh cam.sh detect             显示机型识别与 profile
#   sh cam.sh ports              列出移植包及就绪状态
#   sh cam.sh pool [migrate]     库池状态 / 从模块 backup 迁移
#   sh cam.sh backup             原厂库自备份（首次或原厂更新后）
#   sh cam.sh probe [port-id]    HAL 兼容性探针
#   sh cam.sh diagnose           崩溃归因（Java 闪退 + tombstone 双通道）
#   sh cam.sh profile-gen        未收录机型一键生成 profile（自动采集+验证）
#   sh cam.sh selfcheck          全量自检
#   sh cam.sh migrate            从旧版（硬编码布局）迁移
#   sh cam.sh force-port <id>    对未识别机型强制应用（跳过 profile 检查）
#
# 原理：切换 = resetprop 改机型属性(运行时生效) + pm install -r -d 换 APK
# + 铺 native 库。全程不重启。属性改动只对"之后新起的进程"生效，脚本会
# force-stop 相机保证下次打开是新进程。
#
# 设计文档: docs/ARCHITECTURE.md
# ============================================================

MODDIR=${0%/*}
case "$MODDIR" in
  ""|"."|"$0") MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac
[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
MOD=$MODDIR
RP=/data/adb/ksu/bin/resetprop
LOG=/data/local/tmp/vc/cam.log
mkdir -p /data/local/tmp/vc
: > $LOG
log(){ echo "[cam] $*" | tee -a $LOG; }

# 运行期数据（库池/原厂备份/移植包）；与模块目录分离，卸载模块可保留
VIVODIR=${VIVODIR:-/data/adb/vivocam}
export MODDIR VIVODIR

. "$MODDIR/lib/conf.sh"
. "$MODDIR/lib/profile.sh"
. "$MODDIR/lib/libpool.sh"
. "$MODDIR/lib/backup.sh"
. "$MODDIR/lib/port.sh"
. "$MODDIR/lib/probe.sh"
. "$MODDIR/lib/props.sh"
. "$MODDIR/lib/plugin.sh"
. "$MODDIR/lib/zip.sh"

STATE=$VIVODIR/state           # 格式: mode=<stock|port> port=<id> profile=<id>
LEGACY_STATE=$MODDIR/cam_state # 旧版单行机型码，迁移用

cur_ver(){ dumpsys package com.android.camera 2>/dev/null | grep -m1 "versionName=" | sed 's/.*versionName=//'; }
cur_dir(){ dumpsys package com.android.camera 2>/dev/null | grep -m1 "codePath=/data/app" | sed 's/.*codePath=//' | tr -d ' \r'; }

# ---------- 状态文件 ----------
state_get(){ # $1=键
  awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE" 2>/dev/null
}
state_set(){ # $1=mode $2=port $3=profile
  mkdir -p "$VIVODIR"
  { echo "mode=$1"; echo "port=$2"; echo "profile=$3"; } > "$STATE"
}

# ---------- 属性伪装 / 还原 ----------
# 全部走 lib/props.sh：
#   伪装 = props_spoof <port 的目标码>（hardware.bbk 按 profile 的 HWBBK_MAP）
#   还原 = props_restore（回放首次开机采集的原厂快照，与本机型号无关）
# 这样模块装到 X100 上，原厂值自动就是 X100 的，不存在"原厂=PD2419"的假设。
set_props(){ props_spoof "$1"; }
clear_props(){ props_restore; }

# ---------- 铺库 ----------
# 与 service.sh 串行化：两边都会 rm -rf 目标 lib 目录再重铺，并发会互相
# 删掉对方刚写的文件（实测出现过 106/108 这种非期望值）。
# 用 mkdir 原子锁（不用 flock：本机 toybox flock 只接受已打开的 fd 号，
# 不支持 `exec 9>file` 写法，实测报 "Bad file descriptor"）
LOCKD=$VIVODIR/.lib.lock.d
take_lock(){
  mkdir -p "$VIVODIR" 2>/dev/null
  local i=0
  while [ $i -lt 60 ]; do
    if mkdir "$LOCKD" 2>/dev/null; then
      echo $$ > "$LOCKD/pid" 2>/dev/null
      return 0
    fi
    # 陈旧锁清理：持有者进程已死
    local op=$(cat "$LOCKD/pid" 2>/dev/null)
    if [ -n "$op" ] && ! kill -0 "$op" 2>/dev/null; then
      rm -rf "$LOCKD" 2>/dev/null
      continue
    fi
    sleep 1; i=$((i+1))
  done
  log "⚠ 等库锁超时，继续执行"
  return 0
}
drop_lock(){ rm -rf "$LOCKD" 2>/dev/null; return 0; }

chown_restorecon(){ # $1=/data/app 相机目录
  local D=$1
  chown -R system:system "$D/lib" 2>/dev/null
  chmod 755 "$D/lib" "$D/lib/arm64" 2>/dev/null
  find "$D/lib" -type f -name "*.so" -exec chmod 755 {} \; 2>/dev/null
  restorecon -R "$D/lib" 2>/dev/null
}

fill_stock(){
  local D=$(cur_dir); [ -z "$D" ] && { log "!! 无 /data/app 相机"; return 1; }
  take_lock
  local pid=$(state_get profile); [ -n "$pid" ] || pid=${PROFILE_ID:-_generic}
  # 备份不存在则现做（首启/原厂更新后）
  if ! stock_ready "$pid" "$STOCK_LIB_EXPECT"; then
    log "原厂备份缺失，现做..."
    local slib="${STOCK_LIB_DIR:-}"
    [ -d "$slib" ] || slib=$(stock_libdir_resolve) || slib=""
    [ -n "$slib" ] || { log "!! 找不到原厂 lib 目录"; return 1; }
    stock_backup "$pid" "$slib" "${STOCK_LIB_EXPECT:-0}" || {
      # 兜底：旧版随包的 backup/stock_lib
      if [ -d "$MOD/backup/stock_lib" ]; then
        log "回退到随包 backup/stock_lib"
        rm -rf "$D/lib"; mkdir -p "$D/lib/arm64"
        cp -f "$MOD/backup/stock_lib"/*.so "$D/lib/arm64/" 2>/dev/null
        chown_restorecon "$D"
        log "libs=$(ls "$D/lib/arm64"/*.so 2>/dev/null | wc -l) (bundled)"
        return 0
      fi
      return 1
    }
  fi
  stock_fill "$pid" "$D/lib/arm64" "$STOCK_LIB_EXPECT" | while read -r l; do log "$l"; done
  chown_restorecon "$D"
  drop_lock
}

fill_port(){
  local pid=$1 D=$(cur_dir)
  [ -z "$D" ] && { log "!! 无 /data/app 相机"; return 1; }
  take_lock
  local lst=$(port_list_file "$pid")
  [ -f "$lst" ] || { log "!! 名字清单缺失: $lst"; return 1; }
  local want=$(port_expect "$pid")
  pool_fill "$lst" "$D/lib/arm64" "$want" | while read -r l; do log "$l"; done
  chown_restorecon "$D"
  drop_lock
}

# ---------- 安装 APK ----------
install_apk(){ # $1=apk路径
  local APK=$1
  [ -f "$APK" ] || { log "!! APK 缺失: $APK"; return 1; }
  # pm install 的 system_server 只能读 shell_data_file 标签的
  # /data/local/tmp 下的文件，从 /data/adb 直接装会被 SELinux 拒
  local TMP=/data/local/tmp/cam_install.apk
  log "复制 APK 到 /data/local/tmp ..."
  cp -f "$APK" "$TMP" || { log "!! 复制失败"; return 1; }
  chcon u:object_r:shell_data_file:s0 "$TMP" 2>/dev/null
  chmod 644 "$TMP"
  log "安装 $(basename "$APK") ..."
  local OUT
  OUT=$(pm install -r -d "$TMP" 2>&1 | tail -1)
  rm -f "$TMP"
  log "install: $OUT"
  case "$OUT" in
    *Success*) sleep 3; return 0 ;;
    *) log "!! 安装失败，中止（未铺库，当前版本=$(cur_ver)）"; return 1 ;;
  esac
}

# ---------- 切换 ----------
switch_stock(){
  profile_select || { log "!! 无可用 profile"; return 1; }
  [ "$PROFILE_ID" = "_generic" ] && log "⚠ 未识别机型，仅恢复原厂（不伪装）"
  state_set stock "" "$PROFILE_ID"

  # 还原依赖快照：没有就现采一次（若当前已是伪装态会失败，需重启后采）
  if ! props_have_snapshot; then
    log "原厂属性快照缺失，尝试采集..."
    props_snapshot_capture 0 && log "✓ 已采集原厂快照"       || log "⚠ 采集失败：当前可能处于伪装态。还原将退化为按 ro.product.name 推断"
  fi

  clear_props
  log "props: model.bbk=$(getprop ro.product.model.bbk)"

  am force-stop "${STOCK_PKG:-com.android.camera}" 2>/dev/null; sleep 1
  local WANT=${STOCK_VER:-}
  if [ -n "$WANT" ] && [ "$(cur_ver)" = "$WANT" ]; then
    log "已是 $WANT，跳过安装"
  else
    local sapk=$(stock_apk_resolve) || { log "!! 找不到原厂相机 APK（profile 与自动探测均失败）"; return 1; }
    [ "$sapk" = "${STOCK_APK:-}" ] || log "原厂 APK 自动定位: $sapk"
    install_apk "$sapk" || return 1
  fi
  fill_stock
  log "完成: $(cur_ver)（数据未清除，设置保留）"
  status
}

switch_port(){ # $1=port id 或别名
  local want=$1
  port_find "$want" || { log "!! 未知移植包: $want（用 cam.sh ports 查看）"; return 1; }
  local pid=$PORT_ID

  profile_select || { log "!! 无可用 profile"; return 1; }
  if [ "${GENERIC:-0}" = "1" ]; then
    log "!! 本机型未匹配任何 profile，不支持移植（仅备份+诊断）"
    log "   如需强行尝试: cam.sh force-port $pid"
    return 1
  fi
  port_installed "$pid" || {
    log "!! 移植包未就绪: $pid"
    log "   需要 APK $((${APK_SIZE:-0}/1048576))MB；见 cam.sh ports"
    return 1
  }

  case ",${TARGETS:-}," in
    *",$PROFILE_ID,"*) ;;
    *) [ -n "${TARGETS:-}" ] && log "⚠ 该插件声明验证过的机型: $TARGETS（本机 $PROFILE_ID 不在内，未经实测）" ;;
  esac

  local props=${TARGET_PROJECT:-$SRC_PROJECT}
  state_set port "$pid" "$PROFILE_ID"
  log "=== 切换到 $pid ($PORT_NAME) 伪装 $props ==="
  set_props "$props"
  log "props: model.bbk=$(getprop ro.product.model.bbk)"

  am force-stop "${STOCK_PKG:-com.android.camera}" 2>/dev/null; sleep 1
  if [ "$(cur_ver)" = "$APK_VER" ]; then
    log "已是 $APK_VER，跳过安装"
  else
    install_apk "$(port_apk "$pid")" || return 1
  fi
  fill_port "$pid"
  log "完成: $(cur_ver)，打开相机即可使用（数据未清除，设置保留）"
  status
}

# ---------- 其他命令 ----------
do_clear(){
  pm clear com.android.camera >/dev/null 2>&1 && log "已清除相机数据（设置恢复默认）"
  # 清数据不动库，但保险按当前状态重铺
  if [ "$(state_get mode)" = "port" ]; then
    local pid=$(state_get port)
    port_find "$pid" >/dev/null 2>&1 && fill_port "$pid"
  else
    fill_stock
  fi
}

# 从解包镜像接入一个移植包（= plugin build + 安装）
#
#   cam.sh addport <镜像根> <port-id> [伪装码]
#
# 自动：读版本号（UTF-16 manifest）→ 扫 $$MEAT → 建库池与名字清单
# （符号链接重映射进镜像）→ 产出自包含插件目录 → 校验安装。
addport(){
  local root=$1 pid=$2 tgt=$3 tgts=${4:-}
  if [ -z "$root" ] || [ -z "$pid" ]; then
    echo "用法: cam.sh addport <镜像根> <port-id> [伪装码] [TARGETS]"; return 1
  fi
  plugin_build "$root" "$pid" "$tgt" "$tgts" || return 1
  # 找到刚产出的目录（唯一）
  local out
  out=$(ls -d "$PLUGIN_PORTS_DIR/out/$pid-"*/ 2>/dev/null | head -1)
  [ -n "$out" ] || { echo "!! build 产物缺失"; return 1; }
  plugin_install "${out%/}" || return 1
  # 安装已完成（out 目录里的库已入池、APK 已就位），清理临时产物
  rm -rf "$PLUGIN_PORTS_DIR/out"
  echo
  echo "下一步: sh $MODDIR/cam.sh port $pid"
}

# 原厂属性快照（多机型正确性的基础）
# 首次伪装前必须有一次快照，否则还原时无从得知"原厂是什么"
snapshot_cmd(){
  local force=${1:-0}
  echo "=== 原厂属性快照 ==="
  props_status
  echo
  if props_have_snapshot && [ "$force" != "1" ]; then
    echo "快照已存在，不覆盖（要重采集：cam.sh snapshot --force）"
    return 0
  fi
  if props_snapshot_capture "$force"; then
    echo "✓ 已采集: $(props_file)"
    sed 's/^/  /' "$(props_file)"
  else
    echo "✗ 采集失败"
    echo "  若当前正处于伪装态，请先 cam.sh stock 还原后再采集；"
    echo "  或重启后立即执行（开机时属性尚未被伪装）。"
    return 1
  fi
}

# 铺库后立刻读库数会拿到瞬时值：pm install 会重建 /data/app 目录，
# dexopt 也会短暂改写，实测出现过 49/108 这类假数。稳定读：取最大值重试。
lib_count(){
  local best=0 i=0 c D
  while [ $i -lt 5 ]; do
    D=$(cur_dir)
    c=$(ls "$D/lib/arm64"/*.so 2>/dev/null | wc -l)
    [ "$c" -gt "$best" ] && best=$c
    # 连续两次相同即认为稳定
    if [ "$i" -gt 0 ] && [ "$c" = "$prev" ]; then break; fi
    prev=$c; i=$((i+1)); sleep 1
  done
  echo "$best"
}

status(){
  local m=$(state_get mode) p=$(state_get port) pf=$(state_get profile)
  log "状态: 版本=$(cur_ver) | 属性=$(getprop ro.product.model.bbk) | lib=$(lib_count)"
  log "      mode=${m:-stock} port=${p:-—} profile=${pf:-—} | 真机型=$(target_project)"
}

detect(){
  echo "=== 机型识别 ==="
  echo "真机型码（ro.product.name）: $(target_project)"
  echo "vendor.device: $(getprop ro.product.vendor.device)  board: $(getprop ro.product.board)"
  echo "当前伪装: $(getprop ro.product.model.bbk)"
  echo
  if profile_select; then
    echo "profile: $PROFILE_ID ($PROFILE_NAME)"
    echo "SoC=$SOC OS_GEN=$OS_GEN CAM_COUNT=$CAM_COUNT HAL_FMT=$HAL_CFG_FMT"
    [ "${GENERIC:-0}" = "1" ] && echo "⚠ 兜底 profile：仅备份+诊断，不提供移植"
  else
    echo "!! 无可用 profile"
  fi
}

# 机器可读输出（供 WebUI 解析，一行一个 key=value）
info(){
  profile_select >/dev/null 2>&1
  echo "module=$MODDIR"
  echo "target=$(target_project)"
  echo "profile=$PROFILE_ID"
  echo "profile_name=$PROFILE_NAME"
  echo "generic=${GENERIC:-0}"
  echo "spoofed=$(getprop ro.product.model.bbk)"
  echo "mode=$(state_get mode)"
  echo "curport=$(state_get port)"
  echo "ver=$(cur_ver)"
  local D=$(cur_dir)
  echo "libs=$(ls "$D/lib/arm64"/*.so 2>/dev/null | wc -l)"
  echo "pool=$(ls "$VIVODIR"/libpool/*.so 2>/dev/null | wc -l)"
  local pf=$(state_get profile); [ -n "$pf" ] || pf=$PROFILE_ID
  echo "stock_backup=$(ls "$VIVODIR/stock/$pf"/*.so 2>/dev/null | wc -l)"
  # 移植包/插件（用户插件优先，内置未覆盖的其后）
  local line pid src n=0 upd
  while read -r line; do
    [ -n "$line" ] || continue
    pid=${line%% *}; src=${line#* }
    port_find "$pid" || continue
    n=$((n+1))
    echo "port_src_$n=$src"
    echo "port_id_$n=$pid"
    echo "port_name_$n=$PORT_NAME"
    echo "port_ver_$n=${PLUGIN_VER:-$APK_VER}"
    echo "port_target_$n=${TARGET_PROJECT:-$SRC_PROJECT}"
    echo "port_size_$n=$(( ${APK_SIZE:-0} / 1048576 ))"
    echo "port_expect_$n=${LIB_EXPECT:-0}"
    if port_installed "$pid"; then echo "port_ready_$n=1"; else echo "port_ready_$n=0"; fi
    echo "port_targets_$n=${TARGETS:-}"
  done <<EOF
$(port_enumerate)
EOF
  echo "port_count=$n"
  # 可更新信息（plugin check 的缓存，不在这里联网）
  if [ -f "$UPDATES_CACHE.upd" ]; then
    while IFS= read -r upd; do
      case "$upd" in plugin_upd_*) echo "$upd" ;; esac
    done < "$UPDATES_CACHE.upd"
  fi
}

apply(){ # 重启后属性回原值，按 state 重新应用
  local m=$(state_get mode) p=$(state_get port)
  case "$m" in
    port) [ -n "$p" ] && switch_port "$p" || { log "state 损坏"; return 1; } ;;
    *)    switch_stock ;;
  esac
}

# 旧版迁移：散装布局 → 插件目录。一次性、可重入。
# legacy 注册目录用版本式 id（$VIVODIR/ports/x500pm-210/），所以这里
# 按 legacy 目录枚举，再经 port_find 前缀匹配挂到 family。
migrate(){
  log "=== 迁移到插件布局 ==="
  mkdir -p "$PLUGIN_PORTS_DIR" "$PLUGIN_VERSIONS_DIR"
  local d id fam apk lst sha ver n=0

  # 1) legacy 注册目录（有实体 APK 的）
  for d in "$PORT_ROOT"/*/; do
    [ -d "$d" ] || continue
    id=${d%/}; id=${id##*/}
    case "$id" in .*) continue ;; esac
    apk="$d/VivoCamera.apk"; lst="$d/names.lst"
    [ -f "$apk" ] && [ -f "$lst" ] || continue
    port_find "$id" || continue          # 前缀匹配 → 内置 family 描述
    fam=$PORT_ID
    [ -d "$PLUGIN_PORTS_DIR/$fam" ] && { log "插件已存在: $fam"; continue; }
    mkdir -p "$fam" 2>/dev/null; mkdir -p "$PLUGIN_PORTS_DIR/$fam" || continue
    ln -f "$apk" "$PLUGIN_PORTS_DIR/$fam/VivoCamera.apk" 2>/dev/null       || cp -f "$apk" "$PLUGIN_PORTS_DIR/$fam/VivoCamera.apk" || continue
    cp -f "$lst" "$PLUGIN_PORTS_DIR/$fam/names.lst" || continue
    ver=${PLUGIN_VER:-$APK_VER}
    sha=$(sha256sum "$PLUGIN_PORTS_DIR/$fam/VivoCamera.apk" 2>/dev/null | cut -d' ' -f1)
    {
      echo "SCHEMA=1"
      echo "PLUGIN_KIND=port"
      echo "PLUGIN_VER=$ver"
      echo "PORT_ID=$fam"
      echo "ALIASES=\"$id\""
      echo "PORT_NAME=\"$PORT_NAME\""
      echo "SRC_PROJECT=${SRC_PROJECT:-}"
      echo "MEAT_CODES=\"${MEAT_CODES:-${TARGET_PROJECT:-}}\""
      echo "TARGET_PROJECT=${TARGET_PROJECT:-$SRC_PROJECT}"
      echo "APK_VER=$APK_VER"
      echo "APK_SIZE=${APK_SIZE:-0}"
      echo "APK_SHA256=$sha"
      echo "APK_URL=${APK_URL:-}"
      echo "LIBNAME_LIST=names.lst"
      echo "LIB_EXPECT=${LIB_EXPECT:-0}"
      echo "MODULE_MIN=5"
      echo "TARGETS=${TARGETS:-}"
      echo "KNOWN_LIMITS=\"${KNOWN_LIMITS:-}\""
    } > "$PLUGIN_PORTS_DIR/$fam/port.conf"
    chmod 644 "$PLUGIN_PORTS_DIR/$fam/port.conf" "$PLUGIN_PORTS_DIR/$fam/names.lst"
    log "✓ 迁移: $id → 插件 $fam ($ver)"
    n=$((n+1))
  done

  # 2) 内置 family 无 legacy 注册的：提示等 plugin install/update
  local line pid2
  for line in $(port_enumerate); do
    pid2=${line%% *}
    [ -d "$PLUGIN_PORTS_DIR/$pid2" ] && continue
    port_find "$pid2" >/dev/null 2>&1 || continue
    port_apk "$pid2" >/dev/null 2>&1 || log "待安装: $pid2（cam.sh plugin install / update）"
  done

  # 3) state 里的版本式 id 改写为 family
  if [ -f "$STATE" ]; then
    local sp=$(state_get port)
    if [ -n "$sp" ]; then
      if port_find "$sp" >/dev/null 2>&1 && [ -n "${PORT_ID:-}" ] && [ "$PORT_ID" != "$sp" ]; then
        state_set "$(state_get mode)" "$PORT_ID" "$(state_get profile)"
        log "state: port $sp → $PORT_ID"
      fi
    fi
  fi

  log "迁移完成（$n 个）。校验: cam.sh plugin list / cam.sh ports"
}

# 强制对未识别机型应用 port（用户明确要求时）
force_port(){
  local want=$1
  port_find "$want" || { log "!! 未知移植包: $want"; return 1; }
  local pid=$PORT_ID
  port_installed "$pid" || { log "!! 移植包未就绪"; return 1; }
  log "⚠ 强制模式：跳过 profile 兼容性检查"
  local props=${TARGET_PROJECT:-$SRC_PROJECT}
  state_set port "$pid" "forced"
  set_props "$props"
  am force-stop "${STOCK_PKG:-com.android.camera}" 2>/dev/null; sleep 1
  [ "$(cur_ver)" = "$APK_VER" ] || install_apk "$(port_apk "$pid")" || return 1
  fill_port "$pid"
  status
}

case "$1" in
  stock)     switch_stock ;;
  x500|x500pm) switch_port "$1" ;;
  port)
    [ -n "$2" ] || { echo "用法: cam.sh port <port-id>"; exit 1; }
    switch_port "$2" ;;
  force-port)
    [ -n "$2" ] || { echo "用法: cam.sh force-port <port-id>"; exit 1; }
    force_port "$2" ;;
  clear)     do_clear ;;
  status)    status ;;
  apply)     apply ;;
  detect)    detect ;;
  info)      info ;;
  plugin)
    shift
    sub=${1:-list}
    case "$sub" in
      list)
        echo "family         来源   版本            状态"
        port_status_all
        echo
        echo "可更新检查: cam.sh plugin check（需配置 $REPO_CONF）"
        echo "归档版本:"
        local ff vv d2
        for ff in "$PLUGIN_PORTS_DIR"/*/; do
          [ -d "$ff" ] || continue
          d2="$PLUGIN_VERSIONS_DIR/$(basename "$ff")"
          [ -d "$d2" ] || continue
          for vv in $(ls "$d2" 2>/dev/null); do
            [ -d "$d2/$vv" ] && echo "  $(basename "$ff") $vv"
          done
        done
        ;;
      info)
        [ -n "$2" ] || { echo "用法: plugin info <family>"; exit 1; }
        port_find "$2" || exit 1
        echo "family        : $PORT_ID"
        echo "名称          : $PORT_NAME"
        echo "版本          : ${PLUGIN_VER:-$APK_VER}"
        echo "来源          : $PORT_SOURCE"
        echo "伪装码        : ${TARGET_PROJECT:-$SRC_PROJECT}（MEAT: ${MEAT_CODES:-未声明}）"
        echo "APK           : $(port_apk "$PORT_ID")"
        echo "APK sha256    : ${APK_SHA256:-未声明}"
        echo "验证过的机型  : ${TARGETS:-未声明}"
        echo "已知限制      : ${KNOWN_LIMITS:-无}"
        ;;
      install)
        [ -n "$2" ] || { echo "用法: plugin install <zip|目录> [--thin]"; exit 1; }
        take_lock
        plugin_install "$2" "$3"
        rc=$?; drop_lock; exit $rc ;;
      check)
        plugin_check ;;
      update)
        [ -n "$2" ] || { echo "用法: plugin update <family|all>"; exit 1; }
        take_lock
        if [ "$2" = "all" ]; then
          rc=0
          line=""; fam2=""
          for line in $(port_enumerate); do
            fam2=${line%% *}
            plugin_update "$fam2" || rc=1
          done
        else
          plugin_update "$2"; rc=$?
        fi
        drop_lock; exit $rc ;;
      use)
        [ -n "$3" ] || { echo "用法: plugin use <family> <版本>"; exit 1; }
        take_lock; plugin_use "$2" "$3"; rc=$?; drop_lock; exit $rc ;;
      rollback)
        [ -n "$2" ] || { echo "用法: plugin rollback <family>"; exit 1; }
        take_lock; plugin_rollback "$2"; rc=$?; drop_lock; exit $rc ;;
      remove)
        [ -n "$2" ] || { echo "用法: plugin remove <family>"; exit 1; }
        take_lock; plugin_remove "$2"; rc=$?; drop_lock; exit $rc ;;
      build)
        shift
        take_lock; plugin_build "$@"; rc=$?; drop_lock; exit $rc ;;
      export)
        shift
        take_lock; plugin_export "$@"; rc=$?; drop_lock; exit $rc ;;
      *)
        echo "用法: cam.sh plugin {list|info|install|check|update|use|rollback|remove|build|export}"
        echo "  list                 已装插件与归档版本"
        echo "  info <family>        插件详情"
        echo "  install <zip|目录>   本地导入（校验+原子安装）"
        echo "  check                检查插件源里的可用更新"
        echo "  update <family|all>  从插件源升级"
        echo "  use <family> <ver>   切换活跃版本"
        echo "  rollback <family>    回退上一版"
        echo "  remove <family>      移除用户插件"
        echo "  build <镜像> <family> [伪装码]   从解包镜像产出插件"
        echo "  export <family> [--verified] [--with-profile] [--ver <版本>]"
        echo "                       把已装插件打成分享 zip（随包 profile / 归档版本，docs/PLUGIN-EXPORT.md）"
        exit 1 ;;
    esac ;;
  ports)     port_status_all ;;
  pool)
    case "$2" in
      migrate) mkdir -p "$MOD/lib"; pool_migrate "$MOD" "$MOD/lib" ;;
      *)       pool_status ;;
    esac
    ;;
  backup)
    profile_select
    slib="${STOCK_LIB_DIR:-}"
    [ -d "$slib" ] || slib=$(stock_libdir_resolve) || slib=""
    [ -n "$slib" ] || { echo "!! 找不到原厂 lib 目录"; exit 1; }
    stock_backup "$PROFILE_ID" "$slib" "${STOCK_LIB_EXPECT:-0}" ;;
  probe)
    profile_select
    port_find "${2:-x500pm-163}" && probe_target "$PROFILE_ID" "$PORT_ID" ;;
  diagnose)  diagnose ;;
  selfcheck) selfcheck ;;
  addport)
    shift
    addport "$@" ;;
  snapshot)
    if [ "$2" = "--force" ] || [ "$2" = "force" ]; then snapshot_cmd 1; else snapshot_cmd 0; fi ;;
  profile-gen)
    profile_generate ;;
  migrate)   migrate ;;
  *)
    echo "用法: $0 {stock|x500|x500pm|port <id>|status|apply|clear|detect|info|ports|pool|backup|probe|diagnose|selfcheck|snapshot|plugin ...|addport <镜像根> <family>|migrate|force-port <id>}"
    exit 1 ;;
esac
