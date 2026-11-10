#!/bin/bash
# check-config.sh — 配置体检：把「静默失效」的几类问题查出来
#
#   check-config.sh          只读检查
#   check-config.sh --fix    解除 uchg 锁（会导致编辑失败的那个）
#
# 检查项：
#   1. 目录与文件是否齐全
#   2. YAML 是否合法（缩进错会让 Verge 静默跳过整个文件）
#   3. 内核 mode 与 Merge.yaml 是否一致
#   4. sniffer.override-destination 是否打开
#   5. 规则数与关键规则是否在位
#   6. 组定义是否存在、AI 组是否只有一个成员
#   7. 三个出口 IP 是否互不相同（相同 = 规则没生效）

set -u
export LC_ALL=en_US.UTF-8

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=""
for c in "$SCRIPT_DIR/config.env" "$HOME/proxy-tools/config.env"; do
  [ -f "$c" ] && CONF="$c" && break
done
if [ -z "$CONF" ]; then
  echo "FAIL: 找不到 config.env" >&2; exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

PASS=0; WARN=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }

echo "════════ 配置体检 ════════"
echo ""

# ── 1. 文件 ──
echo "── 1. 配置文件 ──"
if [ -d "$PROFILES_DIR" ]; then
  ok "配置目录存在：$PROFILES_DIR"
else
  bad "找不到配置目录：$PROFILES_DIR"
fi
[ -f "$CLASH_DIR/Merge.yaml" ] && ok "Merge.yaml 存在" || warn "Merge.yaml 不存在（全局 merge 未启用）"

# ── 2. YAML 合法性 ──
echo ""
echo "── 2. YAML 合法性 ──"
YAML_OK=1
if python3 -c "import yaml" 2>/dev/null; then
  while IFS= read -r f; do
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null; then
      :
    else
      bad "$(basename "$f") 解析失败（缩进错误会让整个文件被跳过）"
      YAML_OK=0
    fi
  done <<EOF
$(find "$PROFILES_DIR" -maxdepth 1 -name '*.yaml' ! -name '*.bak*' 2>/dev/null)
EOF
  [ "$YAML_OK" = 1 ] && ok "所有 yaml 解析通过"
else
  warn "未安装 pyyaml，跳过严格校验（pip3 install pyyaml 可启用）"
fi

# ── 3. uchg 锁 ──
echo ""
echo "── 3. 不可变标志（uchg）──"
LOCKED=""
for f in "$CLASH_DIR/Merge.yaml" "$PROFILES_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  if ls -lO "$f" 2>/dev/null | grep -q uchg; then
    LOCKED="$LOCKED $(basename "$f")"
    if [ "$FIX" = 1 ]; then
      chflags nouchg "$f" 2>/dev/null && ok "已解锁 $(basename "$f")"
    else
      warn "$(basename "$f") 带 uchg 锁，编辑会静默失败（加 --fix 解锁）"
    fi
  fi
done
[ -z "$LOCKED" ] && ok "无 uchg 锁"

# ── 4. mode ──
echo ""
echo "── 4. 内核 mode ──"
core_mode=$(curl -s --max-time 4 --unix-socket "$MIHOMO_SOCK" \
  -H "Authorization: Bearer ${MIHOMO_TOKEN}" http://localhost/configs 2>/dev/null \
  | grep -o '"mode":"[^"]*"' | head -1 | cut -d'"' -f4)
file_mode=$(grep -m1 '^mode:' "$CLASH_DIR/Merge.yaml" 2>/dev/null | awk '{print $2}')

if [ -z "$core_mode" ]; then
  warn "读不到内核（Clash Verge 未启动？）"
else
  if [ "$core_mode" = "rule" ]; then
    ok "内核 mode = rule"
  else
    bad "内核 mode = $core_mode（规则不会生效，国内站也会走代理）"
  fi
  if [ -n "$file_mode" ] && [ "$file_mode" != "$core_mode" ]; then
    warn "Merge.yaml 写的是 $file_mode，内核是 $core_mode —— 重启后会被改回去"
  fi
fi

# ── 5. sniffer ──
echo ""
echo "── 5. 域名嗅探 ──"
if grep -q 'override-destination: *true' "$CLASH_DIR/Merge.yaml" 2>/dev/null; then
  ok "override-destination = true"
else
  bad "override-destination 未开启 —— 客户端用裸 IP 连接时会被节点拒绝（tlsv1 alert）"
fi

# ── 6. 规则 ──
echo ""
echo "── 6. 规则 ──"
rule_files=$(grep -l '^prepend:' "$PROFILES_DIR"/*.yaml 2>/dev/null | grep -v Merge || true)
if [ -n "$rule_files" ]; then
  for f in $rule_files; do
    n=$(awk '/^prepend:/{f=1;next} f&&/^[a-z]+:/{f=0} f&&/- /{c++} END{print c+0}' "$f")
    has_ai=$(grep -c ",${AI_GROUP}" "$f" 2>/dev/null)
    has_match=$(awk '/^append:/{f=1;next} f&&/^[a-z]+:/{f=0} f&&/MATCH/{c++} END{print c+0}' "$f")
    echo "  · $(basename "$f")：prepend ${n} 条，指向 ${AI_GROUP} 的 ${has_ai} 条，append MATCH ${has_match} 条"
    [ "$n" -lt 10 ] && warn "  规则数偏少，可能没生效"
    [ "$has_ai" -lt 5 ] && warn "  指向 ${AI_GROUP} 的规则异常少"
    [ "$has_match" -eq 0 ] && bad "  缺少 append MATCH —— 兜底出口未定义"
  done
else
  warn "没找到规则增强文件"
fi

# ── 7. 组 ──
echo ""
echo "── 7. 代理组 ──"
GROUP_OK=1
for g in "$AI_GROUP" "$FALLBACK_GROUP" "$GLOBAL_GROUP"; do
  hit=$(grep -l "name: *\"\?${g}\"\?$" "$PROFILES_DIR"/*.yaml 2>/dev/null | head -1)
  if [ -n "$hit" ]; then
    ok "${g} 已定义（$(basename "$hit")）"
  else
    # 订阅本身可能已定义，这里只提示
    warn "${g} 未在增强文件里找到（可能来自订阅本身，确认一下）"
    GROUP_OK=0
  fi
done

# ── 8. 三出口 ──
echo ""
echo "── 8. 三向出口实测 ──"
d=$(curl -s --max-time 6 https://myip.ipip.net 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
a=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
f=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
echo "  国内探针 : ${d:-超时}"
echo "  AI 支路  : ${a:-超时}"
echo "  兜底支路 : ${f:-超时}"

uniq_n=$(printf '%s\n%s\n%s\n' "$d" "$a" "$f" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [ "$uniq_n" -le 1 ] && [ -n "$d" ]; then
  bad "三个出口 IP 完全相同 —— 规则未生效（多半是 global 模式残留）"
elif [ "$d" = "$a" ] && [ -n "$d" ]; then
  warn "国内探针与 AI 支路同 IP —— 国内没走直连，或 AI 支路没走住宅"
else
  ok "至少两个出口互不相同，分流在工作"
fi

echo ""
echo "════════ 结果 ════════"
echo "  通过 ${PASS} / 警告 ${WARN} / 失败 ${FAIL}"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
