import Foundation
import Testing
@testable import MenuScores

struct NBABoxScoreTests {
    @Test func reorderedColumnsAndSignedPlusMinus() throws {
        let result = try decode(names: ["AST", "+/-", "FG", "PTS", "REB"],
                                stats: ["8", "12", "7-16", "20", "9"])
        let row = try #require(result.teams.first?.rows.first)
        #expect(row.points == "20")
        #expect(row.rebounds == "9")
        #expect(row.assists == "8")
        #expect(row.fieldGoals == "7-16")
        #expect(row.fieldGoalPercentage == "43.8%")
        #expect(row.plusMinus == "+12")
    }

    @Test func zeroAttemptsAndMissingColumnsStayUnknown() throws {
        let result = try decode(names: ["FG", "PTS", "REB"], stats: ["0-0", "0"])
        let row = try #require(result.teams.first?.rows.first)
        #expect(row.fieldGoalPercentage == "—")
        #expect(row.points == "0")
        #expect(row.rebounds == "—")
        #expect(row.assists == "—")
        #expect(row.plusMinus == "—")
    }

    @Test func didNotPlayDoesNotShowZeroStats() throws {
        let result = try decode(names: ["PTS", "FG", "+/-"], stats: ["0", "0-0", "0"], didNotPlay: true)
        let row = try #require(result.teams.first?.rows.first)
        #expect(row.didNotPlay)
        #expect(row.points == "—")
        #expect(row.plusMinus == "—")
    }

    @Test func pregameWithoutBoxscoreDecodes() throws {
        let result = try JSONDecoder().decode(NBABoxScore.self, from: Data("{}".utf8))
        #expect(result.teams.isEmpty)
        #expect(result.scoreTitle == "NBA 球员技术统计")
    }

    @Test func malformedShootingAndNegativePlusMinus() {
        #expect(NBABoxScore.Statistics.percentage("5-2") == "—")
        #expect(NBABoxScore.Statistics.percentage("bad") == "—")
        #expect(NBABoxScore.Statistics.signed("-7") == "-7")
        #expect(NBABoxScore.Statistics.signed("0") == "0")
        #expect(NBABoxScore.Statistics.signed(nil) == "—")
    }
    @Test func overviewKeepsQuarterAndAllNamedTeamStatisticsWithoutFillingGaps() throws {
        let object: [String:Any] = ["header":["competitions":[["competitors":[
            ["team":["id":"1","displayName":"Atlanta Hawks"],"linescores":[["displayValue":"25"],["value":23]]],
            ["team":["id":"2","displayName":"Boston Celtics"],"linescores":[["displayValue":"27"]]]
        ]]]],"boxscore":["teams":[
            ["team":["id":"1","displayName":"Atlanta Hawks"],"statistics":[["name":"fieldGoalsMade-fieldGoalsAttempted","displayValue":"40-90"],["name":"totalTurnovers","displayValue":"16"]]],
            ["team":["id":"2","displayName":"Boston Celtics"],"statistics":[["name":"assists","displayValue":"24"]]]
        ]]]
        let result = try JSONDecoder().decode(NBABoxScore.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(result.match?.competitors?.first?.linescores?.map(\.text) == ["25","23"])
        #expect(result.match?.competitors?.last?.linescores?.count == 1)
        #expect(result.statisticNames == ["fieldGoalsMade-fieldGoalsAttempted","totalTurnovers","assists"])
        #expect(result.statistic("fieldGoalsMade-fieldGoalsAttempted",teamID:"1") == "40-90")
        #expect(result.statistic("totalTurnovers",teamID:"2") == "—")
        #expect(result.statisticLabel("fieldGoalsMade-fieldGoalsAttempted") == "投篮")
        #expect(NBABoxScore.LineScore(displayValue:"bad",value:nil).text == "—")
    }

    private func decode(names: [String], stats: [String], didNotPlay: Bool = false) throws -> NBABoxScore {
        let object: [String: Any] = ["boxscore": ["players": [[
            "team": ["id": "13", "displayName": "Los Angeles Lakers"],
            "statistics": [["names": names, "athletes": [[
                "athlete": ["id": "test", "displayName": "Test Player"],
                "stats": stats, "didNotPlay": didNotPlay
            ]]]]
        ]]]]
        return try JSONDecoder().decode(NBABoxScore.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
