import Foundation
import Testing
@testable import MenuScores

@MainActor
private final class NotchTestOverlay: NBAMilestoneOverlay {
    var wantsMilestones = true
    var available = true
    var shown: [String] = []
    func present(_ reminder: NBAGameReminder) -> Bool {
        guard available else { return false }
        shown.append(reminder.identifier); return true
    }
}
@MainActor
private final class NotchTestSender: NBANotificationSending {
    var status: NBANotificationAuthorization = .allowed
    var sent = 0
    var permissionRequests = 0
    var authorizationChecks = 0
    func authorization() async -> NBANotificationAuthorization { authorizationChecks += 1; return status }
    func requestAuthorization() async throws -> Bool { permissionRequests += 1; return true }
    func send(_ reminder: NBAGameReminder, sound: Bool) async throws { sent += 1 }
}

@MainActor
struct NBANotchTests {
    let now = NBASchedulePolicy.startDate("2026-10-31T01:55:00Z")!
    private func game(_ id: String = "401810123", state: String = "pre", period: Int = 0,
                      name: String = "STATUS_SCHEDULED", completed: Bool = false) throws -> Event {
        let status: [String: Any] = ["period": period, "displayClock": "1:32", "clock": 92,
            "type": ["name": name, "state": state, "completed": completed]]
        let sides: [[String: Any]] = [["id": "13", "homeAway": "away", "score": "100", "team": ["id": "13", "abbreviation": "LAL", "links": []]],
            ["id": "9", "homeAway": "home", "score": "99", "team": ["id": "9", "abbreviation": "GS", "links": []]]]
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "date": "2026-10-31T02:00:00Z", "name": "Lakers vs Warriors", "status": status,
            "competitions": [["status": status, "competitors": sides]]]))
    }
    private func reminder(_ event: Event) -> NBAGameReminder {
        NBAGameReminder(game: event, identifier: "nba.milestone.\(event.id).pregame", eventID: event.id,
                        teamIDs: ["13", "9"], node: .pregame, title: "约5分钟后开赛", body: "湖人 对阵 勇士")
    }
    private func service(_ sender: NotchTestSender, _ overlay: NotchTestOverlay) -> NBAGameReminderService {
        NBAGameReminderService(engine: NBAGameReminderEngine(file: URL(fileURLWithPath: "/tmp/notch-test-\(UUID().uuidString)"), write: { _, _ in }), sender: sender, overlay: overlay)
    }
    @Test func optionsDefaultOffAndScreenSelectionFallsBackWithoutIndexing() {
        let name = "MenuScores.NotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!NBANotchOptions.read(defaults).enabled)
        #expect(!NBANotchOptions.read(defaults).milestones)
        defaults.set(true, forKey: NBANotchOptions.enabledKey)
        defaults.set("disconnected", forKey: NBANotchOptions.screenKey)
        #expect(NBANotchOptions.read(defaults).enabled)
        #expect(NBANotchOptions.screen(preferred: "B", available: ["A", "B"], main: "A") == "B")
        #expect(NBANotchOptions.screen(preferred: "gone", available: ["A", "B"], main: "B") == "B")
        #expect(NBANotchOptions.screen(preferred: "gone", available: ["A"], main: nil) == "A")
        #expect(NBANotchOptions.screen(preferred: "gone", available: [], main: nil) == nil)
        #expect(defaults.string(forKey: NBANotchOptions.screenKey) == "disconnected")
    }
    @Test func temporaryMomentReturnsToLatestPinAndWaitsForHover() throws {
        var session = NBANotchSession()
        session.pinned = try game("401810001")
        session.present(reminder(try game("401810002")), now: now)
        #expect(session.game?.id == "401810002")
        session.pinned = try game("401810003")
        let held = session.finishIfDue(now: now.addingTimeInterval(9), interacting: true)
        #expect(!held)
        #expect(session.game?.id == "401810002")
        let finished = session.finishIfDue(now: now.addingTimeInterval(9), interacting: false)
        #expect(finished)
        #expect(session.game?.id == "401810003")
    }
    @Test func noPinAndSleepCancellationDoNotCreateSelection() throws {
        var session = NBANotchSession()
        session.present(reminder(try game()), now: now)
        let early = session.finishIfDue(now: now.addingTimeInterval(7), interacting: false)
        #expect(!early)
        session.cancelMoment()
        #expect(session.game == nil && session.pinned == nil)
    }
    @Test func pregameLiveFinalAndPostponedHaveHonestLabels() throws {
        #expect(NBANotchPresentation(game: try game()).compactTime == "10:00")
        let live = NBANotchPresentation(game: try game(state: "in", period: 4, name: "STATUS_IN_PROGRESS"))
        #expect(live.status == "第 4 节 · 1:32")
        #expect(live.teams.map(\.homeAway) == ["away", "home"])
        #expect(NBANotchPresentation(game: try game(state: "post", name: "STATUS_FINAL", completed: true)).compactBadge == "已结束")
        let postponed = NBANotchPresentation(game: try game(name: "STATUS_POSTPONED"))
        #expect(postponed.status == "已延期" && postponed.compactTime == nil)
    }
    @Test func overlayOnlyUsesNoNotificationAuthorizationAndDeduplicates() async throws {
        let sender = NotchTestSender(); sender.status = .notDetermined
        let overlay = NotchTestOverlay(); let service = service(sender, overlay)
        let event = try game(); var options = NBAReminderOptions(); options.enabled = false
        let scope: Set<String> = [event.id]
        for offset in [0.0, 15.0] {
            let date = now.addingTimeInterval(offset)
            await service.process([.init(game: event, fetchedAt: date)], eligibleIDs: scope, options: options, now: date) { (scope, options) }
        }
        #expect(overlay.shown.count == 1)
        #expect(sender.sent == 0 && sender.authorizationChecks == 0 && sender.permissionRequests == 0)
    }
    @Test func overlayWinsAndUnavailableOverlayFallsBackToEnabledSystemChannel() async throws {
        let event = try game(); let scope: Set<String> = [event.id]
        var options = NBAReminderOptions(); options.enabled = true
        let sender = NotchTestSender(); let overlay = NotchTestOverlay()
        await service(sender, overlay).process([.init(game: event, fetchedAt: now)], eligibleIDs: scope, options: options, now: now) { (scope, options) }
        #expect(overlay.shown.count == 1 && sender.sent == 0)
        overlay.available = false
        await service(sender, overlay).process([.init(game: event, fetchedAt: now)], eligibleIDs: scope, options: options, now: now) { (scope, options) }
        #expect(sender.sent == 1 && overlay.shown.count == 1)
    }
    @Test func bothOutputsOffOrNodeOffCannotDeliver() async throws {
        let event = try game(); let scope: Set<String> = [event.id]
        let sender = NotchTestSender(); let overlay = NotchTestOverlay(); overlay.wantsMilestones = false
        var options = NBAReminderOptions()
        await service(sender, overlay).process([.init(game: event, fetchedAt: now)], eligibleIDs: scope, options: options, now: now) { (scope, options) }
        overlay.wantsMilestones = true; options.nodes.remove(.pregame)
        await service(sender, overlay).process([.init(game: event, fetchedAt: now)], eligibleIDs: scope, options: options, now: now) { (scope, options) }
        #expect(overlay.shown.isEmpty && sender.sent == 0 && sender.permissionRequests == 0)
    }
    @Test func staleObservationsAndRemovedScopeNeverReachOverlay() async throws {
        let event = try game(); let scope: Set<String> = [event.id]
        let sender = NotchTestSender(); let overlay = NotchTestOverlay(); let options = NBAReminderOptions()
        await service(sender, overlay).process([.init(game: event, fetchedAt: now.addingTimeInterval(-61))], eligibleIDs: scope, options: options, now: now) { (scope, options) }
        await service(sender, overlay).process([.init(game: event, fetchedAt: now)], eligibleIDs: scope, options: options, now: now) { ([], options) }
        #expect(overlay.shown.isEmpty && sender.sent == 0)
    }
    @Test func managerLoadsAndSavesAllLegacyFavoritesWithoutMigration() throws {
        let name = "MenuScores.FavoriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(#"[{"id":"league-f1","leagueKey":"F1","displayName":"F1","abbreviation":"F1","logo":null},{"id":"13","leagueKey":"NBA","displayName":"Lakers","abbreviation":"LAL","logo":null}]"#.utf8)
        defaults.set(data, forKey: "favoriteTeams")
        let manager = FavoritesManager(defaults: defaults)
        #expect(manager.favorites.map(\.leagueKey) == ["F1", "NBA"])
        #expect(defaults.data(forKey: "favoriteTeams") == data)
        manager.saveFavorites()
        let reread = FavoritesManager(defaults: defaults)
        #expect(reread.favorites.map(\.leagueKey) == ["F1", "NBA"])
    }
}
