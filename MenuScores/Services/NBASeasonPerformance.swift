import Foundation

/// Public box-score EFF, averaged over actual appearances. This is production,
/// not a pace/opponent adjusted or complete measure of player impact.
struct NBASeasonPerformance: Equatable {
    static let algorithmVersion = "eff-estimate-v3-k20-effective10g200m"
    static let minimumGames: Int64 = 3
    static let minimumMinutes: Int64 = 60
    static let requiredCounts = ["points", "rebounds", "assists", "steals", "blocks",
                                 "fieldGoalsAttempted", "fieldGoalsMade",
                                 "freeThrowsAttempted", "freeThrowsMade", "turnovers", "gamesPlayed"]

    let numerator: Int64
    let games: Int64
    let minutes: Int64?

    init?(values: [String: Double]) {
        var counts: [String: Int64] = [:]
        for key in Self.requiredCounts {
            guard let value = values[key], value.isFinite, value >= 0,
                  let count = Int64(exactly: value) else { return nil }
            counts[key] = count
        }
        guard let games = counts["gamesPlayed"], games > 0,
              counts["fieldGoalsMade"]! <= counts["fieldGoalsAttempted"]!,
              counts["freeThrowsMade"]! <= counts["freeThrowsAttempted"]! else { return nil }
        // Work entirely in integers and reject arithmetic overflow instead of
        // silently producing a plausible looking score from malformed input.
        let terms = [counts["points"]!, counts["rebounds"]!, counts["assists"]!,
                     counts["steals"]!, counts["blocks"]!,
                     -(counts["fieldGoalsAttempted"]! - counts["fieldGoalsMade"]!),
                     -(counts["freeThrowsAttempted"]! - counts["freeThrowsMade"]!),
                     -counts["turnovers"]!]
        var total: Int64 = 0
        for term in terms {
            let sum = total.addingReportingOverflow(term)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        self.numerator = total
        self.games = games
        if let value = values["minutes"], value.isFinite, value >= 0 {
            minutes = Int64(exactly: value)
        } else { minutes = nil }
    }

    var value: Double { Double(numerator) / Double(games) }
    var display: String { String(format: "%.1f", value) }
    var meetsMinimumSample: Bool {
        games >= Self.minimumGames && (minutes.map { $0 >= Self.minimumMinutes } ?? false)
    }
    var isPreliminary: Bool { meetsMinimumSample && games < 10 }
    var sampleText: String {
        "\(games)场 · " + (minutes.map { "\($0)分钟" } ?? "累计分钟缺失")
    }

    /// Signed 128-bit cross products preserve exact ties even for large input;
    /// rounded display values never affect sorting.
    func isBetter(than other: Self) -> Bool {
        let lhs = numerator.multipliedFullWidth(by: other.games)
        let rhs = other.numerator.multipliedFullWidth(by: games)
        return lhs.high == rhs.high ? lhs.low > rhs.low : lhs.high > rhs.high
    }
}

/// Exact fractions are compared with signed 128-bit cross products. Intermediate
/// model arithmetic is checked; malformed huge inputs never fall back to Double.
struct NBAExactRatio: Comparable {
    let numerator: Int64
    let denominator: Int64
    init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator > 0)
        self.numerator = numerator; self.denominator = denominator
    }
    var value: Double { Double(numerator) / Double(denominator) }
    var fractionText: String { "\(numerator)/\(denominator)" }
    static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
        let b = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
        return a.high == b.high && a.low == b.low
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
        let b = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
        return a.high == b.high ? a.low < b.low : a.high < b.high
    }
}

struct NBAPriorSeasonData {
    let snapshot: NBALeagueSnapshot?
    var refreshFailed = false
    static let unavailable = Self(snapshot: nil)
    static let failed = Self(snapshot: nil, refreshFailed: true)
}

struct NBASeasonEstimate {
    enum PriorStatus: String {
        case usable = "上季证据有效"
        case noRecord = "无紧邻上季记录"
        case insufficient = "上季证据不足"
        case unavailable = "上季数据暂不可用"
    }
    let current: NBASeasonPerformance
    let prior: NBASeasonPerformance?
    let priorStatus: PriorStatus
    let priorDate: Date?
    let priorRefreshFailed: Bool
    let score: NBAExactRatio
    let historicalGames: NBAExactRatio
    let effectiveGames: NBAExactRatio
    let effectiveMinutes: NBAExactRatio?
    let currentWeight: NBAExactRatio
    let historicalWeight: NBAExactRatio

