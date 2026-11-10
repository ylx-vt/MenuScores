import Foundation
import Testing
@testable import MenuScores

struct NBALocalizationTests {
    @Test func statusTranslationIncludesOvertimeAndInterruptions() {
        #expect(NBALocalization.status(state: "post", detail: "Final/OT", period: nil, clock: nil) == "已结束 · 加时赛")
        #expect(NBALocalization.status(state: "in", detail: "Halftime", period: 2, clock: nil) == "中场休息")
        #expect(NBALocalization.status(state: "pre", detail: "Postponed", period: nil, clock: nil) == "比赛延期")
        #expect(NBALocalization.status(state: "in", detail: nil, period: 5, clock: "2:30") == "进行中 · 加时1 2:30")
    }

    @Test func packagedRosterCoversCurrentESPNPlayersAndAccentedNames() throws {
        let bundle = Bundle(for: LocalizationResourceAnchor.self)
        let url = try #require(bundle.url(forResource: "NBA-roster-en-2026-10-29", withExtension: "json"))
        let roster = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        #expect(roster.count == 519)
        let missing = roster.filter { NBALocalization.player($0) == $0 }
        #expect(missing.isEmpty, "Untranslated players: \(missing)")
        #expect(NBALocalization.player("Luka Dončić") == NBALocalization.player("Luka Doncic"))
        #expect(NBALocalization.player("Gary Payton II").contains("佩顿"))
        #expect(NBALocalization.player("Kawhi Leonard") == "科怀·伦纳德")
    }

    @Test func playerMetadataKeepsNumberZeroAndOriginalName() throws {
        let data = Data(#"{"boxscore":{"players":[{"team":{"id":"13","displayName":"Los Angeles Lakers","abbreviation":"LAL","color":"552583"},"statistics":[{"names":["MIN","PTS"],"athletes":[{"athlete":{"id":"one","displayName":"Luka Doncic","jersey":"0","position":{"abbreviation":"PG"}},"stats":["30","20"],"starter":true}]}]}]}}"#.utf8)
        let result = try JSONDecoder().decode(NBABoxScore.self, from: data)
        let team = try #require(result.teams.first)
        let row = try #require(team.rows.first)
        #expect(team.team.chineseName == "湖人")
        #expect(row.jersey == "0")
        #expect(row.name == "卢卡·东契奇")
        #expect(row.originalName == "Luka Doncic")
        #expect(row.position == "控卫")
        #expect(row.starter)
        #expect(row.minutes == "30")
        #expect(NBALocalization.player("New Player") == "New Player")
        #expect(NBALocalization.absence("COACH'S DECISION") == "未出场 · 教练决定")
    }
}

private final class LocalizationResourceAnchor: NSObject {}
