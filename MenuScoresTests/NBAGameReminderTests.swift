import Foundation
import Testing
@testable import MenuScores

@MainActor
private final class FakeReminderSender: NBANotificationSending {
    var status: NBANotificationAuthorization = .allowed
    var sent: [NBAGameReminder] = []
    var soundFlags: [Bool] = []
    var permissionRequests = 0
    var fails = false
    var authorizationHook: (() -> Void)?
    var blockAuthorization = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func authorization() async -> NBANotificationAuthorization {
        authorizationHook?()
        if blockAuthorization { await withCheckedContinuation { waiters.append($0) } }
        return status
    }
    func requestAuthorization() async throws -> Bool { permissionRequests += 1; return true }
    func send(_ reminder: NBAGameReminder, sound: Bool) async throws {
        if fails { throw URLError(.notConnectedToInternet) }
        sent.append(reminder); soundFlags.append(sound)
    }
}

@MainActor
struct NBAGameReminderTests {
    private let start = NBASchedulePolicy.startDate("2026-10-31T02:00Z")!
    private func event(state: String = "in", period: Int = 1, clock: Double? = 600,
                       name: String = "STATUS_IN_PROGRESS", detail: String = "", score: [String] = ["100", "99"],
                       id: String = "401810123", date: String = "2026-10-31T02:00Z") throws -> Event {
        var status: [String: Any] = ["type": ["name": name, "state": state, "completed": state == "post", "detail": detail],
                                     "period": period, "displayClock": "1:59"]
        if let clock { status["clock"] = clock }
        let teams: [[String: Any]] = [
            ["id": "13", "homeAway": "away", "score": score[0], "team": ["id": "13", "abbreviation": "LAL", "links": []]],
            ["id": "2", "homeAway": "home", "score": score[1], "team": ["id": "2", "abbreviation": "BOS", "links": []]]]
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject:
            ["id": id, "name": "NBA", "date": date, "status": status, "competitions": [["status": status, "competitors": teams]]]))
    }
    private func engine() -> NBAGameReminderEngine {
        NBAGameReminderEngine(file: URL(fileURLWithPath: "/tmp/unused-reminder-tests-\(UUID().uuidString)"), write: { _, _ in })
    }
    private func options() -> NBAReminderOptions {
        NBAReminderOptions(enabled: true, sound: false, nodes: Set(NBAMilestone.allCases))
    }
    private func run(_ engine: NBAGameReminderEngine, _ game: Event, at offset: Double,
                     options: NBAReminderOptions? = nil) -> [NBAGameReminder] {
        let date = start.addingTimeInterval(offset)
        return engine.process([.init(game: game, fetchedAt: date)], eligibleIDs: [game.id], options: options ?? self.options(), now: date)
    }

    @Test func pregameUsesActualRemainingTimeAndAbsoluteStart() throws {
        let e = engine(); let pre = try event(state: "pre", period: 0)
        #expect(run(e, pre, at: -601).isEmpty)
        let reminders = run(e, pre, at: -420)
        #expect(reminders.count == 1 && reminders[0].node == .pregame)
        #expect(reminders.first?.title == "约 7 分钟后开赛")
        #expect(run(e, pre, at: -300).isEmpty)
        #expect(run(engine(), pre, at: 1).isEmpty)
        #expect(run(engine(), try event(state: "pre", name: "STATUS_POSTPONED"), at: -300).isEmpty)
    }

    @Test func allStateTransitionsAndPriorityConsumeSuppressedNodes() throws {
        let e = engine()
        #expect(run(e, try event(state: "pre", period: 0), at: -10).first?.node == .pregame)
        #expect(run(e, try event(), at: 10).first?.node == .start)
        #expect(run(e, try event(period: 2), at: 30).isEmpty)
        #expect(run(e, try event(period: 2, clock: 0, name: "STATUS_HALFTIME", detail: "Halftime"), at: 60).first?.node == .halftime)
        #expect(run(e, try event(period: 4, clock: 121), at: 80).isEmpty)
        #expect(run(e, try event(period: 4, clock: 120), at: 100).first?.node == .clutch)
        #expect(run(e, try event(period: 4, clock: 80), at: 120).isEmpty)
        #expect(run(e, try event(period: 5, clock: 100), at: 140).map(\.node) == [.overtime])
        #expect(run(e, try event(period: 5, clock: 99), at: 160).isEmpty)
        #expect(run(e, try event(period: 6, clock: 300), at: 180).first?.node == .overtime)
        #expect(run(e, try event(period: 6, clock: 90), at: 200).first?.node == .clutch)
        #expect(run(e, try event(state: "post", period: 6, clock: 0, name: "STATUS_FINAL"), at: 220).first?.node == .final)
        #expect(run(e, try event(state: "post", period: 6), at: 240).isEmpty)
    }

    @Test func clockAndIntermissionAndScoreMustBeExplicit() throws {
        let invalid: [Event] = [
            try event(period: 2, clock: 0), try event(period: 4, clock: nil),
            try event(period: 4, clock: 0), try event(period: 4, clock: -1),
            try event(period: 4, clock: 100, score: ["—", "99"]),
            try event(period: 4, clock: 100, score: ["110", "99"]),
            try event(period: 4, clock: 100, name: "STATUS_END_PERIOD"),
            try event(period: 4, clock: 100, name: "STATUS_SUSPENDED"),
            try event(period: 2, clock: 0, detail: "End of 2nd")]
        for game in invalid {
            let e = engine(); _ = run(e, try event(period: game.status.period ?? 4, clock: 300), at: 0)
            #expect(run(e, game, at: 15).isEmpty)
        }
        let e = engine(); _ = run(e, try event(period: 4, clock: 300), at: 0)
        #expect(run(e, try event(period: 4, clock: 119, score: ["100", "95"]), at: 15).first?.node == .clutch)
    }

    @Test func firstObservationAndLongRecoveryNeverReplayPastNodes() throws {
        for game in [try event(), try event(period: 2, name: "STATUS_HALFTIME"),
                     try event(period: 5), try event(state: "post", name: "STATUS_FINAL"), try event(period: 4, clock: 100)] {
            let e = engine()
            #expect(run(e, game, at: 0).isEmpty)
            #expect(run(e, game, at: 15).isEmpty)
        }
        let e = engine(); _ = run(e, try event(state: "pre"), at: -10)
        #expect(run(e, try event(period: 5, clock: 100), at: 301).isEmpty)
        #expect(run(e, try event(period: 5, clock: 90), at: 320).isEmpty)
    }

    @Test func staleFutureAndOutOfOrderVersionsCannotTrigger() throws {
        let e = engine(); _ = run(e, try event(state: "pre"), at: -10)
        let game = try event()
        #expect(e.process([.init(game: game, fetchedAt: start.addingTimeInterval(-100))], eligibleIDs: [game.id], options: options(), now: start).isEmpty)
        #expect(e.process([.init(game: game, fetchedAt: start.addingTimeInterval(10))], eligibleIDs: [game.id], options: options(), now: start).isEmpty)
        #expect(run(e, game, at: 15).first?.node == .start)
        #expect(run(e, try event(state: "pre"), at: 10).isEmpty)
        #expect(run(e, game, at: 16).isEmpty)
        #expect(run(e, try event(period: 4, clock: 300), at: 20).isEmpty)
        #expect(run(e, try event(period: 2, name: "STATUS_HALFTIME"), at: 30).isEmpty)
        #expect(run(e, try event(period: 4, clock: 119), at: 40).first?.node == .clutch)
    }

    @Test func favoriteUnionAndManualPinDeduplicateByEventID() throws {
        let game = try event()
        #expect(NBAGameReminderEngine.eligibleIDs(games: [game, game], manualID: game.id, favoriteTeamIDs: ["13", "2"]) == [game.id])
        #expect(NBAGameReminderEngine.eligibleIDs(games: [game], manualID: game.id, favoriteTeamIDs: []) == [game.id])
        #expect(NBAGameReminderEngine.eligibleIDs(games: [game], manualID: nil, favoriteTeamIDs: []).isEmpty)
        let e = engine(); let now = start.addingTimeInterval(-300)
        let pre = try event(state: "pre")
        #expect(e.process([.init(game: pre, fetchedAt: now), .init(game: pre, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now).count == 1)
    }

    @Test func restartRescheduleAndMembershipChangesRetainDurableClaims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ledger.json")
        let first = NBAGameReminderEngine(file: file)
        #expect(run(first, try event(state: "pre"), at: -300).count == 1)
        let second = NBAGameReminderEngine(file: file)
        #expect(run(second, try event(state: "pre", date: "2026-10-31T02:03Z"), at: -100).isEmpty)
        #expect(run(second, try event(), at: 10).first?.node == .start)
        _ = second.process([], eligibleIDs: [], options: options(), now: start.addingTimeInterval(20))
        #expect(run(second, try event(period: 5), at: 30).isEmpty)
        let third = NBAGameReminderEngine(file: file)
        #expect(run(third, try event(state: "post"), at: 40).isEmpty)
    }

    @Test func disabledSwitchesDoNotReplayAndDefaultsPreserveChoices() throws {
        let e = engine(); var off = options(); off.enabled = false
        #expect(run(e, try event(state: "pre"), at: -10, options: off).isEmpty)
        #expect(run(e, try event(), at: 10).isEmpty)
        var selective = options(); selective.nodes.remove(.overtime)
        _ = run(e, try event(period: 4), at: 20, options: selective)
        #expect(run(e, try event(period: 5, clock: 300), at: 30, options: selective).isEmpty)
        #expect(run(e, try event(period: 5, clock: 299), at: 40).isEmpty)
        let suite = "MenuScores.ReminderTests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!NBAReminderOptions.read(defaults).enabled)
        #expect(NBAReminderOptions.read(defaults).nodes == [.pregame, .start, .clutch, .final])
        defaults.set(false, forKey: NBAReminderOptions.key(.start))
        defaults.set(true, forKey: NBAReminderOptions.key(.halftime))
        #expect(!NBAReminderOptions.read(defaults).nodes.contains(.start))
        #expect(NBAReminderOptions.read(defaults).nodes.contains(.halftime))
    }

    @Test func persistenceFailureNeverSubmitsAndCorruptionFailsClosed() throws {
        let e = NBAGameReminderEngine(file: URL(fileURLWithPath: "/tmp/no-ledger-\(UUID().uuidString)"), write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(run(e, try event(state: "pre"), at: -300).isEmpty)
        #expect(e.persistenceError != nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("bad".utf8).write(to: file)
        let broken = NBAGameReminderEngine(file: file)
        #expect(run(broken, try event(state: "pre"), at: -300).isEmpty)
        #expect(try Data(contentsOf: file) == Data("bad".utf8))
    }

    @Test func permissionIsOnlyRequestedFromExplicitUserAction() async throws {
        let sender = FakeReminderSender(); sender.status = .notDetermined
        let service = NBAGameReminderService(engine: engine(), sender: sender)
        let pre = try event(state: "pre"); let now = start.addingTimeInterval(-300)
        await service.process([.init(game: pre, fetchedAt: now)], eligibleIDs: [pre.id], options: options(), now: now) { ([pre.id], options()) }
        #expect(sender.sent.isEmpty && sender.permissionRequests == 0)
        _ = await service.enableFromUserAction()
        #expect(sender.permissionRequests == 1)
        sender.status = .denied
        _ = await service.enableFromUserAction()
        #expect(sender.permissionRequests == 1)
    }

    @Test func permissionAwaitRechecksRelevanceAndEnabledState() async throws {
        let sender = FakeReminderSender(); let service = NBAGameReminderService(engine: engine(), sender: sender)
        let game = try event(state: "pre"); let now = start.addingTimeInterval(-300)
        var current = options()
        sender.authorizationHook = { current.enabled = false }
        await service.process([.init(game: game, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now) { ([game.id], current) }
        #expect(sender.sent.isEmpty)
        let other = NBAGameReminderService(engine: engine(), sender: sender)
        sender.authorizationHook = nil
        await other.process([.init(game: game, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now) { ([], options()) }
        #expect(sender.sent.isEmpty)
    }

    @Test func senderFailureAndDuplicateCallsNeverRetryClaimedNode() async throws {
        let sender = FakeReminderSender(); sender.fails = true
        let service = NBAGameReminderService(engine: engine(), sender: sender)
        let game = try event(state: "pre"); let now = start.addingTimeInterval(-300)
        await service.process([.init(game: game, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now) { ([game.id], options()) }
        sender.fails = false
        await service.process([.init(game: game, fetchedAt: now.addingTimeInterval(15))], eligibleIDs: [game.id], options: options(), now: now.addingTimeInterval(15)) { ([game.id], options()) }
        #expect(sender.sent.isEmpty)
        let fresh = NBAGameReminderService(engine: engine(), sender: sender)
        await fresh.process([.init(game: game, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now) { ([game.id], options()) }
        #expect(sender.sent.count == 1 && sender.soundFlags == [false])
    }

    @Test func concurrentRefreshesClaimBeforeAuthorizationSuspends() async throws {
        let sender = FakeReminderSender(); sender.blockAuthorization = true
        let service = NBAGameReminderService(engine: engine(), sender: sender)
        let game = try event(state: "pre"); let now = start.addingTimeInterval(-300)
        let first = Task {
            await service.process([.init(game: game, fetchedAt: now)], eligibleIDs: [game.id], options: options(), now: now) { ([game.id], options()) }
        }
        while sender.waiters.isEmpty { await Task.yield() }
        await service.process([.init(game: game, fetchedAt: now.addingTimeInterval(15))], eligibleIDs: [game.id], options: options(), now: now.addingTimeInterval(15)) { ([game.id], options()) }
        #expect(sender.waiters.count == 1)
        sender.blockAuthorization = false
        sender.waiters.removeFirst().resume()
        await first.value
        #expect(sender.sent.count == 1)
    }

    @Test func routeRejectsForeignPayloadAndNeverAcceptsURLCommands() {
        let info: [AnyHashable: Any] = ["kind": "nba.milestone.v1", "eventID": "401810123"]
        #expect(NBANotificationRoute.eventID(userInfo: info, identifier: "nba.milestone.401810123.final") == "401810123")
        #expect(NBANotificationRoute.eventID(userInfo: info, identifier: "foreign.401810123") == nil)
        #expect(NBANotificationRoute.eventID(userInfo: ["eventID": "401810123"], identifier: "nba.milestone.401810123.final") == nil)
        #expect(!NBANotificationRoute.validEventID("https://example.com"))
        #expect(!NBANotificationRoute.validEventID("401;open"))
        #expect(!NBANotificationRoute.validEventID("１２３"))
    }
}
