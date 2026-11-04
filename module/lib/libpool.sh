#!/system/bin/sh
# ============================================================
# lib/libpool.sh — 内容寻址库池
#
# 核心事实（实测，见设计文档 §1.2）：
#   x500_lib(107) 与 x500pm_lib(106) 按内容 md5 去重后只有 78 个唯一
#   文件 / 85MB。那 4 个"仅一侧出现"的名字（libmmkv_n6/n7 等）与另一
#   侧的 libmmkv.so 内容完全相同，只是原厂符号链接的目标名。
#   且没有任何 .so 的 DT_NEEDED 引用 _nX 名字（扫 106 个库 0 命中）。
#
# 所以：库池按内容存 <md5>.so，port 只带「要铺哪些文件名」的清单。
# 铺库 = 按清单里的名字，去池里找对应内容再写成该名字。
#
# 池布局：$VIVODIR/libpool/<md5>.so
# 索引 ：$VIVODIR/libpool/<name> -> <md5>   （一行一个，便于反查）
# ============================================================

LIBPOOL=${LIBPOOL:-$VIVODIR/libpool}
IDX=${IDX:-$LIBPOOL/.names}      # 格式: <文件名> <md5>

pool_init(){
  mkdir -p "$LIBPOOL"
  [ -f "$IDX" ] || : > "$IDX"
}

