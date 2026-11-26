#!/system/bin/sh
# ============================================================
# lib/props.sh — 机型属性快照 / 伪装 / 还原
#
# ★ 设计要点（多机型正确性的核心）：
#   绝不能假设「原厂 = PD2419」。装到 X100 上原厂就是 X100 的码。
#   而这些真实值**无法从镜像推导**：
#     - ro.product.device / model.bbk / oem.model / hardware.bbk 都是
#       bootloader/device-tree 阶段注入的，build.prop 里查不到
#     - 镜像里只有 ro.build.expect.hardware=PD2415MA|PD2419MA|PD2458MA
#       这类"期望值列表"，不是本机实际值
#
#   所以策略是「快照 + 回放」：
#     1. 每次开机 post-fs-data 阶段（我们还没伪装前）读一次真实值
#     2. 只有快照缺失、或当前值看起来没被伪装过时，才写入/刷新快照
#     3. 还原时原样回放快照——与本机是什么机型完全无关
#
#   属性改动是 resetprop 写内存，重启即失效，所以每次开机都能拿到
#   未伪装的真值；快照是"跨重启记住它"的唯一可靠手段。
# ============================================================

PROPS_KEYS="ro.product.device ro.product.model.bbk ro.vivo.oem.model ro.hardware.bbk"

# 附加快照键：插件可通过 port.conf 的 SPOOF_PROPS 伪装的"非项目码"属性。
# 这类属性（如 ro.vivo.product.series——vivo 产品系列字母）同样无法从镜像
# 推导本机原厂值，走同一套「快照 + 回放」；不进快照就无法安全还原。
SNAP_EXTRA_KEYS="ro.vivo.product.series"

# resetprop 定位：调用方（cam.sh/post-fs-data.sh）通常已设置 $RP；
# 单独 source 本文件时自己找一遍，避免 $RP 为空导致命令静默失败。
if [ -z "${RP:-}" ] || [ ! -x "${RP:-/nonexistent}" ]; then
  RP=/data/adb/ksu/bin/resetprop
  [ -x "$RP" ] || RP=$(ls /data/adb/*/bin/resetprop 2>/dev/null | head -1)
fi
[ -n "${RP:-}" ] && [ -x "$RP" ] || RP=""

# ★ 权威来源：/proc/cmdline 的 vivooemboot.oem_name（bootloader 注入）
#   resetprop 改不到它，重启也不变，所以「即便当前处于伪装态」也能推回原厂码。
#   实测本机: vivooemboot.oem_name=PD2419B_CN-ZH_FULL_SC_NULL → PD2419
#   同时 product.version=PD2415_A_16.1.12.28.W10（底层共用码，仅作交叉校验）
boot_oem_code(){
  local v
  # cmdline 是空格分隔的单行；用 tr 切成多行再匹配，避免正则跨字段
  v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null \
      | awk -F= '$1=="vivooemboot.oem_name"{print $2; exit}')
  [ -n "$v" ] || return 1
  # PD2419B_CN-ZH_FULL_SC_NULL → PD2419（取前导 PD+数字 段）
  echo "$v" | sed -n 's/^\(PD[0-9][0-9]*\).*/\1/p'
}

# hardware.bbk 的权威来源：cmdline 里没有直接给，但镜像 vendor/build.prop
# 的 ro.build.expect.hardware 列出本平台允许的 *MA 列表；实测本机取项目码+MA。
boot_hw_code(){
  local c=$(boot_oem_code)
  [ -n "$c" ] || return 1
  echo "${c}MA"
}

# 快照文件：key=value 四行
props_file(){ echo "$VIVODIR/original_props"; }

props_get(){ getprop "$1" 2>/dev/null; }

