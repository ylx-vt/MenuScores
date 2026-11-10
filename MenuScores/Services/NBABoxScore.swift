import Foundation

/// ESPN summary uses named columns; their order can change between responses.
struct NBABoxScore: Decodable {
    let boxscore: BoxScore?
    let header: Header?
    let pregame: NBAPregamePreview?

    private enum CodingKeys: String, CodingKey { case boxscore, header }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boxscore = try container.decodeIfPresent(BoxScore.self, forKey: .boxscore)
        header = try container.decodeIfPresent(Header.self, forKey: .header)
        pregame = try? NBAPregamePreview(from: decoder)
    }

    var hasPregamePresentation: Bool {
        if match?.status?.type?.state == "pre" { return true }
        let name = match?.status?.type?.name?.lowercased() ?? ""
        return match?.status?.type?.state != "in" && (name.contains("cancel") || name.contains("postpon"))
    }

    struct BoxScore: Decodable {
        let players: [TeamPlayers]?
        let teams: [TeamTotals]?
    }

    struct Header: Decodable {
        let id: String?
        let competitions: [Match]?
        let season: Season?
    }

    struct Season: Decodable { let year: Int; let type: Int }

    struct Match: Decodable {
        let date: String?
        let competitors: [Competitor]?
        let status: MatchStatus?
    }

    struct Competitor: Decodable {
        let homeAway: String?
        let team: Team
        let score: String?
        let linescores: [LineScore]?
    }

    struct LineScore: Decodable {
        let displayValue: String?
        let value: Double?
        var text: String {
            if let displayValue, let number = Int(displayValue), number >= 0 { return displayValue }
            if let value, value.isFinite, value >= 0, value <= 400, value.rounded() == value { return String(Int(value)) }
            return "—"
        }
    }
    struct TeamTotals: Decodable {
        let team: Team
        let statistics: [Statistic]?
    }
    struct Statistic: Decodable {
        let name: String
        let label: String?
        let displayValue: String?
    }
    var statisticNames: [String] {
        var result: [String] = []
        for team in boxscore?.teams ?? [] {
            for statistic in team.statistics ?? [] where !result.contains(statistic.name) { result.append(statistic.name) }
        }
        return result
    }
    func statistic(_ name: String, teamID: String) -> String {
        let value = boxscore?.teams?.first(where: { $0.team.id == teamID })?.statistics?.first(where: { $0.name == name })?.displayValue ?? "—"
        if (name.hasSuffix("Pct") || name == "leadPercentage"), Double(value) != nil { return value + "%" }
        return value
    }
    func statisticLabel(_ name: String) -> String {
        let labels = ["fieldGoalsMade-fieldGoalsAttempted":"投篮", "fieldGoalPct":"命中率", "threePointFieldGoalsMade-threePointFieldGoalsAttempted":"三分", "threePointFieldGoalPct":"三分率", "freeThrowsMade-freeThrowsAttempted":"罚球", "freeThrowPct":"罚球率", "totalRebounds":"篮板", "offensiveRebounds":"前场板", "defensiveRebounds":"后场板", "assists":"助攻", "steals":"抢断", "blocks":"盖帽", "turnovers":"球员失误", "teamTurnovers":"球队失误", "totalTurnovers":"总失误", "turnoverPoints":"失误失分", "fastBreakPoints":"快攻", "pointsInPaint":"内线", "fouls":"犯规", "technicalFouls":"技术犯规", "flagrantFouls":"恶意犯规", "largestLead":"最大领先", "leadChanges":"交替领先", "timesTied":"平分次数", "totalTechnicalFouls":"总技术犯规", "ejections":"驱逐"]
        if name == "leadPercentage" { return "领先时长" }
        return labels[name] ?? boxscore?.teams?.flatMap { $0.statistics ?? [] }.first(where: { $0.name == name })?.label ?? name
    }

    struct MatchStatus: Decodable {
        let type: StatusType?
        let period: Int?
        let displayClock: String?
        let clock: Double?
    }

    struct StatusType: Decodable {
        let name: String?
        let state: String?
        let completed: Bool?
        let detail: String?
        let shortDetail: String?
    }

    struct Team: Decodable {
        let id: String
        let displayName: String
        let abbreviation: String?
        let color: String?
        let alternateColor: String?
        let logo: String?
        private enum CodingKeys: String, CodingKey { case id, displayName, abbreviation, color, alternateColor, logo, logos }
        private struct Logo: Decodable { let href: String?; let rel: [String]? }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            abbreviation = try container.decodeIfPresent(String.self, forKey: .abbreviation)
            color = try container.decodeIfPresent(String.self, forKey: .color)
            alternateColor = try container.decodeIfPresent(String.self, forKey: .alternateColor)
            let logos = (try? container.decode([Logo].self, forKey: .logos)) ?? []
            logo = (try? container.decodeIfPresent(String.self, forKey: .logo))
                ?? logos.first(where: { $0.rel?.contains("default") == true })?.href ?? logos.first?.href
        }
        var chineseName: String { NBAMenuPresentation.teamName(abbreviation, fallback: displayName) }
    }

    struct TeamPlayers: Decodable, Identifiable {
        let team: Team
        let statistics: [Statistics]?
        var id: String { team.id }
        var rows: [PlayerRow] { statistics?.first?.rows ?? [] }
    }

    struct Statistics: Decodable {
        let names: [String]?
        let labels: [String]?
        let athletes: [Player]?

        var rows: [PlayerRow] {
            let columns = names ?? labels ?? []
            return (athletes ?? []).map { player in
                func value(_ name: String) -> String? {
                    guard let index = columns.firstIndex(of: name),
                          let stats = player.stats, stats.indices.contains(index),
                          !stats[index].isEmpty else { return nil }
                    return stats[index]
                }
                let didNotPlay = player.didNotPlay == true
                let fieldGoals = didNotPlay ? nil : value("FG")
                return PlayerRow(
                    id: player.athlete.id,
                    name: NBALocalization.player(player.athlete.displayName),
                    originalName: player.athlete.displayName,
                    jersey: player.athlete.jersey,
                    position: NBALocalization.position(player.athlete.position?.abbreviation),
                    headshot: player.athlete.headshot?.href,
                    starter: player.starter == true,
                    minutes: didNotPlay ? "—" : value("MIN") ?? "—",
                    absence: NBALocalization.absence(player.reason),
                    didNotPlay: didNotPlay,
                    points: didNotPlay ? "—" : value("PTS") ?? "—",
                    rebounds: didNotPlay ? "—" : value("REB") ?? "—",
                    assists: didNotPlay ? "—" : value("AST") ?? "—",
                    fieldGoals: fieldGoals ?? "—",
                    fieldGoalPercentage: Self.percentage(fieldGoals),
                    plusMinus: didNotPlay ? "—" : Self.signed(value("+/-"))
                )
            }
        }

        static func percentage(_ fieldGoals: String?) -> String {
            let values = fieldGoals?.split(separator: "-").compactMap { Double($0) } ?? []
            guard values.count == 2, values[1] > 0,
                  values[0] >= 0, values[0] <= values[1] else { return "—" }
            return String(format: "%.1f%%", values[0] / values[1] * 100)
        }

        static func signed(_ value: String?) -> String {
            guard let value, let number = Int(value) else { return "—" }
            return number > 0 ? "+\(number)" : "\(number)"
        }
    }

    struct Player: Decodable {
        let athlete: Athlete
        let stats: [String]?
        let didNotPlay: Bool?
        let starter: Bool?
        let reason: String?
    }

    struct Athlete: Decodable {
        let id: String
        let displayName: String
        let jersey: String?
        let position: Position?
        let headshot: Headshot?
    }
    struct Position: Decodable { let abbreviation: String? }
    struct Headshot: Decodable { let href: String? }

    struct PlayerRow: Identifiable {
        let id: String
        let name: String
        let originalName: String
        let jersey: String?
        let position: String
        let headshot: String?
        let starter: Bool
        let minutes: String
        let absence: String
        let didNotPlay: Bool
        let points: String
        let rebounds: String
        let assists: String
        let fieldGoals: String
        let fieldGoalPercentage: String
        let plusMinus: String
    }

    var rankScope: NBALeaguePercentileStore.Scope? {
        guard let season = header?.season, (1946...2200).contains(season.year), (1...3).contains(season.type) else { return nil }
        return .init(year: season.year, type: season.type)
    }

    var match: Match? { header?.competitions?.first }
    var teams: [TeamPlayers] { boxscore?.players ?? [] }
    var scoreTitle: String {
        match?.competitors?.map {
            "\($0.team.chineseName) \($0.score ?? "—")"
        }.joined(separator: "  :  ") ?? "NBA 球员技术统计"
    }

    var chineseStatus: String {
        NBALocalization.status(state: match?.status?.type?.state,
                               detail: match?.status?.type?.shortDetail,
                               period: match?.status?.period, clock: match?.status?.displayClock)
    }

    static func fetch(gameID: String) async throws -> NBABoxScore {
        try await NBABoxScoreStore.shared.load(gameID: gameID).summary
    }

    static func requestData(gameID: String) async throws -> Data {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary")!
        components.queryItems = [URLQueryItem(name: "event", value: gameID)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
