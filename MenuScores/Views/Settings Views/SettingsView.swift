import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: String
    init(initialTab: String = "Favorites") { _selectedTab = State(initialValue: initialTab) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: "Favorites") { Label("关注球队", systemImage: "star") }
                NavigationLink(value: "General") { Label("通用", systemImage: "gear") }
                NavigationLink(value: "Reminders") { Label("比赛提醒", systemImage: "bell") }
                NavigationLink(value: "About") { Label("关于", systemImage: "info.circle") }
            }
            .navigationSplitViewColumnWidth(150)
        } detail: {
            switch selectedTab {
            case "Favorites": FavoritesSettingsView().navigationTitle("NBA 关注球队")
            case "About": AboutSettingsView().navigationTitle("关于")
            case "Reminders": NBAReminderSettingsView().navigationTitle("比赛提醒")
            default: NBAOptionsView().navigationTitle("通用")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 710, minHeight: 500)
    }
}

private struct NBAOptionsView: View {
    @AppStorage("refreshInterval") private var refreshInterval = "15 seconds"
    @AppStorage(NBANotchOptions.enabledKey) private var notchEnabled = false
    @AppStorage(NBANotchOptions.milestonesKey) private var notchMilestones = false
    @AppStorage(NBANotchOptions.screenKey) private var notchScreen = ""
    @AppStorage(NBATerraOptions.enabledKey) private var terraEnabled = true
    @AppStorage("terraAutomaticEnabled") private var terraAutomatic = true
    @State private var displays = NBANotchController.screens

    var body: some View {
        Form {
            Section("菜单栏") {
                LaunchAtLogin.Toggle("登录时启动")
                Picker("比分刷新间隔", selection: $refreshInterval) {
                    Text("10 秒").tag("10 seconds")
                    Text("15 秒").tag("15 seconds")
                    Text("30 秒").tag("30 seconds")
                    Text("1 分钟").tag("1 minute")
                    Text("2 分钟").tag("2 minutes")
                    Text("5 分钟").tag("5 minutes")
                }
                Text("点击篮球图标选择比赛；点击固定的比分查看球员技术统计。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("刘海比分") {
                Toggle("启用刘海比分", isOn: $notchEnabled)
                Toggle("关键时刻展开", isOn: $notchMilestones).disabled(!notchEnabled)
                if displays.count > 1 || !notchScreen.isEmpty {
                    Picker("显示屏", selection: $notchScreen) {
                        Text("自动（主显示器）").tag("")
                        ForEach(displays, id: \.id) { display in Text(display.name).tag(display.id) }
                        if !notchScreen.isEmpty && !displays.contains(where: { $0.id == notchScreen }) {
                            Text("原显示屏未连接（暂用主显示器）").tag(notchScreen)
                        }
                    }.disabled(!notchEnabled)
                }
                Text("跟随固定比赛，悬停展开；无刘海屏使用顶部浮层。关键节点可在“比赛提醒”选择，浮层展示时不重复发送系统通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terra 比赛解读") {
                Toggle("启用赛后总结与赛前看点", isOn: $terraEnabled)
                Toggle("自动准备完赛总结与下一比赛日前瞻", isOn: $terraAutomatic).disabled(!terraEnabled)
                Text("准备状态显示在每场比赛下方，已就绪时可直接点开阅读全文。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("安全配置 OpenAI API key…") { NBATerraCredentialSetup.shared.show() }
                Text("应用运行时自动补齐，串行生成；自动和手动共用每个北京时间自然日 $\(NBATerraAutofill.dailyLimitText) 总上限。相同输入使用缓存，失败需手动重试。可关闭自动准备并按场手动生成。凭据在项目外本机私有配置中明文保存，可在配置窗口删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .onChange(of: terraAutomatic) { if !$0 { Task { await NBATerraAutofill.shared.cancel() } } }
            .onChange(of: terraEnabled) { if !$0 { Task { await NBATerraAutofill.shared.cancel() } } }
            .onChange(of: notchEnabled) { _ in updateNotch() }
            .onChange(of: notchMilestones) { _ in updateNotch() }
            .onChange(of: notchScreen) { _ in updateNotch() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in displays = NBANotchController.screens }
    }
    private func updateNotch() {
        NBANotchController.shared.configure()
        NBAGameReminderService.shared.preferencesChanged()
    }
}
