import Foundation

struct NBAStatDistribution {
    let values: [Double]
    var lowerIsBetter = false
    func position(for value: Double) -> NBALeaguePosition? {
        guard value.isFinite, !values.isEmpty else { return nil }
        let better = values.filter { lowerIsBetter ? $0 < value - 0.0001 : $0 > value + 0.0001 }.count
        let worse = values.filter { lowerIsBetter ? $0 > value + 0.0001 : $0 < value - 0.0001 }.count
        // An external game value can be below every reference value.
        return NBALeaguePosition(rank: min(better + 1, values.count), population: values.count, worseCount: worse)
    }
}

struct NBAStatGrades {
    static let algorithmVersion = NBASeasonPerformance.algorithmVersion
    let distributions: [String: NBAStatDistribution]
    let overall: [String: NBALeaguePosition]
    let ratings: [String: NBASeasonRating]
    let scope: NBALeaguePercentileStore.Scope

    init(snapshot: NBALeagueSnapshot, priorData: NBAPriorSeasonData = .unavailable) {
        var distributions: [String: NBAStatDistribution] = [:]
        for key in NBALeagueSnapshot.keys + ["avgMinutes"] {
            let allowed = snapshot.qualified[key] ?? snapshot.qualified["avgPoints"] ?? []
            let lowerIsBetter = key == "avgTurnovers"
            let values = snapshot.players.compactMap { id, player -> Double? in
                guard (player.values["gamesPlayed"] ?? 0) > 0,
                      let value = player.values[key], value.isFinite, value >= 0 else { return nil }
                guard allowed.contains(id) else { return lowerIsBetter ? .infinity : 0 }
                return value
            }
            distributions[key] = .init(values: values, lowerIsBetter: lowerIsBetter)
        }
        self.distributions = distributions
        self.scope = snapshot.scope
        let performances = snapshot.players.compactMapValues { NBASeasonPerformance(values: $0.values) }
        let estimates = performances.reduce(into: [String: NBASeasonEstimate]()) { result, item in
            result[item.key] = NBASeasonEstimate(current: item.value, id: item.key, scope: snapshot.scope, priorData: priorData)
        }
        let eligible = estimates.filter { $0.value.isEligible }
        let overall = eligible.mapValues { score in
            let better = eligible.values.filter { $0.score > score.score }.count
            let worse = eligible.values.filter { $0.score < score.score }.count
            return NBALeaguePosition(rank: better + 1, population: eligible.count, worseCount: worse)!
        }
        self.overall = overall
        self.ratings = Dictionary(uniqueKeysWithValues: snapshot.players.keys.map { id in
            (id, NBASeasonRating(scope: snapshot.scope, performance: performances[id], estimate: estimates[id], position: overall[id], population: eligible.count))
        })
    }

    func performancePosition(value: Double, key: String) -> NBALeaguePosition? {
        guard let distribution = distributions[key] else { return nil }
        if value == 0 && key != "avgTurnovers" {
            return .init(rank: distribution.values.count, population: distribution.values.count, worseCount: 0)
        }
        return distribution.position(for: value)
    }

    static func isEmphasized(_ tier: NBAPlayerProfile.RankTier?) -> Bool {
        tier == .red || tier == .gold || tier == .purple
    }

    static func number(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]),
           minutes >= 0, (0..<60).contains(seconds) { return minutes + seconds / 60 }
        return Double(text.replacingOccurrences(of: "%", with: ""))
    }
}
