import Foundation
import Testing
@testable import MenuScores

private final class LoadingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private actor LoadingSource {
    var count = 0
    var failing = false
    var state = "in"
    var years: [Int] = []
    var needsConcurrentPrior = false
    var priorStarted = false
    func requireConcurrentPrior() { needsConcurrentPrior = true }
    func fail(_ value: Bool) { failing = value }
    func status(_ value: String) { state = value }
    func total() -> Int { count }
    func recordedYears() -> [Int] { years }
    private func begin() async throws {
        count += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        if failing { throw URLError(.notConnectedToInternet) }
    }
    func summary(_ id: String) async throws -> Data {
        try await begin()
        return Data("{\"header\":{\"id\":\"\(id)\",\"season\":{\"year\":2027,\"type\":2},\"competitions\":[{\"status\":{\"type\":{\"state\":\"\(state)\"}}}]}}".utf8)
    }
    func history(_ url: URL) async throws -> Data {
        try await begin()
        let day = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dates" }?.value ?? ""
        return Data("{\"leagues\":[],\"events\":[{\"id\":\"\(day)\",\"date\":\"2027-01-15T12:00:00Z\",\"name\":\"NBA\",\"competitions\":[],\"status\":{\"type\":{\"state\":\"post\",\"completed\":true}}}]}".utf8)
    }
    func profile(_ url: URL) async throws -> Data {
        try await begin()
        if url.path.hasSuffix("overview") {
            return Data(#"{"statistics":{"names":["avgPoints"],"splits":[{"displayName":"Regular Season","stats":["20"]}]}}"#.utf8)
        }
        let id = url.lastPathComponent
        // Missing statsSummary is legitimate for retired/unranked players.
        return Data("{\"athlete\":{\"id\":\"\(id)\",\"displayName\":\"Test\"}}".utf8)
    }
    func league(_ scope: NBALeaguePercentileStore.Scope) async throws -> NBALeaguePercentileStore.Response {
        years.append(scope.year)
        if scope.year == 2026 { priorStarted = true }
        if needsConcurrentPrior && scope.year == 2027 {
            for _ in 0..<100 where !priorStarted { try await Task.sleep(nanoseconds: 2_000_000) }
            guard priorStarted else { throw URLError(.timedOut) }
        }
        try await begin()
        return try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: Data("{\"pagination\":{\"count\":0,\"page\":1,\"pages\":1},\"requestedSeason\":{\"year\":\(scope.year),\"type\":{\"type\":\(scope.type)}},\"categories\":[],\"athletes\":[]}".utf8))
    }
}

