import Foundation
import Testing
@testable import MenuScores

private final class ScheduleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NBASchedulePolicy.startDate("2026-10-30T04:00Z")!
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor ScheduleSource {
    private var keys: [String] = []
    private var fails = false
    func fail() { fails = true }
    func requests() -> [String] { keys }
    func fetch(_ url: URL) async throws -> Data {
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "dates" }!.value!
        keys.append(key)
        try await Task.sleep(nanoseconds: 10_000_000)
        if fails { throw URLError(.notConnectedToInternet) }
        return Data("{\"leagues\":[],\"events\":[{\"id\":\"\(key)\",\"date\":\"2026-10-31T02:00Z\",\"name\":\"NBA\",\"competitions\":[],\"status\":{\"type\":{\"state\":\"pre\",\"completed\":false}}}]}".utf8)
    }
}

struct NBAScheduleStoreTests {
    @Test func titlesFollowHomeAwayRolesRegardlessOfProviderArrayOrder() throws {
        for reverse in [false, true] {
            var teams: [[String: Any]] = [
                ["id": "13", "homeAway": "away", "score": "99", "team": ["id": "13", "abbreviation": "LAL", "links": []]],
                ["id": "2", "homeAway": "home", "score": "101", "team": ["id": "2", "abbreviation": "BOS", "links": []]]]
            if reverse { teams.reverse() }
            let status: [String: Any] = ["type": ["state": "pre", "completed": false]]
            let data = try JSONSerialization.data(withJSONObject: ["id": "123", "date": "2026-10-31T02:00Z", "name": "NBA",
                "status": status, "competitions": [["status": status, "competitors": teams]]])
            let game = try JSONDecoder().decode(Event.self, from: data)
            #expect(NBAMenuPresentation.title(for: game) == "湖人 对阵 凯尔特人 · 10月31日 10:00")
        }
    }

    @Test func adjacentDaysAndConcurrentLoadsShareRawProviderRequestsAndDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ScheduleClock(); let source = ScheduleSource()
        let store = NBAScheduleStore(directory: directory, now: { clock.now() }, fetch: { try await source.fetch($0) })
        let day = clock.now()
        let next = NBASchedulePolicy.calendar.date(byAdding: .day, value: 1, to: day)!
        #expect(NBAScheduleStore.providerKeys(for: day) == ["20261029", "20261030"])
        #expect(NBAScheduleStore.providerKeys(for: next) == ["20261030", "20261031"])
        async let today = store.load(day: day)
        async let tomorrow = store.load(day: next)
        async let same = store.load(day: day)
        _ = try await (today, tomorrow, same)
        let requests = await source.requests()
        #expect(requests.count == 3)
        #expect(Set(requests) == ["20261029", "20261030", "20261031"])
        let restarted = NBAScheduleStore(directory: directory, now: { clock.now() }, fetch: { try await source.fetch($0) })
        #expect(try await restarted.load(day: next).date == day)
        #expect(await source.requests().count == 3)
    }

    @Test func failedRefreshPreservesOriginalDateAndColdFailureIsAnError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ScheduleClock(); let source = ScheduleSource()
        let store = NBAScheduleStore(directory: directory, now: { clock.now() }, fetch: { try await source.fetch($0) })
        let first = try await store.load(day: clock.now())
        clock.advance(900); await source.fail()
        let failed = try await store.load(day: clock.now())
        #expect(failed.refreshFailed)
        #expect(failed.notificationObservations.isEmpty)
        #expect(failed.date == first.date)
        #expect(failed.games.map(\.id) == first.games.map(\.id))
        #expect(first.notificationObservations.count == first.games.count)
        #expect(first.notificationObservations.allSatisfy { $0.fetchedAt == first.date })
        #expect(await store.cached(day: clock.now())?.notificationObservations.isEmpty == true)
        let count = await source.requests().count
        _ = try await store.load(day: clock.now())
        #expect(await source.requests().count == count)
        let cold = NBAScheduleStore(directory: directory.appendingPathComponent("cold"), fetch: { try await source.fetch($0) })
        await #expect(throws: (any Error).self) { try await cold.load(day: clock.now()) }
    }

    @Test @MainActor func summaryRecoveryKeepsManualOwnerAndUpdatesDateAndExplicitStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NBAPinnedSelectionStore(file: directory.appendingPathComponent("pin.json"))
        let event = try JSONDecoder().decode(Event.self, from: Data(#"{"id":"123","date":"2026-10-31T02:00Z","name":"NBA","competitions":[],"status":{"type":{"state":"pre","completed":false}}}"#.utf8))
        store.pinManually(event)
        let summary = try JSONDecoder().decode(NBABoxScore.self, from: Data(#"{"header":{"id":"123","competitions":[{"date":"2026-11-02T03:00Z","status":{"type":{"name":"STATUS_POSTPONED","state":"pre","detail":"Postponed"}}}]}}"#.utf8))
        store.update(summary: summary, gameID: "123")
        #expect(store.selection?.source == .manual)
        #expect(store.selection?.date == "2026-11-02T03:00Z")
        #expect(store.selection.map { NBAMenuPresentation.specialState(for: $0.game) } == "已延期")
        #expect(NBAPinnedSelectionStore(file: directory.appendingPathComponent("pin.json")).selection?.statusName == "STATUS_POSTPONED")
    }
}
