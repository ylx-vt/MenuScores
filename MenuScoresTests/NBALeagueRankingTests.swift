import Foundation
import Testing
@testable import MenuScores

struct NBALeagueRankingTests {
    @Test func tiesQualificationAndTurnoverDirection() throws {
        let metrics = NBALeagueSnapshot.keys
        let allowed: Set<String> = ["a", "b", "c", "d"]
        var players: [String: NBALeagueSnapshot.Player] = [:]
        for (id, points, turnovers) in [("a", 30.0, 4.0), ("b", 30, 2), ("c", 10, 2), ("d", 0, 0), ("e", 100, 1)] {
            players[id] = .init(values: ["gamesPlayed": 3, "avgPoints": points, "avgTurnovers": turnovers], displays: ["avgPoints": String(points)])
        }
        let board = NBALeagueSnapshot(scope: .init(year: 2027, type: 2), date: Date(), players: players,
                                     qualified: Dictionary(uniqueKeysWithValues: metrics.map { ($0, allowed) }))
        let first = try #require(board.position(id: "a", key: "avgPoints"))
        #expect(first.rank == 1 && first.population == 4)
        #expect(first.text == "优于50.0%") // The tied player is not outperformed.
        #expect(board.position(id: "b", key: "avgPoints")?.rank == 1)
        #expect(board.position(id: "c", key: "avgPoints")?.rank == 3)
        #expect(board.position(id: "d", key: "avgPoints")?.rank == 4)
        #expect(board.position(id: "e", key: "avgPoints") == nil) // Real value remains visible; no ranking when unqualified.
        #expect(board.rankingStatus(id: "e", key: "avgPoints") == "样本不足")
        #expect(board.display(id: "e", key: "avgPoints") == "100.0") // Real data isn't overwritten.
        #expect(board.position(id: "d", key: "avgTurnovers")?.rank == 1) // Zero turnovers is best.
        #expect(board.position(id: "b", key: "avgTurnovers")?.rank == 2)
        #expect(board.position(id: "b", key: "avgTurnovers")?.text == "优于25.0%")
        #expect(board.position(id: "e", key: "avgTurnovers") == nil)
        #expect(board.position(id: "missing", key: "avgPoints") == nil)
        #expect(board.position(id: "a", key: "avgBlocks") == nil)
    }

    @Test func shootingEligibilityAndZeroAttempts() {
        let players: [String: NBALeagueSnapshot.Player] = [
            "a": .init(values: ["gamesPlayed": 4, "fieldGoalPct": 50, "fieldGoalsAttempted": 20], displays: ["fieldGoalPct": "50.0"]),
            "b": .init(values: ["gamesPlayed": 1, "fieldGoalPct": 100, "fieldGoalsAttempted": 1], displays: ["fieldGoalPct": "100.0"]),
            "c": .init(values: ["gamesPlayed": 4, "fieldGoalPct": 0, "fieldGoalsAttempted": 0], displays: ["fieldGoalPct": "0.0"])
        ]
        let board = NBALeagueSnapshot(scope: .init(year: 2027, type: 2), date: Date(), players: players,
                                     qualified: ["fieldGoalPct": ["a"]])
        #expect(board.position(id: "a", key: "fieldGoalPct")?.rank == 1)
        #expect(board.position(id: "a", key: "fieldGoalPct")?.population == 1)
        #expect(board.position(id: "b", key: "fieldGoalPct") == nil)
        #expect(board.position(id: "c", key: "fieldGoalPct") == nil)
        #expect(board.rankingStatus(id: "b", key: "fieldGoalPct") == "样本不足")
        #expect(board.display(id: "c", key: "fieldGoalPct") == "—")
        #expect(board.display(id: "b", key: "fieldGoalPct") == "100.0%")
    }

    @Test func sourceScopeCompletenessAndColumnMapping() throws {
        let json = #"{"pagination":{"count":1,"page":1,"pages":1},"requestedSeason":{"year":2027,"type":{"type":2}},"categories":[{"name":"general","names":["gamesPlayed"]},{"name":"offensive","names":["avgAssists","threePointFieldGoalPct","avgPoints"]}],"athletes":[{"athlete":{"id":"a"},"categories":[{"name":"general","values":[4],"totals":["4"]},{"name":"offensive","values":[8.25,39.62264,36],"totals":["8.3","39.6","36.0"]}]}]}"#
        let response = try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: Data(json.utf8))
        try response.validate(scope: .init(year: 2027, type: 2))
        #expect(response.players()["a"]?.values["avgPoints"] == 36)
        #expect(response.players()["a"]?.values["threePointPct"] == 39.62264)
        #expect(response.players()["a"]?.displays["avgAssists"] == "8.3")
        #expect(throws: (any Error).self) { try response.validate(scope: .init(year: 2026, type: 2)) }
        #expect(throws: (any Error).self) { try response.validate(scope: .init(year: 2027, type: 3)) }
        let partial = try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: Data(json.replacingOccurrences(of: "\"pages\":1", with: "\"pages\":2").utf8))
        #expect(throws: (any Error).self) { try partial.validate(scope: .init(year: 2027, type: 2)) }
        let missing = try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: Data(json.replacingOccurrences(of: "\"count\":1", with: "\"count\":2").utf8))
        #expect(throws: (any Error).self) { try missing.validate(scope: .init(year: 2027, type: 2)) }
        var duplicate = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try #require(duplicate["athletes"] as? [[String: Any]])
        duplicate["athletes"] = rows + rows // Never double-count a transferred athlete's repeated ID.
        duplicate["pagination"] = ["count": 2, "page": 1, "pages": 1]
        let duplicateResponse = try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: JSONSerialization.data(withJSONObject: duplicate))
        #expect(throws: (any Error).self) { try duplicateResponse.validate(scope: .init(year: 2027, type: 2)) }
    }
}