md5of(){ md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# 把一个文件加入池（按内容去重），并登记名字映射
# $1=源文件 $2=逻辑文件名
pool_add(){
  local src=$1 name=$2 m
  [ -f "$src" ] || return 1
  m=$(md5of "$src")
  [ -n "$m" ] || return 1
  [ -f "$LIBPOOL/$m.so" ] || cp -f "$src" "$LIBPOOL/$m.so" || return 1
  # 登记名字->md5（同名多 md5 时以最新为准，但正常不会冲突）
  if grep -q "^$name " "$IDX" 2>/dev/null; then
    grep -v "^$name " "$IDX" > "$IDX.tmp" 2>/dev/null
    echo "$name $m" >> "$IDX.tmp"
    mv -f "$IDX.tmp" "$IDX"
  else
    echo "$name $m" >> "$IDX"
  fi
}

# 名字 -> 池内路径（不存在则空）
pool_path(){
  local name=$1 m
  m=$(awk -v n="$name" '$1==n{print $2; exit}' "$IDX" 2>/dev/null)
  [ -n "$m" ] && [ -f "$LIBPOOL/$m.so" ] && echo "$LIBPOOL/$m.so"
}

# 从一个「镜像或原厂」lib 目录构建池 + 名字清单
# $1=lib目录 $2=输出的名字清单文件
# 关键：符号链接必须解析到「该目录所属镜像内」的目标，不能用设备当前
# /system/lib64（docs/FINDINGS.md §13.1 的假差异教训）。这里用 readlink 拿绝对
# 路径直接读——镜像内的链接是绝对路径，指向的是镜像自己的 lib64。
pool_build_from_dir(){
  local dir=$1 list=$2 f name real m
  pool_init
  : > "$list"
  for f in "$dir"/*.so; do
    # 注意：不能只判 -e。镜像里指向 /system/lib64 的符号链接在设备上是
    # 悬空的（-e 为假），必须用 -L 兜住，否则会静默漏掉一批库。
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    # 解析链接（-L 语义）；解析不到就跳过并记警告
    if [ -L "$f" ]; then
      real=$(readlink -f "$f" 2>/dev/null)
      [ -f "$real" ] || { echo "WARN broken-link $name" >&2; continue; }
    else
      real=$f
    fi
    m=$(md5of "$real")
    [ -n "$m" ] || continue
    [ -f "$LIBPOOL/$m.so" ] || cp -f "$real" "$LIBPOOL/$m.so"
    echo "$name $m" >> "$list.tmp"
    echo "$name" >> "$list"
  done
  [ -f "$list.tmp" ] && cat "$list.tmp" >> "$IDX" && rm -f "$list.tmp"
  # 去重索引
  awk '!seen[$1]++' "$IDX" > "$IDX.u" && mv -f "$IDX.u" "$IDX"
  echo "pool: unique=$(ls "$LIBPOOL"/*.so 2>/dev/null | wc -l) names=$(wc -l < "$list")"
}

# 从「解包镜像」构建库池 + 名字清单
#
# $1=镜像根（如 /data/RNA/RNA_x500）  $2=镜像内 APK 的 lib/arm64 目录
# $3=输出的名字清单
#
# ★ 与 pool_build_from_dir 的区别（关键）：
#   镜像里 lib/arm64 的符号链接是**绝对路径**，指向 /system/lib64/xxx_nN.so。
#   若直接 readlink -f，会解析到**设备自己的** /system/lib64 —— 读到的是本机
#   库（甚至被我们的模块覆盖过），而不是镜像里的库。这正是docs/FINDINGS.md §13.1
#   记录的"假差异"教训。所以必须把绝对目标重映射进镜像根目录。
pool_build_from_image(){
  local root=$1 dir=$2 list=$3 f name link real m
  [ -d "$root" ] || { echo "!! 镜像根不存在: $root"; return 1; }
  [ -d "$dir" ]  || { echo "!! 镜像 lib 目录不存在: $dir"; return 1; }
  pool_init
  : > "$list"
  : > "$list.tmp"

  for f in "$dir"/*.so; do
    # 注意：不能只判 -e。镜像里指向 /system/lib64 的符号链接在设备上是
    # 悬空的（-e 为假），必须用 -L 兜住，否则会静默漏掉一批库。
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    real=$f
    if [ -L "$f" ]; then
      link=$(readlink "$f" 2>/dev/null)
      case "$link" in
        /system/*)
          # 设备路径 /system/lib64/X → 镜像内 system/system/lib64/X
          # （镜像顶层 system/ 是完整根目录，真正的 system 分区在其下的 system/）
          real="$root/system/system/${link#/system/}"
          ;;
        /*)
          # 其它绝对路径：先按"镜像根=设备根"试，再按 system 分区试
          for cand in "$root$link" "$root/system/system$link"; do
            [ -f "$cand" ] && { real=$cand; break; }
          done
          ;;
        *)
          # 相对链接 → 相对当前目录
          cand="$(dirname "$f")/$link"
          [ -f "$cand" ] && real=$cand
          ;;
      esac
      [ -f "$real" ] || { echo "WARN unresolved-link $name -> ${link:-?}" >&2; continue; }
    fi
    m=$(md5of "$real")
    [ -n "$m" ] || continue
    [ -f "$LIBPOOL/$m.so" ] || cp -f "$real" "$LIBPOOL/$m.so" || continue
    echo "$name $m" >> "$list.tmp"
    echo "$name" >> "$list"

    # 链接目标名也实体化一份：原厂布局 libmmkv.so -> libmmkv_n7.so，
    # 前者是加载名、后者是目标名。已验证可用的库集（107/106）两者都带，
    # 为保持一致（防止有库按 _nX 名 dlopen）同样落一份。
    if [ -L "$f" ]; then
      tname=$(basename "$link" 2>/dev/null)
      if [ -n "$tname" ] && [ "$tname" != "$name" ]; then
        echo "$tname $m" >> "$list.tmp"
        echo "$tname" >> "$list"
      fi
    fi
  done

  [ -s "$list.tmp" ] && cat "$list.tmp" >> "$IDX" && rm -f "$list.tmp"
  awk '!seen[$1]++' "$IDX" > "$IDX.u" && mv -f "$IDX.u" "$IDX"
  echo "pool: unique=$(ls "$LIBPOOL"/*.so 2>/dev/null | wc -l) names=$(wc -l < "$list") (from image)"
}

# 按名字清单铺库到目标 lib 目录
# $1=名字清单 $2=目标 lib 目录 $3=期望数量（0=不校验）
# 注意：调用方需保证不与 service.sh 并发（cam.sh 用 flock 串行化）。
# 这里以「铺完再数实际文件」为准，而不是只信循环计数——并发或 cp 失败时
# 循环计数会虚高（本函数初版踩过：报 107/107 实际只有 106）。
pool_fill(){
  local list=$1 dst=$2 want=$3 name p n=0 miss=""
  [ -f "$list" ] || { echo "!! 清单缺失: $list"; return 1; }
  rm -rf "$dst"; mkdir -p "$dst"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    p=$(pool_path "$name")
    if [ -n "$p" ]; then
      cp -f "$p" "$dst/$name" 2>/dev/null && n=$((n+1)) || miss="$miss $name"
    else
      miss="$miss $name"
    fi
  done < "$list"
  chmod 755 "$dst" 2>/dev/null
  find "$dst" -type f -name "*.so" -exec chmod 755 {} \; 2>/dev/null
  [ -n "$miss" ] && echo "!! 失败/缺内容:$miss"
  local real=$(ls "$dst"/*.so 2>/dev/null | wc -l)
  echo "libs=$real${want:+/$want} (pool)"
  if [ -n "$want" ] && [ "$want" != "0" ] && [ "$real" != "$want" ]; then
    return 1
  fi
  return 0
}

pool_status(){
  pool_init
  local u=$(ls "$LIBPOOL"/*.so 2>/dev/null | wc -l)
  local nm=$(wc -l < "$IDX" 2>/dev/null || echo 0)
  local sz=$(du -sm "$LIBPOOL" 2>/dev/null | awk '{print $1}')
  echo "库池: 唯一内容=$u 名字=$nm 体积=${sz:-0}MB  ($LIBPOOL)"
}

# 从既有分集目录迁移（x500_lib / x500pm_lib -> 池 + 两份清单）
# $1=含 backup/ 的目录（模块根）  $2=清单输出目录
# $3=可选：backup 目录的直接路径（测试/异机迁移用）
pool_migrate(){
  local mod=$1 out=$2 b
  b=${3:-$mod/backup}
  pool_init
  if [ -d "$b/x500_lib" ]; then
    pool_build_from_dir "$b/x500_lib" "$out/x500-203.lst"
  else
    echo "skip: $b/x500_lib 不存在"
  fi
  if [ -d "$b/x500pm_lib" ]; then
    pool_build_from_dir "$b/x500pm_lib" "$out/x500pm-163.lst"
  else
    echo "skip: $b/x500pm_lib 不存在"
  fi
  pool_status
}
