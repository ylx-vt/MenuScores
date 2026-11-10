import Foundation
import Testing
@testable import MenuScores

struct NBAMenuPresentationTests {
    @Test func chineseNamesScoresAndOvertime() throws {
        let game = try event(state: "in", period: 5)
        #expect(NBAMenuPresentation.title(for: game) == "湖人 100 : 99 凯尔特人 · 加时1 2:30")
        #expect(NBAFlatMenu.isFavorite(game, teamIDs: ["13"]))
        #expect(!NBAFlatMenu.isFavorite(game, teamIDs: ["26"]))
    }

    @Test func scheduledAndFinishedGamesHaveClearStates() throws {
        let scheduled = NBAMenuPresentation.title(for: try event(state: "pre", period: 0))
        #expect(scheduled.hasPrefix("湖人 对阵 凯尔特人 · "))
        #expect(!scheduled.contains("100"))
        #expect(!scheduled.contains("时间待定"))
        #expect(NBAMenuPresentation.title(for: try event(state: "post", period: 4)) == "湖人 100 : 99 凯尔特人 · 已结束")
    }

    @Test @MainActor func statusBadgeIsCompactAndPreservesColor() throws {
        let image = NBAMenuBarBadge.image(for: try event(state: "in", period: 4))
        #expect(image.size.height == 20)
        #expect(image.size.width < 130)
        #expect(!image.isTemplate)
        #expect(image.accessibilityDescription?.contains("湖人") == true)
    }

    private func event(state: String, period: Int) throws -> Event {
        let status: [String: Any] = ["type": ["state": state, "completed": state == "post"], "period": period, "displayClock": "2:30"]
        let object: [String: Any] = [
            "id": "game", "date": "2026-10-28T02:00Z", "name": "Lakers at Celtics",
            "status": status, "competitions": [["status": status, "competitors": [
                ["id": "2", "score": "99", "team": ["id": "2", "abbreviation": "BOS", "links": []]],
                ["id": "13", "score": "100", "team": ["id": "13", "abbreviation": "LAL", "links": []]]
            ]]]
        ]
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func teamOrderingUsesRolesAndStableFallback() {
    struct Side { let id: String; let role: String? }
    let teams = [Side(id: "13", role: "home"), Side(id: "12", role: "away")]
    #expect(nbaOrderedTeams(teams, side: { $0.role }, id: { $0.id }).map(\.id) == ["12", "13"])
    let first = [Side(id: "13", role: nil), Side(id: "12", role: nil)]
    let second = Array(first.reversed())
    #expect(nbaOrderedTeams(first, side: { $0.role }, id: { $0.id }).map(\.id) == ["12", "13"])
    #expect(nbaOrderedTeams(second, side: { $0.role }, id: { $0.id }).map(\.id) == ["12", "13"])
}
