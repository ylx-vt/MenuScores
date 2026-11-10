import Foundation
import Testing
@testable import MenuScores

struct NBAScheduleAndPinTests {
    private func date(_ value: String) -> Date { NBASchedulePolicy.startDate(value)! }

    @Test func noonIsInclusiveAndDayIntervalsAreHalfOpen() {
        let before = NBASchedulePolicy.window(now: date("2026-10-30T03:59:59Z"))
        #expect(before.tomorrow == nil)
        #expect(before.nextTransition == date("2026-10-30T04:00:00Z"))
        let noon = NBASchedulePolicy.window(now: date("2026-10-30T04:00:00Z"))
        #expect(noon.tomorrow?.start == date("2026-10-30T16:00:00Z"))
        #expect(noon.nextTransition == noon.today.end)
        #expect(NBASchedulePolicy.contains(noon.today.start, in: noon.today))
        #expect(!NBASchedulePolicy.contains(noon.today.end, in: noon.today))
    }

    @Test func fixedBeijingCalendarCrossesYearAndIgnoresForeignDST() {
        let yearEnd = NBASchedulePolicy.window(now: date("2026-12-31T12:00:00+08:00"))
        #expect(yearEnd.tomorrow?.start == date("2027-01-01T00:00:00+08:00"))
        for value in ["2026-03-08T04:00:00Z", "2026-11-01T04:00:00Z"] {
            let window = NBASchedulePolicy.window(now: date(value))
            #expect(window.today.duration == 86400)
            #expect(window.tomorrow?.duration == 86400)
        }
        #expect(NBASchedulePolicy.calendar.timeZone.identifier == "Asia/Shanghai")
        let utc = NBASchedulePolicy.window(now: date("2026-10-30T04:00:00Z"))
        let la = NBASchedulePolicy.window(now: date("2026-10-29T21:00:00-07:00"))
        #expect(utc == la)
        #expect(NBASchedulePolicy.startTime(date("2026-10-30T04:00:00Z")) == "12:00")
    }

    @Test func groupingKeepsLateLiveGamesAndMovesReservationByIDAtMidnight() throws {
        let late = try event("late", "2026-10-28T16:00:00Z", state: "in")
        let today = try event("today", "2026-10-30T03:00Z")
        let tomorrow = try event("reserved", "2026-10-30T16:00Z")
        let after = try event("after", "2026-10-31T16:00Z")
        let input = [late, today, tomorrow, after, tomorrow]
        let before = NBASchedulePolicy.groups(input, now: date("2026-10-30T03:59:59Z"))
        #expect(before.today.map(\.id) == ["late", "today"])
        #expect(before.tomorrow.isEmpty)
        let noon = NBASchedulePolicy.groups(input, now: date("2026-10-30T04:00Z"))
        #expect(noon.today.map(\.id) == ["late", "today"])
        #expect(noon.tomorrow.map(\.id) == ["reserved"])
        let midnight = NBASchedulePolicy.groups(input, now: date("2026-10-30T16:00Z"))
        #expect(midnight.today.map(\.id) == ["late", "reserved"])
        #expect(midnight.tomorrow.isEmpty)
    }

    @Test @MainActor func manualReservationSurvivesRestartMissingResultsAndAutomaticPin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pin.json")
        let store = NBAPinnedSelectionStore(file: file)
        let automatic = try event("auto", "2026-10-30T02:00Z", state: "in")
        #expect(store.pinAutomatically(automatic))
        let reserved = try event("reserved", "2026-10-31T02:00Z")
        store.pinManually(reserved)
        store.update(from: [])
        store.clearAutomaticSelection()
        #expect(!store.pinAutomatically(automatic))
        let restored = NBAPinnedSelectionStore(file: file)
        #expect(restored.selection?.eventID == "reserved")
        #expect(restored.selection?.source == .manual)
        #expect(restored.selection?.game.competitions.first?.competitors?.first?.team?.abbreviation == "BOS")
        #expect(restored.persistenceError == nil)
        let moved = try event("reserved", "2026-11-01T03:00Z", detail: "Postponed")
        restored.update(moved)
        #expect(restored.selection?.date == moved.date)
        #expect(restored.selection?.detail == "Postponed")
        #expect(restored.selection?.source == .manual)
        restored.update(automatic)
        #expect(restored.selection?.eventID == "reserved")
        restored.unpin()
        #expect(NBAPinnedSelectionStore(file: file).selection == nil)
        #expect(restored.pinAutomatically(automatic))
        restored.clearAutomaticSelection()
        #expect(restored.selection == nil)
    }

    private func event(_ id: String, _ start: String, state: String = "pre", detail: String = "Scheduled") throws -> Event {
        let status: [String: Any] = ["type": ["state": state, "completed": false, "detail": detail]]
        let object: [String: Any] = ["id": id, "date": start, "name": "Lakers at Celtics", "status": status,
            "competitions": [["status": status, "competitors": [
                ["id": "2", "homeAway": "home", "team": ["id": "2", "abbreviation": "BOS", "links": []]],
                ["id": "13", "homeAway": "away", "team": ["id": "13", "abbreviation": "LAL", "links": []]]]]]]
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
