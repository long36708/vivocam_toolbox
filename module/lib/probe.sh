#!/system/bin/sh
# ============================================================
# lib/probe.sh — 兼容性探针 + 崩溃归因（诊断工具化）
#
# 设计（文档 §5.3 / §5.4）：
#   探针只做「预测」，不构成「可用」结论——docs/FINDINGS.md §7 已证即便 scene
#   齐全，二进制缺判空仍会崩。唯一有效判据是实机出片。
#
#   diagnose 把 tombstone 归到已知签名，省去人工翻 200 行栈。
# ============================================================

# ---------- HAL 配置读取（.xml 直读 / .dat XOR mysecretkey） ----------
# docs/FINDINGS.md：所有 .dat 都是循环 XOR 的明文 XML，密钥 ASCII "mysecretkey"（11 字节）。
# 实现用 od + busybox awk（本机无 python3）。注意 busybox awk 有内置 xor()，
# 自定义函数必须换名（bxor），否则 "Unexpected token"。
BB=${BB:-/data/adb/ksu/bin/busybox}
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null || echo busybox)

hal_cfg_read(){
  local f=$1 awkf="$MODDIR/lib/xor.awk"
  [ -f "$f" ] || return 1
  case "$f" in
    *.dat)
      [ -f "$awkf" ] || { echo "!! 缺 lib/xor.awk"; return 1; }
      $BB od -An -tu1 -v "$f" 2>/dev/null | $BB awk -v KEY=mysecretkey -f "$awkf" 2>/dev/null
      ;;
    *) cat "$f" ;;
  esac
}

# 取某 HAL 配置里所有 scene 名
hal_scenes(){
  hal_cfg_read "$1" 2>/dev/null | grep -o 'SceneMode value="[^"]*"' | sed 's/.*value="//; s/"//' | sort -u
}

# 取某 HAL 配置里所有流名
hal_streams(){
  hal_cfg_read "$1" 2>/dev/null | grep -o 'Stream id="[^"]*"' | sed 's/.*id="//; s/"//' | sort -u
}

# ---------- 探针：目标机 HAL vs 移植包 scene 需求 ----------
# $1=profile_id $2=port_id
probe_target(){
  local pid=$1 port=$2
  local cfgdir=${HAL_CFG_DIR:-/odm/etc/camera}

  echo "=== HAL 配置探测 ($cfgdir) ==="
  local base=""
  for c in StreamConfigInfo_base.xml StreamConfigInfo_base.dat StreamConfigInfo.xml; do
    [ -f "$cfgdir/$c" ] && { base="$cfgdir/$c"; break; }
  done
  [ -n "$base" ] || { echo "!! 未找到 StreamConfigInfo"; return 1; }
  echo "配置: $base"

  local ns=$(hal_scenes "$base" 2>/dev/null | wc -l)
  local nst=$(hal_streams "$base" 2>/dev/null | wc -l)
  echo "目标机 scene=$ns stream=$nst"
  [ "$ns" = "0" ] && { echo "!! 解析不到 scene（.dat 需要 python3）"; return 1; }

  # 移植包请求的 scene：从 APK dex 抓 SCENE_* 常量
  local apk=$(port_apk "$port")
  if [ -f "$apk" ]; then
    echo "=== 移植包 scene 需求 ($port) ==="
    local tmp=/data/local/tmp/probe_dex
    rm -rf "$tmp"; mkdir -p "$tmp"
    unzip -o -q "$apk" 'classes*.dex' -d "$tmp" 2>/dev/null
    grep -a -o 'SCENE_[A-Z0-9_]*' "$tmp"/classes*.dex 2>/dev/null \
      | sed 's/.*://' | sort -u > /data/local/tmp/probe_scenes.txt
    rm -rf "$tmp"
    local np=$(wc -l < /data/local/tmp/probe_scenes.txt)
    echo "包内 SCENE_* 常量=$np"
    echo "⚠ 注意：dex 里的 SCENE_* 大多是 App 侧状态机常量（如 SCENE_DEBUG/SCENE_CONFIG），"
    echo "  并非都会发给 HAL——下面的差集是『可疑上界』，不是崩溃预测。"
    # 差集：包请求但目标机 HAL 不认识
    hal_scenes "$base" 2>/dev/null | sort -u > /data/local/tmp/probe_have.txt
    local miss=$(comm -23 /data/local/tmp/probe_scenes.txt /data/local/tmp/probe_have.txt | wc -l)
    echo "目标机不认识的 scene=$miss"
    if [ "$miss" != "0" ]; then
      echo "--- 样例（前 15）---"
      comm -23 /data/local/tmp/probe_scenes.txt /data/local/tmp/probe_have.txt | head -15
      echo "→ 预测：这些模式可能崩（但仍需实机验证）"
    else
      echo "→ 预测：scene 齐全"
    fi
  fi
  echo
  echo "⚠ 探针只做预测。docs/FINDINGS.md §7/§9 已证：scene 齐全时二进制缺判空仍会崩。"
  echo "  唯一有效判据 = 实机出片 + 手动快门。"
}

