import Foundation
import Testing
@testable import MenuScores

struct NBASeasonPerformanceTests {
    private let scope = NBALeaguePercentileStore.Scope(year: 2027, type: 2)

    private func values(numerator: Double = 10, games: Double = 3, minutes: Double = 60) -> [String: Double] {
        var values = Dictionary(uniqueKeysWithValues: NBASeasonPerformance.requiredCounts.map { ($0, 0.0) })
        values["points"] = max(numerator, 0)
        values["turnovers"] = max(-numerator, 0)
        values["gamesPlayed"] = games
        values["minutes"] = minutes
        return values
    }
    private func snapshot(_ rows: [String: [String: Double]], scope: NBALeaguePercentileStore.Scope? = nil) -> NBALeagueSnapshot {
        .init(scope: scope ?? self.scope, date: Date(timeIntervalSince1970: 0),
              players: rows.mapValues { .init(values: $0, displays: [:]) }, qualified: [:])
    }
    private struct Fixture: Decodable {
        let names: [String: String]
        let snapshot: NBALeagueSnapshot
    }
    private func fixture(_ year: Int) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NBA-season-\(year)-regular.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func targetHandCalculationAndTwoFullSeasons() throws {
        let current = try fixture(2027).snapshot
        let grades = NBAStatGrades(snapshot: current, priorData: .init(snapshot: try fixture(2026).snapshot))
        let rating = try #require(grades.ratings["4278580"])
        let score = try #require(rating.performance)
        #expect(score.numerator == 67 && score.games == 5 && score.minutes == 121)
        #expect(score.value == 13.4 && score.display == "13.4")
        #expect(rating.position?.rank == 124 && rating.position?.population == 236)
        #expect(rating.position?.tier == .gray && rating.status == "初步估计")
        #expect(rating.rankText.contains("前52.54%"))
        #expect(current.players.count == 425 && grades.ratings.count == 425)
        #expect(grades.ratings.values.filter { $0.performance != nil }.count == 425)
        #expect(grades.overall.count == 236)
        #expect(current.position(id: "4278580", key: "fieldGoalPct")?.population == 133)
        #expect(current.position(id: "4278580", key: "freeThrowPct")?.rank == 108)
        #expect(current.position(id: "4278580", key: "freeThrowPct")?.population == 137)
        #expect(current.position(id: "4278580", key: "freeThrowPct")?.text == "优于19.7%")

        let history = try fixture(2025)
        let historical = NBAStatGrades(snapshot: history.snapshot)
        #expect(history.snapshot.players.count == 569 && historical.overall.count == 456)
        #expect(historical.ratings.values.filter { $0.performance != nil }.count == 569)
        #expect(historical.overall["4278580"]?.rank == 323)
        #expect(historical.overall["3112335"]?.rank == 1)
        #expect(historical.overall["3032977"]?.rank == 2)
        let allNBA = ["Giannis Antetokounmpo", "Shai Gilgeous-Alexander", "Nikola Jokic", "Donovan Mitchell", "Jayson Tatum",
                      "Jalen Brunson", "Stephen Curry", "Anthony Edwards", "LeBron James", "Evan Mobley",
                      "Cade Cunningham", "Tyrese Haliburton", "James Harden", "Karl-Anthony Towns", "Jalen Williams"]
        let allNBAIDs = history.names.filter { allNBA.contains($0.value) }.keys
        #expect(allNBAIDs.count == 15)
        #expect(allNBAIDs.allSatisfy { historical.overall[$0] != nil })
        // These are reference observations, not targets used to tune weights.
        for (id, position) in historical.overall where position.rank <= 20 {
            let player = try #require(history.snapshot.players[id])
            #expect(player.values["minutes"]! / player.values["gamesPlayed"]! >= 20)
        }
    }

