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

# ---------- 未收录机型的一键 profile 生成 ----------
# cam.sh profile-gen / WebUI「自动生成 profile」（genericNote 卡片按钮）
#
# 采集→生成→自动验证三步一体：所有字段来自本机实测属性与原厂相机自动定位，
# 小白不再手填模板。安全边界（缺一不可）：
#   * 本机已匹配非 generic profile 时拒绝——用户目录优先于内置，自动档不许
#     遮蔽已验证的内置 profile
#   * 目标文件已存在时拒绝——里面可能有实测回填的 KNOWN_*_MODES，不许静默覆盖
#   * 生成后立即 profile_load 校验 + 复核 MATCH_KEYS 命中，失败即删不留半套
#
# 采集来源（全部多级候选，哪个有值用哪个）：
#   PROFILE_ID   = ro.product.name 小写化     PROFILE_NAME = marketname→oem.model→model
#   MATCH_KEYS   = name/vendor.device/sku 非空者  SOC = ro.boot.hardware→ro.board.platform
#   OS_GEN       = originos→vivo.os（仅展示用，不参与切换）
#   HWBBK_MAP    = ro.build.expect.hardware 的 "PD2415MA|PD2419MA" → "PD2415=PD2415MA …"
#   STOCK_APK/库目录/库数 = stock_apk_resolve / stock_libdir_resolve 自动定位
#   HAL_CFG_FMT  = /odm/etc/camera 有 .dat → dat，只有 .xml → xml
profile_generate(){
  if profile_select 2>/dev/null && [ "${GENERIC:-0}" != "1" ]; then
    echo "!! 本机已匹配 profile: $PROFILE_ID ($PROFILE_NAME)，无需生成"
    echo "   用户目录的自动档会遮蔽内置已验证档；确要重建请先删 $PLUGIN_PROFILES_DIR/ 下对应文件"
    return 1
  fi
  local name=$(getprop ro.product.name 2>/dev/null)
  [ -n "$name" ] || { echo "!! 读不到 ro.product.name，无法生成"; return 1; }
  local pid=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
  [ -n "$pid" ] || { echo "!! ro.product.name=$name 无法转成 profile id"; return 1; }
  local out="$PLUGIN_PROFILES_DIR/$pid.profile"
  [ -e "$out" ] && { echo "!! 已存在: $out（可能含实测回填），要重来先删它"; return 1; }

  local pname=$(getprop ro.product.marketname 2>/dev/null)
  [ -n "$pname" ] || pname=$(getprop ro.vivo.oem.model 2>/dev/null)
  [ -n "$pname" ] || pname=$(getprop ro.product.model 2>/dev/null)
  local vdev=$(getprop ro.product.vendor.device 2>/dev/null)
  local sku=$(getprop ro.boot.product.hardware.sku 2>/dev/null)
  local soc=$(getprop ro.boot.hardware 2>/dev/null)
  [ -n "$soc" ] || soc=$(getprop ro.board.platform 2>/dev/null)
  local osg=$(getprop ro.build.version.originos 2>/dev/null)
  [ -n "$osg" ] || osg=$(getprop ro.vivo.os.version 2>/dev/null)
  local cc=$(dumpsys media.camera 2>/dev/null | sed -n 's/.*Number of camera devices: //p' | head -1)
  cc=${cc:-0}

  local sapk slib sexpect=0
  sapk=$(stock_apk_resolve 2>/dev/null) \
    || { echo "!! 定位不到原厂相机 APK（pm path com.android.camera 无结果）"; return 1; }
  slib=$(stock_libdir_resolve 2>/dev/null)
  [ -n "$slib" ] && sexpect=$(ls "$slib"/*.so 2>/dev/null | wc -l)

  local hdir=${HAL_CFG_DIR:-/odm/etc/camera} hfmt=""
  if ls "$hdir"/StreamConfigInfo*.dat >/dev/null 2>&1; then hfmt=dat
  elif ls "$hdir"/StreamConfigInfo*.xml >/dev/null 2>&1; then hfmt=xml; fi

  local hwmap="" e
  for e in $(getprop ro.build.expect.hardware 2>/dev/null | tr '|' ' '); do
    case "$e" in *MA) hwmap="$hwmap ${e%MA}=$e" ;; esac
  done
  hwmap=${hwmap# }

  local mk="ro.product.name=$name"
  [ -n "$vdev" ] && mk="$mk ro.product.vendor.device=$vdev"
  [ -n "$sku" ] && mk="$mk ro.boot.product.hardware.sku=$sku"

  mkdir -p "$PLUGIN_PROFILES_DIR" || return 1
  {
    echo "# 由 cam.sh profile-gen 自动采集生成（$(date '+%Y-%m-%d')）——值全部来自本机实测"
    echo "# KNOWN_*_MODES 留空：出片实测后人工回填，探针预测不算数"
    echo "PROFILE_ID=$pid"
    echo "PROFILE_NAME=\"$pname\""
    echo "MATCH_KEYS=\"$mk\""
    echo "SOC=${soc:-}"
    [ -n "$osg" ] && echo "OS_GEN=$osg"
    echo "CAM_COUNT=$cc"
    echo "STOCK_PKG=com.android.camera"
    echo "STOCK_APK=$sapk"
    echo "STOCK_LIB_DIR=$slib"
    echo "STOCK_LIB_EXPECT=$sexpect"
    echo "STOCK_ACTIVITY=.CameraActivity"
    echo "HAL_CFG_DIR=$hdir"
    echo "HAL_CFG_FMT=$hfmt"
    echo "HAL_CORE_LIB=/vendor/lib64/libvcf_core.so"
    [ -n "$hwmap" ] && echo "HWBBK_MAP=\"$hwmap\""
    echo "KNOWN_GOOD_MODES=\"\""
    echo "KNOWN_BAD_MODES=\"\""
    echo "GENERIC=0"
  } > "$out"

  echo "✓ 已生成: $out"
  echo "  机型   : $pname（$pid）"
  echo "  匹配键 : $mk"
  echo "  SoC    : ${soc:-未知}  OS_GEN: ${osg:-未知}  相机数: $cc"
  echo "  原厂库 : $slib（$sexpect 项）"
  echo "  HAL    : $hdir 格式=${hfmt:-未识别（可手填 xml 或 dat）}"
  echo "  HWBBK  : ${hwmap:-未采集到（有快照回放，不影响主路径）}"

  # 自动验证：解析失败或匹配不中 → 删除，不留半套
  if ! profile_load "$out" || [ -z "${PROFILE_ID:-}" ]; then
    echo "!! 生成的 profile 解析失败，已删除"; rm -f "$out"; return 1
  fi
  if profile_match; then
    echo "✓ 自动验证通过：MATCH_KEYS 命中本机，profile 已生效"
    echo "下一步: 导入插件（WebUI「导入插件」/ plugin install）后 cam.sh port <family> 试切；"
    echo "        probe <family> 可先看 HAL scene 差集（可疑上界）"
  else
    echo "!! 自动验证失败：生成的 MATCH_KEYS 未命中本机（异常），已删除"
    rm -f "$out"; return 1
  fi
}
