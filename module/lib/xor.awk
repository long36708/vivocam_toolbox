# XOR 解密 vivo HAL 配置 .dat（循环密钥 mysecretkey）
# 用法: busybox od -An -tu1 -v <file> | busybox awk -v KEY=mysecretkey -f xor.awk
# 注意: 函数不能叫 xor（busybox awk 有内置 xor）
BEGIN {
  for (i = 0; i < 256; i++) { chr[i] = sprintf("%c", i); ord[chr[i]] = i }
  n = length(KEY)
  for (i = 1; i <= n; i++) kv[i] = ord[substr(KEY, i, 1)]
  c = 0
}
{ for (i = 1; i <= NF; i++) b[++c] = $i + 0 }
END {
  out = ""
  for (i = 1; i <= c; i++) {
    k = ((i - 1) % n) + 1
    out = out chr[bxor(b[i], kv[k])]
    if (length(out) > 4000) { printf "%s", out; out = "" }
  }
  printf "%s", out
}
function bxor(a, b,   r, p, abit, bbit) {
  r = 0; p = 1
  while (a > 0 || b > 0) {
    abit = a % 2; bbit = b % 2
    if (abit != bbit) r += p
    a = int(a / 2); b = int(b / 2); p *= 2
  }
  return r
}