    @Test func minimumSampleIsIndependentOfESPNAndMissingMinutes() throws {
        let board = snapshot(["two": values(games: 2, minutes: 100), "short": values(minutes: 59),
                              "exact": values(games: 10, minutes: 200), "ten": values(games: 10, minutes: 200)])
        let grades = NBAStatGrades(snapshot: board)
        #expect(grades.overall.count == 2) // No ESPN eligibility keys required for EFF.
        #expect(grades.ratings["two"]?.performance != nil && grades.overall["two"] == nil)
        #expect(grades.ratings["short"]?.status == "待观察")
        #expect(grades.ratings["exact"]?.status == "初步估计")
        #expect(grades.ratings["ten"]?.status == "初步估计")
        #expect(grades.ratings["ten"]?.performance?.isPreliminary == false)
        var missingMinutes = values(); missingMinutes["minutes"] = nil
        let raw = try #require(NBASeasonPerformance(values: missingMinutes))
        #expect(raw.value > 0 && !raw.meetsMinimumSample)
        #expect(NBAStatGrades(snapshot: snapshot(["x": missingMinutes])).ratings["x"]?.status == "数据不足")
    }

    @Test func exactRationalTiesAndCloseValuesIgnoreDisplayRounding() throws {
        let a = try #require(NBASeasonPerformance(values: values(numerator: 1, games: 3)))
        let b = try #require(NBASeasonPerformance(values: values(numerator: 10, games: 30)))
        let c = try #require(NBASeasonPerformance(values: values(numerator: 1_000_001, games: 3_000_000)))
        #expect(!a.isBetter(than: b) && !b.isBetter(than: a))
        #expect(c.isBetter(than: a) && c.display == a.display)
        let board = snapshot(["a": values(numerator: 1, games: 3, minutes: 200), "b": values(numerator: 10, games: 30, minutes: 200),
                              "c": values(numerator: 1_000_001, games: 3_000_000, minutes: 200)])
        let grades = NBAStatGrades(snapshot: board, priorData: .init(snapshot: snapshot(["a": values(numerator: 10, games: 30), "b": values(numerator: 10, games: 30), "c": values(numerator: 10, games: 30)], scope: scope.previous!)))
        #expect(grades.overall["c"]?.rank == 1)
        #expect(grades.overall["a"]?.rank == 2 && grades.overall["b"]?.rank == 2)
        #expect(grades.overall["a"]?.worseCount == 0)
        let large = try #require(NBASeasonPerformance(values: values(numerator: pow(2, 60), games: pow(2, 59))))
        let small = try #require(NBASeasonPerformance(values: values(numerator: 1, games: 3)))
        #expect(large.isBetter(than: small)) // Cross product exceeds Int64.
    }

    @Test func marginalEventsScalingNegativeScoresAndInvalidFields() throws {
        var original = values(numerator: 20, games: 5, minutes: 100)
        original["fieldGoalsAttempted"] = 10; original["fieldGoalsMade"] = 5
        original["freeThrowsAttempted"] = 4; original["freeThrowsMade"] = 2
        let baseline = try #require(NBASeasonPerformance(values: original))
        for key in ["turnovers", "fieldGoalsAttempted", "freeThrowsAttempted"] {
            var changed = original; changed[key, default: 0] += 1
            #expect(NBASeasonPerformance(values: changed)?.numerator == baseline.numerator - 1)
        }
        let scaled = original.mapValues { $0 * 2 }
        let twice = try #require(NBASeasonPerformance(values: scaled))
        #expect(!baseline.isBetter(than: twice) && !twice.isBetter(than: baseline))
        #expect(NBASeasonPerformance(values: values(numerator: -1))?.value == -1.0 / 3)
        #expect(NBASeasonPerformance(values: values(numerator: 0))?.value == 0)
        for key in NBASeasonPerformance.requiredCounts {
            var missing = original; missing[key] = nil
            #expect(NBASeasonPerformance(values: missing) == nil)
            var invalid = original; invalid[key] = .infinity
            #expect(NBASeasonPerformance(values: invalid) == nil)
        }
        #expect(NBASeasonPerformance(values: values(games: 0)) == nil)
        #expect(NBASeasonPerformance(values: values(games: 3.5)) == nil)
        var invalid = original; invalid["fieldGoalsMade"] = 11
        #expect(NBASeasonPerformance(values: invalid) == nil)
        invalid = original; invalid["freeThrowsMade"] = 5
        #expect(NBASeasonPerformance(values: invalid) == nil)
        invalid = values(); invalid["points"] = pow(2, 62); invalid["rebounds"] = pow(2, 62)
        #expect(NBASeasonPerformance(values: invalid) == nil)
    }

