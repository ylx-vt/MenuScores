import AppKit
import SwiftUI

struct NBATerraCredentialSetupView: View {
    @State private var apiKey = ""
    @State private var status: String?
    @State private var saved = false
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("连接 OpenAI", systemImage: "key.fill").font(.title2.bold())
            Text("使用项目外的本机私有配置。已有 key 可从原钥匙串迁移一次；也可以在隐藏框亲自粘贴，不要发到聊天里。")
            SecureField("OpenAI API key", text: $apiKey)
                .textFieldStyle(.roundedBorder).disabled(busy)
                .accessibilityLabel("OpenAI API key，隐藏输入")
            Text("key 以明文保存在本机 Application Support/MenuScores/PrivateConfiguration/openai.json，仅当前用户可访问。文件不在项目或安装包内；能读取此文件的程序仍可能取得 key。这不是系统加密存储。")
                .font(.callout).foregroundStyle(.secondary)
            Text("仅用于已启用的比赛总结、看点、追问与按需公开资料搜索，向 api.openai.com 认证。保存或迁移不调用 API，不读剪贴板、不记入日志；请求费用共用北京时间每天 $\(NBATerraAutofill.dailyLimitText) 上限。")
                .font(.callout).foregroundStyle(.secondary)
            if let status {
                Label(status, systemImage: saved ? "checkmark.shield" : "info.circle")
                    .foregroundStyle(saved ? Color.green : Color.secondary)
                    .font(.callout).textSelection(.enabled)
            }
            Button("从原钥匙串迁移一次") { authorizeExisting() }
                .disabled(busy)
            Text("迁移可能需要你本人处理一次 macOS 授权提示。原钥匙串条目保留，不改变其访问控制。")
                .font(.caption).foregroundStyle(.secondary)
            Text("配置生效后，请求和重启都只读取本机文件；文件缺失或无效会报错，不会自动回退钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存到本机配置") { save() }.buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("清空输入") { apiKey = "" }.disabled(apiKey.isEmpty || busy)
                Spacer()
                Button("删除本机配置", role: .destructive) { remove() }.disabled(busy)
            }
            Text("MenuScores " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ") · 仅配置凭据，此窗口不发起 API 请求")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 560).background(Color(nsColor: .windowBackgroundColor)).tint(.purple)
        .onAppear { saved = NBAOpenAIPrivateConfiguration.shared.isConfigured; if saved { status = "已保存本机配置。正常请求不读取钥匙串。" } }
        .onDisappear { apiKey = "" }
    }
    private func authorizeExisting() {
        busy = true; status = "请亲自处理 macOS 可能显示的钥匙串提示。"
        Task {
            do {
                let available = try await Task.detached { try NBAOpenAIPrivateConfiguration.shared.migrateLegacy(allowInteraction: true) }.value
                saved = available; status = available ? "已迁移到本机配置。原钥匙串项保留，后续请求只读文件。未发送 API 请求。" : "未找到原凭据，可在隐藏框保存 key。"
            } catch { saved = false; status = error.localizedDescription }
            busy = false
        }
    }
    private func save() {
        busy = true; defer { busy = false }
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try NBAOpenAIPrivateConfiguration.shared.save(value)
            apiKey = ""; saved = true
            status = "已保存到本机私有配置。尚未验证凭据，未发送 API 请求。"
        } catch { saved = false; status = error.localizedDescription }
    }
    private func remove() {
        busy = true; defer { busy = false }
        do {
            try NBAOpenAIPrivateConfiguration.shared.removeLocalConfiguration()
            apiKey = ""; saved = false; status = "本机配置已删除。原钥匙串项保留；不会自动回退读取。"
        } catch { saved = false; status = error.localizedDescription }
    }
}

@MainActor final class NBATerraCredentialSetup: NSObject, NSWindowDelegate {
    static let shared = NBATerraCredentialSetup()
    private var window: NSWindow?
    var exitsOnClose = false
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingView(rootView: NBATerraCredentialSetupView())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MenuScores · 安全配置 OpenAI"
        window.isReleasedWhenClosed = false; window.contentView = host; window.delegate = self; self.window = window
        NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.setContentSize(host.fittingSize) }
    }
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil; window = nil
        if exitsOnClose { NSApp.terminate(nil) }
    }
}