struct NBALoadingCacheTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("NBA-loading-" + UUID().uuidString) }

    @Test func summaryCoalescesSurvivesNavigationAndRestartsWithoutMixingGames() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        let store = NBABoxScoreStore(directory: root, now: { clock.now() }, fetch: { try await source.summary($0) })
        let dismissed = Task { try await store.load(gameID: "1") }
        dismissed.cancel()
        async let same = store.load(gameID: "1")
        let first = try await dismissed.value
        #expect(try await same.summary.header?.id == "1")
        #expect(first.summary.header?.id == "1")
        #expect(await source.total() == 1)
        async let other = store.load(gameID: "2")
        async let warm = store.load(gameID: "1")
        #expect(try await other.summary.header?.id == "2")
        #expect(try await warm.summary.header?.id == "1")
        #expect(await source.total() == 2)
        let restarted = NBABoxScoreStore(directory: root, now: { clock.now() }, fetch: { try await source.summary($0) })
        #expect(try await restarted.load(gameID: "1").date == first.date)
        #expect(await source.total() == 2)
    }

    @Test func summaryTTLExactBoundariesCompletedCorrectionAndLiveTransition() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        await source.status("pre")
        let store = NBABoxScoreStore(directory: root, now: { clock.now() }, fetch: { try await source.summary($0) })
        let first = try await store.load(gameID: "1")
        clock.advance(14.999)
        _ = try await store.load(gameID: "1")
        #expect(await source.total() == 1)
        clock.advance(0.001)
        await source.status("in")
        #expect(try await store.load(gameID: "1").summary.match?.status?.type?.state == "in")
        #expect(await source.total() == 2)
        await source.status("post")
        let completed = try await store.load(gameID: "1", force: true)
        #expect(completed.summary.match?.status?.type?.state == "post")
        clock.advance(NBABoxScoreStore.completedTTL - 0.001)
        _ = try await store.load(gameID: "1")
        #expect(await source.total() == 3)
        clock.advance(0.001)
        let expired = try #require(await store.cached(gameID: "1"))
        #expect(expired.isStale && expired.date == completed.date)
        _ = try await store.load(gameID: "1")
        #expect(await source.total() == 4)
        await source.status("in") // Upstream correction/reopened game.
        let corrected = try await store.load(gameID: "1", force: true)
        #expect(NBABoxScoreStore.ttl(for: corrected.summary) == 15)
        clock.advance(15)
        _ = try await store.load(gameID: "1")
        #expect(await source.total() == 6)
        #expect(first.date < corrected.date)
        clock.advance(29.999)
        _ = try await store.load(gameID: "1", liveInterval: 30)
        #expect(await source.total() == 6)
        clock.advance(0.001)
        _ = try await store.load(gameID: "1", liveInterval: 30)
        #expect(await source.total() == 7)
    }

    @Test func summaryFailureAllWaitersKeepDateAndManualRefreshBypassesCooldown() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        let store = NBABoxScoreStore(directory: root, now: { clock.now() }, fetch: { try await source.summary($0) })
        let first = try await store.load(gameID: "1")
        clock.advance(15); await source.fail(true)
        async let a = store.load(gameID: "1"); async let b = store.load(gameID: "1")
        let results = try await [a,b]
        #expect(results.allSatisfy { $0.refreshFailed && $0.isStale && $0.date == first.date })
        #expect(await source.total() == 2)
        _ = try await store.load(gameID: "1")
        #expect(await source.total() == 2)
        await source.fail(false)
        #expect(try await !store.load(gameID: "1", force: true).refreshFailed)
        #expect(await source.total() == 3)
    }

    @Test func historyDayIsolationConcurrentFailureAndFiveMinuteBoundary() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        let store = NBAHistoryStore(directory: root, now: { clock.now() }, fetch: { try await source.history($0) })
        let calendar: Calendar = {
            var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
            return value
        }()
        let day = calendar.startOfDay(for: clock.now())
        async let a = store.loadEntry(day: day, calendar: calendar)
        async let b = store.loadEntry(day: day, calendar: calendar)
        let initial = try await [a,b]
        #expect(initial[0].date == initial[1].date)
        #expect(await source.total() == 2)
        clock.advance(299.999)
        _ = try await store.loadEntry(day: day, calendar: calendar)
        #expect(await source.total() == 2)
        clock.advance(0.001); await source.fail(true)
        async let failedA = store.loadEntry(day: day, calendar: calendar)
        async let failedB = store.loadEntry(day: day, calendar: calendar)
        let failed = try await [failedA, failedB]
        #expect(failed.allSatisfy { $0.refreshFailed && $0.isStale && $0.date == initial[0].date })
        #expect(await source.total() == 4)
        await source.fail(false)
        let otherDay = calendar.date(byAdding: .day, value: -1, to: day)!
        _ = try await store.loadEntry(day: otherDay, calendar: calendar)
        #expect(await source.total() == 6)
        #expect(await store.cached(day: day, calendar: calendar)?.date == initial[0].date)
        let oldDay = calendar.date(byAdding: .day, value: -3, to: day)!
        #expect(try await store.loadEntry(day: oldDay, calendar: calendar).games.isEmpty)
        #expect(await source.total() == 8)
        clock.advance(86399.999)
        _ = try await store.loadEntry(day: oldDay, calendar: calendar)
        #expect(await source.total() == 8)
        clock.advance(0.001)
        _ = try await store.loadEntry(day: oldDay, calendar: calendar)
        #expect(await source.total() == 10)
    }

    @Test func profileCoalescesUnrankedDataAndOnlyRefreshesTwoPersonalEndpoints() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        let store = NBAPlayerProfileStore(directory: root, now: { clock.now() }, fetch: { try await source.profile($0) })
        async let a = store.loadResult(id: "1"); async let b = store.loadResult(id: "1")
        let initial = try await [a,b]
        #expect(await source.total() == 2)
        #expect(initial.allSatisfy { $0.entry.profile.athlete.statsSummary == nil && !$0.refreshFailed })
        clock.advance(899.999); _ = try await store.load(id: "1")
        #expect(await source.total() == 2)
        clock.advance(0.001); await source.fail(true)
        async let failedA = store.loadResult(id: "1"); async let failedB = store.loadResult(id: "1")
        let failed = try await [failedA,failedB]
        #expect(failed.allSatisfy { $0.refreshFailed && $0.isStale && $0.entry.date == initial[0].entry.date })
        #expect(await source.total() == 4)
        await source.fail(false)
        _ = try await store.loadResult(id: "1", force: true)
        #expect(await source.total() == 6)
        _ = try await store.loadResult(id: "2")
        #expect(await source.total() == 8)
        let restarted = NBAPlayerProfileStore(directory: root, now: { clock.now() }, fetch: { try await source.profile($0) })
        #expect(try await restarted.load(id: "2").profile.athlete.id == "2")
        #expect(await source.total() == 8)
    }

    @Test func leaguePairStartsSeasonsTogetherAndSurvivesDiskEviction() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        await source.requireConcurrentPrior()
        let scope = NBALeaguePercentileStore.Scope(year: 2027, type: 2)
        let store = NBALeaguePercentileStore(directory: root, priorDirectory: root.appendingPathComponent("prior"), now: { clock.now() }) { scope, _, _ in try await source.league(scope) }
        async let a = store.loadPair(scope: scope); async let b = store.loadPair(scope: scope)
        let pairs = await [a,b]
        #expect(pairs.allSatisfy { $0.snapshot?.scope == scope && $0.prior.snapshot?.scope == scope.previous })
        #expect(await source.total() == 6)
        let years = await source.recordedYears()
        #expect(Set(years) == [2027,2026])
        // Evicting disk must not affect a warm in-memory prior read.
        try FileManager.default.removeItem(at: root)
        #expect(await store.loadPrior(for: scope).snapshot?.date == pairs[0].prior.snapshot?.date)
        #expect(await source.total() == 6)
        clock.advance(900)
        _ = await store.loadPair(scope: scope)
        #expect(await source.total() == 11) // Current only; prior remains valid.
        clock.advance(86400 - 900)
        _ = await store.loadPair(scope: scope)
        #expect(await source.total() == 17) // Exact 24h prior boundary.
        let post = NBALeaguePercentileStore.Scope(year: 2027, type: 3)
        #expect(await store.loadPair(scope: post).prior.snapshot?.scope == post.previous)
        #expect(await source.total() == 23)
    }

    @Test func leagueConcurrentFailureReturnsSameOldSnapshotsAndFailureState() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        let scope = NBALeaguePercentileStore.Scope(year: 2027, type: 2)
        let store = NBALeaguePercentileStore(directory: root, priorDirectory: root.appendingPathComponent("prior"), now: { clock.now() }) { scope, _, _ in try await source.league(scope) }
        let first = await store.loadPair(scope: scope)
        clock.advance(86400); await source.fail(true)
        async let a = store.loadPair(scope: scope); async let b = store.loadPair(scope: scope)
        let failed = await [a,b]
        #expect(failed.allSatisfy { $0.currentRefreshFailed && $0.prior.refreshFailed && $0.snapshot?.date == first.snapshot?.date && $0.prior.snapshot?.date == first.prior.snapshot?.date })
        let count = await source.total()
        _ = await store.loadPair(scope: scope)
        #expect(await source.total() == count)
        await source.fail(false)
        let fixed = await store.loadPair(scope: scope, forceCurrent: true, forcePrior: true)
        #expect(!fixed.currentRefreshFailed && !fixed.prior.refreshFailed)
    }

    @Test func coldFailuresBackOffAndInvalidDiskOrWrongGameCannotPoisonCache() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LoadingSource(); let clock = LoadingClock()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("1.json"))
        let store = NBABoxScoreStore(directory: root, now: { clock.now() }, fetch: { try await source.summary($0) })
        await source.fail(true)
        do { _ = try await store.load(gameID: "1"); Issue.record("Cold offline load should fail") } catch {}
        do { _ = try await store.load(gameID: "1"); Issue.record("Cooldown should retain failure") } catch {}
        #expect(await source.total() == 1)
        clock.advance(60)
        do { _ = try await store.load(gameID: "1"); Issue.record("Cold offline load should fail again after cooldown") } catch {}
        #expect(await source.total() == 2)
        await source.fail(false)
        let good = try await store.load(gameID: "1", force: true)
        #expect(good.summary.header?.id == "1")
        let wrong = NBABoxScoreStore(directory: root, now: { clock.now() }) { _ in try await source.summary("999") }
        let retained = try await wrong.load(gameID: "1", force: true)
        #expect(retained.refreshFailed && retained.summary.header?.id == "1" && retained.date == good.date)
        #expect(await wrong.cached(gameID: "999") == nil)
        let unavailable = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: unavailable)
        let memoryOnly = NBABoxScoreStore(directory: unavailable, now: { clock.now() }, fetch: { try await source.summary($0) })
        #expect(try await !memoryOnly.load(gameID: "7").refreshFailed)
        #expect(await memoryOnly.cached(gameID: "7")?.summary.header?.id == "7")
        #expect(try Data(contentsOf: unavailable) == sentinel)
    }
}
