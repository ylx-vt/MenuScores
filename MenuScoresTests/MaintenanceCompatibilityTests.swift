import AppKit
import Foundation
import Testing
@testable import MenuScores

struct MaintenanceCompatibilityTests {
    @Test func unitTestHostDoesNotStartProductionWork() {
        #expect(AppRuntime.isUnitTestHost)
    }

    @Test func savedRefreshIntervalsRetainTheirMeaning() {
        let values: [String: UInt64] = ["10 seconds": 10, "15 seconds": 15,
            "20 seconds": 20, "30 seconds": 30, "40 seconds": 40,
            "50 seconds": 50, "1 minute": 60, "2 minutes": 120, "5 minutes": 300]
        for (saved, seconds) in values {
            #expect(ScoreRefreshInterval.seconds(for: saved) == seconds)
        }
        #expect(ScoreRefreshInterval.seconds(for: "") == 15)
        #expect(ScoreRefreshInterval.seconds(for: "obsolete") == 15)
    }

    @Test @MainActor func sharedLogoResolverKeepsIdentitiesAndAliases() throws {
        let canonical = try #require(NBATeamLogo.bundledImage(url: nil, abbreviation: "lal"))
        let byID = try #require(NBATeamLogo.bundledImage(url: nil, teamID: "13"))
        #expect(canonical.tiffRepresentation == byID.tiffRepresentation)
        let warriors = try #require(NBATeamLogo.bundledImage(url: nil, abbreviation: "gs"))
        let alias = try #require(NBATeamLogo.bundledImage(url: nil, abbreviation: "GSW"))
        let byURL = try #require(NBATeamLogo.bundledImage(url: "https://a.espncdn.com/i/teamlogos/nba/500/gs.png"))
        #expect(alias.tiffRepresentation == warriors.tiffRepresentation)
        #expect(byURL.tiffRepresentation == warriors.tiffRepresentation)
        #expect(NBATeamLogo.bundledImage(url: nil, abbreviation: "../outside") == nil)
        #expect(NBATeamLogo.bundledImage(url: nil) == nil)
    }

    @Test @MainActor func logoNormalizationRemovesTransparentPadding() throws {
        let source = try #require(NBATeamLogo.bundledImage(url: nil, teamID: "13"))
        let cropped = try #require(NBATeamLogo.normalizedImage(url: nil, teamID: "13"))
        #expect(cropped.size.width > 0 && cropped.size.height > 0)
        #expect(cropped.size.width < source.size.width)
        #expect(cropped.size.height < source.size.height)
    }

    @Test func legacyFavoritesPreserveLeagueIdentityAndOrdering() throws {
        let data = Data(#"[{"id":"13","leagueKey":"NBA","displayName":"Los Angeles Lakers","abbreviation":"LAL","logo":null},{"id":"league-f1","leagueKey":"F1","displayName":"F1","abbreviation":"F1","logo":null},{"id":"13","leagueKey":"NHL","displayName":"Legacy team","abbreviation":"LEGACY","logo":"https://example.com/legacy.png"}]"#.utf8)
        let favorites = try JSONDecoder().decode([FavoriteTeam].self, from: data)
        #expect(favorites.map(\.uniqueID) == ["NBA-13", "F1-league-f1", "NHL-13"])
        #expect(Set(favorites).count == 3)
        let roundtrip = try JSONDecoder().decode([FavoriteTeam].self, from: JSONEncoder().encode(favorites))
        #expect(roundtrip.map(\.leagueKey) == ["NBA", "F1", "NHL"])
        #expect(roundtrip.last?.logo == "https://example.com/legacy.png")
        #expect(FavoriteTeams.isLeagueOnly("F1"))
        #expect(FavoriteTeams.displayName(for: "NHL") == "NHL")
    }
}
