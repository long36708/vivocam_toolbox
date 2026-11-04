#!/system/bin/sh
# ============================================================
# lib/plugin.sh — 插件生命周期（docs/ARCHITECTURE.md P2-P4）
#
# 布局：
#   $VIVODIR/plugins/ports/<family>/          活跃插件（family 为目录名）
#     port.conf / names.lst / VivoCamera.apk [/ lib/*.so]
#   $VIVODIR/plugins/ports/.versions/<family>/<ver>/   归档（rollback/use）
#   $VIVODIR/plugins/profiles/*.profile       profile 插件
#   $VIVODIR/plugins/sigs/*.conf              崩溃签名插件
#   $VIVODIR/plugins/repo.conf                REPO_URL=...
#
# 优先级：用户插件 > 模块内置（同 id 覆盖）——这是"不更新模块就能
# 更新插件"的机制本体。模块被 KSU 更新时 /data/adb/vivocam 原样保留。
# ============================================================

PLUGIN_ROOT=${PLUGIN_ROOT:-$VIVODIR/plugins}
PLUGIN_PORTS_DIR=${PLUGIN_PORTS_DIR:-$PLUGIN_ROOT/ports}
PLUGIN_PROFILES_DIR=${PLUGIN_PROFILES_DIR:-$PLUGIN_ROOT/profiles}
PLUGIN_SIGS_DIR=${PLUGIN_SIGS_DIR:-$PLUGIN_ROOT/sigs}
PLUGIN_VERSIONS_DIR=${PLUGIN_VERSIONS_DIR:-$PLUGIN_PORTS_DIR/.versions}
REPO_CONF=${REPO_CONF:-$PLUGIN_ROOT/repo.conf}
UPDATES_CACHE=${UPDATES_CACHE:-$PLUGIN_ROOT/.updates}

SCHEMA_SUPPORTED=1
MAX_ARCHIVED=2                  # 每家族最多保留的归档版本数

# ---------- 版本比较 ----------
# ver_ge <a> <b>：a>=b 时返回 0。按 . 分段数值比较，短侧补 0，非数字段当 0
ver_ge(){
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,A,"."); m=split(b,B,".")
    k=(n>m)?n:m
    for(i=1;i<=k;i++){
      x=(i<=n)?A[i]+0:0; y=(i<=m)?B[i]+0:0
      if(x>y) exit 0
      if(x<y) exit 1
    }
    exit 0
  }'
}

module_version_code(){
  [ -n "$MODULE_VERCODE" ] && { echo "$MODULE_VERCODE"; return; }
  MODULE_VERCODE=$(conf_get "$MODDIR/module.prop" '^(versionCode)$' versionCode 2>/dev/null)
  echo "${MODULE_VERCODE:-0}"
}

# ---------- MEAT 扫描（与 addport 同源，安装复核用） ----------
# 输出：空格分隔的 $$MEAT 机型码；APK 无 $$MEAT 时输出空
plugin_meat_scan(){
  local apk=$1 d=/data/local/tmp/plugmeat.$$
  rm -rf "$d"; mkdir -p "$d"
  unzip -o -q "$apk" 'classes*.dex' -d "$d" 2>/dev/null
  grep -a -o 'FeatureConfig_meat_PD[0-9A-Z_]*..MEAT;' "$d"/classes*.dex 2>/dev/null \
    | sed 's/.*FeatureConfig_meat_//' \
    | sed 's/[$][$]MEAT;.*//' \
    | sort -u | tr '\n' ' ' | sed 's/ *$//'
  rm -rf "$d"
}

