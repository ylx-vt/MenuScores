import Foundation

struct NBAReviewEventReference: Codable, Sendable, Identifiable {
    let id: String; let gameID: String; let label: String; let score: String; let text: String
    // The JSON endpoint has no documented per-event fragment. Show the exact
    // event ID beside the record and link to its real source, never invent one.
    var url: URL { URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(gameID)")! }
}
struct NBAReviewLocalEvidence: Codable, Sendable {
    let gameID: String; let matchDate: String?; let dataAsOf: Date
    let summaries: [String]; let events: [NBAReviewEventReference]
    var queryScope: String? = nil
    var identitySources: [NBAReviewAnswer.Source]? = nil
}

/// The model chooses a bounded query. All scores, time filters and player
/// attribution below are local calculations over the current public game.
enum NBAReviewGameQuery {
    enum Failure: Error, LocalizedError {
        case resultTooLarge(Int)
        var errorDescription: String? { "本场查询结果超过安全大小，尚未发送后续解读。比赛资料已保留，请缩小到一个球员或时段；已发生的查数费用仍记账。" }
    }
    struct Request: Codable, Sendable {
        enum Intent: String, Codable, Sendable { case matchAnalysis = "match_analysis", externalFact = "external_fact", mixed, clarification, conversation }
        let queries: [Query]
        let needsExternalResearch: Bool
        let intent: Intent
        init(queries: [Query], needsExternalResearch: Bool, intent: Intent) { self.queries = queries; self.needsExternalResearch = needsExternalResearch; self.intent = intent }
        // Decode/replay old receipts without reinterpreting them as new calls.
        init(queries: [Query], needsOfficialResearch: Bool) { self.init(queries: queries, needsExternalResearch: needsOfficialResearch, intent: needsOfficialResearch ? .externalFact : .matchAnalysis) }
        private enum CodingKeys: String, CodingKey { case queries, needsExternalResearch, needsOfficialResearch, intent }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            queries = try c.decode([Query].self, forKey: .queries)
            needsExternalResearch = try c.decodeIfPresent(Bool.self, forKey: .needsExternalResearch) ?? c.decodeIfPresent(Bool.self, forKey: .needsOfficialResearch) ?? false
            intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? (needsExternalResearch ? .externalFact : .matchAnalysis)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(queries, forKey: .queries); try c.encode(needsExternalResearch, forKey: .needsExternalResearch); try c.encode(intent, forKey: .intent)
        }
    }
    struct Query: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case overview, player, events, runs, lead_changes, recent, availability, identity, impact, rotation }
        enum Scope: String, Codable, Sendable { case game, selected, period, range, last_five, clutch, critical, close }
        let kind: Kind; let scope: Scope; let player: String?; let period: Int?
        let remainingFrom: Double?; let remainingTo: Double?; let eventTypes: [String]
    }
    struct Result: Sendable {
        let json: String; let evidence: NBAReviewLocalEvidence; let numbers: Set<Double>
        let requiresOfficial: Bool; let needsClarification: Bool; let missingEvents: Bool
        var entityNames: Set<String> = []
    }
    struct Metrics: Sendable {
        var points = 0, fieldGoalsMade = 0, fieldGoalsAttempted = 0, threesMade = 0, threesAttempted = 0
        var freeThrowsMade = 0, freeThrowsAttempted = 0, rebounds = 0, assists = 0, blocks = 0, steals = 0, turnovers = 0
        var dictionary: [String: Int] { ["points":points,"fieldGoalsMade":fieldGoalsMade,"fieldGoalsAttempted":fieldGoalsAttempted,
            "threesMade":threesMade,"threesAttempted":threesAttempted,"freeThrowsMade":freeThrowsMade,"freeThrowsAttempted":freeThrowsAttempted,
            "rebounds":rebounds,"assists":assists,"blocks":blocks,"steals":steals,"turnovers":turnovers] }
    }
    struct Window {
        let indices: [Int]; let label: String; let complete: Bool; let covered: Bool; let definition: String
    }
    static let eventTypes = ["score","shot","assist","rebound","block","steal","turnover","foul","substitution"]
    static func decode(_ arguments: String) throws -> Request {
        guard arguments.utf8.count <= 6000, let data = arguments.data(using: .utf8) else { throw NBARecapError.invalidData }
        guard let raw = try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(raw.keys).isSubset(of:["queries","needsOfficialResearch","needsExternalResearch","intent"]),
              let queries = raw["queries"] as? [[String:Any]],queries.allSatisfy({ Set($0.keys).isSubset(of:["kind","scope","player","period","remainingFrom","remainingTo","eventTypes"]) }) else { throw NBARecapError.invalidData }
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard (1...3).contains(request.queries.count), request.queries.allSatisfy({ q in
            (q.player?.count ?? 0) <= 100 && (q.period == nil || (1...20).contains(q.period!)) && q.eventTypes.count <= eventTypes.count && q.eventTypes.allSatisfy(eventTypes.contains) &&
            [q.remainingFrom,q.remainingTo].compactMap { $0 }.allSatisfy { $0.isFinite && (0...720).contains($0) } &&
            (q.player == nil || !q.player!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) &&
            (q.scope != .period || q.period != nil) &&
            (q.scope != .range || q.period != nil && q.remainingFrom != nil && q.remainingTo != nil && q.remainingFrom! >= q.remainingTo! && q.remainingFrom! <= (q.period! <= 4 ? 720 : 300))
        }) else { throw NBARecapError.invalidData }
        return request
    }
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier:"en_US_POSIX"))
            .replacingOccurrences(of:"’",with:"'").split(whereSeparator: \.isWhitespace).joined(separator:" ")
    }
    static func matches(_ text: String, athlete: NBAReviewEvidence.Athlete) -> Bool {
        let value = normalized(text)
        if value == athlete.id || value == normalized(athlete.name) || value == normalized(athlete.originalName) { return true }
        let chinese = athlete.name.split(separator:"·").last.map(String.init) ?? athlete.name
        let english = athlete.originalName.split(separator:" ").last.map(String.init) ?? athlete.originalName
        if value == normalized(chinese) || value == normalized(english) { return true }
        return value.count >= 2 && value.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains(Int($0.value)) } && normalized(athlete.name).contains(value)
    }
    static func roles(_ point: NBAReviewEvidence.Point, athlete: NBAReviewEvidence.Athlete) -> (Metrics, Set<String>) {
        var m = Metrics(), roles: Set<String> = []
        // A participant can be the opponent, assist provider or substitution
        // partner. Merely appearing in participants never earns the points.
        guard point.participantIDs.contains(athlete.id) else { return (m,roles) }
        let text = normalized(point.text), name = normalized(athlete.originalName)
        let actor = text.hasPrefix(name + " "), shooter = point.participantIDs.first == athlete.id && point.teamID == athlete.teamID
        let freeThrow = text.contains("free throw")
        if shooter && point.shootingPlay {
            if freeThrow { m.freeThrowsAttempted = 1 } else { m.fieldGoalsAttempted = 1; if text.contains("three point") { m.threesAttempted = 1 } }
            roles.insert("shot")
        }
        if shooter && actor && point.scoringPlay && (1...4).contains(point.scoreValue) && text.contains(" makes ") {
            m.points = point.scoreValue
            if freeThrow { m.freeThrowsMade = 1 } else { m.fieldGoalsMade = 1; if point.scoreValue == 3 { m.threesMade = 1 } }
            roles.insert("score")
        }
        if point.scoringPlay && text.contains(name + " assists") { m.assists = 1; roles.insert("assist") }
        if actor && text.contains("rebound") { m.rebounds = 1; roles.insert("rebound") }
        if actor && text.contains(" blocks ") { m.blocks = 1; roles.insert("block") }
        if text.contains(name + " steals") { m.steals = 1; roles.insert("steal") }
        if actor && text.contains("turnover") { m.turnovers = 1; roles.insert("turnover") }
        if actor && text.contains("foul") { roles.insert("foul") }
        if actor && text.contains("enters the game") || text.contains("enters the game for " + name) { roles.insert("substitution") }
        return (m,roles)
    }
    static func add(_ a: inout Metrics, _ b: Metrics) {
        a.points += b.points; a.fieldGoalsMade += b.fieldGoalsMade; a.fieldGoalsAttempted += b.fieldGoalsAttempted
        a.threesMade += b.threesMade; a.threesAttempted += b.threesAttempted; a.freeThrowsMade += b.freeThrowsMade; a.freeThrowsAttempted += b.freeThrowsAttempted
        a.rebounds += b.rebounds; a.assists += b.assists; a.blocks += b.blocks; a.steals += b.steals; a.turnovers += b.turnovers
    }
    static func validTransition(_ index: Int, in e: NBAReviewEvidence) -> Bool {
        let p = e.points[index]
        guard !p.conflictingEvidence else { return false }
        guard index > 0 else { return p.home == 0 && p.away == 0 }
        let previous = e.points[index-1], h = p.home-previous.home, a = p.away-previous.away
        guard !p.correction, !p.conflictingEvidence, p.elapsed >= previous.elapsed else { return false }
        if !p.scoringPlay { return h == 0 && a == 0 }
        guard (1...4).contains(p.scoreValue) else { return false }
        return p.teamID == e.home?.id ? h == p.scoreValue && a == 0 : p.teamID == e.away?.id && a == p.scoreValue && h == 0
    }
    static func window(_ q: Query, evidence e: NBAReviewEvidence, segmentID: String?, frozenSelection: NBAReviewEvidence.Segment? = nil) -> Window {
        let points = e.points
        guard !points.isEmpty else { return Window(indices:[],label:"逐回合缺失",complete:false,covered:false,definition:"没有本地逐回合，不能把缺失当作零。") }
        if q.scope == .selected {
            let s = frozenSelection ?? e.segments.first { $0.id == segmentID }
            guard let s, let firstID = s.evidenceIDs.first?.replacingOccurrences(of:"play.",with:""), let lastID = s.evidenceIDs.last?.replacingOccurrences(of:"play.",with:""),
                  let a = points.firstIndex(where:{$0.id == firstID}),let b = points.firstIndex(where:{$0.id == lastID}),b > a else {
                return Window(indices:[],label:s?.time ?? "所选时段",complete:false,covered:false,definition:"缺少所选时段的原始端点，不能改用另一个自动转折段。")
            }
            let indices = Array(a+1...b)
            return Window(indices:indices,label:s.time,complete:!points[a].conflictingEvidence && indices.allSatisfy { validTransition($0,in:e) },covered:true,definition:"统计起点比分之后至终点事件（左开右闭），起点事件不重复计分。")
        }
        let period = q.period ?? 4
        var indices: [Int]
        let label: String
        var covered: Bool
        switch q.scope {
        case .close:
            indices = points.indices.filter { (q.period == nil || points[$0].period == q.period) && $0 > 0 && abs(points[$0-1].margin) <= 5 && validTransition($0,in:e) }
            covered = q.period.map { n in points.contains { $0.period == n && $0.remaining >= (n <= 4 ? 720 : 300) } && points.contains { $0.period == n && $0.remaining == 0 } } ?? (e.coverage == .complete)
            label = (q.period.map { "Q\($0)" } ?? "全场") + "已核胶着回合（回合前分差≤5，不限最后5分钟）"
        case .last_five,.clutch:
            indices = points.indices.filter { points[$0].period >= 4 && points[$0].remaining <= 300 }
            let finalPeriod = max(4,e.input?.facts.periods.last?.number ?? points.last!.period)
            covered = (4...finalPeriod).allSatisfy { n in
                points.contains { $0.period == n && $0.remaining >= 300 } && points.contains { $0.period == n && $0.remaining == 0 }
            } && points.last?.home == e.home?.score && points.last?.away == e.away?.score
            label = q.scope == .clutch ? "clutch：末节／加时最后5分钟，回合前分差≤5" : "末节／加时最后5分钟（不限制分差）"
        case .period,.range:
            let from = q.scope == .period ? (period <= 4 ? 720.0 : 300.0) : q.remainingFrom ?? 0
            let to = q.scope == .period ? 0.0 : q.remainingTo ?? 0
            indices = points.indices.filter { points[$0].period == period && points[$0].remaining <= from && points[$0].remaining >= to }
            covered = points.contains { $0.period == period && $0.remaining >= from } && points.contains { $0.period == period && $0.remaining <= to }
            label = "Q\(period) 剩余\(NBAReviewEvidence.clock(from))–\(NBAReviewEvidence.clock(to))"
        default:
            indices = Array(points.indices); covered = e.coverage == .complete
            label = "本场全部已记录事件"
        }
        // A clock correction can temporarily leave the requested clock range.
        // Validate the whole source span, not just the filtered timestamps.
        var verification = Set(indices)
        for n in Set(indices.map { points[$0].period }) {
            let part = indices.filter { points[$0].period == n }
            if let a = part.first,let b = part.last { verification.formUnion(a...b) }
        }
        let complete = covered && verification.allSatisfy { validTransition($0,in:e) }
        if q.scope == .clutch {
            indices = indices.filter { $0 > 0 && abs(points[$0-1].margin) <= 5 && validTransition($0,in:e) }
        }
        return Window(indices:indices,label:label,complete:complete,covered:covered,
            definition:q.scope == .clutch ? "按回合发生前分差≤5统计；没有符合回合与数据缺失是两种状态。不是笼统把整个末节叫关键时刻。" : q.scope == .close ? "各节回合前分差≤5，不限最后5分钟；只计比分转换已核的记录，覆盖不全时不称完整总数。" : "按实际比赛剩余时钟过滤，时间上下界均包含；计数只来自记录。没有完整轮换不计算时段正负值或阵容。")
    }
    static func largestSwing(_ indices: [Int], evidence e: NBAReviewEvidence) -> (Int,Int,Int,Int)? {
        let selected = Set(indices)
        var prefix = [0]
        for i in e.points.indices { prefix.append(prefix.last! + (selected.contains(i) && validTransition(i,in:e) ? 0 : 1)) }
        var best: (Int,Int,Int,Int)?
        for end in indices where end > 0 {
            for start in stride(from:end-1,through:0,by:-1) {
                let a = e.points[start],b = e.points[end],span = b.elapsed-a.elapsed
                if a.period != b.period || span > 240 { break }
                guard span >= 60,!a.conflictingEvidence,prefix[end+1] == prefix[start+1] else { continue }
                let h = b.home-a.home,v = b.away-a.away
                guard h >= 0,v >= 0,abs(h-v) >= 4,abs(h-v) > abs((best?.2 ?? 0)-(best?.3 ?? 0)) else { continue }
                best = (start,end,h,v)
            }
        }
        return best
    }
    static func execute(_ request: Request, evidence e: NBAReviewEvidence, segmentID: String?, frozenSelection: NBAReviewEvidence.Segment? = nil, identities: [NBAReviewIdentityDirectory.Identity] = [], recentRoles: [NBAReviewPlayerHistory.Appearance] = []) throws -> Result {
        _ = try decode(String(decoding:JSONEncoder().encode(request),as:UTF8.self))
        var results: [[String:Any]] = [], refs: [NBAReviewEventReference] = [], summaries: [String] = [], scopeLabels: [String] = []
        var numbers: Set<Double> = [], requiresOfficial = request.needsExternalResearch && [.externalFact,.mixed].contains(request.intent), clarification = false, missingEvents = false
        var identitySources: [NBAReviewAnswer.Source] = []
        var entityNames: Set<String> = []
        func addRef(_ p: NBAReviewEvidence.Point) {
            if refs.count < 32 && !refs.contains(where:{$0.id == p.id}) { refs.append(.init(id:p.id,gameID:e.gameID,label:p.label,score:"\(p.away)–\(p.home)",text:p.text)) }
            [p.home,p.away,p.period,Int(p.remaining)/60,Int(p.remaining)%60].forEach { numbers.insert(Double($0)) }
            numbers.insert((p.remaining.truncatingRemainder(dividingBy:60)*1000).rounded()/1000)
        }
        for q in request.queries {
            if q.kind == .impact {
                var candidates: [NBAReviewEvidence.Athlete] = []
                for side in e.sides {
                    let players = e.athletes.filter { $0.teamID == side.id && !$0.didNotPlay }
                    candidates += players.sorted { (Int($0.statistics["PTS"] ?? "") ?? 0) > (Int($1.statistics["PTS"] ?? "") ?? 0) }.prefix(3)
                    for key in ["REB","AST","BLK"] {
                        if let player = players.max(by:{(Int($0.statistics[key] ?? "") ?? 0) < (Int($1.statistics[key] ?? "") ?? 0)}),!candidates.contains(where:{$0.id == player.id}) { candidates.append(player) }
                    }
                }
                var rows: [[String:Any]] = []
                for athlete in candidates {
                    var row: [String:Any] = ["id":athlete.id,"name":athlete.name,"teamID":athlete.teamID,"fullGameBoxStatistics":athlete.statistics]
                    for scope in [Query.Scope.close,.last_five,.clutch,.period] {
                        let query = Query(kind:.player,scope:scope,player:athlete.id,period:scope == .period ? 4 : nil,remainingFrom:nil,remainingTo:nil,eventTypes:[])
                        let w = window(query,evidence:e,segmentID:segmentID), indices = w.indices.filter { validTransition($0,in:e) }
                        var metrics = Metrics()
                        for i in indices { add(&metrics,roles(e.points[i],athlete:athlete).0) }
                        row[scope.rawValue] = ["recordedMetrics":metrics.dictionary,"scope":w.label,"completeCoverage":w.complete,"definition":w.definition]
                        metrics.dictionary.values.forEach { numbers.insert(Double($0)) }
                        if scope == .close || scope == .last_five {
                            for i in indices.filter({ roles(e.points[$0],athlete:athlete).0.points > 0 }).suffix(2) { addRef(e.points[i]) }
                        }
                    }
                    if let points = Double(athlete.statistics["PTS"] ?? ""),let total = e.sides.first(where:{$0.id == athlete.teamID})?.score,total > 0 {
                        let share = (points/Double(total)*1000).rounded()/10
                        row["teamPointSharePercent"] = share;numbers.insert(share)
                    }
                    for text in athlete.statistics.values { text.split(whereSeparator:{ !$0.isNumber && $0 != "." }).compactMap { Double($0) }.forEach { numbers.insert($0) } }
                    rows.append(row)
                }
                let clutch = window(Query(kind:.events,scope:.clutch,player:nil,period:nil,remainingFrom:nil,remainingTo:nil,eventTypes:[]),evidence:e,segmentID:nil)
                results.append(["kind":"impact","candidates":rows,"strictClutchExists":clutch.complete ? !clutch.indices.isEmpty : NSNull(),"limits":"候选含双方得分前3及篮板/助攻/盖帽领跑者，不是自动影响力评分。胶着为各节回合前分差≤5，clutch另限末节/加时最后5分钟。局部覆盖时只称已记录的胶着贡献；有全场统计和具体回合仍可给出有依据的个人判断，不能断言唯一胜因或防守战术。"])
                summaries.append("关键球员比较：全场统计＋已核胶着回合＋最后5分钟；判断与事实分开。");scopeLabels.append("本场关键球员比较")
                continue
            }
            let targets = q.player.map { value in e.athletes.filter { matches(value,athlete:$0) } } ?? e.athletes
            if let player = q.player, targets.count != 1 {
                let ambiguous = targets.count > 1 || ["他","她","这个球员"].contains(player)
                let candidates = identities.filter { matches(player, athlete: $0.athlete) }
                let relation = candidates.contains { e.sides.map(\.id).contains($0.athlete.teamID) } ? "球队关系可能相符，但本场名单未核到，不能排除DNP或名单缺失" : "本场名单未匹配；其他有日期的名单仅作身份线索，不能直接认定伤停"
                results.append(["kind":"identity","requestedPlayer":player,"status":ambiguous ? "同名或指代需要澄清" : relation,"currentMatch":e.matchTitle,"matchingPlayers":targets.map { ["id":$0.id,"name":$0.name,"teamID":$0.teamID,"didNotPlay":$0.didNotPlay] },"datedIdentityCandidates":candidates.map(\.json),"nextStep":"先自然说明当前比赛双方，结合姓名/对话与有日期的身份线索核对问题前提；若像在问另一场或另一人，简短澄清。不要把没查到本场统计直接当伤病，更不要用未取得官方引用的模板代替澄清。"])
                clarification = true
                summaries.append("球员与比赛关系：\(player)未唯一匹配本场名单。先核对姓名和比赛，不推断伤病。")
                scopeLabels.append("球员身份与本场关系")
                for item in candidates {
                    entityNames.formUnion([item.athlete.name, item.athlete.originalName, item.teamName])
                    identitySources.append(.init(url:item.source,title:item.athlete.name + " · " + item.teamName + "名单记录",publishedAt:item.matchDate,fetchedAt:item.fetchedAt,pageFetched:true))
                    if let date = NBASchedulePolicy.startDate(item.matchDate) {
                        for zone in [NBASchedulePolicy.calendar.timeZone, TimeZone(secondsFromGMT:0)!] {
                            var calendar = Calendar(identifier:.gregorian);calendar.timeZone = zone
                            let parts = calendar.dateComponents([.year,.month,.day,.hour,.minute], from:date)
                            [parts.year,parts.month,parts.day,parts.hour,parts.minute].compactMap { $0 }.forEach { numbers.insert(Double($0)) }
                        }
                    }
                }
                continue
            }
            if q.kind == .identity {
                results.append(["kind":"identity","currentMatch":e.matchTitle,"matchingPlayers":targets.map { ["id":$0.id,"name":$0.name,"teamID":$0.teamID,"didNotPlay":$0.didNotPlay] },"limit":"这些球员ID在本场名单中，DNP也保留；名单与分钟不等于伤病原因。"])
                summaries.append("已按本场名单核对球员身份，含DNP。"); scopeLabels.append("球员身份与本场关系")
                continue
            }
            if q.kind == .overview {
                results.append(["kind":"overview","facts":try e.questionFacts(segmentID:segmentID),"playerBoxStatistics":targets.map { ["id":$0.id,"name":$0.name,"statistics":$0.statistics] as [String:Any] },"limits":"本场统计不证明防守战术、轮换正负值或伤病。"])
                continue
            }
            if q.kind == .recent {
                if q.player != nil {
                    let appearances = recentRoles.filter { item in targets.contains(where: { $0.id == item.playerID }) }
                    results.append(["kind":"recent","players":targets.map { ["id":$0.id,"name":$0.name,"currentMatchRole":$0.lineupRole] },"cachedAppearances":appearances.map(\.json),"limits":"这是本应用已有且注明日期的有限比赛样本，不代表完整赛季或最新固定轮换。第六人是长期角色，不等于本场替补；本场starter标记优先。需要最新惯常角色时可按需查可靠报道，不能从一个换人事件猜。"])
                    summaries.append("近期出场角色仅含已有比赛样本，每场日期和来源可回查。")
                    for item in appearances { entityNames.insert(item.name); for value in [item.points,item.minutes,item.year,item.month,item.day] { if let value { numbers.insert(Double(value)) } } }
                    for item in appearances { identitySources.append(.init(url:item.source,title:item.name + " · " + item.matchDate + "出场记录",publishedAt:item.matchDate,fetchedAt:item.fetchedAt,pageFetched:true)) }
                    continue
                }
                let teams = e.input?.facts.teams ?? []
                let recent = teams.flatMap { $0.recentGames }
                let data = try JSONEncoder().encode(teams)
                results.append(["kind":"recent","verifiedExistingContext":String(decoding:data,as:UTF8.self),"status":recent.isEmpty ? "缺少已核近期逐场数据，不把本场表现说成近期状态。" : "只含已核的有限近期比赛，不能推断完整近5场。"])
                continue
            }
            if q.kind == .availability {
                results.append(["kind":"availability","players":targets.map { ["id":$0.id,"name":$0.name,"didNotPlay":$0.didNotPlay,"starter":$0.starter as Any? ?? NSNull(),"bench":$0.starter.map { !$0 } as Any? ?? NSNull(),"role":$0.lineupRole,"minutes":$0.statistics["MIN"] ?? "未提供"] as [String:Any] },"limits":"starter为本场boxscore明确标记，未知才null；DNP/分钟不能证明伤病原因或长期第六人角色。无需依赖PBP完整才确认已有首发标记。"])
                scopeLabels.append("本场技术统计首发／替补标记");summaries.append("首发依据boxscore的starter标记，未按换人推断。")
                continue
            }
            if q.kind == .rotation {
                let w = window(q,evidence:e,segmentID:segmentID,frozenSelection:frozenSelection), selected = Set(w.indices)
                var rows: [[String:Any]] = []
                for athlete in targets {
                    let rotation = NBAReviewPlayerRotation.make(athlete:athlete,evidence:e,selected:selected)
                    rows.append(rotation.json)
                    for p in rotation.events { addRef(p) }
                    rotation.numbers.forEach { numbers.insert($0) }
                }
                results.append(["kind":"rotation","scope":w.label,"players":rows,"limits":"换入/换出仅按参与者ID和明确enters...for...文本映射。记录区间不等于完整轮换，不推算阵容正负值；首次已记录换入不一定是实际第一轮替补。starter以boxscore为准。"])
                scopeLabels.append(w.label + " · 换人记录");summaries.append("本场首发标记＋明确换入换出，保留覆盖缺口。")
                continue
            }
            let scopes: [Query.Scope] = q.scope == .critical ? (e.segments.contains(where:{$0.id == segmentID}) ? [.selected,.last_five,.clutch] : [.last_five,.clutch]) : [q.scope]
            for scope in scopes {
                let query = Query(kind:q.kind,scope:scope,player:q.player,period:q.period,remainingFrom:q.remainingFrom,remainingTo:q.remainingTo,eventTypes:q.eventTypes)
                let w = window(query,evidence:e,segmentID:segmentID,frozenSelection:frozenSelection)
                let selected = Set(w.indices)
                var record: [String:Any] = ["kind":q.kind.rawValue,"scope":w.label,"definition":w.definition,"timeCovered":w.covered,"scoreSequenceVerified":w.complete,"recordedEvents":w.indices.count]
                if scope == .clutch { record["qualifyingClutchExists"] = w.complete ? !w.indices.isEmpty : NSNull() }
                if [.last_five,.clutch].contains(scope) {
                    let values = e.points.indices.filter { e.points[$0].period >= 4 && e.points[$0].remaining <= 300 }
                    let margins = values.flatMap { i in [abs(e.points[i].margin)] + (i > 0 ? [abs(e.points[i-1].margin)] : []) }
                    if let low = margins.min(),let high = margins.max() { record["lastFiveRecordedMarginMin"] = low; record["lastFiveRecordedMarginMax"] = high; numbers.insert(Double(low));numbers.insert(Double(high)) }
                }
                if !w.covered && (scope != .game || e.points.isEmpty) { missingEvents = true }
                if q.kind == .lead_changes {
                    var lastLeader: Bool?, changes: [[String:Any]] = []
                    for i in e.points.indices {
                        let p = e.points[i]
                        guard validTransition(i,in:e) else { lastLeader = nil;continue }
                        if p.margin != 0 {
                            let leader = p.margin > 0
                            if let previous = lastLeader, leader != previous, selected.contains(i) {
                                changes.append(["eventID":p.id,"time":p.label,"score":"\(p.away)–\(p.home)","newLeader":leader ? e.home?.name ?? "主队" : e.away?.name ?? "客队"]); addRef(p)
                            }
                            lastLeader = leader
                        }
                    }
                    record["verifiedLeadChanges"] = Array(changes.suffix(10)); record["leadChangeCount"] = changes.count; numbers.insert(Double(changes.count))
                } else if q.kind == .runs {
                    var runs: [[String:Any]] = [], side: String?, start: Int?, end: Int?, total = 0, previousIndex: Int?
                    func flush() {
                        if total >= 4,let a = start,let b = end { let first = e.points[a],last = e.points[b];runs.append(["teamID":side ?? "","unansweredPoints":total,"startAfter":first.label,"end":last.label,"startScore":"\(first.away)–\(first.home)","endScore":"\(last.away)–\(last.home)","startID":first.id,"endID":last.id]);numbers.insert(Double(total));addRef(first);addRef(last) }
                        side = nil;start = nil;end = nil;total = 0
                    }
                    for i in w.indices {
                        let p = e.points[i]
                        if previousIndex != nil && i != previousIndex! + 1 || !validTransition(i,in:e) { flush() }
                        previousIndex = i
                        guard p.scoringPlay,validTransition(i,in:e) else { continue }
                        if side != p.teamID { flush();side = p.teamID;start = max(0,i-1) }
                        total += p.scoreValue;end = i
                    }
                    flush();record["unansweredRuns"] = Array(runs.sorted { ($0["unansweredPoints"] as? Int ?? 0) > ($1["unansweredPoints"] as? Int ?? 0) }.prefix(6))
                    if let (a,b,h,v) = largestSwing(w.indices,evidence:e) {
                        record["verifiedFourMinuteSwing"] = ["startAfter":e.points[a].label,"end":e.points[b].label,"homePoints":h,"awayPoints":v,"netHomeMarginChange":h-v,"startScore":"\(e.points[a].away)–\(e.points[a].home)","endScore":"\(e.points[b].away)–\(e.points[b].home)","startID":e.points[a].id,"endID":e.points[b].id];addRef(e.points[a]);addRef(e.points[b]);[h,v,abs(h-v)].forEach { numbers.insert(Double($0)) }
                    }
                } else {
                    var rows: [[String:Any]] = [], events: [[String:Any]] = [], attributionGaps = 0
                    for athlete in targets {
                        var metrics = Metrics(), allGame = Metrics(), records = 0, byPeriod: [Int:Metrics] = [:]
                        for (index,p) in e.points.enumerated() {
                            let (value,kinds) = roles(p,athlete:athlete); add(&allGame,value)
                            var periodValue = byPeriod[p.period] ?? Metrics();add(&periodValue,value);byPeriod[p.period] = periodValue
                            guard selected.contains(index) else { continue }
                            add(&metrics,value)
                            if !kinds.isEmpty { records += 1 }
                            if normalized(p.text).contains(normalized(athlete.originalName)) && !p.participantIDs.contains(athlete.id) { attributionGaps += 1 }
                            if !kinds.isEmpty && (q.eventTypes.isEmpty || !kinds.isDisjoint(with:q.eventTypes)) && events.count < 12 {
                                events.append(["eventID":p.id,"playerID":athlete.id,"player":athlete.name,"time":p.label,"score":"\(p.away)–\(p.home)","roles":kinds.sorted(),"scoredPoints":value.points,"text":p.text,"attribution":"参与者ID＋事件动作文本核对，助攻不计为本人得分"]);addRef(p)
                            }
                        }
                        if q.player != nil || records > 0 {
                            var row: [String:Any] = ["playerID":athlete.id,"player":athlete.name,"allTypesRecordedMetrics":metrics.dictionary,"recordedPersonalEvents":records,"fullGameBoxStatistics":athlete.statistics,"fullGameRecordedPoints":allGame.points,"fullGamePointsMatchBox":Int(athlete.statistics["PTS"] ?? "") == allGame.points]
                            if q.scope == .game && q.player != nil { row["recordedByPeriod"] = byPeriod.keys.sorted().map { ["period":$0,"metrics":byPeriod[$0]!.dictionary] as [String:Any] } }
                            var percentages: [String:Double] = [:]
                            if metrics.fieldGoalsAttempted > 0 { percentages["fieldGoalPct"] = (Double(metrics.fieldGoalsMade) / Double(metrics.fieldGoalsAttempted) * 1000).rounded() / 10 }
                            if metrics.threesAttempted > 0 { percentages["threePointPct"] = (Double(metrics.threesMade) / Double(metrics.threesAttempted) * 1000).rounded() / 10 }
                            row["recordedPercentages"] = percentages;percentages.values.forEach { numbers.insert($0) };rows.append(row)
                            metrics.dictionary.values.forEach { numbers.insert(Double($0)) };allGame.dictionary.values.forEach { numbers.insert(Double($0)) }
                            for value in athlete.statistics.values { value.split(whereSeparator:{ "-%:".contains($0) }).compactMap { Double($0) }.forEach { numbers.insert($0) } }
                        }
                    }
                    record["players"] = rows;record["events"] = events;record["listedEventTypeFilter"] = q.eventTypes;record["playerAttributionGaps"] = attributionGaps
                    record["countsAreExactForVerifiedScope"] = w.complete && attributionGaps == 0
                    record["limits"] = "计数按ID和明确动作归属；参与同一事件不等于得分者。不计算无完整轮换支持的在场正负值、阵容或防守战术价值。事件列表有界，完整计数在players中。"
                }
                results.append(record);scopeLabels.append(w.label)
                summaries.append(w.label + (w.complete ? " · 时段比分已核。" : " · 仅已记录事件，覆盖需核对。") + w.definition)
            }
        }
        if clarification { requiresOfficial = false }
        if request.queries.allSatisfy({ $0.kind == .identity }) { requiresOfficial = false }
        if let date = e.matchDate { let parts = NBASchedulePolicy.calendar.dateComponents([.year,.month,.day],from:date);[parts.year,parts.month,parts.day].compactMap{$0}.forEach { numbers.insert(Double($0)) } }
        let root: [String:Any] = ["gameID":e.gameID,"matchDate":e.input?.facts.matchDate ?? "未提供","dataAsOf":ISO8601DateFormatter().string(from:e.dataAsOf),"source":e.sourceURL.absoluteString,"queries":results,"needsClarification":clarification,"intent":request.intent.rawValue,"requiresExternalResearch":requiresOfficial]
        let data = try NBAReviewQueryPacket.make(root,athletes:e.athletes,references:refs)
        var local = NBAReviewLocalEvidence(gameID:e.gameID,matchDate:e.input?.facts.matchDate,dataAsOf:e.dataAsOf,summaries:summaries,events:refs)
        if !identitySources.isEmpty { local.identitySources = identitySources.reduce(into:[]) { value, source in if !value.contains(where: { $0.url == source.url }) { value.append(source) } } }
        let uniqueLabels = scopeLabels.reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }
        local.queryScope = request.queries.contains(where:{$0.scope == .critical}) ? "所选片段与末节最后5分钟／clutch口径" : uniqueLabels.isEmpty ? nil : uniqueLabels.joined(separator:" / ")
        return Result(json:String(decoding:data,as:UTF8.self),evidence:local,numbers:numbers,requiresOfficial:requiresOfficial,needsClarification:clarification,missingEvents:missingEvents,entityNames:entityNames)
    }

}

/// At most one public-summary refresh per game in five minutes, only after a
/// query finds missing time coverage. Never scans unrelated matches or news.
actor NBAReviewEvidenceRefresh {
    static let shared = NBAReviewEvidenceRefresh()
    private var lastAttempt: [String:Date] = [:]
    func supplement(_ evidence: NBAReviewEvidence, boxes: NBABoxScoreStore) async -> NBAReviewEvidence? {
        let now = Date()
        guard lastAttempt[evidence.gameID].map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return nil }
        lastAttempt[evidence.gameID] = now
        guard let entry = try? await boxes.load(gameID:evidence.gameID,force:true),
              let refreshed = try? NBAReviewEvidence.make(data:entry.data,gameID:evidence.gameID,dataAsOf:entry.date),
              refreshed.sides.map(\.id) == evidence.sides.map(\.id),refreshed.home?.score == evidence.home?.score,refreshed.away?.score == evidence.away?.score else { return nil }
        return refreshed
    }
}
