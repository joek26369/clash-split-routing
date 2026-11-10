---
name: clash-split-routing
description: 在 Clash Verge 上搭建可预测的三向分流（国内直连 / AI 走住宅 / 其余走机房），并提供出口切换脚本与 macOS 出口面板。当用户需要配置或排查代理分流规则、要求「某个应用的出口 IP 必须固定」、遇到改了配置不生效/规则明明在却不按规则走/某网站域名能开但 IP 打不开、或需要快速在住宅与机房出口之间切换时使用。
agent_created: true
---

# Clash Verge 三向分流

## 它解决什么问题

常见的机场配置追求「自动选优」，代价是出口不可预测：节点抖动就换一个，账号侧看到同一会话出现两个 IP。对普通浏览无所谓，对登录态、支付、AI 账号这类需要稳定身份的场景是致命的。

这套配置反过来：**不追求快，追求「我说从哪个出口出去，就一定只从那个出口出去」**。

```
国内域名        → DIRECT
AI / 账号相关域 → AI-RESIDENTIAL（单个住宅节点，成员唯一，失效即断）
其余国外        → RELAY（机房中转）
```

## 三个设计决定

**1. AI 组只放一个节点。** 多成员 + 自动切换 = fail-open：主节点挂了静默换备用，同一会话留下两条 IP 轨迹，风控直接命中。宁可断线 —— 断线用户会去修，静默换路没人知道。

**2. 遥测域必须和主站同出口。** 只钉 `claude.ai`、埋点走机场，等于告诉风控「这个账号同时在两个地方」。Sentry / Datadog / Sift / Statsig / Segment 这一批都要一起钉。

**3. 视频流量走机房。** 住宅套餐常见 140GB/月，YouTube 视频能在一周内吃光，而 AI 应用恰恰需要那份额度。两个出口都是美国 IP 时，不存在跨洲横跳风险。

## 安装

```bash
# 1. 把模板装进 Clash Verge 配置目录
bash scripts/install.sh --residential "住宅节点名" --relay "机房节点名"

# 2. 按 install.sh 打印的步骤，在 UI 里把规则/分组绑到当前订阅

# 3. 配置
cp scripts/config.env.example ~/proxy-tools/config.env
cp scripts/switch-exit.sh ~/proxy-tools/
chmod +x ~/proxy-tools/switch-exit.sh

# 4. 体检
bash scripts/check-config.sh
```

## 日常使用

```bash
# 只切兜底那一支（登录/支付窗口期用，用完关掉）
~/proxy-tools/switch-exit.sh login on
~/proxy-tools/switch-exit.sh login off

# 全局单出口（需要所有流量同一 IP 时）
~/proxy-tools/switch-exit.sh global on
~/proxy-tools/switch-exit.sh global off

# 看当前状态
~/proxy-tools/switch-exit.sh status
```

两个开关都走 mihomo 运行时 API，**零重启、秒生效**，不影响已建立的连接。

## 出口面板

`assets/panel/` 是配套的 macOS App，一屏同时显示三个出口的真实 IP，并可以直接切换：

```bash
cd assets/panel
./build.sh --install --run
```

面板的设计要点：
- **只读内核状态，不读 flag 文件**。flag 会因目录变动而失真，导致面板显示的和实际相反。
- **按实测 IP 判定标签，不按开关状态**。开关开了但路径没生效时，按状态着色会撒谎。
- **三出口同源时显红报警**。这是「规则整体没生效」最快的可视化信号。

## 排障

改完配置没反应，按这个顺序查：

| 症状 | 先查 |
|---|---|
| 国内站也走代理 | 内核 `mode` 是否被重置成 `global` |
| 改了文件没变化 | 文件是否带 `uchg` 不可变标志 |
| 规则数突然变少 | YAML 缩进是否坏了（`prepend:` 必须 0 缩进） |
| 某站域名能开 IP 打不开 | `sniffer.override-destination` 是否为 true |
| 账号被要求额外验证 | 遥测域是否和主站出口不一致 |
| 面板显示与实际相反 | 面板读的是不是 flag 而不是内核 |

详细根因与验证方法见 `references/pitfalls.md`。

## 文件

| 路径 | 内容 |
|---|---|
| `references/rules-template.yaml` | 分流规则（含逐条理由） |
| `references/groups-template.yaml` | 组结构（为什么 AI 组只放一个节点） |
| `references/merge-template.yaml` | mode 固定 + 域名嗅探 |
| `references/pitfalls.md` | 12 个实际踩过的坑，症状→根因→处置 |
| `scripts/install.sh` | 装模板进配置目录 |
| `scripts/check-config.sh` | 配置体检，查静默失效 |
| `scripts/switch-exit.sh` | 出口切换（login / global） |
| `scripts/linkcheck.sh` | 链路体检，单目标或多目标对比 |
| `assets/panel/` | macOS 出口面板源码 + 构建脚本 |

## 注意

- 组名 `AI-RESIDENTIAL` / `RELAY` 是占位符，必须换成你自己订阅里实际存在的节点名，否则编译后组是空的。
- `delete:` 段必须按你的订阅实际内容改写，否则订阅自带的 `MATCH` 会让你的 `append MATCH` 永远轮不到。
- 这套配置的前提是**你已经有**住宅节点和机房节点。它不提供节点，只解决「怎么把流量分配到正确的节点」。
