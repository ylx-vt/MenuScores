import Foundation
import Testing
@testable import MenuScores

private actor MenuScheduleSource {
    private var count = 0
    private var failing = false
    func fail() { failing = true }
    func requests() -> Int { count }
    func fetch(_ url: URL) throws -> Data {
        count += 1
        if failing { throw URLError(.notConnectedToInternet) }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "dates" }!.value!
        let events: String
        switch key {
        case "20261029": events = #"{"id":"live","date":"2026-10-30T03:00Z","name":"NBA","competitions":[],"status":{"type":{"state":"in","completed":false}}}"#
        case "20261030": events = #"{"id":"reserved","date":"2026-10-31T02:00Z","name":"NBA","competitions":[],"status":{"type":{"state":"pre","completed":false}}}"#
        default: events = ""
        }
        return Data("{\"leagues\":[],\"events\":[\(events)]}".utf8)
    }
}

struct NBAScheduleViewModelTests {
    @Test @MainActor func noonAddsTomorrowAndMidnightMovesItsStableIDToToday() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MenuScheduleSource()
        let before = NBASchedulePolicy.startDate("2026-10-30T03:59:59Z")!
        let store = NBAScheduleStore(directory: directory, now: { before }, fetch: { try await source.fetch($0) })
        let model = GamesListView()
        await model.refreshSchedule(now: before, store: store)
        #expect(!model.showsTomorrow)
        #expect(model.games.map(\.id) == ["live"])
        #expect(model.tomorrowGames.isEmpty)
        #expect(await source.requests() == 2)
        let noon = before.addingTimeInterval(1)
        await model.refreshSchedule(now: noon, store: store)
        #expect(model.showsTomorrow)
        #expect(model.games.map(\.id) == ["live"])
        #expect(model.tomorrowGames.map(\.id) == ["reserved"])
        #expect(await source.requests() == 3)
        #expect(model.scheduleDelay(now: noon) == 15)
        await model.refreshSchedule(now: NBASchedulePolicy.startDate("2026-10-30T16:00Z")!, store: store)
        #expect(!model.showsTomorrow)
        #expect(model.games.map(\.id) == ["live", "reserved"])
        #expect(model.tomorrowGames.isEmpty)
        #expect(await source.requests() == 3)
    }

    @Test @MainActor func coldFailureIsNotEmptyScheduleAndFarPregameDoesNotPollEvery15Seconds() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MenuScheduleSource(); await source.fail()
        let noon = NBASchedulePolicy.startDate("2026-10-30T04:00Z")!
        let store = NBAScheduleStore(directory: directory, now: { noon }, fetch: { try await source.fetch($0) })
        let model = GamesListView()
        await model.refreshSchedule(now: noon, store: store)
        #expect(model.errorMessage != nil && model.tomorrowError != nil)
        #expect(model.games.isEmpty && model.tomorrowGames.isEmpty)
        #expect(model.scheduleDelay(now: noon) == 60)
        #expect(!model.isLoading && !model.tomorrowIsLoading)
        model.errorMessage = nil; model.tomorrowError = nil
        #expect(model.scheduleDelay(now: noon) == 900)
        #expect(model.scheduleDelay(now: noon.addingTimeInterval(12 * 3600 - 10)) == 10)
    }
}
