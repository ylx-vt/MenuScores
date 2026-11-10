import AppKit
import SwiftUI
import UserNotifications

struct NBARecapNotification: Sendable {
    let gameID: String
    let cacheKey: String
    let title: String
    let body: String
    var identifier: String { "nba.recap." + gameID }
    var userInfo: [String: String] { ["kind": "nba.recap.v1", "eventID": gameID, "cacheKey": cacheKey] }

    init?(_ article: NBARecap) {
        guard article.kind == .recap, article.editorialPasses == 2,
              article.promptVersion == NBATerraClient.promptVersion,
              NBATerraClient.matchesModel(article.model, expected: NBATerraClient.editorialModel),
              NBANotificationRoute.validEventID(article.gameID),
              Self.validCacheKey(article.cacheKey),
              let title = article.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lead = article.lead, !lead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        gameID = article.gameID; cacheKey = article.cacheKey
        self.title = title; body = lead
    }
    static func validCacheKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

@MainActor
protocol NBARecapNotificationSending {
    func authorization() async -> NBANotificationAuthorization
    func send(_ notification: NBARecapNotification, sound: Bool) async throws
}

extension NBASystemNotificationSender: NBARecapNotificationSending {
    func send(_ notification: NBARecapNotification, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.subtitle = "NBA赛后总结"; content.body = notification.body
        content.userInfo = notification.userInfo
        content.interruptionLevel = .active
        if sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: notification.identifier, content: content, trigger: nil))
    }
}

/// Triggered only after a final article has been saved. No timer or paid request.
@MainActor
final class NBARecapNotificationService: ObservableObject {
    static let shared = NBARecapNotificationService()
    static let enabledKey = "nbaRecapNotificationsEnabled"
    static let soundKey = "nbaRecapNotificationsSound"
    @Published private(set) var message: String?
    private var consumed: Set<String> = []
    private var readable = true
    private let file: URL
    private let sender: any NBARecapNotificationSending
    private let defaults: UserDefaults
    private let write: (Data, URL) throws -> Void

    init(file: URL? = nil, sender: (any NBARecapNotificationSending)? = nil,
         defaults: UserDefaults = .standard, write: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuScores/nba-recap-notifications-v1.json")
        self.sender = sender ?? NBASystemNotificationSender(); self.defaults = defaults; self.write = write
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { consumed = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: self.file)) }
            catch { readable = false; message = "总结推送记录读取失败，已暂停推送" }
        }
    }

    func articleReady(_ article: NBARecap) async {
        guard defaults.bool(forKey: Self.enabledKey), readable, !Task.isCancelled,
              let notification = NBARecapNotification(article), !consumed.contains(article.gameID) else { return }
        // Persist before the first suspension: concurrent completions, revisions
        // and process restarts cannot emit a second alert for the same game.
        var next = consumed; next.insert(article.gameID)
        do { try write(JSONEncoder().encode(next), file); consumed = next }
        catch { message = "总结推送记录保存失败，本篇未推送"; return }
        guard await sender.authorization() == .allowed else {
            message = "系统尚未允许通知，可在系统设置中开启"; return
        }
        guard defaults.bool(forKey: Self.enabledKey), !Task.isCancelled else { return }
        do {
            try await sender.send(notification, sound: defaults.bool(forKey: Self.soundKey))
            message = nil
        } catch { message = "总结通知提交失败；本篇未自动重发" }
    }

    func sendLatestTest() async {
        guard let article = await NBATerraRecapStore.live.latestFinalRecap(),
              let notification = NBARecapNotification(article) else {
            message = "暂无可推送的新版赛后总结"; return
        }
        guard await sender.authorization() == .allowed else {
            message = "系统尚未允许通知，可在系统设置中开启"; return
        }
        do {
            try await sender.send(notification, sound: defaults.bool(forKey: Self.soundKey))
            message = "已提交最新总结通知，点击通知可阅读全文"
        } catch { message = "测试通知提交失败，请稍后重试" }
    }
}

/// Reads the exact cached edition named in the notification, even while offline.
struct NBARecapNotificationReader: View {
    let article: NBARecap
    let showStatistics: () -> Void
    var body: some View {
        let presentation = NBATerraPresentation(article: article, fallbackTitle: article.kind?.title ?? "比赛解读")
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(presentation.title).font(.system(size: 21, weight: .semibold))
                if !presentation.lead.isEmpty { Text(presentation.lead).font(.system(size: 14, weight: .medium)) }
                ForEach(Array(presentation.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.system(size: 14)).lineSpacing(6)
                }
                Divider()
                HStack {
                    Text(article.generatedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("技术统计", action: showStatistics).buttonStyle(.borderless)
                }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(minWidth: 560, minHeight: 400)
    }
}
