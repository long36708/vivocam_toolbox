#!/system/bin/sh
# ============================================================
# lib/profile.sh — 目标机 profile / 移植包 port 解析层
#
# 设计要点（docs/ARCHITECTURE.md §1、docs/FINDINGS.md §4）：
#   * 配置一律走 conf_read（非执行解析器）——插件来自外部，
#     绝不允许把 conf 当 shell 代码执行
#   * 身份匹配「多键任意命中」：本机 ro.product.name=PD2419 而
#     ro.product.vendor.device=PD2415，单键会漏
#   * 身份属性必须未被伪装污染：ro.product.device 会被 post-fs-data 改掉
#   * port 发现顺序：用户插件 > 模块内置（同 family 覆盖）
# ============================================================

[ -n "$MODDIR" ] || MODDIR=${MODDIR:-${0%/*}}
VIVODIR=${VIVODIR:-/data/adb/vivocam}

PROFILE_DIR="$MODDIR/profiles"
PORT_DIR="$MODDIR/ports"

# 配置字段白名单
PROFILE_FIELDS='^(PROFILE_ID|PROFILE_NAME|MATCH_KEYS|SOC|OS_GEN|CAM_COUNT|STOCK_PKG|STOCK_APK|STOCK_LIB_DIR|STOCK_LIB_EXPECT|STOCK_ACTIVITY|HAL_CFG_DIR|HAL_CFG_FMT|HAL_CORE_LIB|PROPS_MAP|HWBBK_MAP|KNOWN_GOOD_MODES|KNOWN_BAD_MODES|GENERIC)$'
PORT_FIELDS='^(SCHEMA|PLUGIN_KIND|PLUGIN_VER|PORT_ID|ALIASES|PORT_NAME|SRC_PROJECT|MEAT_CODES|TARGET_PROJECT|APK_VER|APK_SIZE|APK_SHA256|APK_URL|LIBNAME_LIST|LIB_EXPECT|LIB_SHA256|MODULE_MIN|TARGETS|KNOWN_LIMITS|CHANGELOG)$'

# ---------- 身份读取（只用干净属性） ----------
target_project(){
  local v
  v=$(getprop ro.product.name 2>/dev/null)
  [ -n "$v" ] || v=$(getprop ro.product.vendor.device 2>/dev/null)
  [ -n "$v" ] || v=$(getprop ro.product.device 2>/dev/null)
  echo "$v"
}

identity_keys(){
  local p
  for p in ro.product.name ro.product.vendor.device ro.boot.product.hardware.sku \
           ro.product.board ro.boot.hardware; do
    local v=$(getprop "$p" 2>/dev/null)
    [ -n "$v" ] && echo "$p=$v"
  done
}

# ---------- profile 解析 ----------
# 兼容旧调用约定：载入后直接可读 PROFILE_* 变量
profile_load(){
  local f=$1
  [ -f "$f" ] || return 1
  unset PROFILE_ID PROFILE_NAME MATCH_KEYS SOC OS_GEN CAM_COUNT \
        STOCK_PKG STOCK_APK STOCK_LIB_DIR STOCK_LIB_EXPECT STOCK_ACTIVITY \
        HAL_CFG_DIR HAL_CFG_FMT HAL_CORE_LIB KNOWN_GOOD_MODES KNOWN_BAD_MODES \
        PROPS_MAP HWBBK_MAP GENERIC
  conf_read "$f" "$PROFILE_FIELDS" "" || return 1
  PROFILE_FILE=$f
  return 0
}

profile_match(){
  local k v
  for kv in ${MATCH_KEYS:-}; do
    k=${kv%%=*}; v=${kv#*=}
    [ -z "$v" ] && continue
    [ "$(getprop "$k" 2>/dev/null)" = "$v" ] && return 0
  done
  return 1
}

# 选 profile：用户插件目录优先，其次内置；首个命中即用，否则 _generic
profile_select(){
  local d f
  for d in "${PLUGIN_PROFILES_DIR:-}" "$PROFILE_DIR"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*.profile; do
      [ -f "$f" ] || continue
      case "${f##*/}" in _generic.profile) continue ;; esac
      profile_load "$f" || continue
      profile_match && return 0
    done
  done
  if profile_load "$PROFILE_DIR/_generic.profile"; then
    PROFILE_ID=_generic
    return 0
  fi
  return 1
}

