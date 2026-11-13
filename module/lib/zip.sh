#!/system/bin/sh
# ============================================================
# lib/zip.sh — store-only zip 打包器（插件导出分享的设备侧兜底）
#
# 为什么存在：真机实测（docs/PLUGIN-EXPORT.md）KSU 的 busybox 是
# Magisk 构建（v1.36.1.1，358 applets），zip 相关只有解包三件套
# （bunzip2/gzip/unzip），没有打包 applet；toybox 也没有 zip/crc32。
# plugin export 因此需要零依赖的 zip 生成能力。
#
# 原理（zip 规格 PKWARE APPNOTE）：
#   zip = [local file header 30B + 文件名 + 数据] × N
#       + central directory (46B + 文件名) × N
#       + EOCD 22B。store 模式压缩方法=0——APK/.so 本就是高压缩内容，
#       不压缩体积几乎无损失（PLUGIN-EXPORT.md 的设计前提）。
#   CRC-32 不自己算：gzip 尾部 8 字节 = CRC32 + ISIZE（RFC 1952，
#   均为小端 4 字节）——恰好就是 zip 头需要的字段，C 速度、零新代码。
#   ⚠ 依赖小端机（gzip trailer 按 od/xxd 的宿主字节序解读）——
#   本模块的目标机全是 arm64 LE。
#
# 头部以 hex 字符串拼好再经 `xxd -r -p` 还原成二进制；正文用 cat 直通，
# 不经过任何文本处理。ISIZE 与 stat 的实测大小互为校验（防 gzip 半截）。
# ============================================================

# $1=文件 → 输出 "crc size"（十进制）。CRC 来自 gzip 尾部（-1 最快档）
zip_store_crc(){
  local h
  h=$(busybox gzip -1c "$1" | tail -c 8 | busybox xxd -p | tr -d '\n\r ')
  [ ${#h} = 16 ] || return 1
  awk -v h="$h" '
    function h2d(s,  i, r){ r=0
      for(i=1;i<=length(s);i++) r=r*16+index("0123456789abcdef",substr(s,i,1))-1
      return r }
    BEGIN{
      # 尾 8 字节 = CRC32(LE 4B) + ISIZE(LE 4B)：按小端拼回数值
      printf "%d %d\n",
        h2d(substr(h,7,2) substr(h,5,2) substr(h,3,2) substr(h,1,2)),
        h2d(substr(h,15,2) substr(h,13,2) substr(h,11,2) substr(h,9,2))
    }'
}

# 写一个文件的 local header + 数据 + CD 条目
# $1=输出zip $2=根目录 $3=相对路径 $4=CD暂存文件；Z_OFF/Z_NENT 为调用方累积的全局
zip_store_file(){
  local out=$1 root=$2 name=$3 cdf=$4
  local f="$root/$name"
  [ -f "$f" ] || { echo "!! zip_store: 不是文件: $name"; return 1; }
  local cs crc size
  cs=$(zip_store_crc "$f") || { echo "!! CRC 计算失败: $name"; return 1; }
  crc=${cs%% *}; size=${cs##* }
  [ -n "$crc" ] && [ -n "$size" ] \
    && [ "$size" = "$(stat -c %s "$f")" ] \
    || { echo "!! CRC/大小校验失败: $name"; return 1; }
  local nlen=${#name}   # 条目名均为 ASCII（port.conf names.lst VivoCamera.apk lib/*.so）

  # local file header：sig + 版本20 + flags0 + method0(store) + time0 + date(2024-01-01)
  #                  + CRC + csize + usize + 名长 + extra0
  # ⚠ awk 的 print 必须单行：字符串拼接靠紧邻，裸换行会终止 print，
  #   后续行被当成"裸表达式语句"静默丢弃（本文件初版踩过：CD/EOCD 被截断）
  awk -v crc="$crc" -v size="$size" -v nlen="$nlen" '
    function h1(b){ return sprintf("%02x", b) }
    function le16(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) }
    function le32(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) h1(int(v/65536)%256) h1(int(v/16777216)%256) }
    BEGIN{ print "504b0304" le16(20) "0000" "0000" "0000" "2158" le32(crc) le32(size) le32(size) le16(nlen) "0000" }' \
    | busybox xxd -r -p >> "$out" || return 1
  printf '%s' "$name" >> "$out"
  cat "$f" >> "$out" || return 1

  # central directory 条目：+ made-by20 + disk0 + 内/外属性（0644=0x81a4）+ 本地偏移
  awk -v crc="$crc" -v size="$size" -v nlen="$nlen" -v off="$Z_OFF" '
    function h1(b){ return sprintf("%02x", b) }
    function le16(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) }
    function le32(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) h1(int(v/65536)%256) h1(int(v/16777216)%256) }
    BEGIN{ print "504b0102" le16(20) le16(20) "0000" "0000" "0000" "2158" le32(crc) le32(size) le32(size) le16(nlen) "0000" "0000" "0000" "0000" "a4810000" le32(off) }' \
    | busybox xxd -r -p >> "$cdf" || return 1
  printf '%s' "$name" >> "$cdf"

  Z_OFF=$(( Z_OFF + 30 + nlen + size ))
  Z_NENT=$(( Z_NENT + 1 ))
  return 0
}

# zip_store <输出zip> <根目录> <条目...>
# 条目为相对根目录的路径；目录自动递归其下全部普通文件。
# 条目名即 zip 内路径（'/' 分隔）；不写目录条目，解包端按文件路径隐式建目录。
zip_store(){
  local out=$1 root=$2; shift 2
  [ -n "$out" ] && [ -d "$root" ] && [ $# -gt 0 ] \
    || { echo "用法: zip_store <输出zip> <根目录> <条目...>"; return 1; }
  local cd="$out.cd.$$"
  : > "$cd" || return 1
  Z_OFF=0 Z_NENT=0

  local ent f
  for ent in "$@"; do
    if [ -d "$root/$ent" ]; then
      for f in $(find "$root/$ent" -type f | sort); do
        zip_store_file "$out" "$root" "${f#"$root"/}" "$cd" \
          || { rm -f "$cd" "$out"; return 1; }
      done
    else
      zip_store_file "$out" "$root" "$ent" "$cd" \
        || { rm -f "$cd" "$out"; return 1; }
    fi
  done

  # central directory + EOCD
  local cdoff cdsize
  cdoff=$(stat -c %s "$out")
  cat "$cd" >> "$out" || { rm -f "$cd"; return 1; }
  cdsize=$(( $(stat -c %s "$out") - cdoff ))
  rm -f "$cd"
  awk -v n="$Z_NENT" -v cdsz="$cdsize" -v cdoff="$cdoff" '
    function h1(b){ return sprintf("%02x", b) }
    function le16(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) }
    function le32(v){ v=int(v); return h1(v%256) h1(int(v/256)%256) h1(int(v/65536)%256) h1(int(v/16777216)%256) }
    BEGIN{ print "504b0506" "0000" "0000" le16(n) le16(n) le32(cdsz) le32(cdoff) "0000" }' \
    | busybox xxd -r -p >> "$out" || return 1
  return 0
}
