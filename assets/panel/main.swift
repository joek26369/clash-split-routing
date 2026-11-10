import SwiftUI
import Foundation

// 代理出口面板
//
// 为什么是「带窗口的 Dock App」而不是菜单栏 App：
// 菜单栏 status item 在 macOS 15.x + 未签名的本地构建上不渲染（实测），
// 双击图标后什么都不会出现，极难排查。带窗口的普通 App 绝对可靠。
//
// 数据来源全部是实测，不读任何 flag 文件：
//   国内直连  → https://myip.ipip.net           （走 DIRECT）
//   AI 支路   → https://api.ipify.org           （规则里已钉到 AI 组，
//               返回的就是该组选中节点的真实出口；节点挂了显示「超时」）
//   普通国外  → cloudflare cdn-cgi/trace        （未预钉，走 MATCH → 兜底组）
//
// 已知出口 IP → 标签 的映射放在 ~/proxy-tools/exit-tags.json，不写死在代码里
// （出口 IP 会随订阅轮换，写死必然误报）。

// MARK: - 出口标签

struct ExitTags {
    static let path = NSHomeDirectory() + "/proxy-tools/exit-tags.json"

    /// 读取 {"ip": "标签"} 映射；文件不存在时返回空表
    static func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }
}

// MARK: - 模型

final class ModeModel: ObservableObject {
    @Published var isOn = false
    @Published var groupNow = "读取中…"
    @Published var busy = false

    @Published var globalOn = false
    @Published var coreMode = "读取中…"
    @Published var globalBusy = false

    @Published var directIp = "读取中…"
    @Published var pinnedIp = "读取中…"
    @Published var fallbackIp = "读取中…"

    @Published var tags: [String: String] = ExitTags.load()

    // 统一入口脚本（login / global / status）
    private let switchScript = NSHomeDirectory() + "/proxy-tools/switch-exit.sh"
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { timer?.invalidate() }

    // MARK: 切换