    init?(current: NBASeasonPerformance, id: String, scope: NBALeaguePercentileStore.Scope,
          priorData: NBAPriorSeasonData) {
        self.current = current
        let snapshot = priorData.snapshot.flatMap { $0.scope == scope.previous ? $0 : nil }
        let record = snapshot?.players[id]
        let previous = record.flatMap { NBASeasonPerformance(values: $0.values) }
        prior = previous
        priorDate = snapshot?.date
        priorRefreshFailed = priorData.refreshFailed
        if snapshot == nil { priorStatus = .unavailable }
        else if record == nil { priorStatus = .noRecord }
        else if previous?.meetsMinimumSample != true { priorStatus = .insufficient }
        else { priorStatus = .usable }

        func multiply(_ a: Int64, _ b: Int64) -> Int64? {
            let x = a.multipliedReportingOverflow(by: b)
            return x.overflow ? nil : x.partialValue
        }
        func add(_ a: Int64, _ b: Int64) -> Int64? {
            let x = a.addingReportingOverflow(b)
            return x.overflow ? nil : x.partialValue
        }
        if priorStatus == .usable, let previous {
            // Cancelling priorGP gives exact, small integer expressions:
            // score=(currentEFFtotal*(p+20)+20*priorEFFtotal)/(currentGP*(p+20)+20*p)
            guard let base = add(previous.games, 20),
                  let history = multiply(20, previous.games),
                  let cg = multiply(current.games, base), let denominator = add(cg, history),
                  let cn = multiply(current.numerator, base), let pn = multiply(20, previous.numerator),
                  let numerator = add(cn, pn) else { return nil }
            score = .init(numerator, denominator)
            historicalGames = .init(history, base)
            effectiveGames = .init(denominator, base)
            currentWeight = .init(cg, denominator)
            historicalWeight = .init(history, denominator)
            if let minutes = current.minutes, let oldMinutes = previous.minutes {
                guard let cm = multiply(minutes, base), let pm = multiply(20, oldMinutes),
                      let total = add(cm, pm) else { return nil }
                effectiveMinutes = .init(total, base)
            } else { effectiveMinutes = nil }
        } else {
            score = .init(current.numerator, current.games)
            historicalGames = .init(0)
            effectiveGames = .init(current.games)
            effectiveMinutes = current.minutes.map { .init($0) }
            currentWeight = .init(1)
            historicalWeight = .init(0)
        }
    }
    var isEligible: Bool {
        current.meetsMinimumSample && effectiveGames >= .init(10) &&
            effectiveMinutes.map { $0 >= .init(200) } == true
    }
    var display: String { String(format: "%.1f", score.value) }
    var evidenceText: String {
        let minutes = effectiveMinutes.map { String(format: "%.1f分钟", $0.value) } ?? "缺失"
        return String(format: "历史等效场次 %.1f场；有效场次 %.1f场；有效分钟 %@",
                      historicalGames.value, effectiveGames.value, minutes)
    }
    var waitingReasons: [String] {
        var result: [String] = []
        if current.games < 3 { result.append("本季实际出场不足3场") }
        if let minutes = current.minutes {
            if minutes < 60 { result.append("本季实际累计分钟不足60") }
        } else { result.append("本季累计分钟缺失或非法") }
        if effectiveGames < .init(10) { result.append("有效证据场次不足10") }
        if effectiveMinutes.map({ $0 < .init(200) }) ?? true { result.append("有效证据分钟不足200") }
        return result
    }
    var priorDescription: String {
        if priorStatus == .unavailable && priorRefreshFailed { return "上季取数失败，暂无可用缓存" }
        if priorRefreshFailed { return "\(priorStatus.rawValue)（使用上季缓存，刷新失败）" }
        return priorStatus.rawValue
    }
}

struct NBASeasonRating {
    let scope: NBALeaguePercentileStore.Scope
    let performance: NBASeasonPerformance?
    let estimate: NBASeasonEstimate?
    let position: NBALeaguePosition?
    let population: Int

    var status: String {
        guard let performance, performance.minutes != nil, estimate != nil else { return "数据不足" }
        return position == nil ? "待观察" : "初步估计"
    }
    var rankText: String {
        position.map { String(format: "第%d / %d名 · 前%.2f%%", $0.rank, $0.population, $0.topPercent) } ?? status
    }
    var helpText: String {
        var text = "近期数据表现估计（基础技术统计）"
        if let estimate { text += " · 估计\(estimate.display) · \(estimate.priorDescription)" }
        if let performance { text += " · 当季原始EFF \(performance.display) · 实际\(performance.sampleText)" }
        text += "。\(rankText)"
        if let estimate {
            let minutesText = estimate.effectiveMinutes.map { String(format: "%.3f", $0.value) } ?? "缺失"
            text += String(format: "。历史权重%.2f%%，有效证据场次%.3f，有效证据分钟%@。",
                           estimate.historicalWeight.value * 100, estimate.effectiveGames.value,
                           minutesText)
            if !estimate.isEligible { text += estimate.waitingReasons.joined(separator: "；") + "。" }
        }
        text += "本季至少3场且累计60分钟，并要求有效证据10场及200分钟；等效量不是独立实际样本，也不是置信保证。"
        if population == 0 { text += "当前没有满足条件的可比球员。" }
        return text + "未准入保留当季数据，无综合档位。不是本季原始场均、本场表现或全面实力，未经早季逐场回测。"
    }
}