# ---------- 崩溃归因 ----------
# 双通道：Java 闪退看 logcat crash 缓冲区（App 直接退出，tombstone 抓不到——
# 实测案例：高→低版本回落后原厂相机录像闪退，根因是 minivlog DB 列冲突），
# native/HAL 看 tombstone。两路都归因输出：用户主诉的闪退通常在前者，
# 但 HAL 崩溃只有 tombstone 有记录——别只看一边。

# 最近一次 com.android.camera 的 FATAL：时间戳\t异常首行\t栈顶帧×3\t链因（最后一个
# Caused by——RuntimeException 包装类崩溃的真实根因都在链尾，如 ReflectException）
java_fatal_latest(){
  logcat -b crash -d 2>/dev/null | awk '
    /FATAL EXCEPTION/ { ts = $1 " " $2; proc = ""; exc = ""; cause = ""; n = 0 }
    ts != "" && match($0, /Process: [A-Za-z0-9._]+/) { proc = substr($0, RSTART + 9, RLENGTH - 9) }
    ts != "" && proc == "com.android.camera" && exc == "" && $0 !~ /Process: / \
      && match($0, /E AndroidRuntime: [A-Za-z]/) { exc = substr($0, RSTART + 18) }
    ts != "" && exc != "" && match($0, /Caused by: /) { cause = substr($0, RSTART + 11) }
    ts != "" && exc != "" && n < 3 && match($0, /[ \t]at [a-zA-Z]/) { fr[n++] = substr($0, RSTART + 1) }
    END { if (ts != "" && exc != "") printf "%s\t%s\t%s\t%s\t%s\t%s", ts, exc, fr[0], fr[1], fr[2], cause }'
}

# Java 闪退归因（$1=java_fatal_latest 的输出）
java_fatal_show(){
  local blk=$1
  local ts=$(printf '%s\n' "$blk" | cut -f1)
  local exc=$(printf '%s\n' "$blk" | cut -f2)
  local f1=$(printf '%s\n' "$blk" | cut -f3)
  local cause=$(printf '%s\n' "$blk" | cut -f6)
  local sig verdict advice
  case "$exc $cause" in
    *"duplicate column name"*)
      sig="minivlog DB duplicate column"
      verdict="高→低版本相机数据残留：16.x 移植相机已升级库表，原厂相机迁移重建同名列失败（PD2419 实测 2026-11）"
      advice="cam.sh clear 清相机数据——设置会重置、MiniVLog 草稿会丢；DCIM 媒体不受影响" ;;
    *configMeatZoomSceneConfig*)
      sig="configMeatZoomSceneConfig is null"
      verdict="伪装码在 APK 内无 MEAT 子类（docs/FINDINGS.md §6）"
      advice="把移植包 port.conf 的 TARGET_PROJECT 改为 APK 实际的 \$\$MEAT 码后重切" ;;
    *"Unable to instantiate application"*)
      sig="CameraApp 实例化失败"
      verdict="App 初始化阶段反射失败，根因看下方链因行（PD2419 曾见重启后首开一过性：18:10 崩、18:13 起正常）"
      advice="链因行给出真实异常；仅重启后首开偶发可先忽略，反复出现则反馈完整链" ;;
    *)
      echo "时间   : $ts"
      echo "异常   : $exc"
      [ -n "$f1" ] && echo "栈顶   : $f1"
      [ -n "$cause" ] && echo "链因   : $cause"
      echo "签名   : 未收录"
      echo "处置   : 把异常与栈顶反馈到仓库 issue；疑似数据残留可先试 cam.sh clear"
      return 0 ;;
  esac
  echo "时间   : $ts"
  echo "签名   : $sig"
  echo "归因   : $verdict"
  [ -n "$cause" ] && echo "链因   : $cause"
  echo "处置   : $advice"
}

