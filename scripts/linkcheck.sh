#!/bin/bash
# linkcheck.sh — 链路体检：RTT / 丢包 / 抖动，可选逐跳
#
#   linkcheck.sh --target <IP>              单目标，20 包
#   linkcheck.sh --target <IP> --long       60 包（晚高峰用，20 包太短，
#                                           一次 6 秒的突发就能把均值从 171 拉到 245）
#   linkcheck.sh --target <IP> --full       追加上去程 traceroute（需 sudo）
#   linkcheck.sh --targets <文件>           多目标对比表
#   linkcheck.sh --save                     落盘到 ~/proxy-tools/state/linkcheck/
#
# targets 文件格式（一行一个，# 开头是注释）：
#   名称|IP|备注
#
# ⚠️ TUN 模式下 ICMP 由内核代发，traceroute 也看不到真实路径。
#    --full 会临时给目标加一条 /32 路由走物理网关绕开 TUN，跑完自动删。

set -u
export LC_ALL=en_US.UTF-8

PKT=20
IVL=0.3
TARGET=""
TARGETS_FILE=""
FULL=0
SAVE=0
STATE_DIR="${HOME}/proxy-tools/state/linkcheck"

while [ $# -gt 0 ]; do
  case "$1" in
    --target)  TARGET="${2:-}"; shift 2 ;;
    --targets) TARGETS_FILE="${2:-}"; shift 2 ;;
    --long)    PKT=60; IVL=0.5; shift ;;
    --full)    FULL=1; shift ;;
    --save)    SAVE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: ${1}（-h 看用法）" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET" ] && [ -z "$TARGETS_FILE" ]; then
  echo "需要 --target <IP> 或 --targets <文件>（-h 看用法）" >&2
  exit 2
fi

# ── TUN 检测 ──
tun_active() {
  pgrep -f "verge-mihomo|mihomo|sing-box" >/dev/null 2>&1
}

one_target() { # one_target <ip> → 输出 "min|avg|max|stdev|loss"
  local ip="$1"
  local out line vals
  out=$(ping -c "$PKT" -i "$IVL" -t 200 "$ip" 2>/dev/null)
  line=$(printf '%s\n' "$out" | grep 'round-trip')
  if [ -z "$line" ]; then
    echo "--- |--- |--- |--- |100"
    return
  fi
  vals=$(printf '%s' "$line" | sed 's/.*= *//; s/ ms.*//')
  local loss
  loss=$(printf '%s\n' "$out" | grep -oE '[0-9.]+% packet loss' | head -1 | sed 's/% packet loss//')
  printf '%s|%s|%s|%s|%s\n' \
    "$(printf '%s' "$vals" | cut -d/ -f1)" \
    "$(printf '%s' "$vals" | cut -d/ -f2)" \
    "$(printf '%s' "$vals" | cut -d/ -f3)" \
    "$(printf '%s' "$vals" | cut -d/ -f4)" \
    "${loss:-0}"
}

echo "════════ 链路体检 $(date '+%Y-%m-%d %H:%M:%S %Z') ════════"
if tun_active; then
  echo "⚠️  检测到代理内核在运行：ICMP 可能由内核代发，逐跳不可信"
  echo "   （比较「直连」与「代理」两条路径的延迟在 TUN 下是无效的）"
fi
echo ""

