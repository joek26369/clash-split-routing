# 踩坑清单

每条都是实际发生过、花了时间才定位到的问题。按「症状 → 根因 → 处置」组织。

---

## 1. 规则一条没少，但国内站也走代理了

**症状**：`/rules` 显示一百多条规则全在，但访问国内站时出口还是海外 IP。

**根因**：内核 mode 是 `global`，不是 `rule`。global 模式下 rules 整体作废，所有流量走 `GLOBAL` 组。Clash Verge 在重启、切换订阅、更新订阅后会重置 mode。

**处置**：三层同时固定。

```
① profiles/Merge.yaml          mode: rule
② 订阅增强 JS                   config.mode = "rule"
③ 运行时                        PATCH /configs {"mode":"rule"}
```

只做 ① 或 ② 不够 —— Verge 的 GUI 状态和内核状态是两套东西，GUI 显示 rule 不代表内核是 rule。

**判定方法**：以内核为准，别信 UI，也别信自己写的 flag 文件：

```bash
curl -s --unix-socket "$SOCK" -H "Authorization: Bearer $TOKEN" \
  http://localhost/configs | grep -o '"mode":"[^"]*"'
```

---

## 2. 改了配置文件，重启后一点变化都没有

**症状**：编辑 `Merge.yaml` 保存成功，重启 Verge，行为不变。

**根因**：文件带 `uchg` 不可变标志（由某个守护脚本设置防覆盖）。`sed -i` 和常规写入会失败，但某些编辑器会显示「已保存」。

**处置**：

```bash
ls -lO profiles/Merge.yaml          # 看 uchg
chflags nouchg profiles/Merge.yaml  # 解锁
# 写入
chflags uchg profiles/Merge.yaml    # 改完锁回
```

**教训**：曾经出现过「改成 rule」实际没写进去，但被误判为生效，后面所有排查都建立在错误前提上。**改完必须回读文件内容确认，不能只看保存成功。**

---

## 3. 同一个网站，域名能开、IP 打不开

**症状**：浏览器报 `ERR_SSL_PROTOCOL_ERROR`；用域名 curl 返回 200，用解析出的 IP curl 返回 `tlsv1 alert protocol version`。

**根因**：`sniffer.override-destination: false`。客户端（Chrome 最典型，它有自己的 DNS 缓存）直接用裸 IP 连接，节点收到的是 IP 而不是域名。住宅线路对 IP 型目标一律拒绝。

**处置**：`override-destination: true`（见 `merge-template.yaml`）。

**验证**：内核日志出现 `[Sniffer] replace domain []-->[example.com]` 即生效。

**为什么难查**：浏览器缓存过真实 IP 后，即使你把系统 DNS 换对，它仍然连旧 IP。所以现象看起来像「只有这一个站坏了」。

---

## 4. 组里塞了 DIRECT，节点挂了就悄悄直连

**症状**：节点故障时网页还能开，但查出口是国内 IP；账号侧看到两条 IP 轨迹。

**根因**：fail-open。`url-test` / `fallback` 组在全部成员不可用时可能回落到 `DIRECT`；或者组的成员列表里本来就包含 `DIRECT`。

**处置**：

- 关键分组（AI 出口）成员唯一，不用自动切换组
- 兜底 `MATCH` 指向固定组，该组不含 `DIRECT`
- 检查订阅自带的规则：`GEOSITE,XXX,某组` 里的「某组」如果是多成员含 DIRECT 的组，用 `delete:` 段删掉

**原则**：宁可断线，不要静默换路。断线用户会去修；静默换路没人知道，直到账号出事。

---

## 5. 账号安全：遥测域和主站出口不一致

**症状**：主站能正常用，但登录/验证环节偶发失败，或账号被要求额外验证。

**根因**：只钉了主域名，埋点/错误上报/功能开关走的是另一条出口。Sift、Turnstile 这类风控看到的是「同一会话、两个 IP」。

**处置**：把主站实际使用的遥测域全部钉到同一出口。常见的有：

```
sentry.io / sentry-cdn.com
datadoghq.com / browser-intake-datadoghq.com
siftscience.com / sift.com
segment.io / segment.com
statsig.com / featuregates.org
amplitude.com
google-analytics.com / googletagmanager.com
cloudflareinsights.com
intercom.io / intercomcdn.com
```

**更彻底的做法**：按进程名 + 进程完整路径兜底，域名清单永远追不上客户端更新速度。

---

