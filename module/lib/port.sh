#!/system/bin/sh
# ============================================================
# lib/port.sh — 移植包资源解析（APK / 名字清单 / 校验）
#
# 解析优先级（docs/ARCHITECTURE.md §4）：
#   1. 用户插件目录   $VIVODIR/plugins/ports/<family>/
#   2. 内置描述相对路径 $MODDIR/$LIBNAME_LIST（随模块分发的 .lst）
#   3. legacy 注册目录 $VIVODIR/ports/<id>/
#
# 插件目录是自包含的（port.conf + names.lst + APK [+ lib]）；
# 内置描述只有 conf+清单，APK 需经 legacy 目录注册或插件安装。
# ============================================================

PORT_ROOT=${PORT_ROOT:-$VIVODIR/ports}

port_dir(){ echo "$PORT_ROOT/$1"; }

# APK 路径（按 id 解析，不依赖调用方的加载状态）
port_apk(){
  local pid=$1
  [ -n "$pid" ] || return 1
  if [ -n "${PLUGIN_PORTS_DIR:-}" ] && [ -f "$PLUGIN_PORTS_DIR/$pid/VivoCamera.apk" ]; then
    echo "$PLUGIN_PORTS_DIR/$pid/VivoCamera.apk"; return 0
  fi
  if [ -f "$PORT_ROOT/$pid/VivoCamera.apk" ]; then
    echo "$PORT_ROOT/$pid/VivoCamera.apk"; return 0
  fi
  return 1
}