    func toggle() {
        guard !busy, !globalBusy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.runScript(self.switchScript, ["login", self.isOn ? "off" : "on"])
            self.readState()
            DispatchQueue.main.async { self.busy = false }
        }
    }

    func toggleGlobal() {
        guard !busy, !globalBusy else { return }
        globalBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.runScript(self.switchScript, ["global", self.globalOn ? "off" : "on"])
            self.readState()
            DispatchQueue.main.async { self.globalBusy = false }
        }
    }

    func reloadTags() {
        tags = ExitTags.load()
    }

    // MARK: 轮询

    func refresh() {
        guard !busy, !globalBusy else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readState()
        }
    }

    private func readState() {
        let group = DispatchGroup()
        var loginOut = "", globalOut = ""
        var direct = "?", fallback = "?"

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            loginOut = self.runScript(self.switchScript, ["login", "status"])
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            globalOut = self.runScript(self.switchScript, ["global", "status"])
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            direct = self.curlDirect()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            fallback = self.curlTrace()
            group.leave()
        }
        group.wait()

        let loginOn = loginOut.contains("登录/支付模式: ON")

        var g = "?"
        for line in loginOut.split(separator: "\n") where line.contains("当前选中") {
            g = String(line.split(separator: ":").last ?? "")
                .trimmingCharacters(in: .whitespaces)
        }

        var m = "?"
        for line in globalOut.split(separator: "\n") where line.contains("内核 mode") {
            m = String(line.split(separator: ":").last ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        // 内核 mode 是唯一真相。脚本写下的 flag 会因目录变动而失真 ——
        // 删掉状态目录后 status 恒报 OFF，内核实际却是 global，
        // 面板据此显示「规则模式」，与事实完全相反。这里强制以内核为准。
        let globalOn = (m == "global")

        let pinned = curlIpify()
        let currentTags = ExitTags.load()

        DispatchQueue.main.async {
            self.isOn = loginOn
            self.groupNow = g
            self.globalOn = globalOn
            self.coreMode = m
            self.directIp = direct
            self.pinnedIp = pinned
            self.fallbackIp = fallback
            self.tags = currentTags
        }
    }

    // MARK: 探针

    // 国内直连出口。探针选 myip.ipip.net：ip.3322.net 从海外 IP 不可达，
    // 全局模式下该格会永远「超时」；ipip.net 国内直连与海外都可达。
    private func curlDirect() -> String {
        let s = runCurl(["https://myip.ipip.net"], timeout: "6")
        if let r = s.range(of: #"(\d{1,3}\.){3}\d{1,3}"#, options: .regularExpression) {
            return String(s[r])
        }
        return "超时"
    }

    // AI 支路出口。api.ipify.org 已被规则钉到 AI 组，返回该节点真实出口。
    private func curlIpify() -> String {
        let s = runCurl(["https://api.ipify.org"], timeout: "8")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只接受纯 IP，防止节点失效时把错误页 HTML 当成 IP 显示
        let ipChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        if !s.isEmpty, s.count <= 45, s.unicodeScalars.allSatisfy({ ipChars.contains($0) }) {
            return s
        }
        return "超时"
    }

    // 兜底出口。cloudflare trace 未被任何规则预钉，走 MATCH → 兜底组。
    private func curlTrace() -> String {
        let out = runCurl(["https://www.cloudflare.com/cdn-cgi/trace"], timeout: "8")
        for line in out.split(separator: "\n") where line.hasPrefix("ip=") {
            return String(line.dropFirst(3))
        }
        return "超时"
    }

    private func runCurl(_ urls: [String], timeout: String) -> String {
        var args = ["-s", "--max-time", timeout]
        args.append(contentsOf: urls)
        return run("/usr/bin/curl", args)
    }

    /// 跑 shell 脚本。显式用 /bin/bash 调用，避免依赖执行位与 shebang。
    private func runScript(_ path: String, _ args: [String]) -> String {
        run("/bin/bash", [path] + args)
    }

    @discardableResult
    private func run(_ executable: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - App

@main
struct ExitPanelApp: App {
    @StateObject private var model = ModeModel()

    var body: some Scene {
        WindowGroup("代理出口面板", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 380, height: 660)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: ModeModel

    private func exitRow(_ name: String, _ ip: String, _ tag: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .frame(width: 112, alignment: .leading)
            Text(ip)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            Spacer()
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .clipShape(Capsule())
        }
    }

    // 标签按实测 IP 查表判定，不看开关状态 ——
    // 开关开了但路径没生效时，按状态着色会撒谎。
    private func tag(for ip: String) -> (String, Color) {
        switch ip {
        case "超时", "?", "读取中…":
            return ("未知", .gray)
        default:
            if let label = model.tags[ip] {
                if label.contains("住宅") { return (label, .red) }
                if label.contains("机房") { return (label, .gray) }
                return (label, .orange)
            }
            return ("其他", .orange)
        }
    }

    // 国内直连不能「非超时即直连」—— global 模式下该探针会返回住宅 IP，
    // 会谎报成「直连」。判据改为同源比较：国内探针与任一代理支路撞 IP，
    // 说明流量被代理吞了。
    private var cnTag: (String, Color) {
        switch model.directIp {
        case "超时", "?", "读取中…":
            return ("未知", .gray)
        default:
            if model.directIp == model.pinnedIp || model.directIp == model.fallbackIp {
                return ("被代理", .red)
            }
            return ("直连", .green)
        }
    }

    // 三出口同源 = 规则没生效（global 残留 / 规则被整体跳过）
    private var exitsHomogeneous: Bool {
        let ips = [model.directIp, model.pinnedIp, model.fallbackIp]
            .filter { $0 != "超时" && $0 != "?" && $0 != "读取中…" }
        return ips.count >= 2 && Set(ips).count == 1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: 当前模式 + 三出口
                Group {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.globalOn ? Color.red : Color.green)
                            .frame(width: 14, height: 14)
                        Text(model.globalOn ? "全局模式 · 单出口" : "规则模式 · 三向分流")
                            .font(.title3).bold()
                    }

                    Text(model.globalOn
                         ? "内核 mode：global — 规则已作废，所有流量无视规则直走 GLOBAL 组"
                         : "内核 mode：\(model.coreMode) — 国内直连 / AI 住宅 / 普通国外兜底")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    if exitsHomogeneous {
                        Text("⚠️ 三出口同源（\(model.directIp)）— 规则未生效，国内也没走直连")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("三个出口当前 IP").font(.headline)
                        exitRow("国内站（直连）", model.directIp, cnTag.0, cnTag.1)
                        exitRow("AI（预钉）", model.pinnedIp, tag(for: model.pinnedIp).0, tag(for: model.pinnedIp).1)
                        exitRow("普通国外（兜底）", model.fallbackIp, tag(for: model.fallbackIp).0, tag(for: model.fallbackIp).1)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("标签来自 ~/proxy-tools/exit-tags.json")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // MARK: 登录/支付模式
                Group {
                    Text("登录/支付模式").font(.headline)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.isOn ? Color.red : Color.gray)
                            .frame(width: 14, height: 14)
                        Text(model.isOn ? "已开启 · 漏网外网走住宅" : "已关闭 · 漏网外网走机房")
                            .font(.title3).bold()
                    }

                    Text("只把「普通国外」这一支的出口从机房临时切到住宅。SSO IdP、3DS 验证页等预钉不到的域名自动全走住宅，保证登录/支付链路 IP 统一。国内直连和 AI 两支不受影响。用完记得关。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        model.toggle()
                    } label: {
                        Text(model.busy ? "切换中…" : (model.isOn ? "关闭（恢复机房）" : "开启（漏网走住宅）"))
                            .frame(width: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy || model.globalBusy || model.globalOn)
                    .tint(model.isOn ? .red : .green)
                }

                Divider()

                // MARK: 全局模式
                Group {
                    Text("全局模式").font(.headline)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.globalOn ? Color.red : Color.gray)
                            .frame(width: 14, height: 14)
                        Text(model.globalOn ? "已开启 · 全流量走单出口" : "已关闭 · 保持三向分流")
                            .font(.title3).bold()
                    }

                    Text("三个出口全部强制走同一个节点，规则整体作废——国内站也走代理，查 IP 全网一致。适合需要统一出口的场景；会拖慢国内站，且国内地区授权内容会把你识别成海外用户。用完记得关。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        model.toggleGlobal()
                    } label: {
                        Text(model.globalBusy ? "切换中…" : (model.globalOn ? "关闭（恢复规则分流）" : "开启（单一出口）"))
                            .frame(width: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy || model.globalBusy)
                    .tint(model.globalOn ? .red : .green)
                }
            }
            .padding(26)
            .frame(minWidth: 340, minHeight: 600)
        }
    }
}
