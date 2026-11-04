#!/usr/bin/env bash
# ============================================================
# build.sh — 打包 vivocam-toolbox 模块 zip（开源仓库版）
#
# 用法: bash build.sh
# 产物: dist/vivocam-toolbox-v<版本>.zip
#
# 打包内容 = module/ 目录（脚本 + lib + profiles + 内置 port 描述 + WebUI）。
# ★ 不含任何 APK / native 库：vivo 相机固件是专有文件，本仓库不分发。
#   移植包由用户从自己获取的固件解包目录生成：
#     sh cam.sh addport <镜像根> <family>   （见 docs/ARCHITECTURE.md）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

SRC=module
DIST=dist
VER=$(grep '^version=' "$SRC/module.prop" | cut -d= -f2)

[ -f "$SRC/module.prop" ] || { echo "!! 缺 $SRC/module.prop"; exit 1; }

REQUIRED="module.prop cam.sh service.sh post-fs-data.sh uninstall.sh
lib/conf.sh lib/profile.sh lib/port.sh lib/plugin.sh lib/libpool.sh
lib/backup.sh lib/probe.sh lib/props.sh lib/xor.awk
lib/x500-203.lst lib/x500pm-210.lst
profiles/pd2419.profile profiles/_generic.profile profiles/x100.profile
ports/x500.port ports/x500pm.port
webroot/index.html"
for f in $REQUIRED; do
  [ -f "$SRC/$f" ] || { echo "!! 缺少必需文件: $SRC/$f"; exit 1; }
done

# 语法检查（任意 POSIX shell；mksh/busybox ash 差异小）
if command -v sh >/dev/null 2>&1; then
  for f in "$SRC"/cam.sh "$SRC"/service.sh "$SRC"/post-fs-data.sh "$SRC"/uninstall.sh "$SRC"/lib/*.sh; do
    sh -n "$f" || { echo "!! 语法错误: $f"; exit 1; }
  done
fi

mkdir -p "$DIST"
OUT="$DIST/vivocam-toolbox-$VER.zip"
rm -f "$OUT"

python - "$SRC" "$OUT" <<'PY'
import os, sys, zipfile, stat

src, out = sys.argv[1], sys.argv[2]
EXEC = {'cam.sh', 'service.sh', 'post-fs-data.sh', 'uninstall.sh'}
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in ('__pycache__', '.git', '.versions', 'out')]
        for name in sorted(files):
            if name == '.DS_Store':
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src).replace(os.sep, '/')
            zi = zipfile.ZipInfo(rel)
            mode = 0o755 if (name in EXEC or (name.endswith('.sh') and rel.startswith('lib/'))) else 0o644
            zi.external_attr = (stat.S_IFREG | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(full, 'rb') as f:
                z.writestr(zi, f.read())
print("打包完成:", out)
PY

unzip -l "$OUT" >/dev/null 2>&1 && python - "$OUT" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
assert 'module.prop' in names, 'module.prop 必须在 zip 根'
print(f"共 {len(names)} 个文件 | 体积:", end=' ')
import os
print(f"{os.path.getsize(sys.argv[1])/1024:.0f} KB | module.prop 在根 ✓")
print("警告：包内含 APK（不应分发）!" if any(n.endswith('.apk') for n in names) else "不含专有固件 ✓")
PY