# ---------- port 解析 ----------
# port_load <conf路径>
# 载入后可用：PORT_ID/PORT_NAME/SRC_PROJECT/APK_VER/... 及
#   PORT_SOURCE=user|builtin  PORT_PLUGIN_DIR=<插件目录，仅 user>
port_load(){
  local f=$1
  [ -f "$f" ] || return 1
  unset PORT_ID PORT_NAME SRC_PROJECT APK_VER APK_SIZE APK_SHA256 APK_URL \
        LIBNAME_LIST LIB_EXPECT TARGET_PROJECT KNOWN_LIMITS \
        PLUGIN_VER SCHEMA MEAT_CODES ALIASES TARGETS MODULE_MIN
  PORT_SOURCE=builtin
  PORT_PLUGIN_DIR=""
  if [ "${f##*/}" = "port.conf" ]; then
    conf_read "$f" "$PORT_FIELDS" "" || return 1
    PORT_SOURCE=user
    PORT_PLUGIN_DIR=$(dirname "$f")
  else
    conf_read "$f" "$PORT_FIELDS" "" || return 1
  fi
  PORT_FILE=$f
  # 兼容：老描述没有 PLUGIN_VER 时视 APK_VER 为版本
  [ -n "${PLUGIN_VER:-}" ] || PLUGIN_VER=${APK_VER:-}
  return 0
}

# 按 family / 别名找 port；用户插件优先于内置
# 找到后 PORT_* 变量已就绪
port_find(){
  local want=$1 f a
  # 1) 用户插件（精确 id / 别名）
  for f in "${PLUGIN_PORTS_DIR:-}"/*/port.conf; do
    [ -f "$f" ] || continue
    port_load "$f" || continue
    [ "${PORT_ID:-}" = "$want" ] && return 0
    for a in ${ALIASES:-}; do [ "$a" = "$want" ] && return 0; done
  done
  # 2) 内置 .port（精确 / 别名）
  for f in "$PORT_DIR"/*.port; do
    [ -f "$f" ] || continue
    port_load "$f" || continue
    [ "${PORT_ID:-}" = "$want" ] && return 0
    for a in ${ALIASES:-}; do [ "$a" = "$want" ] && return 0; done
  done
  # 3) 前缀唯一匹配（want-xxx，兼容旧版本式 id）
  local cnt=0 cand=""
  for f in "${PLUGIN_PORTS_DIR:-}"/*/port.conf "$PORT_DIR"/*.port; do
    [ -f "$f" ] || continue
    port_load "$f" || continue
    case "${PORT_ID:-}" in
      "$want"-*) cnt=$((cnt+1)); cand=$f ;;
    esac
  done
  if [ "$cnt" = "1" ]; then
    port_load "$cand" && return 0
  elif [ "$cnt" -gt 1 ]; then
    echo "!! '$want' 匹配到多个移植包，请写完整 id：" >&2
    local g
    for g in "${PLUGIN_PORTS_DIR:-}"/*/port.conf "$PORT_DIR"/*.port; do
      [ -f "$g" ] || continue
      port_load "$g" >/dev/null 2>&1
      case "${PORT_ID:-}" in "$want"-*) echo "   $PORT_ID" >&2 ;; esac
    done
  fi
  return 1
}

# 枚举所有 family（用户插件优先，内置未覆盖的排后）
# 输出 "family user|builtin" 每行一条
port_enumerate(){
  local f fam seen=" "
  for f in "${PLUGIN_PORTS_DIR:-}"/*/port.conf; do
    [ -f "$f" ] || continue
    fam=$(conf_get "$f" "$PORT_FIELDS" PORT_ID 2>/dev/null)
    [ -n "$fam" ] || continue
    echo "$fam user"
    seen="$seen$fam "
  done
  for f in "$PORT_DIR"/*.port; do
    [ -f "$f" ] || continue
    fam=$(conf_get "$f" "$PORT_FIELDS" PORT_ID 2>/dev/null)
    [ -n "$fam" ] || continue
    case "$seen" in *" $fam "*) continue ;; esac
    echo "$fam builtin"
  done
}

port_list(){
  port_enumerate | awk '{print $1}'
}
