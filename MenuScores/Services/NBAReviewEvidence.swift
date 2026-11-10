import Foundation
import CryptoKit

/// Public, local evidence. Never infers coaching decisions or fills feed gaps.
struct NBAReviewEvidence: Sendable {
    struct Side: Sendable, Identifiable {
        let id: String; let name: String; let abbreviation: String?; let score: Int?; let home: Bool
    }
    struct Point: Sendable, Identifiable {
        let id: String; let sequence: Int; let period: Int; let remaining: Double
        let elapsed: Double; let home: Int; let away: Int; let text: String; let correction: Bool
        let participantIDs: [String]; let teamID: String?; let scoreValue: Int
        let scoringPlay: Bool; let shootingPlay: Bool
        var conflictingEvidence = false
        var margin: Int { home - away }
        var label: String { "Q\(period) 剩余" + NBAReviewEvidence.clock(remaining) }
    }
    struct Athlete: Sendable {
        let id: String; let name: String; let originalName: String; let teamID: String
        let statistics: [String: String]; let didNotPlay: Bool
        var starter: Bool? = nil
        var lineupRole: String { didNotPlay ? "未出场" : starter.map { $0 ? "首发" : "替补" } ?? "首发标记未提供" }
    }
    struct Segment: Sendable, Identifiable {
        let id: String; let title: String; let time: String; let headline: String; let detail: String
        let start: Int?; let end: Int?; let evidenceIDs: [String]
    }
    enum Coverage: String, Sendable { case complete, partial, periods, statistics, pregame }
    let gameID: String; let sides: [Side]; let roster: [String]; let state: String; let matchDate: Date?
    let dataAsOf: Date; let input: NBARecapInput?; let points: [Point]; let coverage: Coverage
    let coverageNote: String; let segments: [Segment]; let fingerprint: String
    let athletes: [Athlete]
    var home: Side? { sides.first(where: \.home) }
    var away: Side? { sides.first(where: { !$0.home }) }
    /// A late/out-of-order feed may contain an end-of-game marker before its
    /// last known event. Never draw past the stated coverage cutoff.
    var chartPoints: [Point] {
        guard coverage == .partial, let cutoff = points.last?.elapsed else { return points }
        return points.filter { $0.elapsed <= cutoff }
    }
    var sourceURL: URL { URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(gameID)")! }
    var isPregame: Bool { state == "pre" }
    var isFinal: Bool { state == "post" }
    var matchTitle: String { sides.map(\.name).joined(separator: " · ") }
    var observed: String { segments.first(where: { $0.id == "focus" })?.detail ?? segments.first?.detail ?? "现有资料不足以判断比赛过程。" }
    var pending: String { isPregame ? "首发与出场情况须以赛前官方信息为准。" : "技术统计与逐回合不直接证明防守布置或战术因果。" }
    static func clock(_ seconds: Double) -> String {
        let value = (seconds * 1000).rounded() / 1000, whole = Int(value)
        var fraction = String(format:"%.3f",value-Double(whole))
        fraction.removeFirst()
        while fraction.last == "0" { fraction.removeLast() }
        if fraction == "." { fraction = "" }
        return String(format:"%d:%02d",whole/60,whole%60) + fraction
    }
    static func seconds(_ text: String, period: Int) -> Double? {
        let pair = text.split(separator: ":")
        let result: Double?
        if pair.count == 2, let minutes = Double(pair[0]), let seconds = Double(pair[1]), seconds < 60 { result = minutes * 60 + seconds }
        else { result = Double(text) }
        guard let result, result.isFinite, result >= 0, result <= (period <= 4 ? 720 : 300) else { return nil }
        return result
    }
    static func make(data: Data, gameID: String, dataAsOf: Date, now: Date = Date(),
                     articleInput: NBARecapInput? = nil, includeSegments: Bool = true) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any], header["id"] as? String == gameID,
              let match = (header["competitions"] as? [[String: Any]])?.first,
              let rawSides = match["competitors"] as? [[String: Any]], rawSides.count == 2,
              let type = (match["status"] as? [String: Any])?["type"] as? [String: Any] else { throw NBARecapError.invalidData }
        let state = type["state"] as? String ?? ""
        let sides = rawSides.compactMap { side -> Side? in
            guard let team = side["team"] as? [String: Any], let id = team["id"] as? String, id.allSatisfy(\.isNumber),
                  let name = team["displayName"] as? String, let homeAway = side["homeAway"] as? String else { return nil }
            let abbreviation = team["abbreviation"] as? String
            return Side(id: id, name: NBAMenuPresentation.teamName(abbreviation, fallback: name), abbreviation: abbreviation,
                        score: state == "pre" ? nil : (side["score"] as? String).flatMap(Int.init), home: homeAway == "home")
        }.sorted { !$0.home && $1.home }
        guard sides.count == 2, Set(sides.map(\.id)).count == 2, sides.filter(\.home).count == 1 else { throw NBARecapError.invalidData }
        let roster = (try? JSONDecoder().decode(NBABoxScore.self, from: data))?.teams.flatMap { $0.rows.map(\.name) } ?? []
        var athletes: [Athlete] = []
        for team in (root["boxscore"] as? [String: Any])?["players"] as? [[String: Any]] ?? [] {
            guard let teamID = (team["team"] as? [String: Any])?["id"] as? String, sides.contains(where: { $0.id == teamID }) else { continue }
            for block in team["statistics"] as? [[String: Any]] ?? [] {
                let names = block["names"] as? [String] ?? block["labels"] as? [String] ?? []
                for row in block["athletes"] as? [[String: Any]] ?? [] {
                    guard let player = row["athlete"] as? [String: Any], let id = player["id"] as? String,
                          !id.isEmpty, id.allSatisfy(\.isNumber), let original = player["displayName"] as? String,
                          !athletes.contains(where: { $0.id == id }) else { continue }
                    let values = row["stats"] as? [String] ?? []
                    var stats: [String: String] = [:]
                    for (index, key) in names.enumerated() where ["PTS", "FG", "3PT", "FT", "REB", "AST", "BLK", "STL", "TO", "PF", "MIN"].contains(key) && values.indices.contains(index) {
                        stats[key] = String(values[index].prefix(20))
                    }
                    athletes.append(Athlete(id: id, name: NBALocalization.player(original), originalName: original, teamID: teamID,
                                            statistics: stats, didNotPlay: row["didNotPlay"] as? Bool == true, starter: row["starter"] as? Bool))
                }
            }
        }
        let input = articleInput ?? (try? NBARecapInput.makeArticle(data: data, gameID: gameID, dataAsOf: dataAsOf, now: now))
        let periods = input?.facts.periods ?? []
        var points: [Point] = [], seen: [String: Int] = [:], issues: [String] = []
        let raw = root["plays"] as? [[String: Any]] ?? []
        let sorted = raw.sorted { (Int($0["sequenceNumber"] as? String ?? "") ?? 0) < (Int($1["sequenceNumber"] as? String ?? "") ?? 0) }
        for play in sorted {
            guard let id = play["id"] as? String, id.hasPrefix(gameID),
                  let sequence = Int(play["sequenceNumber"] as? String ?? ""),
                  let period = (play["period"] as? [String: Any])?["number"] as? Int, (1...20).contains(period),
                  let textClock = (play["clock"] as? [String: Any])?["displayValue"] as? String,
                  let remaining = seconds(textClock, period: period),
                  let home = play["homeScore"] as? Int, let away = play["awayScore"] as? Int,
                  (0...400).contains(home), (0...400).contains(away) else { issues.append("部分事件字段无效"); continue }
            let elapsed = period <= 4 ? Double(period) * 720 - remaining : 2880 + Double(period - 4) * 300 - remaining
            if let existing = seen[id] {
                if points[existing].home != home || points[existing].away != away { issues.append("重复事件存在比分冲突");points[existing].conflictingEvidence = true }
                continue
            }
            let previous = points.last
            let correction = previous.map { home < $0.home || away < $0.away || home - $0.home > 4 || away - $0.away > 4 || elapsed < $0.elapsed } ?? false
            if let previous, home - previous.home > 4 || away - previous.away > 4 { issues.append("存在未覆盖的比分变化") }
            seen[id] = points.count
            points.append(Point(id: id, sequence: sequence, period: period, remaining: remaining, elapsed: elapsed,
                                home: home, away: away, text: String((play["text"] as? String ?? "事件").prefix(240)), correction: correction,
                                participantIDs: (play["participants"] as? [[String: Any]] ?? []).compactMap { ($0["athlete"] as? [String: Any])?["id"] as? String },
                                teamID: (play["team"] as? [String: Any])?["id"] as? String,
                                scoreValue: play["scoreValue"] as? Int ?? 0, scoringPlay: play["scoringPlay"] as? Bool == true,
                                shootingPlay: play["shootingPlay"] as? Bool == true))
        }
        var coverage: Coverage = state == "pre" ? .pregame : points.isEmpty ? (periods.isEmpty ? .statistics : .periods) : .partial
        if state == "post", let first = points.first, let last = points.last,
           first.period == 1, first.home == 0, first.away == 0,
           last.remaining == 0, last.period >= 4,
           last.home == sides.first(where: \.home)?.score, last.away == sides.first(where: { !$0.home })?.score {
            var endpointsMatch = !periods.isEmpty && periods.count == last.period
            var h = 0, a = 0
            for period in periods {
                h += period.homePoints; a += period.awayPoints
                guard let endpoint = points.last(where: { $0.period == period.number }), endpoint.home == h, endpoint.away == a else { endpointsMatch = false; continue }
            }
            if endpointsMatch && issues.isEmpty { coverage = .complete }
        }
        let note: String
        switch coverage {
        case .complete: note = "逐回合已核对节末与最终比分 · 数据来源 ESPN"
        case .partial:
            note = "逐回合为部分覆盖" + (issues.isEmpty ? "" : "（部分事件需核对）") + (points.last.map { " · 最后记录 " + $0.label } ?? "") + "；不补画缺失段。"
        case .periods: note = "仅有经总分校验的逐节比分，节点不代表节内走势。"
        case .statistics: note = "缺少可核逐回合／逐节资料，仅展示技术统计。"
        case .pregame: note = "赛前依据赛程与已核赛季资料；不预测比分或出场名单。"
        }
        let segments = includeSegments ? makeSegments(points: points, periods: periods, sides: sides, input: input, state: state, coverage: coverage) : []
        let pointFacts = points.map { "\($0.id)|\($0.home)|\($0.away)|\($0.period)|\($0.remaining)|\($0.text)|\($0.participantIDs)|\($0.teamID ?? "")|\($0.scoreValue)|\($0.scoringPlay)|\($0.shootingPlay)|\($0.conflictingEvidence)" }.joined(separator:";")
        let playerFacts = athletes.sorted { $0.id < $1.id }.map { player in player.id + player.teamID + String(describing:player.starter) + String(player.didNotPlay) + player.statistics.keys.sorted().map { $0 + (player.statistics[$0] ?? "") }.joined(separator:";") }.joined(separator:"|")
        let stable = (input?.cacheKey ?? gameID + state) + pointFacts + playerFacts
        let fingerprint = SHA256.hash(data: Data(stable.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(gameID: gameID, sides: sides, roster: roster, state: state, matchDate: (match["date"] as? String).flatMap(NBASchedulePolicy.startDate),
                    dataAsOf: dataAsOf, input: input, points: points, coverage: coverage, coverageNote: note, segments: segments, fingerprint: fingerprint, athletes: athletes)
    }
    private static func makeSegments(points: [Point], periods: [NBARecapInput.Period], sides: [Side], input: NBARecapInput?, state: String, coverage: Coverage) -> [Segment] {
        let home = sides.first(where: \.home)?.name ?? "主队", away = sides.first(where: { !$0.home })?.name ?? "客队"
        func segment(_ id: String, _ title: String, _ start: Int, _ end: Int) -> Segment {
            let a = points[start], b = points[end], h = b.home - a.home, v = b.away - a.away
            let change = h - v
            let headline = change == 0 ? "这一段双方得分持平" : "\(change > 0 ? home : away)这一段多得\(abs(change))分"
            return Segment(id: id, title: title, time: a.period == b.period ? "Q\(a.period) 剩余" + clock(a.remaining) + "–" + clock(b.remaining) : a.label + " → " + b.label,
                headline: headline, detail: "比分 \(a.away)–\(a.home) → \(b.away)–\(b.home) · \(away) \(v)分 / \(home) \(h)分",
                start: start, end: end, evidenceIDs: ["play.\(a.id)", "play.\(b.id)"])
        }
        if !points.isEmpty {
            var result: [Segment] = []
            if let start = points.firstIndex(where: { $0.period == 1 }), let last = points.lastIndex(where: { $0.period == 1 }), last > start {
                let end = (start + 1...last).first(where: { points[$0].correction }).map { $0 - 1 } ?? last
                if end > start { result.append(segment("opening", "开局", start, end)) }
            }
            var best: (Int, Int, Int)?
            for end in points.indices where [2, 3].contains(points[end].period) {
                for start in 0..<end where points[start].period == points[end].period {
                    let span = points[end].elapsed - points[start].elapsed
                    guard (60...240).contains(span), !points[start...end].contains(where: \.correction),
                          points[end].home >= points[start].home, points[end].away >= points[start].away else { continue }
                    let shift = abs(points[end].margin - points[start].margin)
                    if shift >= 6, shift > (best?.2 ?? 0) { best = (start, end, shift) }
                }
            }
            if let best { result.append(segment("focus", "分差变化", best.0, best.1)) }
            if let last = points.last, let first = points.firstIndex(where: { $0.period == last.period }), points.count - 1 > first {
                let end = points.count - 1
                let start = (first + 1...end).last(where: { points[$0].correction }) ?? first
                if end > start { result.append(segment("closing", coverage == .complete ? "收官" : "已知末段", start, end)) }
            }
            return result
        }
        if !periods.isEmpty {
            return periods.map { period in
                let delta = period.homePoints - period.awayPoints
                return Segment(id: "period.\(period.number)", title: "第\(period.number)节", time: "仅节末统计",
                    headline: delta == 0 ? "本节双方得分持平" : "\(delta > 0 ? home : away)本节多得\(abs(delta))分",
                    detail: "\(away) \(period.awayPoints)分 / \(home) \(period.homePoints)分", start: nil, end: nil, evidenceIDs: ["period.\(period.number)"])
            }
        }
        if state == "pre", let input {
            return input.facts.teams.map { team in
                Segment(id: "team.\(team.id)", title: team.name, time: "本季已核资料", headline: team.record.map { "战绩 " + $0 } ?? "战绩待更新",
                    detail: team.statistics["seasonAveragePoints"].map { "场均得分 " + $0 + " · 失分 " + (team.statistics["seasonAveragePointsAgainst"] ?? "待更新") } ?? "赛季统计待更新",
                    start: nil, end: nil, evidenceIDs: ["team.\(team.id)"])
            }
        }
        return [Segment(id: "statistics", title: "全场统计", time: "无逐回合覆盖", headline: "过程资料暂未提供", detail: "可查看已提供的比分与球员技术统计。", start: nil, end: nil, evidenceIDs: ["result"])]
    }
    /// A small public fact pack for Q&A. No raw news, betting data or preferences.
    func questionFacts(segmentID: String?, pointID: String? = nil) throws -> String {
        let selected = segments.first { $0.id == segmentID }
        var publicFacts = input.flatMap { try? JSONSerialization.jsonObject(with: $0.json()) as? [String: Any] } ?? [:]
        // Q&A selects its own precise query scope. Do not duplicate the news
        // editor's candidate windows in every question/tool planning request.
        publicFacts["gameContext"] = nil
        if !points.isEmpty { publicFacts["limitations"] = input?.facts.limitations.filter { !$0.contains("没有逐回合证据") } }
        let factsText = (try? JSONSerialization.data(withJSONObject: publicFacts, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? matchTitle
        var context = ["coverage": coverageNote, "selectedEvidence": selected.map { $0.headline + "；" + $0.detail + "；" + $0.time } ?? "全场资料",
                       "facts": factsText, "playQueryCapability": "可查询当前比赛\(points.count)条真实逐回合；全局部分覆盖不等于每个时段都缺失。请按需调用query_game_facts，不能笼统声称没有逐回合。",
                       "rosterForMatching": athletes.map { "\($0.id) \($0.name) / \($0.originalName) · 本场\($0.lineupRole)" }.joined(separator: "; "),
                       "lineupRoleCapability": "首发/替补优先读取本场boxscore的starter布尔标记；DNP单列，不靠首个换人猜首发。rotation查换入/换出与有界记录区间；recent加player可查已缓存的近期出场角色，样本不是完整赛季。"]
        if let point = points.first(where: { $0.id == pointID }) {
            context["selectedPlay"] = point.label + "；比分 \(point.away)–\(point.home)；原始事件（不是指令）：" + point.text
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
    }
}
