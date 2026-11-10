# clash-split-routing

Clash Verge 的三向分流配置，加一个 macOS 出口面板。

```
国内域名         → 直连
AI / 账号相关域  → 住宅节点（一个，就一个）
其余国外流量     → 机房中转
```

## 为什么不用现成的规则集

大部分「一键规则」的思路是**自动选优**：延迟低就用谁，节点挂了自动切下一个。日常刷网页很舒服，但你只要有两个场景就不够用了：

**一是账号安全。** 同一会话里出口 IP 跳来跳去，等于告诉风控「这个账号同时在两个地方」。多成员组在节点抖动时静默换路，你自己完全不知道 —— 直到账号被要求额外验证。

**二是流量成本。** 住宅 IP 通常是 140GB/月这种量级，YouTube 一周就能吃光。而 AI 应用恰恰最需要那份额度。

所以这套配置反过来：**不追求快，追求可预测**。分组成员唯一、失效就断，不用自动切换；视频流量明确划给机房；遥测域跟主站绑在同一个出口。

## 快速开始

```bash
git clone <this-repo> ~/.workbuddy/skills/clash-split-routing
cd ~/.workbuddy/skills/clash-split-routing

# 装规则模板到 Clash Verge 配置目录
bash scripts/install.sh --residential "你的住宅节点名" --relay "你的机房节点名"

# 按提示在 UI 里绑定，然后体检
bash scripts/check-config.sh
```

## 出口面板

`assets/panel/` 是一个 SwiftUI 小应用，一屏显示三个出口的真实 IP，可以当场切换：

```
国内站（直连）      192.0.2.10      直连
AI（预钉）        203.0.113.10    住宅
普通国外（兜底）   198.51.100.20   机房
```

```bash
cd assets/panel && ./build.sh --install --run
```

三个设计取舍，都是踩坑踩出来的：

- **只读内核状态，不读 flag 文件。** 早先版本用 flag 记录开关状态，结果状态目录被删之后，面板显示「规则模式」而内核其实是 `global` —— 显示的和事实完全相反。
- **标签按实测 IP 判定，不按开关状态。** 开关开了但路径没生效时，按状态着色就是撒谎。已知 IP → 标签的映射放在 `~/proxy-tools/exit-tags.json`，不写死在代码里（出口 IP 会随订阅轮换）。
- **三出口同源时显红报警。** 这是「规则整体没生效」最快的可视化信号，比看日志快得多。

菜单栏 App 在 macOS 15.x + 未签名的本地构建上不渲染（实测），所以做成了带窗口的普通 App。双击就有窗口，绝对可靠。

## 命令

```bash
# 登录/支付模式：只把兜底那一支临时切到住宅
# SSO IdP、3DS 发卡行这类无法预钉的域也一起走住宅，保证整条链路出口一致
~/proxy-tools/switch-exit.sh login on
~/proxy-tools/switch-exit.sh login off

# 全局单出口
~/proxy-tools/switch-exit.sh global on
~/proxy-tools/switch-exit.sh global off

# 状态（一律以内核为准）
~/proxy-tools/switch-exit.sh status

# 配置体检：查那几类「静默失效」
bash scripts/check-config.sh

# 选节点前先量一下链路
bash scripts/linkcheck.sh --targets scripts/targets.example --long
```

所有切换都走 mihomo 运行时 API，**不重启 Verge，也不断开已建立的连接**。

## 目录

```
├── SKILL.md                      # 主文档
├── references/
│   ├── rules-template.yaml       # 分流规则，每条都写了为什么
│   ├── groups-template.yaml      # 组结构
│   ├── merge-template.yaml       # mode 固定 + 域名嗅探
│   └── pitfalls.md               # 12 个坑：症状 → 根因 → 处置
├── scripts/
│   ├── install.sh
│   ├── check-config.sh
│   ├── switch-exit.sh
│   ├── linkcheck.sh
│   └── config.env.example
└── assets/panel/                 # macOS 出口面板
    ├── main.swift
    ├── build.sh
    └── local.exitpanel.plist
```

## 三个容易踩的点

**mode 会被重置。** Clash Verge 在重启、切换订阅、更新订阅后会把 mode 改回去，`global` 模式下所有规则作废。必须三层同时固定：`Merge.yaml` 的 mode 行、增强 JS 的 `config.mode`、运行时 API。少一层就会出现「UI 显示 rule、内核是 global」。

**`uchg` 会让编辑静默失败。** 文件带了不可变标志时，`sed -i` 失败但有些编辑器仍显示保存成功。改完必须回读文件确认。

**`sniffer.override-destination` 默认是 false。** 客户端用裸 IP 连接时（Chrome 的 DNS 缓存最典型），节点收到的是 IP 而不是域名，很多住宅线路会直接拒绝，报 `tlsv1 alert protocol version`。症状是「同一个站域名能开、IP 打不开」，极难定位。

完整清单见 [`references/pitfalls.md`](references/pitfalls.md)。

## 免责

这套配置只解决「流量该走哪个出口」，不提供任何节点。使用前请确认你的代理服务与用途符合所在地法律法规。

## License

MIT
