import Foundation

struct NBAPlayerProfile: Codable {
    let athlete: Athlete
    let statistics: Statistics?

    struct Athlete: Codable {
        let id: String
        let displayName: String
        let jersey: String?
        let age: Int?
        let displayHeight: String?
        let displayWeight: String?
        let position: Position?
        let team: Team?
        let statsSummary: Summary?
    }
    struct Position: Codable { let abbreviation: String? }
    struct Team: Codable { let abbreviation: String?; let displayName: String? }
    struct Summary: Codable {
        let displayName: String?
        let statistics: [RankedStatistic]?
    }
    struct RankedStatistic: Codable {
        let name: String
        let displayValue: String?
        let rank: Int?
    }
    enum RankTier: Int, CaseIterable {
        case red, gold, purple, blue, green, gray
        init(topPercent: Double) {
            self = topPercent <= 1 ? .red : topPercent <= 5 ? .gold : topPercent <= 10 ? .purple : topPercent <= 25 ? .blue : topPercent <= 50 ? .green : .gray
        }
        var legend: String {
            switch self {
            case .red: return "≤1%"
            case .gold: return "≤5%"
            case .purple: return "≤10%"
            case .blue: return "≤25%"
            case .green: return "≤50%"
            case .gray: return ">50%"
            }
        }
    }
    func leagueRank(_ key: String, career: Bool) -> Int? {
        // Summary rankings belong to its named season/type, never to career totals.
        guard !career, let title = athlete.statsSummary?.displayName?.lowercased(),
              let split = seasonSplit,
              (split == "Regular Season" && title.contains("regular season")) ||
              (split == "Postseason" && title.contains("postseason")) ||
              (split == "Preseason" && title.contains("preseason")),
              let statistic = athlete.statsSummary?.statistics?.first(where: { $0.name == key }),
              let rank = statistic.rank, rank > 0,
              let summaryValue = statistic.displayValue,
              let lhs = Double(summaryValue.replacingOccurrences(of: "%", with: "")),
              let rhs = Double(statistics?.value(key, split: split).replacingOccurrences(of: "%", with: "") ?? ""),
              abs(lhs - rhs) < 0.051 else { return nil }
        return rank
    }
    struct Statistics: Codable {
        let names: [String]?
        let splits: [Split]?
        struct Split: Codable {
            let displayName: String
            let stats: [String]?
        }
        func value(_ key: String, split: String) -> String {
            guard let index = names?.firstIndex(of: key),
                  let values = splits?.first(where: { $0.displayName == split })?.stats,
                  values.indices.contains(index), !values[index].isEmpty,
                  values[index] != "--", values[index] != "-" else { return "—" }
            let value = values[index]
            return key.hasSuffix("Pct") && !value.hasSuffix("%") ? value + "%" : value
        }
    }
    var seasonTitle: String {
        let title = athlete.statsSummary?.displayName ?? ""
        let year = title.split(separator: " ").first.map(String.init) ?? ""
        let prefix = year.first?.isNumber == true ? year + " " : ""
        if title.localizedCaseInsensitiveContains("postseason") { return prefix + "季后赛" }
        if title.localizedCaseInsensitiveContains("preseason") { return prefix + "季前赛" }
        return prefix + "常规赛"
    }
    var seasonSplit: String? {
        statistics?.splits?.first(where: { ["Regular Season", "Postseason", "Preseason"].contains($0.displayName) })?.displayName
    }
    var seasonSplitTitle: String {
        switch seasonSplit {
        case "Postseason": return seasonTitle.replacingOccurrences(of: "常规赛", with: "季后赛")
        case "Preseason": return seasonTitle.replacingOccurrences(of: "常规赛", with: "季前赛")
        default: return seasonTitle
        }
    }
    var measurements: String {
        // ESPN uses feet/inches and pounds. Convert to locally familiar units.
        var parts: [String] = []
        if let age = athlete.age { parts.append("\(age)岁") }
        if let height = athlete.displayHeight {
            let numbers = height.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
            if numbers.count == 2 { parts.append(String(format: "%.0f厘米", (numbers[0] * 12 + numbers[1]) * 2.54)) }
        }
        if let weight = athlete.displayWeight?.split(separator: " ").first.flatMap({ Double($0) }) {
            parts.append(String(format: "%.1f公斤", weight * 0.45359237))
        }
        return parts.joined(separator: " · ")
    }
}

actor NBAPlayerProfileStore {
    static let shared = NBAPlayerProfileStore()
    struct Entry: Codable { let profile: NBAPlayerProfile; let date: Date }
    struct LoadResult {
        let entry: Entry
        let refreshFailed: Bool
        let isStale: Bool
    }
    static let ttl: TimeInterval = 900
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let cache: NBAResourceCache
    private let fetch: Fetch
    private let now: NBAResourceCache.Clock

    init(directory: URL? = nil, now: @escaping NBAResourceCache.Clock = { Date() }, fetch: Fetch? = nil) {
        self.now = now
        self.fetch = fetch ?? { try await Self.request($0) }
        cache = NBAResourceCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBAPlayerProfiles", isDirectory: true), now: now,
            storedDate: { (try? JSONDecoder().decode(Entry.self, from: $0))?.date }) { key, data in
                let entry = try JSONDecoder().decode(Entry.self, from: data)
                guard entry.profile.athlete.id == key else { throw URLError(.cannotParseResponse) }
            }
    }

    func cached(id: String) async -> LoadResult? {
        guard let result = await cache.cached(id) else { return nil }
        return try? value(result)
    }

    func load(id: String, force: Bool = false) async throws -> Entry {
        try await loadResult(id: id, force: force).entry
    }

    func loadResult(id: String, force: Bool = false) async throws -> LoadResult {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw URLError(.badURL) }
        let fetch = self.fetch
        let now = self.now
        let result = try await cache.load(id, ttl: Self.ttl, force: force) {
            let base = "https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/\(id)"
            async let info = fetch(URL(string: base)!)
            async let overview = fetch(URL(string: base + "/overview")!)
            struct Info: Decodable { let athlete: NBAPlayerProfile.Athlete }
            struct Overview: Decodable { let statistics: NBAPlayerProfile.Statistics? }
            let athlete = try JSONDecoder().decode(Info.self, from: await info).athlete
            let stats = try JSONDecoder().decode(Overview.self, from: await overview).statistics
            let entry = Entry(profile: NBAPlayerProfile(athlete: athlete, statistics: stats), date: now())
            return try JSONEncoder().encode(entry)
        }
        return try value(result)
    }

    private func value(_ result: NBAResourceCache.Result) throws -> LoadResult {
        let entry = try JSONDecoder().decode(Entry.self, from: result.entry.data)
        return LoadResult(entry: entry, refreshFailed: result.refreshFailed,
                          isStale: now().timeIntervalSince(entry.date) >= Self.ttl)
    }

    private static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
