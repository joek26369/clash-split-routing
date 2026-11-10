#!/bin/bash
# switch-exit.sh — 出口切换（登录/支付模式 + 全局模式），零重启、秒生效
#
#   switch-exit.sh login on|off|status    只切 MATCH 兜底那一支：
#                                         on  → 兜底走住宅（SSO/3DS/漏网流量全走住宅）
#                                         off → 兜底走机房（默认，省住宅配额）
#   switch-exit.sh global on|off|status   内核 mode 切 rule / global
#   switch-exit.sh status                 两边状态一起看
#
# 原理：mihomo 运行时 API。
#   组切换  → PUT  /proxies/<group>   {"name":"..."}
#   mode    → PATCH /configs          {"mode":"..."}
# 都不需要重启 Verge，也不影响已建立的连接。
#
# ⚠️ 状态一律以内核为准。flag 文件只是「上次操作意图」的记录，
#    目录被动过就会说谎（见 references/pitfalls.md #8）。

set -u
export LC_ALL=en_US.UTF-8

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=""
for c in "$SCRIPT_DIR/config.env" "$HOME/proxy-tools/config.env"; do
  [ -f "$c" ] && CONF="$c" && break
done
if [ -z "$CONF" ]; then
  echo "FAIL: 找不到 config.env，先复制 scripts/config.env.example 为 config.env" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

STATE_DIR="${HOME}/proxy-tools/state"
mkdir -p "$STATE_DIR" 2>/dev/null

api() { # api <METHOD> <PATH> [BODY]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s --max-time 5 -X "$m" --unix-socket "$MIHOMO_SOCK" \
      -H "Authorization: Bearer ${MIHOMO_TOKEN}" \
      -H "Content-Type: application/json" -d "$b" "http://localhost${p}" 2>/dev/null
  else
    curl -s --max-time 5 -X "$m" --unix-socket "$MIHOMO_SOCK" \
      -H "Authorization: Bearer ${MIHOMO_TOKEN}" "http://localhost${p}" 2>/dev/null
  fi
}

core_running() { pgrep -f "verge-mihomo" >/dev/null 2>&1; }

mode_now() {
  # 用 grep 纯文本提取：JSON 过管道时中文字节可能损坏
  api GET /configs | grep -o '"mode":"[^"]*"' | head -1 | cut -d'"' -f4
}

group_now() { # group_now <组名>
  api GET "/proxies/$1" | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4
}

group_select() { # group_select <组名> <成员名>
  api PUT "/proxies/$1" "{\"name\":\"$2\"}" >/dev/null
}

exit_ip() {
  # cloudflare trace 未预钉，走的就是兜底出口 —— 测到的正是切换后的真实出口
  curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep '^ip=' | cut -d= -f2
}

need_core() {
  if ! core_running; then
    echo "FAIL:代理内核未运行，请先打开 Clash Verge"; exit 1
  fi
}

cmd_login() {
  case "${1:-}" in
    on)
      need_core
      group_select "$FALLBACK_GROUP" "$MEMBER_RESIDENTIAL"
      echo "on" > "$STATE_DIR/login-mode"
      sleep 1
      now=$(group_now "$FALLBACK_GROUP"); ip=$(exit_ip)
      # 只校验组选中项，不校验出口 IP —— 住宅节点 IP 会随订阅轮换
      if [ "$now" = "$MEMBER_RESIDENTIAL" ]; then
        echo "OK:登录/支付模式已开启 — 兜底出口 = 住宅 ${ip:-未知}"
        echo "    SSO IdP / 3DS / 漏网国外流量现在全走住宅；用完执行 switch-exit.sh login off"
      else
        echo "FAIL:切换未生效（组=${now:-未知} 出口=${ip:-未知}）— 检查节点状态"; exit 1
      fi
      ;;
    off)
      need_core
      group_select "$FALLBACK_GROUP" "$MEMBER_RELAY"
      rm -f "$STATE_DIR/login-mode"
      sleep 1
      now=$(group_now "$FALLBACK_GROUP"); ip=$(exit_ip)
      if [ "$now" = "$MEMBER_RELAY" ]; then
        echo "OK:登录/支付模式已关闭 — 兜底出口 = 机房 ${ip:-未知}"
      else
        echo "WARN:关闭未完全生效（组=${now:-未知} 出口=${ip:-未知}）"
      fi
      ;;
    status)
      now=$(group_now "$FALLBACK_GROUP")
      if [ "$now" = "$MEMBER_RESIDENTIAL" ]; then
        echo "登录/支付模式: ON（住宅兜底）"
      else
        echo "登录/支付模式: OFF（机房兜底）"
      fi
      echo "${FALLBACK_GROUP} 当前选中: ${now:-未知}"
      echo "当前兜底出口: $(exit_ip)"
      ;;
    *) echo "用法: switch-exit.sh login on|off|status"; exit 2 ;;
  esac
}

cmd_global() {
  case "${1:-}" in
    on)
      need_core
      if [ "$(mode_now)" != "global" ]; then
        api PATCH /configs '{"mode":"global"}' >/dev/null
      fi
      if [ "$(mode_now)" != "global" ]; then
        rm -f "$STATE_DIR/global-mode"
        echo "FAIL:PATCH mode=global 未生效 — 检查内核状态"; exit 1
      fi
      echo "on" > "$STATE_DIR/global-mode"
      # 防节点漂移：订阅更新会把 GLOBAL 组选中项改掉，
      # 全局模式下全部流量压进 GLOBAL，选中节点失效则整网不通
      if [ -n "${GLOBAL_PIN_MEMBER:-}" ]; then
        group_select "$GLOBAL_GROUP" "$GLOBAL_PIN_MEMBER"
      fi
      echo "OK:全局模式已开启 — 所有流量走 ${GLOBAL_GROUP} 组（当前出口 $(exit_ip)）"
      echo "    国内站也走代理；用完执行 switch-exit.sh global off"
      ;;
    off)
      need_core
      rm -f "$STATE_DIR/global-mode"
      if [ "$(mode_now)" != "rule" ]; then
        api PATCH /configs '{"mode":"rule"}' >/dev/null
      fi
      if [ "$(mode_now)" != "rule" ]; then
        echo "FAIL:PATCH mode=rule 未生效 — 检查内核状态"; exit 1
      fi
      echo "OK:全局模式已关闭 — 恢复三向分流（兜底出口 $(exit_ip)）"
      ;;
    status)
      km=$(mode_now)
      if [ "$km" = "global" ]; then
        echo "全局模式: ON（所有流量走 ${GLOBAL_GROUP} 组）"
      else
        echo "全局模式: OFF（rule 三向分流）"
      fi
      echo "内核 mode: ${km:-未知}"
      echo "当前出口: $(exit_ip)"
      ;;
    *) echo "用法: switch-exit.sh global on|off|status"; exit 2 ;;
  esac
}

case "${1:-}" in
  login)  shift; cmd_login  "$@" ;;
  global) shift; cmd_global "$@" ;;
  status)
    echo "── 内核 ──"
    echo "mode: $(mode_now)"
    echo ""
    echo "── 登录/支付模式 ──"
    cmd_login status
    echo ""
    echo "── 全局模式 ──"
    cmd_global status
    ;;
  *) echo "用法: switch-exit.sh login|global|status [on|off|status]"; exit 2 ;;
esac
