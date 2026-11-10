import Foundation
import Testing
@testable import MenuScores

struct NBAStatGradesTests {
    @Test func currentGameValuesAreGradedIndependentlyOfPlayerLevel() throws {
        var players: [String: NBALeagueSnapshot.Player] = [:]
        for (id, value) in [("a", 10.0), ("b", 5), ("c", 1), ("d", 100)] {
            var values = Dictionary(uniqueKeysWithValues: NBALeagueSnapshot.keys.map { ($0, value) })
            values["avgTurnovers"] = id == "a" ? 1 : id == "b" ? 2 : 3
            values["gamesPlayed"] = 10; values["avgMinutes"] = value
            for key in NBASeasonPerformance.requiredCounts where key != "gamesPlayed" { values[key] = 0 }
            values["points"] = value
            values["minutes"] = id == "d" ? 5 : 200
            for key in NBALeagueSnapshot.attempts.values { values[key] = 20 }
            players[id] = .init(values: values, displays: [:])
        }
        let board = NBALeagueSnapshot(scope: .init(year: 2027, type: 2), date: Date(), players: players,
                                     qualified: Dictionary(uniqueKeysWithValues: NBALeagueSnapshot.keys.map { ($0, Set(["a", "b", "c"])) }))
        let grades = NBAStatGrades(snapshot: board)
        #expect(grades.overall["a"]?.rank == 1)
        #expect(grades.overall["c"]?.rank == 3)
        #expect(grades.overall["d"] == nil)
        #expect(grades.performancePosition(value: 20, key: "avgPoints")?.text == "优于100.0%")
        #expect(grades.performancePosition(value: 0, key: "avgPoints")?.rank == 4)
        #expect(grades.performancePosition(value: 0, key: "avgTurnovers")?.rank == 1)
        #expect(grades.performancePosition(value: 20, key: "avgPoints")?.rank != grades.overall["c"]?.rank)
    }

    @Test func fixedRanksKeepOriginalEmphasisAndAvatarTier() throws {
        let distribution = NBAStatDistribution(values: (1...100).map(Double.init))
        let top = try #require(distribution.position(for: 100))
        let middle = try #require(distribution.position(for: 60))
        #expect(top.tier == .red)
        #expect(NBAStatGrades.isEmphasized(top.tier))
        #expect(middle.tier == .green)
        #expect(!NBAStatGrades.isEmphasized(middle.tier))
        #expect(!NBAStatGrades.isEmphasized(nil))
        // The avatar consumes the same overall tier returned by the season performance ranking.
        #expect(NBAPlayerProfile.RankTier(topPercent: top.topPercent) == top.tier)
    }

    @Test func externalGameValuesHandleExtremesAndTies() {
        let reference = NBAStatDistribution(values: [10, 20, 30])
        #expect(reference.position(for: 40)?.rank == 1)
        #expect(reference.position(for: 40)?.text == "优于100.0%")
        #expect(reference.position(for: 5)?.rank == 3)
        #expect(reference.position(for: 5)?.text == "优于0.0%")
        #expect(reference.position(for: 20)?.text == "优于33.3%")
        #expect(reference.position(for: .nan) == nil)
        #expect(NBAStatDistribution(values: []).position(for: 10) == nil)
    }

    @Test func matchSeasonAndDisplayValuesParseWithoutGuessing() throws {
        #expect(NBAStatGrades.number("12:30") == 12.5)
        #expect(NBAStatGrades.number("48.4%") == 48.4)
        #expect(NBAStatGrades.number("+12") == 12)
        #expect(NBAStatGrades.number("—") == nil)
        let match = try JSONDecoder().decode(NBABoxScore.self, from: Data(#"{"header":{"season":{"year":2027,"type":2}}}"#.utf8))
        #expect(match.rankScope == .init(year: 2027, type: 2))
        let unknown = try JSONDecoder().decode(NBABoxScore.self, from: Data(#"{"header":{}}"#.utf8))
        #expect(unknown.rankScope == nil)
    }
}
