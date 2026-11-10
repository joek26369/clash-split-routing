#!/bin/bash
# install.sh — 把三份模板装进 Clash Verge 的配置目录
#
#   install.sh                                  交互式
#   install.sh --residential "住宅节点名" --relay "机房节点名"
#   install.sh --uninstall                      删除本工具生成的文件
#
# 只做两件事：拷文件 + 替换节点名占位符。
# **不修改 profiles.yaml** —— 绑定到哪个订阅交给你在 UI 里点（4 次点击），
# 远比脚本盲改配置安全。装完会打印具体步骤。

set -u
export LC_ALL=en_US.UTF-8

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=""
for c in "$SCRIPT_DIR/config.env" "$HOME/proxy-tools/config.env"; do
  [ -f "$c" ] && CONF="$c" && break
done
if [ -z "$CONF" ]; then
  echo "提示：未找到 config.env，将使用默认配置目录"
  CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
  PROFILES_DIR="$CLASH_DIR/profiles"
else
  # shellcheck disable=SC1090
  . "$CONF"
fi

RESIDENTIAL=""
RELAY=""
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --residential) RESIDENTIAL="${2:-}"; shift 2 ;;
    --relay)       RELAY="${2:-}"; shift 2 ;;
    --uninstall)   UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: ${1}（-h 看用法）" >&2; exit 2 ;;
  esac
done

if [ ! -d "$PROFILES_DIR" ]; then
  echo "FAIL: 找不到配置目录 $PROFILES_DIR" >&2
  echo "      确认 Clash Verge 已安装并至少启动过一次" >&2
  exit 1
fi

# ── 卸载 ──
if [ "$UNINSTALL" = 1 ]; then
  n=0
  for f in "$PROFILES_DIR"/cr-*.yaml; do
    [ -f "$f" ] || continue
    rm -f "$f" && echo "  已删除 $(basename "$f")" && n=$((n+1))
  done
  echo "共删除 ${n} 个文件。记得去 UI 里解除绑定。"
  exit 0
fi

# ── 节点名 ──
if [ -z "$RESIDENTIAL" ]; then
  printf "住宅节点名称（在 Verge 的「代理」页里能看到，需要完全一致）："
  read -r RESIDENTIAL
fi
if [ -z "$RELAY" ]; then
  printf "机房中转节点名称："
  read -r RELAY
fi
if [ -z "$RESIDENTIAL" ] || [ -z "$RELAY" ]; then
  echo "FAIL: 两个节点名都必须提供" >&2; exit 1
fi

gen_uid() { LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12; }

RULES_UID="cr-r-$(gen_uid)"
GROUPS_UID="cr-g-$(gen_uid)"
TMP=$(mktemp -d /tmp/clash-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo ""
echo "════════ 安装 ════════"

# ── 规则 ──
sed -e "s/\"RESIDENTIAL-NODE\"/\"${RESIDENTIAL}\"/g" \
    -e "s/\"RELAY-NODE\"/\"${RELAY}\"/g" \
    "$SCRIPT_DIR/../references/rules-template.yaml" > "$TMP/rules.yaml"

# ── 组 ──
sed -e "s/\"RESIDENTIAL-NODE\"/\"${RESIDENTIAL}\"/g" \
    -e "s/\"RELAY-NODE\"/\"${RELAY}\"/g" \
    "$SCRIPT_DIR/../references/groups-template.yaml" > "$TMP/groups.yaml"

# ── merge（若已存在则不覆盖，只提示）──
MERGE_DST="$CLASH_DIR/Merge.yaml"

# 校验 YAML
if python3 -c "import yaml" 2>/dev/null; then
  for f in "$TMP/rules.yaml" "$TMP/groups.yaml" "$SCRIPT_DIR/../references/merge-template.yaml"; do
    if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null; then
      echo "FAIL: $(basename "$f") YAML 解析失败，已中止（未写入任何文件）" >&2
      exit 1
    fi
  done
  echo "  ✅ YAML 校验通过"
else
  echo "  ⚠️  未安装 pyyaml，跳过校验"
fi

# 检查是否已被 uchg 锁
for f in "$MERGE_DST"; do
  if [ -f "$f" ] && ls -lO "$f" 2>/dev/null | grep -q uchg; then
    echo "  ⚠️  $f 带 uchg 锁，先解锁：chflags nouchg \"$f\""
  fi
done

cp "$TMP/rules.yaml"  "$PROFILES_DIR/${RULES_UID}.yaml"  && echo "  ✅ 规则 → ${RULES_UID}.yaml"
cp "$TMP/groups.yaml" "$PROFILES_DIR/${GROUPS_UID}.yaml" && echo "  ✅ 分组 → ${GROUPS_UID}.yaml"

if [ -f "$MERGE_DST" ]; then
  echo "  ⚠️  Merge.yaml 已存在，未覆盖。请手动把 references/merge-template.yaml 的"
  echo "      mode 与 sniffer 两段合并进去（或先备份再替换）。"
else
  cp "$SCRIPT_DIR/../references/merge-template.yaml" "$MERGE_DST" && echo "  ✅ 全局 merge → Merge.yaml"
fi

cat <<EOF

════════ 下一步（在 Clash Verge 里操作）════════

1. 打开「配置」页，找到你正在用的订阅，右键 → 编辑规则
   选「本地文件」，挑 ${RULES_UID}.yaml

2. 同一个订阅右键 → 编辑代理组
   选「本地文件」，挑 ${GROUPS_UID}.yaml

3. 右键 → 编辑 Merge（若你只有一个订阅，第 4 步可以跳过）
   （全局 Merge.yaml 已写好，通常不用动）

4. 点订阅卡片让它重新编译，然后在「代理」页确认三个组都在：
   ${AI_GROUP:-AI-RESIDENTIAL} / ${FALLBACK_GROUP:-FALLBACK-OUT} / ${GLOBAL_GROUP:-GLOBAL}

5. 复制配置并跑体检：
   cp ${SCRIPT_DIR}/config.env.example ~/proxy-tools/config.env
   # 按需修改组名与节点名
   bash ${SCRIPT_DIR}/check-config.sh

⚠️  如果第 4 步之后国内站变成走代理，说明内核 mode 被重置为 global，
    先跑：bash ${SCRIPT_DIR}/switch-exit.sh global off
EOF
