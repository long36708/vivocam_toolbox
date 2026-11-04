#!/system/bin/sh
# ============================================================
# lib/backup.sh — 原厂库首启自备份
#
# 为什么自备份而不是随包（设计文档 §1.3 / §10）：
#   原厂 lib/arm64 = 53 实体 + 23 符号链接，链接目标全在 /system/lib64
#   且全部存在（broken=0）。cp -L 实测 76/76 全部解析成功。
#   → 每台机备份的是它自己的原厂库，随包带别人的库是错的。
#
# 备份目录：$VIVODIR/stock/<profile_id>/
# 清单    ：$VIVODIR/stock/<profile_id>/.manifest  (name md5)
# ============================================================

STOCK_ROOT=${STOCK_ROOT:-$VIVODIR/stock}

stock_dir(){ echo "$STOCK_ROOT/$1"; }

# ---------- 原厂相机路径解析（多机型关键）----------
# 路径因机型/OS 代而异：/system/app、/system/priv-app、/product/app 都有
# 可能，不能像 pd2419.profile 那样写死。解析顺序：
#   profile 显式路径（存在才用）→ pm path 的系统分区结果 → 目录扫描
stock_apk_resolve(){
  local pkg="${STOCK_PKG:-com.android.camera}" p d f
  if [ -n "${STOCK_APK:-}" ] && [ -f "$STOCK_APK" ]; then echo "$STOCK_APK"; return 0; fi
  p=$(pm path "$pkg" 2>/dev/null | sed -n 's/^package://p' | head -1)
  case "$p" in
    /system/*|/product/*|/system_ext/*|/odm/*|/vendor/*)
      [ -f "$p" ] && { echo "$p"; return 0; } ;;
  esac
  for d in /system/app /system/priv-app /product/app /product/priv-app            /system_ext/app /system_ext/priv-app /odm/app /odm/priv-app; do
    [ -d "$d" ] || continue
    for f in "$d"/VivoCamera/*.apk "$d"/*[Cc]amera*/[Vv]ivo*.apk "$d"/*[Cc]amera*/*.apk; do
      [ -f "$f" ] && { echo "$f"; return 0; }
    done
  done
  return 1
}

# 原厂 lib 目录 = 原厂 APK 同目录下的 lib/arm64
stock_libdir_resolve(){
  local apk=$(stock_apk_resolve) || return 1
  local d="$(dirname "$apk")/lib/arm64"
  [ -d "$d" ] && { echo "$d"; return 0; }
  return 1
}

# 生成/刷新原厂库备份
# $1=profile_id $2=源 lib 目录 $3=期望数量
stock_backup(){
  local pid=$1 src=$2 want=${3:-0}
  local dst=$(stock_dir "$pid")
  [ -d "$src" ] || { echo "!! 原厂库目录不存在: $src"; return 1; }
  mkdir -p "$(dirname "$dst")" || return 1

  # 临时目录必须建在 $dst 之外：若放在 $dst/.new，下面 mv $dst 到 .bak 时
  # 会把临时目录一起搬走，导致随后的 mv 找不到源（本函数初版的 bug）
  local tmp="$dst.new.$$"
  rm -rf "$tmp"; mkdir -p "$tmp"

  # -L：符号链接解析成实体。原厂布局是"实体+链接"混合，相机加载的是
  # 链接名（如 libmmkv.so），所以必须按链接名落成实体文件。
  cp -Lf "$src"/*.so "$tmp/" 2>/dev/null
  local n=$(ls "$tmp"/*.so 2>/dev/null | wc -l)
  if [ "$want" != "0" ] && [ "$n" != "$want" ]; then
    echo "!! 备份数量不符: 得到 $n / 期望 $want"
    rm -rf "$tmp"
    return 1
  fi
  # 校验：每个文件非空且 md5 可算
  local f bad=0
  for f in "$tmp"/*.so; do
    [ -s "$f" ] || { bad=$((bad+1)); continue; }
    [ -n "$(md5sum "$f" 2>/dev/null | awk '{print $1}')" ] || bad=$((bad+1))
  done
  if [ "$bad" != "0" ]; then
    echo "!! 备份中有 $bad 个不可读文件"
    rm -rf "$tmp"
    return 1
  fi

  # 原子替换：先把旧目录挪开，再整体换上新的（不是逐个 mv 文件——
  # 那样一旦中途失败会留下半套库，正是本函数最初实现踩的坑）
  rm -rf "$dst.bak"
  if [ -d "$dst" ]; then mv -f "$dst" "$dst.bak" 2>/dev/null; fi
  if ! mv -f "$tmp" "$dst" 2>/dev/null; then
    echo "!! 替换备份目录失败，回滚"
    [ -d "$dst.bak" ] && mv -f "$dst.bak" "$dst" 2>/dev/null
    rm -rf "$tmp"
    return 1
  fi
  chmod 755 "$dst"; find "$dst" -type f -exec chmod 644 {} \; 2>/dev/null

  # 清单
  ( cd "$dst" && md5sum *.so > .manifest 2>/dev/null )
  echo "原厂库已备份: $n 个 -> $dst"
  return 0
}

# 备份是否可用（存在且数量够）
stock_ready(){
  local pid=$1 want=${2:-0}
  local dst=$(stock_dir "$pid")
  [ -d "$dst" ] || return 1
  local n=$(ls "$dst"/*.so 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || return 1
  if [ "$want" != "0" ] && [ "$n" != "$want" ]; then return 1; fi
  return 0
}

# 校验备份完整性（清单 vs 实际）
stock_verify(){
  local pid=$1 dst=$(stock_dir "$1")
  [ -f "$dst/.manifest" ] || { echo "无清单"; return 1; }
  local bad=$(cd "$dst" && md5sum -c .manifest 2>/dev/null | grep -c 'FAILED')
  if [ "${bad:-0}" = "0" ]; then
    echo "备份校验通过 ($(wc -l < "$dst/.manifest") 个文件)"
    return 0
  fi
  echo "校验失败 $bad 个"
  return 1
}

# 把备份铺到目标 lib 目录
stock_fill(){
  local pid=$1 dstlib=$2 want=${3:-0}
  local src=$(stock_dir "$pid")
  [ -d "$src" ] || { echo "!! 无原厂备份: $src"; return 1; }
  rm -rf "$dstlib"; mkdir -p "$dstlib"
  cp -f "$src"/*.so "$dstlib/" 2>/dev/null
  chmod 755 "$dstlib" 2>/dev/null
  find "$dstlib" -type f -exec chmod 755 {} \; 2>/dev/null
  local n=$(ls "$dstlib"/*.so 2>/dev/null | wc -l)
  echo "libs=$n${want:+/$want} (stock-backup)"
  [ "$want" = "0" ] || [ "$n" = "$want" ] || return 1
  return 0
}

stock_status(){
  local pid=$1 dst=$(stock_dir "$1")
  if stock_ready "$pid"; then
    echo "原厂备份: $(ls "$dst"/*.so 2>/dev/null | wc -l) 个 ($dst)"
  else
    echo "原厂备份: 缺失 ($dst)"
  fi
}