    @Test func emptyPoolSmallPoolAndStrictTierBoundaries() throws {
        let empty = NBAStatGrades(snapshot: snapshot(["x": values(games: 1)]))
        #expect(empty.overall.isEmpty)
        #expect(empty.ratings["x"]?.helpText.contains("没有满足条件的可比球员") == true)
        var rows: [String: [String: Double]] = [:]
        for i in 1...100 { rows[String(i)] = values(numerator: Double(i), games: 10, minutes: 200) }
        let hundred = NBAStatGrades(snapshot: snapshot(rows))
        #expect(hundred.overall["100"]?.tier == .red)
        #expect(hundred.overall["96"]?.tier == .gold)
        #expect(hundred.overall["91"]?.tier == .purple)
        rows["1"] = nil
        let ninetyNine = NBAStatGrades(snapshot: snapshot(rows))
        #expect(ninetyNine.overall["100"]?.rank == 1 && ninetyNine.overall["100"]?.tier == .gold)
    }

    @Test func legacyRawCacheRecomputesAndSeasonScopesStaySeparate() throws {
        let old = try fixture(2027).snapshot
        let raw = try JSONEncoder().encode(old)
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["algorithmVersion"] = "legacy-nine-percentiles"
        object["overall"] = ["4278580": ["rank": 32, "population": 425]]
        let decoded = try JSONDecoder().decode(NBALeagueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let fresh = NBAStatGrades(snapshot: decoded, priorData: .init(snapshot: try fixture(2026).snapshot))
        #expect(decoded.date == old.date && decoded.players.count == old.players.count)
        #expect(decoded.rankingAlgorithmVersion == "eff-estimate-v3-k20-effective10g200m")
        #expect(fresh.overall["4278580"]?.rank == 124)
        let playoffScope = NBALeaguePercentileStore.Scope(year: 2027, type: 3)
        let playoffs = NBAStatGrades(snapshot: snapshot(["4278580": values(numerator: 0)], scope: playoffScope))
        #expect(playoffs.ratings["4278580"]?.scope == playoffScope)
        #expect(fresh.ratings["4278580"]?.scope != playoffs.ratings["4278580"]?.scope)
    }

    @Test func legitimateZeroShootingAndCountingValuesParticipate() throws {
        let players: [String: NBALeagueSnapshot.Player] = [
            "zero": .init(values: ["gamesPlayed": 3, "fieldGoalPct": 0, "fieldGoalsAttempted": 5, "avgPoints": 0, "avgTurnovers": 0], displays: ["fieldGoalPct": "0.0"]),
            "made": .init(values: ["gamesPlayed": 3, "fieldGoalPct": 50, "fieldGoalsAttempted": 10, "avgPoints": 4, "avgTurnovers": 1], displays: [:]),
            "none": .init(values: ["gamesPlayed": 3, "fieldGoalPct": 0, "fieldGoalsAttempted": 0], displays: [:]),
            "out": .init(values: ["gamesPlayed": 1, "fieldGoalPct": 100, "fieldGoalsAttempted": 1], displays: ["fieldGoalPct": "100.0"])
        ]
        let board = NBALeagueSnapshot(scope: scope, date: Date(), players: players,
                                      qualified: ["fieldGoalPct": ["zero", "made", "none"], "avgPoints": ["zero", "made"], "avgTurnovers": ["zero", "made"]])
        #expect(board.position(id: "zero", key: "fieldGoalPct")?.rank == 2)
        #expect(board.position(id: "zero", key: "fieldGoalPct")?.population == 2)
        #expect(board.display(id: "zero", key: "fieldGoalPct") == "0.0%")
        #expect(board.position(id: "zero", key: "avgPoints")?.rank == 2)
        #expect(board.position(id: "zero", key: "avgTurnovers")?.rank == 1)
        #expect(board.position(id: "out", key: "fieldGoalPct") == nil)
        #expect(board.rankingStatus(id: "out", key: "fieldGoalPct") == "样本不足")
        #expect(board.position(id: "none", key: "fieldGoalPct") == nil)
        #expect(board.rankingStatus(id: "none", key: "fieldGoalPct") == "样本不足")
    }
}