# ---------- 校验（design §5 校验序）----------
# plugin_validate <dir> → 把通过的元数据读进 P_* 变量；失败输出原因并返回 1
plugin_validate(){
  local d=$1
  [ -f "$d/port.conf" ] || { echo "缺 port.conf"; return 1; }
  [ -f "$d/names.lst" ] || { echo "缺 names.lst"; return 1; }
  [ -f "$d/VivoCamera.apk" ] || { echo "缺 VivoCamera.apk"; return 1; }

  unset P_PORT_ID P_PLUGIN_VER P_SCHEMA P_MODULE_MIN P_APK_SHA256 \
        P_APK_VER P_LIB_EXPECT P_MEAT_CODES P_TARGET_PROJECT P_SRC_PROJECT \
        P_PORT_NAME P_TARGETS P_KNOWN_LIMITS
  conf_read "$d/port.conf" \
    '^(SCHEMA|PLUGIN_KIND|PLUGIN_VER|PORT_ID|ALIASES|PORT_NAME|SRC_PROJECT|MEAT_CODES|TARGET_PROJECT|APK_VER|APK_SIZE|APK_SHA256|APK_URL|LIBNAME_LIST|LIB_EXPECT|LIB_SHA256|MODULE_MIN|TARGETS|KNOWN_LIMITS|CHANGELOG)$' P_ \
    || { echo "port.conf 解析失败"; return 1; }

  [ -n "${P_PORT_ID:-}" ]       || { echo "缺 PORT_ID"; return 1; }
  [ -n "${P_TARGET_PROJECT:-}" ] || { echo "缺 TARGET_PROJECT"; return 1; }
  [ "${P_SCHEMA:-1}" = "$SCHEMA_SUPPORTED" ] || { echo "SCHEMA ${P_SCHEMA:-?} 不受支持（本模块支持 $SCHEMA_SUPPORTED）"; return 1; }

  # 模块版本要求
  local mv=$(module_version_code)
  if [ -n "${P_MODULE_MIN:-}" ] && ! ver_ge "$mv" "$P_MODULE_MIN"; then
    echo "需要模块 ≥ v$P_MODULE_MIN（当前 v$mv），请先升级模块"; return 1
  fi

  # APK 完整性
  if [ -n "${P_APK_SHA256:-}" ]; then
    local got=$(sha256sum "$d/VivoCamera.apk" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$P_APK_SHA256" ] || { echo "APK sha256 不符（声明 ${P_APK_SHA256:0:12}… 实得 ${got:0:12}…）"; return 1; }
  else
    echo "!! 警告：未声明 APK_SHA256，跳过完整性校验"
  fi

  # MEAT 复核：扫描结果必须非空，且 TARGET_PROJECT 必须是真实的 $$MEAT 码
  echo "扫描 \$\$MEAT 复核伪装码..."
  local scanned=$(plugin_meat_scan "$d/VivoCamera.apk")
  [ -n "$scanned" ] || { echo "APK 内没有任何 \$\$MEAT 类，16.x 框架起不来"; return 1; }
  case " $scanned " in
    *" ${P_TARGET_PROJECT} "*) ;;
    *) echo "伪装码 $P_TARGET_PROJECT 不在 APK 的 \$\$MEAT 集合里（实际: $scanned）"; return 1 ;;
  esac

  # 清单数量
  if [ -n "${P_LIB_EXPECT:-}" ] && [ "$P_LIB_EXPECT" != "0" ]; then
    local n=$(wc -l < "$d/names.lst" | tr -d ' ')
    [ "$n" = "$P_LIB_EXPECT" ] || { echo "names.lst 行数 $n ≠ 声明 LIB_EXPECT $P_LIB_EXPECT"; return 1; }
  fi

  # family 名合法性（会作为目录名）
  case "${P_PORT_ID}" in
    *[!A-Za-z0-9_.-]*|""|.*|*.*) echo "PORT_ID 非法: $P_PORT_ID"; return 1 ;;
  esac
  return 0
}

