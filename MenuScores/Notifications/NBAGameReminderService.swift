import AppKit
import SwiftUI
import UserNotifications
import OSLog

enum NBANotificationAuthorization { case allowed, denied, notDetermined }

@MainActor
protocol NBANotificationSending {
    func authorization() async -> NBANotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func send(_ reminder: NBAGameReminder, sound: Bool) async throws
}

@MainActor
final class NBASystemNotificationSender: NBANotificationSending {
    func authorization() async -> NBANotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func send(_ reminder: NBAGameReminder, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.body = reminder.body
        content.userInfo = ["kind": "nba.milestone.v1", "eventID": reminder.eventID]
        content.interruptionLevel = .active
        if sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
    }
}

@MainActor
final class NBAGameReminderService: ObservableObject {
    static let shared = NBAGameReminderService()
    private let engine: NBAGameReminderEngine
    private let sender: any NBANotificationSending
    private let overlay: (any NBAMilestoneOverlay)?
    private let log = Logger(subsystem: "daniyalmaster.MenuScores", category: "GameReminders")
    @Published private(set) var message: String?

    init(engine: NBAGameReminderEngine? = nil, sender: (any NBANotificationSending)? = nil, overlay: (any NBAMilestoneOverlay)? = nil) {
        self.engine = engine ?? NBAGameReminderEngine(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuScores/nba-reminder-ledger-v1.json"))
        self.sender = sender ?? NBASystemNotificationSender()
        self.overlay = overlay ?? (AppRuntime.isUnitTestHost ? nil : NBANotchController.shared)
    }

    func permissionMessage() async -> String {
        switch await sender.authorization() {
        case .allowed: return "系统已允许通知"
        case .denied: return "系统尚未允许通知，可在系统设置中开启"
        case .notDetermined: return "开启比赛提醒时申请系统通知权限"
        }
    }

    func preferencesChanged() { engine.resetTracking() }

    /// Called only by the user's explicit enable action, never at launch.
    func enableFromUserAction() async -> String {
        do {
            switch await sender.authorization() {
            case .allowed: return "系统已允许通知"
            case .denied: return "系统尚未允许通知，可在系统设置中开启"
            case .notDetermined:
                return try await sender.requestAuthorization() ? "系统已允许通知" : "系统尚未允许通知，可在系统设置中开启"
            }
        } catch { return "申请通知权限失败，请稍后重试" }
    }

    func process(_ observations: [NBAGameObservation], eligibleIDs: Set<String>, options: NBAReminderOptions,
                 now: Date = Date(), currentContext: () -> (Set<String>, NBAReminderOptions)) async {
        // Claim each milestone once, then choose a single output. Overlay-only
        // reminders do not require system notification authorization.
        var detection = options
        detection.enabled = options.enabled || overlay?.wantsMilestones == true
        let reminders = engine.process(observations, eligibleIDs: eligibleIDs, options: detection, now: now)
        message = engine.persistenceError
        for reminder in reminders {
            guard !Task.isCancelled else { return }
            var (ids, current) = currentContext()
            guard ids.contains(reminder.eventID), current.nodes.contains(reminder.node) else { continue }
            if overlay?.wantsMilestones == true, overlay?.present(reminder) == true { continue }
            guard current.enabled, await sender.authorization() == .allowed else { continue }
            (ids, current) = currentContext()
            guard !Task.isCancelled, ids.contains(reminder.eventID), current.nodes.contains(reminder.node) else { continue }
            if overlay?.wantsMilestones == true, overlay?.present(reminder) == true { continue }
            guard current.enabled else { continue }
            do { try await sender.send(reminder, sound: current.sound) }
            catch { log.error("Local reminder submission failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// One reusable window for user-clicked notifications, separate from pin state.
@MainActor
final class NBANotificationDetailWindow: NSWindowController, NSWindowDelegate {
    static let shared = NBANotificationDetailWindow()
    private(set) var currentEventID: String?
    private var currentArticleKey: String?
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "比赛详情"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func open(eventID: String) {
        guard NBANotificationRoute.validEventID(eventID) else { return }
        window?.title = "比赛详情"
        if currentEventID != eventID || currentArticleKey != nil {
            currentArticleKey = nil
            currentEventID = eventID
            window?.contentView = NSHostingView(rootView: NBABoxScoreView(gameID: eventID).id(eventID))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func openArticle(eventID: String, cacheKey: String) async {
        guard NBANotificationRoute.validEventID(eventID), NBARecapNotification.validCacheKey(cacheKey) else { return }
        currentEventID = eventID; currentArticleKey = cacheKey
        let article = await NBATerraRecapStore.live.savedArticle(gameID: eventID, cacheKey: cacheKey)
        guard currentEventID == eventID, currentArticleKey == cacheKey else { return }
        window?.title = "赛后总结"
        if let article {
            window?.contentView = NSHostingView(rootView: NBARecapNotificationReader(article: article) { [weak self] in
                self?.open(eventID: eventID)
            })
        } else {
            window?.contentView = NSHostingView(rootView: Text("这篇总结的本地缓存暂不可用。")
                .font(.system(size: 14)).padding(32).frame(width: 620, height: 400))
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        // Releasing content ends its visibility-driven polling.
        window?.contentView = nil; currentEventID = nil; currentArticleKey = nil
        if SettingsWindowController.shared.window?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }
}