## 6. 本地中转客户端把流量回环给自己

**症状**：CPU 打满、网络不通、日志里同一个连接反复出现。

**根因**：本地 TUN 客户端的出站流量又被 TUN 抓回来，形成 `本地客户端 → TUN → 规则 → 本地客户端` 的循环。

**处置**：规则最前面加一条按进程名直连：

```yaml
- PROCESS-NAME,sing-box,DIRECT
```

放在 prepend 的第一位，优先级高于一切。

---

## 7. bash 3.2：`$var` 后面紧跟中文会报 unbound variable

**症状**：`line 37: a?: unbound variable`，脚本在 `set -u` 下直接退出。参数完全正常。

**根因**：macOS 自带 bash 3.2 在 UTF-8 环境下，会把全角字符的首字节当成变量名的一部分。`echo "未知: $a（看用法）"` 里的 `$a（` 被解析成变量 `a（`。

**处置**：永远写 `${a}（`。

```bash
echo "未知参数: ${1}（-h 看用法）"   # ✅
echo "未知参数: $1（-h 看用法）"    # ❌
```

**同类问题**：`ping` 输出、mihomo API 响应过管道时中文字节可能损坏，导致字符串比较恒假。提取 JSON 字段用 `grep -o` + `cut`，不要用 python 读 stdin。

---

## 8. 面板显示的开关状态和实际不符

**症状**：面板显示「规则模式」，实际内核是 global；或显示 OFF，实际兜底组选的是住宅。

**根因**：面板读的是脚本写的 flag 文件。flag 所在目录被删/改名后，status 恒报 OFF，而内核状态没变。

**处置**：**面板只读内核状态，不读 flag**。

```bash
# 模式
grep -o '"mode":"[^"]*"'  ← /configs
# 组选中项
grep -o '"now":"[^"]*"'   ← /proxies/<group>
```

flag 只能作为「上次操作意图」的辅助记录，不能作为状态来源。

---

## 9. 出口 IP 写死在代码里，节点轮换后误报

**症状**：切换脚本报 FAIL，但实际已经切成功了。

**根因**：脚本里写死 `if [ "$ip" = "某个固定IP" ]` 做校验。住宅节点出口 IP 会随订阅轮换而变。

**处置**：校验「组的选中项」而不是「出口 IP」。IP 只用于展示。

```bash
now=$(api_get | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4)
[ "$now" = "AI-RESIDENTIAL" ] && echo OK
```

---

## 10. TUN 模式下 ICMP 被代发，traceroute 看不到真实路径

**症状**：`ping -m 1`（TTL=1）竟然直接收到目标回复；`traceroute` 第 1 跳就显示到达。

**根因**：TUN 下 ICMP 由 mihomo 自己代发，不尊重 TTL，也不返回中间跳的 Time Exceeded。TCP 版 traceroute 同理 —— TUN 在本地就终结了握手。

**处置**：临时给目标加一条 `/32` 路由走物理网关，绕开 TUN，跑完删掉。

```bash
GW=$(netstat -rn -f inet | awk '/^default/{print $2; exit}')
sudo route add -host <TARGET_IP> "$GW"
sudo traceroute -n -q 1 -w 2 -m 20 <TARGET_IP>
sudo route delete -host <TARGET_IP>
```

**推论**：TUN 下用 ping 比较「直连」和「代理」两条路径的延迟是无效的 —— 两次都是 mihomo 在代发。

---

## 11. 中间跳的高丢包不是真实丢包

**症状**：mtr 里中间几跳 70–90% 丢包，但终点 0%。

**根因**：骨干路由器对「发往自身」的 ICMP 做低优先级处理或限速，转发别人的包不受影响。

**判定方法**：看**终点**丢包率，不看中间跳。另一个铁证是「某跳延迟比它后面的跳还高」—— 转发路径上的设备不可能比下游更慢，出现这种情况一定是 ICMP 回程绕路。

---

## 12. 改完配置，Verge 静默跳过整个规则文件

**症状**：规则数从 140 掉到 50，AI 域名规则全失效，但 Verge 不报错。

**根因**：YAML 缩进错误。`prepend:` 被多推了两个空格，整个文件解析失败，Verge 选择跳过而不是报错。

**处置**：

- 改完跑 `scripts/check-config.sh`，它会做 YAML 合法性检查 + 规则数比对
- `prepend:` / `append:` / `delete:` 必须是 0 缩进
- 改完一定回读文件，确认结构没坏
