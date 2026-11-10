import Foundation
import Testing
@testable import MenuScores

struct NBAHistoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    @Test func requestCoversUSScheduleDatesForLocalDay() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        #expect(NBAHistoryStore.dayKey(day, calendar: calendar) == "20261029")
        let urls = NBAHistoryStore.urls(for: day, calendar: calendar)
        let url = urls[0]
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first(where: { $0.name == "dates" })?.value == "20261028")
        #expect(query.first(where: { $0.name == "limit" })?.value == "1000")
        #expect(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dates" })?.value == "20261029")
    }
    @Test func localMidnightBoundariesAndEmptyDates() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        func event(_ id: String, _ date: String) -> [String: Any] {
            ["id": id, "date": date, "name": "NBA", "competitions": [],
             "status": ["type": ["state": "post", "completed": true]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["leagues": [], "events": [
            event("before", "2026-10-28T15:59Z"), event("last", "2026-10-29T15:59:59Z"),
            event("first", "2026-10-28T16:00Z"), event("after", "2026-10-29T16:00Z")]])
        #expect(try NBAHistoryStore.games(from: data, on: day, calendar: calendar).map(\.id) == ["first", "last"])
        let merged = try NBAHistoryStore.merge([data, data])
        #expect(try NBAHistoryStore.games(from: merged, on: day, calendar: calendar).map(\.id) == ["first", "last"])
        let empty = calendar.date(byAdding: .day, value: -10, to: day)!
        #expect(try NBAHistoryStore.games(from: data, on: empty, calendar: calendar).isEmpty)
    }
}
