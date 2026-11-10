import Foundation

enum NBAMenuPresentation {
    private static let teamNames = [
        "ATL": "老鹰", "BOS": "凯尔特人", "BKN": "篮网", "CHA": "黄蜂",
        "CHI": "公牛", "CLE": "骑士", "DAL": "独行侠", "DEN": "掘金",
        "DET": "活塞", "GS": "勇士", "GSW": "勇士", "HOU": "火箭",
        "IND": "步行者", "LAC": "快船", "LAL": "湖人", "MEM": "灰熊",
        "MIA": "热火", "MIL": "雄鹿", "MIN": "森林狼", "NO": "鹈鹕",
        "NOP": "鹈鹕", "NY": "尼克斯", "NYK": "尼克斯", "OKC": "雷霆",
        "ORL": "魔术", "PHI": "76人", "PHX": "太阳", "PHO": "太阳",
        "POR": "开拓者", "SAC": "国王", "SA": "马刺", "SAS": "马刺",
        "TOR": "猛龙", "UTAH": "爵士", "UTA": "爵士", "WSH": "奇才", "WAS": "奇才"
    ]

    static func teamName(_ abbreviation: String?, fallback: String) -> String {
        teamNames[abbreviation ?? ""] ?? fallback
    }

    static func title(for game: Event) -> String {
        guard let competitors = game.competitions.first?.competitors, competitors.count >= 2 else {
            return game.shortName ?? game.name
        }
        let teams = nbaOrderedTeams(competitors, side: { $0.homeAway }, id: { $0.team?.id ?? $0.id })
        func name(_ team: Competitor) -> String {
            teamNames[team.team?.abbreviation ?? ""] ?? team.team?.displayName ?? team.id
        }
        if let special = specialState(for: game) { return "\(name(teams[0])) 对阵 \(name(teams[1])) · \(special)" }
        if game.status.type.state == "pre" {
            let time = NBASchedulePolicy.startDate(game.date).map { NBASchedulePolicy.startTime($0, includeDay: true) } ?? "时间待定"
            return "\(name(teams[0])) 对阵 \(name(teams[1])) · \(time)"
        }
        let score = "\(name(teams[0])) \(teams[0].score ?? "—") : \(teams[1].score ?? "—") \(name(teams[1]))"
        if game.status.type.state == "post" { return "\(score) · 已结束" }
        let period = game.status.period ?? 1
        let periodTitle = period > 4 ? "加时\(period - 4)" : "第\(period)节"
        return "\(score) · \(periodTitle) \(game.status.displayClock ?? "")"
    }

    static func specialState(for game: Event) -> String? {
        let detail = [game.status.type.name, game.status.type.detail, game.status.type.shortDetail].compactMap { $0 }.joined(separator: " ").lowercased()
        if detail.contains("cancel") { return "已取消" }
        if detail.contains("postpon") { return "已延期" }
        if detail.contains("suspend") { return "已暂停" }
        if detail.contains("delay") { return "延迟开赛" }
        return nil
    }
}

/// Use explicit home/away only when both sides are known; otherwise use team IDs
/// consistently across scoreboard and summary responses.
func nbaOrderedTeams<T>(_ teams: [T], side: (T) -> String?, id: (T) -> String) -> [T] {
    if teams.count == 2, let away = teams.first(where: { side($0) == "away" }),
       let home = teams.first(where: { side($0) == "home" }) { return [away, home] }
    return teams.sorted { id($0) < id($1) }
}
