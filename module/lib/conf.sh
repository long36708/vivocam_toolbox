#!/system/bin/sh
# ============================================================
# lib/conf.sh — KEY=VALUE 配置的安全解析器（插件架构 P1）
#
# ★ 为什么必须换掉 `. "$file"`：
#   旧实现用 shell source 读 port/profile 配置，等于把插件 conf 当
#   root 代码执行——恶意 port.conf 里写一行 `rm -rf /` 就会被执行。
#   插件化后配置来自外部（网盘/别人分享），这个注入面必须关掉。
#
# 实现说明（POSIX sh 没有不求值的动态赋值，所以用「受控求值」）：
#   1. 键必须命中白名单正则，且只允许 [A-Za-z_][A-Za-z0-9_]*——
#      PATH/LD_PRELOAD/IFS 这类危险名根本进不来
#   2. 值做单引号转义后拼进单引号字符串再 eval——文件内容永远是
#      字面量，永远不会被当作代码。注入用例实测全部保持字面量
#   3. 值支持三种写法（模板/描述文件里都很常见）：
#        KEY=裸值               KEY=裸值     # 行尾注释
#        KEY="带空格的值"        KEY="带空格的值"  # 行尾注释
#      成对引号判断先于注释剥离，否则 KEY="v" # c 会残留引号；
#      只出现半个引号时按裸值处理（引号不吞）
#   4. CRLF 兼容：行尾 \r 会被剥掉
#
# ⚠ mksh 陷阱：case 模式里直接写反斜杠转义引号（\"）不可靠——实测匹配语义
#   会退化成「必须以引号结尾」，`"a" # c` 反而不命中。本文件把引号存进变量
#   QU，用 *"$QU"*"$QU"*) 形式（变量展开后引号作为字面量参与模式），行为正确。
# ============================================================

# 单引号转义（读 stdin）：' -> '\''
_sq(){ sed "s/'/'\\\\''/g"; }

# 受控赋值：$1=已校验变量名 $2=字面值
_conf_set(){ eval "$1='$(printf "%s" "$2" | _sq)'"; }

# conf_read <file> <allow_regex> <prefix>
#   逐行解析 KEY=VALUE，允许的键读成 ${prefix}${KEY}；不认识的键直接跳过
#   prefix 为空时变量名就是 KEY 本身（兼容现有调用点）
conf_read(){
  local f=$1 allow=$2 pfx=$3
  [ -f "$f" ] || return 1
  local CR TAB QU LINE key val
  CR=$(printf '\r')
  TAB=$(printf '\t')
  QU='"'
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE=${LINE%"$CR"}
    case "$LINE" in ''|\#*|\;*) continue ;; esac
    case "$LINE" in *=*) ;; *) continue ;; esac
    key=${LINE%%=*}
    val=${LINE#*=}
    # 键去首尾空白
    while :; do case "$key" in ' '*|"$TAB"*) key=${key#?} ;; *) break ;; esac; done
    while :; do case "$key" in *' '|*"$TAB") key=${key%?} ;; *) break ;; esac; done
    [ -n "$key" ] || continue
    # 键字符白名单（挡前导数字与下划线开头，避免碰内部变量）
    case "$key" in *[!A-Za-z0-9_]*|[0-9]*|_*) continue ;; esac
    # 字段白名单正则
    if [ -n "$allow" ]; then
      printf '%s' "$key" | grep -qE "$allow" 2>/dev/null || continue
    fi

    # ---- 值处理：成对引号优先（容忍其后空白+#注释）；无引号才剥行内注释 ----
    case "$val" in
      *"$QU"*"$QU"*)
        val=${val#*"$QU"}
        val=${val%"$QU"*}
        ;;
      *)
        case "$val" in *" #"*) val=${val%%' #'*} ;; esac
        ;;
    esac
    # 统一去首尾空白/制表符
    while :; do case "$val" in ' '*|"$TAB"*) val=${val#?} ;; *) break ;; esac; done
    while :; do case "$val" in *' '|*"$TAB") val=${val%?} ;; *) break ;; esac; done

    _conf_set "${pfx}${key}" "$val"
  done < "$f"
  return 0
}

# 便捷读取单个键（不落变量）：conf_get <file> <allow_regex> <KEY>
conf_get(){
  # 键格式校验：$3 会被拼进 unset/变量名，不接受任意字符串
  case "$3" in *[!A-Za-z0-9_]*|[0-9]*|_*) return 1 ;; esac
  local pfx=__cg_
  unset "__cg_${3}" 2>/dev/null
  conf_read "$1" "$2" "$pfx" || return 1
  eval "printf '%s' \"\${${pfx}${3}:-}\""
  unset "__cg_${3}" 2>/dev/null
}
