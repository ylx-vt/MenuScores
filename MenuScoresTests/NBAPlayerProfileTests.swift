import Foundation
import Testing
@testable import MenuScores

struct NBAPlayerProfileTests {
    @Test func namedColumnsMissingValuesAndPercentages() throws {
        let stats = try JSONDecoder().decode(NBAPlayerProfile.Statistics.self, from: Data(#"{"names":["avgAssists","fieldGoalPct","avgPoints","avgRebounds"],"splits":[{"displayName":"Regular Season","stats":["6.8","42.6","15.5"]},{"displayName":"Career","stats":["7.4","50.7%","26.8","7.5"]}]}"#.utf8))
        #expect(stats.value("avgPoints", split: "Regular Season") == "15.5")
        #expect(stats.value("fieldGoalPct", split: "Regular Season") == "42.6%")
        #expect(stats.value("fieldGoalPct", split: "Career") == "50.7%")
        #expect(stats.value("avgRebounds", split: "Regular Season") == "—")
        #expect(stats.value("avgPoints", split: "Postseason") == "—")
    }
    @Test func localizedScopeAndMeasurements() throws {
        let profile = try JSONDecoder().decode(NBAPlayerProfile.self, from: Data(#"{"athlete":{"id":"1966","displayName":"LeBron James","age":41,"displayHeight":"6' 9\"","displayWeight":"250 lbs","statsSummary":{"displayName":"2026-27 regular season stats"}},"statistics":{"names":[],"splits":[{"displayName":"Regular Season","stats":[]}]}}"#.utf8))
        #expect(profile.seasonSplitTitle == "2026-27 常规赛")
        #expect(profile.rankScope == .init(year: 2027, type: 2))
        #expect(profile.measurements == "41岁 · 206厘米 · 113.4公斤")
    }
    @Test func rankingsRequireMatchingScopeAndValues() throws {
        let json = #"{"athlete":{"id":"1","displayName":"Player","statsSummary":{"displayName":"2026-27 regular season stats","statistics":[{"name":"avgPoints","displayValue":"36.0","rank":1},{"name":"avgAssists","displayValue":"8.3","rank":0},{"name":"avgRebounds","displayValue":"7.0","rank":52}]}},"statistics":{"names":["avgPoints","avgAssists","avgRebounds"],"splits":[{"displayName":"Regular Season","stats":["36.0","8.3","6.8"]}]}}"#
        let profile = try JSONDecoder().decode(NBAPlayerProfile.self, from: Data(json.utf8))
        #expect(profile.leagueRank("avgPoints", career: false) == 1)
        #expect(profile.leagueRank("avgPoints", career: true) == nil)
        #expect(profile.leagueRank("avgAssists", career: false) == nil)
        #expect(profile.leagueRank("avgRebounds", career: false) == nil)
        #expect(profile.leagueRank("avgBlocks", career: false) == nil)
        let postseason = json.replacingOccurrences(of: "regular season stats", with: "postseason stats")
        let other = try JSONDecoder().decode(NBAPlayerProfile.self, from: Data(postseason.utf8))
        #expect(other.leagueRank("avgPoints", career: false) == nil)

    }

    @Test func percentileUsesMetricPopulationAndRejectsInvalidRanks() {
        let scoring = NBALeaguePosition(rank: 1, population: 332)
        #expect(scoring?.text == "优于99.7%")
        #expect(scoring?.tier == .red)
        #expect(NBALeaguePosition(rank: 64, population: 133)?.text == "优于51.9%")
        #expect(NBALeaguePosition(rank: 64, population: 133)?.tier == .green)
        #expect(NBALeaguePosition(rank: 0, population: 133) == nil)
        #expect(NBALeaguePosition(rank: 134, population: 133) == nil)
        #expect(NBALeaguePosition(rank: 1, population: 0) == nil)
        for (percent, tier) in [(1.0, NBAPlayerProfile.RankTier.red), (1.01, .gold),
                                (5.0, .gold), (5.01, .purple), (10.0, .purple),
                                (10.01, .blue), (25.0, .blue), (25.01, .green),
                                (50.0, .green), (50.01, .gray), (100.0, .gray)] {
            #expect(NBAPlayerProfile.RankTier(topPercent: percent) == tier)
        }
    }
}