# ── 单目标 ──
if [ -n "$TARGET" ]; then
  R=$(one_target "$TARGET")
  mn=$(printf '%s' "$R" | cut -d'|' -f1)
  av=$(printf '%s' "$R" | cut -d'|' -f2)
  mx=$(printf '%s' "$R" | cut -d'|' -f3)
  sd=$(printf '%s' "$R" | cut -d'|' -f4)
  ls=$(printf '%s' "$R" | cut -d'|' -f5)

  echo "目标 : ${TARGET}"
  echo "样本 : ${PKT} 包"
  echo "  RTT    : ${av} ms（min ${mn} / max ${mx} / 抖动 ${sd}）"
  echo "  丢包   : ${ls}%"

  # min 正常而 max 偏高 → 排队延迟，不是路径劣化
  if [ "$mn" != "---" ] && [ "$mx" != "---" ]; then
    awk -v mi="$mn" -v ma="$mx" -v l="$ls" 'BEGIN{
      d = ma - mi
      if (d > 20 && l + 0 == 0)
        printf "  判读   : 峰值高出 %0.0f ms 且零丢包 → 瞬时排队积压，路径本身没问题\n", d
      else if (d > 20 && l + 0 > 0)
        printf "  判读   : 波动 %0.0f ms 且丢包 %s%% → 链路真实拥塞\n", d, l
      else
        printf "  判读   : 稳定\n"
    }'
  fi

  # ── 逐跳 ──
  if [ "$FULL" = 1 ]; then
    echo ""
    echo "──── 去程逐跳 ────"
    GW=$(netstat -rn -f inet | awk '/^default/{print $2; exit}')
    echo "  物理网关: ${GW:-未找到}"
    if sudo -n true 2>/dev/null || [ -t 0 ]; then
      sudo route add -host "$TARGET" "$GW" 2>/dev/null || echo "  （路由已存在，继续）"
      trap 'sudo route delete -host "'"$TARGET"'" 2>/dev/null' EXIT INT TERM
      sudo traceroute -n -q 1 -w 2 -m 20 "$TARGET" 2>&1 | sed 's/^/  /'
    else
      echo "  ⚠️  需要 sudo 才能加临时路由绕开 TUN。先执行 sudo -v 再重跑。"
    fi
  fi
fi

# ── 多目标 ──
if [ -n "$TARGETS_FILE" ]; then
  if [ ! -f "$TARGETS_FILE" ]; then
    echo "FAIL: 找不到 ${TARGETS_FILE}" >&2; exit 1
  fi
  RAW=$(mktemp /tmp/linkcheck.XXXXXX)
  trap 'rm -f "$RAW"' EXIT INT TERM
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    ip=$(printf '%s' "$line" | cut -d'|' -f2)
    note=$(printf '%s' "$line" | cut -d'|' -f3)
    [ -z "$ip" ] && continue
    R=$(one_target "$ip")
    echo "${name}|${ip}|${note}|${R}" >> "$RAW"
  done < "$TARGETS_FILE"

  python3 - "$RAW" <<'PY'
import sys, unicodedata
def w(s): return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
def pad(s,n): return s+" "*max(0,n-w(s))
def padl(s,n): return " "*max(0,n-w(s))+s

rows=[]
for ln in open(sys.argv[1], encoding="utf-8"):
    p=ln.rstrip("\n").split("|")
    if len(p)>=8: rows.append(p)

hdr=[("节点",14),("位置",20),("min",8),("avg",8),("max",8),("抖动",7),("丢包",7)]
print("  "+" ".join(pad(h,n) if i<2 else padl(h,n) for i,(h,n) in enumerate(hdr)))
print("  "+"─"*(sum(n for _,n in hdr)+len(hdr)-1))
for p in rows:
    cells=[pad(p[0],14),pad(p[2],20),padl(p[3],8),padl(p[4],8),
           padl(p[5],8),padl(p[6],7),padl(p[7].strip()+"%",7)]
    print("  "+" ".join(cells))

valid=[p for p in rows if p[4].strip() not in ("---","")]
if valid:
    print()
    best=min(valid,key=lambda p: float(p[4]))
    worst=max(valid,key=lambda p: float(p[4]))
    print(f"  最快 : {best[0]}  {best[4]} ms")
    print(f"  最慢 : {worst[0]}  {worst[4]} ms（相差 {float(worst[4])-float(best[4]):.1f} ms）")
    for p in valid:
        sd=float(p[6]) if p[6].strip() not in ("","---") else 0
        ls=float(p[7]) if p[7].strip() not in ("","---") else 0
        if ls>2: print(f"  ⚠️ {p[0]}：丢包 {ls}% > 2%，链路真实拥塞")
        if sd>20: print(f"  ⚠️ {p[0]}：抖动 {sd:.1f} ms，存在排队积压")
PY

  if [ "$SAVE" = 1 ]; then
    mkdir -p "$STATE_DIR"
    F="$STATE_DIR/$(date +%Y%m%d-%H%M).log"
    cp "$RAW" "$F"
    echo ""
    echo "  快照 → $F"
  fi
fi