# ---------- 安装 ----------
# plugin_install <zip|目录> [--thin]
#   zip：根必须直接是 port.conf（对齐 module.prop 规则）
plugin_install(){
  local src=$1 thin=${2:-}
  [ -n "$src" ] || { echo "用法: plugin install <zip|目录>"; return 1; }

  local stage=/data/local/tmp/pluginst.$$
  rm -rf "$stage"; mkdir -p "$stage"

  case "$src" in
    *.zip)
      echo "解包 $src ..."
      unzip -o -q "$src" -d "$stage" 2>/dev/null || { echo "!! zip 解包失败"; rm -rf "$stage"; return 1; }
      # 兼容包了一层目录的 zip：根没有 port.conf 就往下找一层
      if [ ! -f "$stage/port.conf" ]; then
        local sub=$(find "$stage" -maxdepth 2 -name port.conf 2>/dev/null | head -1)
        [ -n "$sub" ] || { echo "!! zip 根找不到 port.conf"; rm -rf "$stage"; return 1; }
        local real=$(dirname "$sub") stage2="${stage}2"
        rm -rf "$stage2"
        mv -f "$real" "$stage2" && rm -rf "$stage" && mv -f "$stage2" "$stage"           || { echo "!! zip 结构调整失败"; rm -rf "$stage" "$stage2"; return 1; }
      fi
      ;;
    *)
      [ -d "$src" ] || { echo "!! 不存在: $src"; return 1; }
      cp -a "$src/." "$stage/" || { rm -rf "$stage"; return 1; }
      ;;
  esac

  echo "校验插件..."
  if ! plugin_validate "$stage"; then
    rm -rf "$stage"; return 1
  fi
  local fam=$P_PORT_ID ver=${P_PLUGIN_VER:-$P_APK_VER}

  mkdir -p "$PLUGIN_PORTS_DIR" "$PLUGIN_VERSIONS_DIR/$fam"

  # 库入池（自包含模式）：把 lib/*.so 按 md5 合并进内容寻址池
  if [ -d "$stage/lib" ]; then
    echo "合并库集入库池..."
    local so m
    for so in "$stage"/lib/*.so; do
      [ -f "$so" ] || continue
      m=$(md5sum "$so" 2>/dev/null | cut -d' ' -f1)
      [ -n "$m" ] || continue
      [ -f "$LIBPOOL/$m.so" ] || cp -f "$so" "$LIBPOOL/$m.so" 2>/dev/null
    done
  elif [ "$thin" != "--thin" ]; then
    echo "（插件未带 lib/，依赖已有库池：$(ls "$LIBPOOL"/*.so 2>/dev/null | wc -l) 个内容）"
  fi

  # 归档旧活跃版本（原子替换：先挪旧、再上新的，失败回滚）
  local active="$PLUGIN_PORTS_DIR/$fam"
  local oldver=""
  if [ -d "$active" ]; then
    oldver=$(conf_get "$active/port.conf" '^(PLUGIN_VER|APK_VER)$' PLUGIN_VER 2>/dev/null)
    [ -n "$oldver" ] || oldver=$(conf_get "$active/port.conf" '^(PLUGIN_VER|APK_VER)$' APK_VER 2>/dev/null)
    oldver=${oldver:-unknown}
    if ! mv -f "$active" "$PLUGIN_VERSIONS_DIR/$fam/$oldver" 2>/dev/null; then
      rm -rf "$stage"; echo "!! 归档旧版本失败"; return 1
    fi
  fi
  if ! mv -f "$stage" "$active" 2>/dev/null; then
    [ -n "$oldver" ] && mv -f "$PLUGIN_VERSIONS_DIR/$fam/$oldver" "$active" 2>/dev/null
    echo "!! 安装失败，已回滚"; return 1
  fi
  chmod 755 "$active"; chmod 644 "$active"/port.conf "$active"/names.lst 2>/dev/null
  find "$active" -maxdepth 1 -type f -name "*.apk" -exec chmod 644 {} \; 2>/dev/null

  plugin_prune_versions "$fam"
  echo
  echo "✓ 插件已安装: $fam $ver（$([ -d "$active/lib" ] && echo 自包含 || echo thin)）"
  [ -n "$oldver" ] && echo "  旧版本已归档: $oldver（cam.sh plugin rollback 可回退）"
  return 0
}

# 归档数量修剪（保留最近 MAX_ARCHIVED 版）
plugin_prune_versions(){
  local fam=$1 d="$PLUGIN_VERSIONS_DIR/$1" v
  [ -d "$d" ] || return 0
  local n=$(ls -d "$d"/*/ 2>/dev/null | wc -l)
  [ "$n" -le "$MAX_ARCHIVED" ] && return 0
  # 按版本升序删最老的
  local sorted=$(ls -d "$d"/*/ 2>/dev/null | while read -r v; do basename "$v"; done | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
  local drop=$(echo "$sorted" | head -n $((n - MAX_ARCHIVED)))
  for v in $drop; do rm -rf "$d/$v"; done
}

# ---------- 列表 / 检查 ----------
# plugin_list_installed：输出 family 一行一条（用户插件优先，内置同名跳过）
plugin_list_installed(){
  local seen="" f fam
  # 用户插件
  for f in "$PLUGIN_PORTS_DIR"/*/port.conf; do
    [ -f "$f" ] || continue
    fam=$(conf_get "$f" '^(PORT_ID)$' PORT_ID 2>/dev/null)
    [ -n "$fam" ] || continue
    echo "$fam user"
    seen="$seen $fam "
  done
  # 内置（未被用户插件覆盖的）
  for f in "$MODDIR"/ports/*.port; do
    [ -f "$f" ] || continue
    fam=$(conf_get "$f" '^(PORT_ID)$' PORT_ID 2>/dev/null)
    [ -n "$fam" ] || continue
    case "$seen" in *" $fam "*) continue ;; esac
    echo "$fam builtin"
  done
}

# repo index：一行 kind|family|ver|url|sha256|min_module
plugin_fetch_index(){
  local url
  url=$(conf_get "$REPO_CONF" '^(REPO_URL)$' REPO_URL 2>/dev/null)
  [ -n "$url" ] || { echo "!! 未配置插件源（$REPO_CONF 里写 REPO_URL=...）"; return 1; }
  mkdir -p "$PLUGIN_ROOT"
  busybox wget -q -O "$UPDATES_CACHE.part" "$url" 2>/dev/null || { echo "!! 拉取 index 失败: $url"; return 1; }
  [ -s "$UPDATES_CACHE.part" ] || { echo "!! index 为空"; return 1; }
  mv -f "$UPDATES_CACHE.part" "$UPDATES_CACHE"
  return 0
}

plugin_check(){
  plugin_fetch_index || return 1
  local line kind fam ver url sha minm
  local found=0
  : > "$UPDATES_CACHE.seen"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|"") continue ;; esac
    kind=$(echo  "$line" | cut -d'|' -f1)
    fam=$( echo  "$line" | cut -d'|' -f2)
    ver=$(echo   "$line" | cut -d'|' -f3)
    [ "$kind" = "port" ] || continue
    [ -n "$fam" ] || continue
    # 已安装的最高版本
    local cur=""
    local cf="$PLUGIN_PORTS_DIR/$fam/port.conf"
    if [ -f "$cf" ]; then
      cur=$(conf_get "$cf" '^(PLUGIN_VER|APK_VER)$' PLUGIN_VER 2>/dev/null)
      [ -n "$cur" ] || cur=$(conf_get "$cf" '^(PLUGIN_VER|APK_VER)$' APK_VER 2>/dev/null)
    fi
    if [ -z "$cur" ]; then
      echo "可安装: $fam $ver（当前未安装）"; found=$((found+1))
    elif ! ver_ge "$cur" "$ver"; then
      echo "可更新: $fam $cur → $ver"; found=$((found+1))
      echo "plugin_upd_$fam=$ver" >> "$UPDATES_CACHE.seen"
    fi
  done < "$UPDATES_CACHE"
  [ "$found" = "0" ] && echo "全部为最新"
  # 只保留 seen 标记供 info 用
  [ -f "$UPDATES_CACHE.seen" ] && mv -f "$UPDATES_CACHE.seen" "$UPDATES_CACHE.upd" || rm -f "$UPDATES_CACHE.upd"
  return 0
}

plugin_update(){
  local fam=$1
  plugin_fetch_index || return 1
  local line kind f2 ver url sha minm best_ver="" best_url="" best_sha="" best_min=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|"") continue ;; esac
    kind=$(echo "$line" | cut -d'|' -f1)
    f2=$(echo   "$line" | cut -d'|' -f2)
    [ "$kind" = "port" ] && [ "$f2" = "$fam" ] || continue
    ver=$(echo "$line" | cut -d'|' -f3)
    url=$(echo "$line" | cut -d'|' -f4)
    sha=$(echo "$line" | cut -d'|' -f5)
    minm=$(echo "$line" | cut -d'|' -f6)
    if [ -z "$best_ver" ] || ver_ge "$ver" "$best_ver"; then
      best_ver=$ver; best_url=$url; best_sha=$sha; best_min=$minm
    fi
  done < "$UPDATES_CACHE"
  [ -n "$best_url" ] || { echo "!! index 里没有 $fam"; return 1; }
  # 已是最新则跳过
  local cf="$PLUGIN_PORTS_DIR/$fam/port.conf"
  if [ -f "$cf" ]; then
    local cur=$(conf_get "$cf" '^(PLUGIN_VER|APK_VER)$' PLUGIN_VER 2>/dev/null)
    [ -n "$cur" ] || cur=$(conf_get "$cf" '^(PLUGIN_VER|APK_VER)$' APK_VER 2>/dev/null)
    if [ -n "$cur" ] && ver_ge "$cur" "$best_ver"; then
      echo "$fam 已是最新（$cur）"; return 0
    fi
  fi
  local tmp="/data/local/tmp/$fam-$best_ver.plugin.zip"
  echo "下载 $fam $best_ver ..."
  busybox wget -O "$tmp" "$best_url" 2>&1 | tail -2
  [ -s "$tmp" ] || { echo "!! 下载为空"; return 1; }
  if [ -n "$best_sha" ]; then
    local got=$(sha256sum "$tmp" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$best_sha" ] || { echo "!! zip sha256 不符（${best_sha:0:12}… / ${got:0:12}…）"; rm -f "$tmp"; return 1; }
  fi
  plugin_install "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# ---------- use / rollback / remove ----------
plugin_use(){
  local fam=$1 ver=$2
  local active="$PLUGIN_PORTS_DIR/$fam"
  local arc="$PLUGIN_VERSIONS_DIR/$fam/$ver"
  [ -d "$arc" ] || { echo "!! 没有归档版本 $fam $ver"; return 1; }
  local cur=$(conf_get "$active/port.conf" '^(PLUGIN_VER|APK_VER)$' PLUGIN_VER 2>/dev/null)
  [ -n "$cur" ] || cur=$(conf_get "$active/port.conf" '^(PLUGIN_VER|APK_VER)$' APK_VER 2>/dev/null)
  cur=${cur:-unknown}
  mv -f "$active" "$PLUGIN_VERSIONS_DIR/$fam/$cur" || { echo "!! 挪当前版本失败"; return 1; }
  if mv -f "$arc" "$active" 2>/dev/null; then
    echo "✓ $fam 活跃版本: $cur → $ver"
  else
    mv -f "$PLUGIN_VERSIONS_DIR/$fam/$cur" "$active"
    echo "!! 切换失败，已回滚"; return 1
  fi
}

plugin_rollback(){
  local fam=$1 d="$PLUGIN_VERSIONS_DIR/$1" best="" v
  [ -d "$d" ] || { echo "!! 没有可回退的归档版本"; return 1; }
  for v in $(ls "$d" 2>/dev/null); do
    [ -d "$d/$v" ] || continue
    if [ -z "$best" ] || ver_ge "$v" "$best"; then best=$v; fi
  done
  [ -n "$best" ] || { echo "!! 没有可回退的归档版本"; return 1; }
  plugin_use "$fam" "$best"
}

plugin_remove(){
  local fam=$1
  local active="$PLUGIN_PORTS_DIR/$fam"
  if [ -d "$active" ]; then
    rm -rf "$active" || { echo "!! 删除失败"; return 1; }
    echo "✓ 已移除用户插件 $fam"
  else
    echo "$fam 不是用户插件（可能是内置的，模块更新时随模块走）"
  fi
}

# ---------- 构建（P4）：从解包镜像产出可分发插件目录 ----------
# plugin_build <镜像根> <family> [伪装码] [TARGETS]
# 复用 addport 已验证的扫描逻辑；输出 $VIVODIR/plugins/out/<family>-<ver>/
# TARGETS：已在哪些目标机实测过（逗号分隔）。默认留空——构建器不能替人
# 背书"已验证"，那是出片实测后人工补的声明。
plugin_build(){
  local root=$1 fam=$2 tgt=$3 tgts=${4:-}
  if [ -z "$root" ] || [ -z "$fam" ]; then
    echo "用法: plugin build <镜像根> <family> [伪装码]"; return 1
  fi
  [ -d "$root" ] || { echo "!! 镜像根不存在: $root"; return 1; }

  local apk="" c
  for c in "$root/system/system/app/VivoCamera/VivoCamera.apk" \
           "$root/system/app/VivoCamera/VivoCamera.apk"; do
    [ -f "$c" ] && { apk=$c; break; }
  done
  [ -n "$apk" ] || { echo "!! 镜像里找不到 VivoCamera.apk"; return 1; }
  local libdir="$(dirname "$apk")/lib/arm64"
  [ -d "$libdir" ] || { echo "!! 镜像里没有 lib/arm64"; return 1; }

  local ver
  ver=$(unzip -p "$apk" AndroidManifest.xml 2>/dev/null \
        | tr -d '\000' \
        | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -1)
  [ -n "$ver" ] || ver=unknown

  local srcprj
  srcprj=$(grep -a 'ro.vivo.system.product.model=' "$root/system/system/build.prop" 2>/dev/null \
           | head -1 | cut -d= -f2 | tr -d ' \r')

  echo "扫描 \$\$MEAT ..."
  local meat=$(plugin_meat_scan "$apk")
  [ -n "$meat" ] || { echo "!! APK 无 \$\$MEAT 类，拒绝"; return 1; }
  echo "MEAT 可用码: $meat"
  [ -n "$tgt" ] || tgt=$(echo "$meat" | awk '{print $1}')

  # 名字清单：链接重映射进镜像（同 pool_build_from_image），加载名+目标名都收
  mkdir -p "$PLUGIN_PORTS_DIR"
  local list="$PLUGIN_PORTS_DIR/.build.$$.lst"
  pool_build_from_image "$root" "$libdir" "$list" >/dev/null || { rm -f "$list"; return 1; }
  local nlib=$(wc -l < "$list" | tr -d ' ')

  local out="$PLUGIN_PORTS_DIR/out/$fam-$ver"
  rm -rf "$out"; mkdir -p "$out/lib"

  # port.conf（扫描实测值，不允许手填）
  local sha size
  sha=$(sha256sum "$apk" 2>/dev/null | cut -d' ' -f1)
  size=$(stat -c %s "$apk" 2>/dev/null); [ -n "$size" ] || size=0
  {
    echo "SCHEMA=1"
    echo "PLUGIN_KIND=port"
    echo "PLUGIN_VER=$ver"
    echo "PORT_ID=$fam"
    echo "ALIASES=\"${fam}-${ver##*.}\""
    echo "PORT_NAME=\"${fam} 相机 $ver\""
    echo "SRC_PROJECT=${srcprj:-$tgt}"
    echo "MEAT_CODES=\"$meat\""
    echo "TARGET_PROJECT=$tgt"
    echo "APK_VER=$ver"
    echo "APK_SIZE=$size"
    echo "APK_SHA256=$sha"
    echo "APK_URL="
    echo "LIBNAME_LIST=names.lst"
    echo "LIB_EXPECT=$nlib"
    echo "MODULE_MIN=5"
    echo "TARGETS=${tgts}"
    echo "KNOWN_LIMITS=\"由镜像自动打包；默认拍照可能崩 ExtendCap（HAL 二进制缺陷）\""
  } > "$out/port.conf"

  cp -f "$list" "$out/names.lst"
  rm -f "$list"

  # APK 与库：APK 直接拷（分发件需要），库从池里物化
  ln -f "$apk" "$out/VivoCamera.apk" 2>/dev/null || cp -f "$apk" "$out/VivoCamera.apk"     || { rm -rf "$out"; return 1; }
  local name p
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    p=$(pool_path "$name")
    [ -n "$p" ] && cp -f "$p" "$out/lib/$name" 2>/dev/null
  done < "$out/names.lst"

  echo
  echo "✓ 插件已构建: $out"
  echo "  family=$fam ver=$ver MEAT=$meat libs=$nlib"
  echo "  分发: 把该目录打成 zip（port.conf 在根），或直接 plugin install $out"
}