diagnose(){
  echo "=== Java 闪退（logcat crash 缓冲区）==="
  local blk
  blk=$(java_fatal_latest)
  if [ -n "$blk" ]; then
    java_fatal_show "$blk"
  else
    echo "（无 com.android.camera 闪退记录）"
  fi
  echo
  echo "=== tombstone（native / HAL）==="
  local td=/data/tombstones
  [ -d "$td" ] || { echo "无 $td"; return 0; }
  local f
  f=$(ls -t "$td"/tombstone_* 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "无 tombstone"; return 0; }
  echo "最新: $f ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
  echo

  local sig="" verdict="" advice=""
  # 1) 用户签名插件（$VIVODIR/plugins/sigs/*.conf）优先：
  #    每条 SIG=<egrep 模式> / VERDICT=<归因> / ADVICE=<处置>
  if [ -d "${PLUGIN_SIGS_DIR:-}" ]; then
    local sf
    for sf in "$PLUGIN_SIGS_DIR"/*.conf; do
      [ -f "$sf" ] || continue
      local pat
      pat=$(conf_get "$sf" '^(SIG)$' SIG 2>/dev/null)
      [ -n "$pat" ] || continue
      if grep -aqE "$pat" "$f" 2>/dev/null; then
        echo "签名   : $pat（来自签名插件 $(basename "$sf")）"
        echo "归因   : $(conf_get "$sf" '^(VERDICT)$' VERDICT 2>/dev/null)"
        echo "处置   : $(conf_get "$sf" '^(ADVICE)$' ADVICE 2>/dev/null)"
        return 0
      fi
    done
  fi
  # 2) 内置签名表
  if grep -q "ExtendCapMainBuilderDecisionRule" "$f" 2>/dev/null; then
    sig="ExtendCapMainBuilderDecisionRule"
    verdict="目标机 stock core 缺判空（docs/FINDINGS.md §9，0x17330c；PD2419 实测）"
    advice="换拍摄模式（如「原生光影」）；HAL 二进制缺陷，不可修"
  elif grep -q "getOutputHALNodeBufferInfos" "$f" 2>/dev/null; then
    sig="getOutputHALNodeBufferInfos"
    verdict="node 18 无输出 buffer（docs/FINDINGS.md §10.4）"
    advice="同上，属扩展管线空路径；换模式"
  elif grep -q "findMatchedActiveHwDevice" "$f" 2>/dev/null; then
    sig="findMatchedActiveHwDevice"
    verdict="hash_table 空节点（docs/FINDINGS.md §10.3）"
    advice="同上"
  elif grep -q "moduleZoomConfig is null" "$f" 2>/dev/null; then
    sig="moduleZoomConfig is null"
    verdict="伪装码在 APK 内无 MEAT 子类（docs/FINDINGS.md §6）"
    advice="把伪装码改成 port 的 TARGET_PROJECT（用 cam.sh ports 看）"
  elif grep -q "Cannot get correct stream id" "$f" 2>/dev/null; then
    sig="Cannot get correct stream id"
    verdict="HAL 配置代际不匹配（缺该流）"
    advice="该移植包与本机 HAL 不兼容；跑 cam.sh probe 看差集"
  elif grep -q "cameraserver\|camerahalserver" "$f" 2>/dev/null; then
    sig="cameraserver/camerahalserver (未归类)"
    verdict="HAL 崩溃，签名未收录"
    advice="取栈顶 3 帧反馈；可能是新机型的新签名"
  else
    echo "未匹配已知签名。栈顶线索："
    grep -A3 "^backtrace:" "$f" 2>/dev/null | head -8
    return 0
  fi

  echo "签名   : $sig"
  echo "归因   : $verdict"
  echo "处置   : $advice"
}

# ---------- 装机自检 ----------
selfcheck(){
  echo "=== vivocam-toolbox 自检 ==="
  echo "模块目录: $MODDIR"
  echo "运行期  : $VIVODIR"
  echo

  echo "--- 身份（只用未污染属性）---"
  echo "ro.product.name            = $(getprop ro.product.name)"
  echo "ro.product.vendor.device   = $(getprop ro.product.vendor.device)"
  echo "ro.boot.product.hardware.sku = $(getprop ro.boot.product.hardware.sku)"
  echo "ro.product.board           = $(getprop ro.product.board)"
  echo "ro.boot.hardware           = $(getprop ro.boot.hardware)"
  echo "（ro.product.device 会被伪装，不作身份用: $(getprop ro.product.device)）"
  echo

  echo "--- profile 匹配 ---"
  if profile_select; then
    echo "命中: $PROFILE_ID ($PROFILE_NAME)"
    echo "SoC=$SOC OS_GEN=$OS_GEN CAM_COUNT=$CAM_COUNT HAL_FMT=$HAL_CFG_FMT"
    [ "$PROFILE_ID" = "_generic" ] && echo "⚠ 未匹配已知机型 → 仅备份+诊断模式"
  else
    echo "!! 无可用 profile"
  fi
  echo

  echo "--- 原厂相机 ---"
  echo "包名   : ${STOCK_PKG:-com.android.camera}"
  local _apk=$(stock_apk_resolve 2>/dev/null)
  echo "APK    : ${_apk:-未定位} $([ -n "$_apk" ] && echo '[自动定位]' || echo '[缺失]')"
  echo "版本   : $(cur_ver)"
  local libd=${STOCK_LIB_DIR:-/nonexistent}
  echo "库目录 : ${libd} ($(ls "$libd"/*.so 2>/dev/null | wc -l) 项)"
  echo

  echo "--- 原厂属性快照（多机型还原依据）---"
  props_status
  echo

  echo "--- 库池 ---"
  pool_status
  echo "--- 原厂备份 ---"
  stock_status "${PROFILE_ID:-_generic}"
  echo

  echo "--- 移植包 ---"
  port_status_all
}
