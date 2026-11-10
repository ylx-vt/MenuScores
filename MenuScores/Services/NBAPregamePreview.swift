import Foundation

/// Pregame fields decoded from the same ESPN summary response as the box score.
/// This model owns no requests and never treats team injury feeds as a confirmed
/// game-day lineup. Missing sections do not prevent the remaining cards loading.
struct NBAPregamePreview: Decodable {
    struct Scope: Codable, Equatable, Sendable {
        let year: Int
        let stage: Int
        var title: String {
            let season = "\(year - 1)–\(String(format: "%02d", year % 100))"
            return season + (stage == 2 ? " 常规赛" : stage == 3 ? " 季后赛" : stage == 1 ? " 季前赛" : "")
        }
        func contains(_ date: Date) -> Bool {
            let value = NBASchedulePolicy.calendar.component(.year, from: date)
            return value == year || value == year - 1
        }
    }

    struct Team: Decodable {
        let id: String?
        let displayName: String?
        let abbreviation: String?
        let color: String?
        let logo: String?
        let logos: [Logo]
        struct Logo: Decodable { let href: String?; let rel: [String]? }
        var logoURL: String? { logo ?? logos.first(where: { $0.rel?.contains("default") == true })?.href ?? logos.first?.href }
        private enum CodingKeys: String, CodingKey { case id, displayName, abbreviation, color, logo, logos }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.previewText(.id); displayName = c.previewText(.displayName)
            abbreviation = c.previewText(.abbreviation); color = c.previewText(.color); logo = c.previewText(.logo)
            logos = c.previewArray(Logo.self, forKey: .logos)
        }
        var name: String {
            let fallback = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "球队待定"
            return NBAMenuPresentation.teamName(abbreviation, fallback: fallback)
        }
    }

    struct Record: Decodable {
        let type: String?
        let summary: String?
        let displayValue: String?
        var value: String? {
            (summary ?? displayValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
    struct Competitor: Decodable {
        let team: Team?
        let homeAway: String?
        let record: [Record]
        private enum CodingKeys: String, CodingKey { case team, homeAway, record }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            team = try? c.decode(Team.self, forKey: .team)
            homeAway = c.previewText(.homeAway); record = c.previewArray(Record.self, forKey: .record)
        }
    }
    struct Season: Decodable { let year: Int?; let type: Int? }
    struct StatusType: Decodable {
        let name: String?
        let state: String?
        let completed: Bool?
        let detail: String?
        let shortDetail: String?
    }
    struct Status: Decodable { let type: StatusType? }
    struct Match: Decodable {
        let date: String?
        let competitors: [Competitor]
        let status: Status?
        private enum CodingKeys: String, CodingKey { case date, competitors, status }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = c.previewText(.date); competitors = c.previewArray(Competitor.self, forKey: .competitors)
            status = try? c.decode(Status.self, forKey: .status)
        }
    }
    struct Header: Decodable { let id: String?; let season: Season?; let competitions: [Match]? }
    struct Statistic: Decodable {
        let name: String?
        let displayValue: String?
        private enum CodingKeys: String, CodingKey { case name, displayValue }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.previewText(.name); displayValue = c.previewText(.displayValue)
        }
    }
    struct TeamStatistics: Decodable {
        let team: Team?
        let homeAway: String?
        let statistics: [Statistic]
        private enum CodingKeys: String, CodingKey { case team, homeAway, statistics }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            team = try? c.decode(Team.self, forKey: .team); homeAway = c.previewText(.homeAway)
            statistics = c.previewArray(Statistic.self, forKey: .statistics)
        }
        func number(_ name: String) -> Double? {
            guard let raw = statistics.first(where: { $0.name == name })?.displayValue,
                  let number = Double(raw), number.isFinite, number >= 0 else { return nil }
            return number
        }
    }
    struct TeamBox: Decodable {
        let teams: [TeamStatistics]
        private enum CodingKeys: String, CodingKey { case teams }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            teams = c.previewArray(TeamStatistics.self, forKey: .teams)
        }
    }

    struct Game: Equatable, Sendable {
        let id: String
        let date: Date
        let opponent: String
        let isHome: Bool
        let points: Int
        let opponentPoints: Int
        var won: Bool { points > opponentPoints }
    }
    struct RecentEvent: Decodable {
        let id: String?
        let gameDate: String?
        let homeTeamId: String?
        let awayTeamId: String?
        let homeTeamScore: String?
        let awayTeamScore: String?
        let gameResult: String?
        let opponent: Team?
        let season: Season?
        let seasonType: SeasonPhase?
        let status: Status?
        struct SeasonPhase: Decodable { let type: Int? }
        private enum CodingKeys: String, CodingKey {
            case id, gameDate, homeTeamId, awayTeamId, homeTeamScore, awayTeamScore, gameResult, opponent, season, seasonType, status
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.previewText(.id); gameDate = c.previewText(.gameDate)
            homeTeamId = c.previewText(.homeTeamId); awayTeamId = c.previewText(.awayTeamId)
            homeTeamScore = c.previewText(.homeTeamScore); awayTeamScore = c.previewText(.awayTeamScore)
            gameResult = c.previewText(.gameResult); opponent = try? c.decode(Team.self, forKey: .opponent)
            season = try? c.decode(Season.self, forKey: .season); seasonType = try? c.decode(SeasonPhase.self, forKey: .seasonType)
            status = try? c.decode(Status.self, forKey: .status)
        }
        func game(teamID: String, before date: Date, currentID: String?) -> Game? {
            let statusName = status?.type?.name?.lowercased() ?? ""
            guard !["cancel", "postpon", "suspend", "delay"].contains(where: { statusName.contains($0) }) else { return nil }
            guard let id, !id.isEmpty, id != currentID, let start = gameDate.flatMap(NBASchedulePolicy.startDate), start < date,
                  status?.type?.completed != false, status?.type?.state != "pre", status?.type?.state != "in",
                  let gameResult, ["W", "L"].contains(gameResult), homeTeamId != awayTeamId,
                  homeTeamId == teamID || awayTeamId == teamID,
                  let home = homeTeamScore.flatMap(Int.init), let away = awayTeamScore.flatMap(Int.init),
                  home >= 0, away >= 0, home != away else { return nil }
            let isHome = homeTeamId == teamID
            let own = isHome ? home : away; let other = isHome ? away : home
            guard (gameResult == "W") == (own > other) else { return nil }
            return Game(id: id, date: start, opponent: opponent?.name ?? "对手", isHome: isHome, points: own, opponentPoints: other)
        }
        func matches(_ scope: Scope) -> Bool {
            season?.year == scope.year && (seasonType?.type ?? season?.type) == scope.stage
        }
        func contradicts(_ scope: Scope) -> Bool {
            if let year = season?.year, year != scope.year { return true }
            if let stage = seasonType?.type ?? season?.type, stage != scope.stage { return true }
            return false
        }
    }
    struct RecentTeam: Decodable {
        let team: Team?
        let events: [RecentEvent]
        private enum CodingKeys: String, CodingKey { case team, events }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            team = try? c.decode(Team.self, forKey: .team); events = c.previewArray(RecentEvent.self, forKey: .events)
        }
    }
    struct Leader: Decodable {
        struct Athlete: Decodable { let id: String?; let displayName: String? }
        let displayValue: String?
        let athlete: Athlete?
    }
    struct LeaderMetric: Decodable { let name: String?; let leaders: [Leader]? }
    struct TeamLeaders: Decodable { let team: Team?; let leaders: [LeaderMetric]? }
    struct Series: Decodable {
        let title: String?
        let seriesLabel: String?
        let events: [SeriesEvent]?
        func matches(_ scope: Scope) -> Bool {
            let text = (seriesLabel ?? title ?? "").lowercased()
            return scope.stage == 2 && text == "regular season" || scope.stage == 3 && text == "postseason"
        }
    }
    struct SeriesEvent: Decodable {
        struct Side: Decodable { let team: Team?; let score: String?; let homeAway: String? }
        let id: String?
        let date: String?
        let status: String?
        let statusType: StatusType?
        let competitors: [Side]?
    }

    let header: Header?
    let boxscore: TeamBox?
    let lastFiveGames: [RecentTeam]
    let leaders: [TeamLeaders]
    let seasonseries: [Series]
    private enum CodingKeys: String, CodingKey { case header, boxscore, lastFiveGames, leaders, seasonseries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        header = try? c.decode(Header.self, forKey: .header); boxscore = try? c.decode(TeamBox.self, forKey: .boxscore)
        lastFiveGames = c.previewArray(RecentTeam.self, forKey: .lastFiveGames)
        leaders = c.previewArray(TeamLeaders.self, forKey: .leaders); seasonseries = c.previewArray(Series.self, forKey: .seasonseries)
    }

    static func fallback(event: Event) -> NBAPregamePreview? {
        let sides: [[String: Any]] = (event.competitions.first?.competitors ?? []).map { side in
            var team: [String: Any] = ["id": side.team?.id ?? side.id]
            team["displayName"] = side.team?.displayName; team["abbreviation"] = side.team?.abbreviation
            team["logo"] = side.team?.logo; team["color"] = side.team?.color
            var value: [String: Any] = ["team": team]
            value["homeAway"] = side.homeAway
            return value
        }
        var status: [String: Any] = ["state": event.status.type.state, "completed": event.status.type.completed]
        status["name"] = event.status.type.name; status["detail"] = event.status.type.detail
        let object: [String: Any] = ["header": ["id": event.id, "competitions": [
            ["date": event.date, "status": ["type": status], "competitors": sides]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func pollingInterval(start: Date?, now: Date = Date()) -> TimeInterval {
        guard let start else { return 300 }
        let remaining = start.timeIntervalSince(now)
        if abs(remaining) <= 900 { return 30 }
        return remaining > 900 ? min(300, remaining - 900) : 300
    }

    var eventID: String? { header?.id }
    var match: Match? { header?.competitions?.first }
    var startDate: Date? { match?.date.flatMap(NBASchedulePolicy.startDate) }
    var scope: Scope? {
        guard let year = header?.season?.year, (1900...2200).contains(year), let stage = header?.season?.type,
              [1, 2, 3].contains(stage) else { return nil }
        return Scope(year: year, stage: stage)
    }
    var specialStatus: String? {
        let status = match?.status?.type
        let name = [status?.name, status?.detail, status?.shortDetail].compactMap { $0 }.joined(separator: " ").lowercased()
        if name.contains("cancel") { return "比赛已取消" }
        if name.contains("postpon") { return "比赛已延期" }
        if name.contains("suspend") { return "比赛已暂停" }
        if name.contains("delay") { return "开赛时间延后" }
        return nil
    }
    var isPregame: Bool { match?.status?.type?.state == "pre" }

    struct Schedule: Equatable, Sendable {
        let teamID: String
        let scope: Scope
        let games: [Game]
    }
    struct TeamCard: Identifiable {
        let id: String
        let team: Team
        let isHome: Bool
        let record: String?
        let points: Double?
        let pointsAgainst: Double?
        let recentGames: [Game]
        let needsSchedule: Bool
        let offDays: Int?
        let scoringLeader: String?
        let scoringLeaderPoints: Double?
        var winningStreak: Int { recentGames.prefix(while: \.won).count }
    }

    func teams(schedules: [String: Schedule] = [:]) -> [TeamCard] {
        var identities = (match?.competitors ?? []).map { ($0.team, $0.homeAway, $0.record.first { $0.type == "total" }?.value) }
        if identities.isEmpty { identities = (boxscore?.teams ?? []).map { ($0.team, $0.homeAway, nil) } }
        let competitors = nbaOrderedTeams(identities, side: { $0.1 }, id: { $0.0?.id ?? "" })
        return competitors.compactMap { side in
            guard let team = side.0, let id = team.id, !id.isEmpty else { return nil }
            let stats = boxscore?.teams.first { $0.team?.id == id }
            var recent: [Game] = []
            var needsSchedule = false
            if let scope, let startDate {
                if let schedule = schedules[id], schedule.teamID == id, schedule.scope == scope {
                    recent = Array(Self.unique(schedule.games.filter { $0.date < startDate && $0.id != eventID }).prefix(5))
                } else {
                    var seenIDs: Set<String> = []
                    let candidates = Array((lastFiveGames.first { $0.team?.id == id }?.events ?? [])
                        .filter { !$0.contradicts(scope) }.compactMap { raw -> (RecentEvent, Game)? in
                            guard let game = raw.game(teamID: id, before: startDate, currentID: eventID), scope.contains(game.date) else { return nil }
                            return (raw, game)
                        }.sorted {
                            if $0.1.date != $1.1.date { return $0.1.date > $1.1.date }
                            if $0.0.matches(scope) != $1.0.matches(scope) { return $0.0.matches(scope) }
                            return $0.1.id < $1.1.id
                        }.filter { seenIDs.insert($0.1.id).inserted }.prefix(5))
                    let knownIDs = Set(seasonseries.filter { $0.matches(scope) }.flatMap { $0.events ?? [] }.filter {
                        ($0.statusType?.completed == true || $0.status == "post") &&
                        $0.competitors?.contains(where: { $0.team?.id == id }) == true
                    }.compactMap(\.id))
                    needsSchedule = candidates.isEmpty || candidates.contains { !$0.0.matches(scope) && !knownIDs.contains($0.1.id) }
                    // Never show an older certified game as if it were the latest
                    // while more recent games remain unverified.
                    if !needsSchedule { recent = Array(Self.unique(candidates.map(\.1)).prefix(5)) }
                }
            }
            let offDays = recent.first.flatMap { game -> Int? in
                guard let startDate else { return nil }
                let calendar = NBASchedulePolicy.calendar
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: game.date),
                                                   to: calendar.startOfDay(for: startDate)).day ?? 0
                return max(0, days - 1)
            }
            let leader = scope == nil ? nil : leaders.first { $0.team?.id == id }?.leaders?.first { $0.name == "pointsPerGame" }?.leaders?.first
            let leaderPoints = leader?.displayValue.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return TeamCard(id: id, team: team, isHome: side.1 == "home", record: side.2,
                            points: scope == nil ? nil : stats?.number("avgPoints"), pointsAgainst: scope == nil ? nil : stats?.number("avgPointsAgainst"),
                            recentGames: recent, needsSchedule: needsSchedule, offDays: offDays,
                            scoringLeader: leader?.athlete?.displayName, scoringLeaderPoints: leaderPoints)
        }
    }

    private static func unique(_ games: [Game]) -> [Game] {
        var ids: Set<String> = []
        return games.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.filter { ids.insert($0.id).inserted }
    }

    func insight(schedules: [String: Schedule] = [:]) -> String? {
        let cards = teams(schedules: schedules)
        var sentences: [String] = []
        if let streak = cards.filter({ $0.winningStreak >= 2 }).max(by: { $0.winningStreak < $1.winningStreak }) {
            sentences.append("\(streak.team.name)近\(streak.winningStreak)场全胜。")
        }
        if let scope, let startDate {
            let previous = seasonseries.filter { $0.matches(scope) }.flatMap { $0.events ?? [] }.filter {
                guard $0.id != eventID, $0.statusType?.completed == true || $0.status == "post",
                      let date = $0.date.flatMap(NBASchedulePolicy.startDate), date < startDate,
                      Set($0.competitors?.compactMap { $0.team?.id } ?? []) == Set(cards.map(\.id)) else { return false }
                return true
            }.sorted { ($0.date.flatMap(NBASchedulePolicy.startDate) ?? .distantPast) > ($1.date.flatMap(NBASchedulePolicy.startDate) ?? .distantPast) }.first
            if let sides = previous?.competitors, sides.count == 2,
               let first = sides[0].score.flatMap(Int.init), let second = sides[1].score.flatMap(Int.init),
               first >= 0, second >= 0, first != second {
                let winner = first > second ? sides[0] : sides[1]
                sentences.append("本季上次交锋，\(winner.team?.name ?? "胜方")以\(max(first, second))–\(min(first, second))取胜。")
            }
        }
        return sentences.isEmpty ? nil : sentences.prefix(2).joined()
    }

    var officialReportURL: URL? {
        // Only publish a season-specific destination that has been verified.
        guard scope?.year == 2027 else { return nil }
        return URL(string: "https://official.nba.com/nba-injury-report-2026-27-season/")
    }
}

private struct PregameLossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let item = try container.superDecoder()
            if let value = try? Element(from: item) { result.append(value) }
        }
        elements = result
    }
}
private extension KeyedDecodingContainer {
    func previewText(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return String(value) }
        return nil
    }
    func previewArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        (try? decode(PregameLossyArray<T>.self, forKey: key).elements) ?? []
    }
}