# 名字清单路径
port_list_file(){
  local pid=$1
  if [ -n "${PLUGIN_PORTS_DIR:-}" ] && [ -f "$PLUGIN_PORTS_DIR/$pid/names.lst" ]; then
    echo "$PLUGIN_PORTS_DIR/$pid/names.lst"; return 0
  fi
  # 已加载描述里的相对路径（内置 .lst 随模块分发，路径模块相对）
  if [ -n "${PORT_ID:-}" ] && [ "${PORT_ID:-}" = "$pid" ] && [ -n "${LIBNAME_LIST:-}" ]; then
    case "$LIBNAME_LIST" in
      /*) [ -f "$LIBNAME_LIST" ] && { echo "$LIBNAME_LIST"; return 0; } ;;
      *)  [ -f "$MODDIR/$LIBNAME_LIST" ] && { echo "$MODDIR/$LIBNAME_LIST"; return 0; } ;;
    esac
  fi
  if [ -f "$PORT_ROOT/$pid/names.lst" ]; then
    echo "$PORT_ROOT/$pid/names.lst"; return 0
  fi
  return 1
}

port_installed(){
  local pid=$1 a l
  a=$(port_apk "$pid")   || return 1
  l=$(port_list_file "$pid") || return 1
  [ -f "$a" ] && [ -f "$l" ]
}

# 期望库数量：优先已加载的 LIB_EXPECT，否则读描述
port_expect(){
  local pid=$1
  if [ -n "${PORT_ID:-}" ] && [ "${PORT_ID:-}" = "$pid" ] && [ -n "${LIB_EXPECT:-}" ]; then
    echo "$LIB_EXPECT"; return 0
  fi
  local f v
  for f in "${PLUGIN_PORTS_DIR:-}"/*/port.conf "$PORT_DIR"/*.port; do
    [ -f "$f" ] || continue
    v=$(conf_get "$f" "$PORT_FIELDS" PORT_ID 2>/dev/null)
    [ "$v" = "$pid" ] || continue
    conf_get "$f" "$PORT_FIELDS" LIB_EXPECT 2>/dev/null
    return 0
  done
  echo 0
}

# 注册一个已存在的 APK（legacy 兼容；插件用 plugin install）
port_register(){
  local pid=$1 apk=$2 lst=$3 d
  d=$(port_dir "$pid"); mkdir -p "$d" || return 1
  [ -f "$apk" ] || { echo "!! APK 不存在: $apk"; return 1; }
  [ -f "$lst" ] || { echo "!! 清单不存在: $lst"; return 1; }
  if ! ln -f "$apk" "$d/VivoCamera.apk" 2>/dev/null; then
    cp -f "$apk" "$d/VivoCamera.apk" || return 1
  fi
  cp -f "$lst" "$d/names.lst" || return 1
  local sha=$(sha256sum "$d/VivoCamera.apk" 2>/dev/null | awk '{print $1}')
  echo "$sha" > "$d/.verified"
  echo "port $pid 已注册 (apk $(du -m "$d/VivoCamera.apk" 2>/dev/null | awk '{print $1}')MB, names=$(wc -l < "$d/names.lst"))"
}

# 校验 APK 哈希（插件目录用 port.conf 里的 APK_SHA256；legacy 用 .verified）
port_verify(){
  local pid=$1 want got d
  port_installed "$pid" || { echo "未安装"; return 1; }
  # 插件目录：port.conf 的 APK_SHA256
  if [ -f "$PLUGIN_PORTS_DIR/$pid/port.conf" ]; then
    want=$(conf_get "$PLUGIN_PORTS_DIR/$pid/port.conf" "$PORT_FIELDS" APK_SHA256 2>/dev/null)
    got=$(sha256sum "$PLUGIN_PORTS_DIR/$pid/VivoCamera.apk" 2>/dev/null | awk '{print $1}')
    if [ -n "$want" ]; then
      [ "$want" = "$got" ] && { echo "校验通过"; return 0; }
      echo "!! 哈希不符: ${want:0:12}… / ${got:0:12}…"; return 1
    fi
    echo "未声明哈希"; return 0
  fi
  # legacy：.verified
  d=$(port_dir "$pid")
  if [ -f "$d/.verified" ]; then
    want=$(cat "$d/.verified" 2>/dev/null)
    got=$(sha256sum "$d/VivoCamera.apk" 2>/dev/null | awk '{print $1}')
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      echo "校验通过"; return 0
    fi
    echo "!! 哈希不符: ${want:0:12}… / ${got:0:12}…"; return 1
  fi
  echo "无校验记录"; return 0
}

# 下载移植包 APK（legacy；插件走 plugin update）
port_fetch(){
  local pid=$1 url=$2 want_sha=$3 d
  d=$(port_dir "$pid"); mkdir -p "$d" || return 1
  [ -n "$url" ] || { echo "!! 该 port 未提供下载地址"; return 1; }
  local tmp="$d/VivoCamera.apk.part"
  rm -f "$tmp"
  echo "下载 $pid ..."
  if ! busybox wget -O "$tmp" "$url" 2>&1 | tail -3; then
    echo "!! 下载失败"; rm -f "$tmp"; return 1
  fi
  [ -s "$tmp" ] || { echo "!! 下载为空"; rm -f "$tmp"; return 1; }
  local got=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
  if [ -n "$want_sha" ] && [ "$got" != "$want_sha" ]; then
    echo "!! 哈希不符（期望 ${want_sha:0:12}… 实得 ${got:0:12}…），已丢弃"
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$d/VivoCamera.apk"
  echo "$got" > "$d/.verified"
  echo "下载完成并校验通过"
}

# 全量状态：用户插件 + 内置未覆盖项
port_status_all(){
  local line pid src ver ready
  while read -r line; do
    [ -n "$line" ] || continue
    pid=${line%% *}
    src=${line#* }
    port_find "$pid" || continue
    ver=${PLUGIN_VER:-$APK_VER}
    ready="未下载"
    if port_installed "$pid"; then
      ready="[已就绪] $(port_verify "$pid" 2>&1 | head -1)"
    fi
    local tag=""
    [ "$src" = "user" ] && tag="插件"
    printf "%-14s %-6s %-12s %s\n" "$pid" "[$tag]" "$ver" "$ready"
  done <<EOF
$(port_enumerate)
EOF
}