# 当前四个属性的值是否"看起来像被我们伪装过"
# 判据：model.bbk 与 ro.product.name 不同，且 model.bbk 落在某个 port 的
# TARGET_PROJECT 集合里。这样避免把伪装值误存为"原厂"。
props_looks_spoofed(){
  local cur name t
  cur=$(props_get ro.product.model.bbk)
  name=$(props_get ro.product.name)
  [ -n "$cur" ] || return 1
  [ "$cur" = "$name" ] && return 1
  # 收集所有 port 的目标码
  local f
  for f in "$MODDIR"/ports/*.port; do
    [ -f "$f" ] || continue
    t=$(awk -F= '$1=="TARGET_PROJECT"{print $2; exit}' "$f" 2>/dev/null)
    [ -n "$t" ] && [ "$t" = "$cur" ] && return 0
  done
  return 1
}

# 判断 <key> 的 <value> 是否是某个已装插件声明的伪装值
# （快照采集防污染：伪装态下的 getprop 是插件写进去的值，绝不能存成"原厂"）
prop_value_is_spoof(){
  local key=$1 val=$2 conf pair
  for conf in "${PLUGIN_PORTS_DIR:-$VIVODIR/plugins/ports}"/*/port.conf \
              "$MODDIR"/ports/*.port; do
    [ -f "$conf" ] || continue
    for pair in $(conf_get "$conf" "$PORT_FIELDS" SPOOF_PROPS 2>/dev/null); do
      [ "${pair%%=*}" = "$key" ] && [ "${pair#*=}" = "$val" ] && return 0
    done
  done
  return 1
}

# 旧快照迁移：补采 SNAP_EXTRA_KEYS。
# 仅当当前值不是伪装值时写入；伪装态下跳过，重启后 post-fs-data 自动补
# （resetprop 是内存态，开机即恢复真值）。
props_snapshot_migrate(){
  local f k v
  f=$(props_file)
  for k in $SNAP_EXTRA_KEYS; do
    v=$(props_orig "$k" 2>/dev/null)
    [ -n "$v" ] && continue                 # 快照已有该键
    v=$(props_get "$k")
    [ -n "$v" ] || continue                 # 本机没有该属性
    prop_value_is_spoof "$k" "$v" && continue
    echo "$k=$v" >> "$f"
  done
}

# 采集快照
# $1=force（1=无条件覆盖）
#
# 取值优先级（关键：伪装态下也能拿到真值）：
#   1. /proc/cmdline 的 vivooemboot.oem_name → bootloader 注入，resetprop 改不到
#      → 即便当前属性已被伪装，也能推出原厂码
#   2. 当前 getprop 值（仅当它看起来没被伪装）
# 两者都拿不到才失败。
props_snapshot_capture(){
  local force=${1:-0} f k v
  f=$(props_file)
  mkdir -p "$VIVODIR" 2>/dev/null

  if [ "$force" != "1" ] && [ -s "$f" ]; then
    props_snapshot_migrate
    return 0                      # 已有快照，仅补采附加键
  fi

  local boot_code boot_hw
  boot_code=$(boot_oem_code)      # 可能为空
  boot_hw=$(boot_hw_code)

  # 若当前属性明显是伪装态，就只信 cmdline
  local spoofed=0
  props_looks_spoofed && spoofed=1

  local tmp="$f.new.$$"
  : > "$tmp"
  local ok=1
  for k in $PROPS_KEYS $SNAP_EXTRA_KEYS; do
    case "$k" in
      ro.product.device|ro.product.model.bbk|ro.vivo.oem.model)
        if [ "$spoofed" = "1" ] && [ -n "$boot_code" ]; then
          v=$boot_code
        else
          v=$(props_get "$k")
          # 非伪装态下若 getprop 为空，退回 cmdline
          [ -n "$v" ] || v=$boot_code
        fi
        ;;
      ro.hardware.bbk)
        if [ "$spoofed" = "1" ] && [ -n "$boot_hw" ]; then
          v=$boot_hw
        else
          v=$(props_get "$k")
          [ -n "$v" ] || v=$boot_hw
        fi
        ;;
      *)
        # 附加键（SNAP_EXTRA_KEYS）：cmdline 里没有，只能读当前值。
        # 伪装态下读到的是插件写的值——绝不能存进快照。
        v=$(props_get "$k")
        if [ -n "$v" ] && prop_value_is_spoof "$k" "$v"; then
          echo "⚠ $k 当前为伪装值($v)，本次跳过快照（重启后自动补采）" >&2
          v=""
        fi
        ;;
    esac
    if [ -z "$v" ]; then
      case " $SNAP_EXTRA_KEYS " in
        *" $k "*)
          # 附加键拿不到原厂值不致命：不写入快照，等下次开机补采
          continue ;;
      esac
      echo "!! 无法确定原厂值: $k（cmdline 与 getprop 均为空）" >&2
      ok=0; break
    fi
    echo "$k=$v" >> "$tmp"
  done

  if [ "$ok" != "1" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$f"
  return 0
}

# 读快照里的某个键
props_orig(){ awk -F= -v k="$1" '$1==k{print substr($0, index($0,"=")+1); exit}' "$(props_file)" 2>/dev/null; }

props_have_snapshot(){ [ -s "$(props_file)" ]; }

# 伪装成 $1 指定的项目码
# hardware.bbk 默认跟随同码；若 profile 提供 HWBBK_MAP（形如 "PD2419=PD2419MA"）
# 则按表映射——但只用于"没有快照时的兜底还原"，正常伪装走同码。
props_spoof(){
  local code=$1 hw=$1 pair
  [ -n "$code" ] || return 1
  [ -n "$RP" ] || { echo "!! resetprop 不可用，无法改属性" >&2; return 1; }
  for pair in $HWBBK_MAP; do
    [ "${pair%%=*}" = "$code" ] && hw="${pair#*=}"
  done
  $RP ro.product.device    "$code"
  $RP ro.product.model.bbk "$code"
  $RP ro.vivo.oem.model    "$code"
  $RP ro.hardware.bbk      "$hw"
  # 插件声明的附加属性（port.conf 的 SPOOF_PROPS="key=value ..."）。
  # 实战案例：S60 相机读 ro.vivo.product.series 判产品系列——不伪装时本机
  # 真值(X)与 MEAT 配置(S)并存，DeviceUtil.isSSeries/isXSeries 同时命中，
  # 一拍得闪光灯 entries/entryValues 错配（3/2）→ 启动即崩。
  for pair in ${SPOOF_PROPS:-}; do
    case "$pair" in *=*) $RP "${pair%%=*}" "${pair#*=}" ;; esac
  done
}

# 还原为原厂值
#
# 三级来源，逐级降级：
#   1. 快照（最准，含 hardware.bbk 的原始值）
#   2. /proc/cmdline 的 bootloader 注入值（伪装态下也可靠）
#   3. ro.product.name 推断（最后兜底）
props_restore(){
  local k v
  [ -n "$RP" ] || { echo "!! resetprop 不可用，无法还原属性" >&2; return 1; }

  # 0) 附加键：有快照就回放；无快照只能警告（伪装值可能残留到下次开机）
  for k in $SNAP_EXTRA_KEYS; do
    v=$(props_orig "$k" 2>/dev/null)
    if [ -n "$v" ]; then
      $RP "$k" "$v"
    elif [ -n "$(props_get "$k")" ]; then
      echo "⚠ $k 无快照，无法还原原厂值（伪装值可能残留；重启后 post-fs-data 自动补快照）" >&2
    fi
  done

  # 1) 快照
  if props_have_snapshot; then
    local miss=0
    for k in $PROPS_KEYS; do
      v=$(props_orig "$k")
      if [ -n "$v" ]; then $RP "$k" "$v"; else miss=$((miss+1)); fi
    done
    [ "$miss" = "0" ] && return 0
  fi

  # 2) cmdline（bootloader 注入，resetprop 改不到）
  local code hw
  code=$(boot_oem_code); hw=$(boot_hw_code)
  if [ -n "$code" ]; then
    [ -n "$hw" ] || hw=$code
    $RP ro.product.device    "$code"
    $RP ro.product.model.bbk "$code"
    $RP ro.vivo.oem.model    "$code"
    $RP ro.hardware.bbk      "$hw"
    return 0
  fi

  # 3) ro.product.name 兜底（该属性我们从不改）
  local name=$(props_get ro.product.name)
  [ -n "$name" ] || return 1
  hw=$name
  local pair
  for pair in $HWBBK_MAP; do
    [ "${pair%%=*}" = "$name" ] && hw="${pair#*=}"
  done
  $RP ro.product.device    "$name"
  $RP ro.product.model.bbk "$name"
  $RP ro.vivo.oem.model    "$name"
  $RP ro.hardware.bbk      "$hw"
  return 0
}

# 显示快照状态（诊断用）
props_status(){
  local f=$(props_file)
  if props_have_snapshot; then
    echo "原厂属性快照: $f"
    sed 's/^/  /' "$f"
  else
    echo "原厂属性快照: 缺失（下次开机 post-fs-data 会自动采集）"
  fi
  echo "当前实际:"
  local k
  for k in $PROPS_KEYS $SNAP_EXTRA_KEYS; do
    printf "  %-24s = %s\n" "$k" "$(props_get "$k")"
  done
}
