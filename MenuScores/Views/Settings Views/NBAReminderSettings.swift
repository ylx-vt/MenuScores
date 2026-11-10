import SwiftUI

struct NBAReminderSettingsView: View {
    @AppStorage(NBAReminderOptions.enabledKey) private var enabled = false
    @AppStorage(NBANotchOptions.enabledKey) private var notchEnabled = false
    @AppStorage(NBANotchOptions.milestonesKey) private var notchMilestones = false
    @AppStorage(NBAReminderOptions.soundKey) private var sound = false
    @AppStorage(NBARecapNotificationService.enabledKey) private var recapEnabled = false
    @AppStorage(NBARecapNotificationService.soundKey) private var recapSound = false
    @State private var permission = "正在检查系统通知状态…"
    @State private var requesting = false
    @ObservedObject private var service = NBAGameReminderService.shared
    @ObservedObject private var recapService = NBARecapNotificationService.shared

    var body: some View {
        Form {
            Section {
                Toggle("系统通知", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    service.preferencesChanged()
                    if value {
                        requesting = true
                        Task { permission = await service.enableFromUserAction(); requesting = false }
                    }
                })).disabled(requesting)
                Text("仅提醒手动固定和关注球队的比赛。刘海比分可在通用设置开启，无需系统通知权限。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("需 App 运行、网络可用且系统允许通知；睡眠或退出期间不保证提醒。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("提醒节点") {
                ForEach(NBAMilestone.allCases, id: \.self) { node in
                    NBAReminderNodeToggle(node: node)
                }
            }.disabled(!enabled && !(notchEnabled && notchMilestones))
            Section("赛后总结推送") {
                Toggle("每篇总结完成后通知", isOn: Binding(get: { recapEnabled }, set: { value in
                    recapEnabled = value
                    if value {
                        requesting = true
                        Task { permission = await service.enableFromUserAction(); requesting = false }
                    }
                })).disabled(requesting)
                Text("所有比赛的新版终稿各推送一次，显示标题和导语，点击阅读全文。不受关注球队限制，不补发已有总结。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("总结通知提示音", isOn: $recapSound).disabled(!recapEnabled)
                Button("发送最新总结测试通知") { Task { await recapService.sendLatestTest() } }
                    .disabled(!recapEnabled || requesting)
                if let message = recapService.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("系统通知设置") {
                Toggle("播放提示音", isOn: $sound).disabled(!enabled)
                Text(permission).foregroundStyle(.secondary)
                Button("打开系统通知设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") { NSWorkspace.shared.open(url) }
                }
                if let message = service.message { Text(message).foregroundStyle(.orange) }
                DisclosureGroup("提醒说明") {
                    Text("首次打开已进行或已结束的比赛不补发过去节点。恢复超过 5 分钟后重新观察比赛；同一节点只提醒一次。数据可能晚于现场，提醒仅供关注比赛。点击通知可查看详情，不改变菜单栏预约。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
            .task { permission = await service.permissionMessage() }
    }
}

private struct NBAReminderNodeToggle: View {
    let node: NBAMilestone
    @AppStorage private var selected: Bool
    init(node: NBAMilestone) {
        self.node = node
        _selected = AppStorage(wrappedValue: NBAReminderOptions().nodes.contains(node), NBAReminderOptions.key(node))
    }
    var body: some View { Toggle(node.title, isOn: $selected) }
}
