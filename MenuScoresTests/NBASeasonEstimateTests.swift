import Foundation
import Testing
@testable import MenuScores

struct NBASeasonEstimateTests {
    private let currentScope = NBALeaguePercentileStore.Scope(year: 2027, type: 2)
    private func counts(_ total: Double = 10, gp: Double = 10, minutes: Double = 200) -> [String: Double] {
        var v = Dictionary(uniqueKeysWithValues: NBASeasonPerformance.requiredCounts.map { ($0, 0.0) })
        v["points"] = max(total, 0); v["turnovers"] = max(-total, 0)
        v["gamesPlayed"] = gp; v["minutes"] = minutes
        return v
    }
    private func board(_ rows: [String: [String: Double]], year: Int = 2027, type: Int = 2, date: Date = Date()) -> NBALeagueSnapshot {
        .init(scope: .init(year: year, type: type), date: date,
              players: rows.mapValues { .init(values: $0, displays: [:]) }, qualified: [:])
    }
    private struct Fixture: Decodable { let snapshot: NBALeagueSnapshot }
    private func fixture(_ year: Int) throws -> NBALeagueSnapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-season-\(year)-regular.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
    }
    private func estimate(_ current: [String: Double], prior: [String: Double]?, year: Int = 2026, type: Int = 2) throws -> NBASeasonEstimate {
        let raw = try #require(NBASeasonPerformance(values: current))
        return try #require(NBASeasonEstimate(current: raw, id: "x", scope: currentScope,
                                              priorData: .init(snapshot: board(prior.map { ["x": $0] } ?? [:], year: year, type: type))))
    }

    @Test func approvedFormulaAndUnifiedEvidenceBoundaries() throws {
        let target = try estimate(counts(67, gp: 5, minutes: 121), prior: counts(1136, gp: 80, minutes: 1751))
        #expect(target.score == .init(1471, 105))
        #expect(target.historicalGames == .init(16))
        #expect(target.effectiveGames == .init(21))
        #expect(target.effectiveMinutes == .init(2356, 5))
        #expect(target.historicalWeight == .init(16, 21))
        #expect(target.evidenceText == "历史等效场次 16.0场；有效场次 21.0场；有效分钟 471.2分钟")
        #expect(target.isEligible)
        let kessler = try estimate(counts(109, gp: 5, minutes: 152), prior: counts(124, gp: 5, minutes: 154))
        #expect(kessler.score == .init(347, 15))
        #expect(kessler.historicalGames == .init(4))
        #expect(kessler.effectiveGames == .init(9) && !kessler.isEligible)
        let beringer = try estimate(counts(0, gp: 5, minutes: 78), prior: counts(10, gp: 40, minutes: 314))
        #expect(beringer.effectiveMinutes == .init(548, 3) && !beringer.isEligible)
        let maluach = try estimate(counts(0, gp: 3, minutes: 70), prior: counts(10, gp: 46, minutes: 411))
        #expect(maluach.effectiveMinutes == .init(2140, 11) && !maluach.isEligible)
        let justEnough = try estimate(counts(0, gp: 10, minutes: 200), prior: nil)
        #expect(justEnough.isEligible && justEnough.historicalGames == .init(0))
        #expect(justEnough.currentWeight == .init(1))
        #expect(try !estimate(counts(0, gp: 9, minutes: 200), prior: nil).isEligible)
        #expect(try !estimate(counts(0, gp: 10, minutes: 199), prior: nil).isEligible)
        // Prior existence cannot bypass the same effective evidence minimum.
        #expect(try !estimate(counts(20, gp: 3, minutes: 60), prior: counts(30, gp: 3, minutes: 60)).isEligible)
        #expect(try !estimate(counts(20, gp: 2, minutes: 200), prior: counts(30, gp: 80, minutes: 2000)).isEligible)
        #expect(try !estimate(counts(20, gp: 3, minutes: 59), prior: counts(30, gp: 80, minutes: 2000)).isEligible)
        #expect(NBAExactRatio(999, 100) < .init(10))
        #expect(NBAExactRatio(19999, 100) < .init(200))
    }

    @Test func missingWeakFailedAndWrongSeasonPriorsRemainDistinct() throws {
        let early = counts(60, gp: 3, minutes: 60)
        let missing = try estimate(early, prior: nil)
        #expect(missing.priorStatus == .noRecord && missing.historicalGames == .init(0))
        #expect(!missing.isEligible)
        for prior in [counts(100, gp: 2, minutes: 100), counts(100, gp: 3, minutes: 59)] {
            let weak = try estimate(early, prior: prior)
            #expect(weak.priorStatus == .insufficient && weak.historicalGames == .init(0) && !weak.isEligible)
        }
        var bad = counts(); bad["rebounds"] = nil
        #expect(try estimate(early, prior: bad).priorStatus == .insufficient)
        #expect(try estimate(early, prior: counts(), year: 2025).priorStatus == .unavailable)
        #expect(try estimate(early, prior: counts(), type: 3).priorStatus == .unavailable)
        let raw = try #require(NBASeasonPerformance(values: counts(0)))
        let failed = try #require(NBASeasonEstimate(current: raw, id: "x", scope: currentScope, priorData: .failed))
        #expect(failed.priorStatus == .unavailable && failed.priorRefreshFailed)
        #expect(failed.priorDescription.contains("取数失败"))
        #expect(failed.isEligible && failed.score == .init(0)) // Pure current 10GP/200MIN is allowed and labelled.
        #expect(missing.priorDescription.contains("无紧邻上季记录"))
    }

    @Test func exactTiesNegativesAndOverflowNeverUseRoundedDoubles() throws {
        let prior = board(["a": counts(200, gp: 20, minutes: 400), "b": counts(200, gp: 20, minutes: 400),
                           "c": counts(200, gp: 20, minutes: 400)], year: 2026)
        let current = board(["a": counts(40, gp: 4, minutes: 80), "b": counts(50, gp: 5, minutes: 100),
                             "c": counts(400001, gp: 40000, minutes: 800000)])
        let grades = NBAStatGrades(snapshot: current, priorData: .init(snapshot: prior))
        #expect(grades.overall["a"]?.rank == 2 && grades.overall["b"]?.rank == 2)
        #expect(grades.overall["c"]?.rank == 1)
        #expect(grades.ratings["a"]?.estimate?.display == grades.ratings["c"]?.estimate?.display)
        let negative = try estimate(counts(-10, gp: 10, minutes: 200), prior: counts(-20, gp: 20, minutes: 400))
        #expect(negative.score == .init(-1) && negative.isEligible)
        let huge = try #require(NBASeasonPerformance(values: counts(pow(2, 62), gp: 10, minutes: 200)))
        #expect(NBASeasonEstimate(current: huge, id: "a", scope: currentScope, priorData: .init(snapshot: prior)) == nil)
        var invalid = counts(); invalid["fieldGoalsMade"] = 2; invalid["fieldGoalsAttempted"] = 1
        #expect(NBASeasonPerformance(values: invalid) == nil)
    }

    /// RFC4180 reader: the golden file is the exact v3 CSV already delivered to
    /// the user, not expected values regenerated from the production Swift code.
    private func csv(_ text: String) -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\u{feff}", with: ""))
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == "," && !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r\n" || c == "\r") && !quoted {
                row.append(field); if !row.allSatisfy(\.isEmpty) { rows.append(row) }; row = []; field = ""
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    private func fraction(_ text: String) throws -> NBAExactRatio {
        let parts = text.split(separator: "/")
        return .init(try #require(Int64(parts[0])), parts.count == 2 ? try #require(Int64(parts[1])) : 1)
    }

    @Test func everyCurrentPlayerMatchesDeliveredV3CSVAndBothHistoricalFixtures() throws {
        let current = try fixture(2027), previous = try fixture(2026), older = try fixture(2025)
        let grades = NBAStatGrades(snapshot: current, priorData: .init(snapshot: previous))
        #expect(current.players.count == 425 && previous.players.count == 582 && older.players.count == 569)
        #expect(grades.overall.count == 236 && grades.ratings.count == 425)
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-estimate-v3-reference.csv")
        let records = csv(try String(contentsOf: path, encoding: .utf8))
        let headers = try #require(records.first)
        #expect(records.count == 426)
        var seen: Set<String> = []
        for cells in records.dropFirst() {
            #expect(cells.count == headers.count)
            let row = Dictionary(uniqueKeysWithValues: zip(headers, cells))
            let id = try #require(row["球员ID"]); seen.insert(id)
            let rating = try #require(grades.ratings[id]), estimate = try #require(rating.estimate)
            #expect(estimate.score == (try fraction(row["估计精确值"]!)))
            #expect(estimate.historicalGames == (try fraction(row["历史等效场次精确值"]!)))
            #expect(estimate.effectiveGames == (try fraction(row["有效证据场次精确值"]!)))
            #expect(estimate.effectiveMinutes == (try fraction(row["有效证据分钟精确值"]!)))
            #expect(rating.performance?.games == Int64(row["本季实际GP"]!))
            #expect(rating.performance?.minutes == Int64(row["本季实际累计分钟"]!))
            if row["状态"] == "初步估计" {
                #expect(rating.position?.rank == Int(row["名次"]!))
                #expect(rating.position?.population == 236 && rating.status == "初步估计")
                let color = ["红", "金", "紫", "蓝", "绿", "灰"][rating.position!.tier.rawValue]
                #expect(color == row["档位"])
            } else { #expect(rating.position == nil && rating.status == "待观察") }
        }
        #expect(seen == Set(current.players.keys))
        #expect(grades.overall["4278580"]?.rank == 124)
        #expect(grades.overall["4433136"] == nil && grades.overall["5279133"] == nil)
        #expect(grades.ratings.values.filter { $0.estimate?.priorStatus == .noRecord }.count == 57)
        // The two completed-season fixtures exercise the same adjacent-prior
        // model; unavailable earlier history uses only the unified pure-current gate.
        let historical = NBAStatGrades(snapshot: previous, priorData: .init(snapshot: older))
        #expect(historical.ratings.count == 582)
        #expect(historical.ratings.values.allSatisfy { $0.performance != nil && $0.estimate != nil })
        #expect(historical.overall["3112335"]?.rank == 1)
        #expect(NBAStatGrades(snapshot: older).overall.count == 456)
        // Wrong-stage/older inputs never produce the v3 prior-ranked early pool.
        #expect(NBAStatGrades(snapshot: current, priorData: .init(snapshot: older)).overall.isEmpty)
    }

    private func response(scope: NBALeaguePercentileStore.Scope, duplicate: Bool = false) throws -> NBALeaguePercentileStore.Response {
        let row: [String: Any] = ["athlete": ["id": "x"], "categories": [["name": "general", "values": [10, 200, 100]]]]
        let object: [String: Any] = ["pagination": ["count": duplicate ? 2 : 1, "page": 1, "pages": 1],
                                    "requestedSeason": ["year": scope.year, "type": ["type": scope.type]],
                                    "categories": [["name": "general", "names": ["gamesPlayed", "minutes", "points"]]],
                                    "athletes": duplicate ? [row, row] : [row]]
        return try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private actor FetchLog {
        var scopes: [NBALeaguePercentileStore.Scope] = []
        var qualification: [Bool] = []
        func record(_ scope: NBALeaguePercentileStore.Scope, qualified: Bool) { scopes.append(scope); qualification.append(qualified) }
        func count() -> Int { scopes.count }
        func allScopes() -> [NBALeaguePercentileStore.Scope] { scopes }
        func flags() -> [Bool] { qualification }
    }

    @Test func priorFetchIsSingleBatchCoalescedAndStageIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FetchLog()
        let store = NBALeaguePercentileStore(directory: directory.appendingPathComponent("legacy"), priorDirectory: directory.appendingPathComponent("prior")) { scope, _, qualified in
            await log.record(scope, qualified: qualified)
            try await Task.sleep(nanoseconds: 5_000_000)
            return try response(scope: scope)
        }
        async let a = store.loadPrior(for: currentScope)
        async let b = store.loadPrior(for: currentScope)
        let result = await [a,b]
        #expect(result.allSatisfy { $0.snapshot?.scope == currentScope.previous && !$0.refreshFailed })
        #expect(await log.count() == 1)
        #expect(await log.flags() == [false])
        _ = await store.loadPrior(for: currentScope)
        #expect(await log.count() == 1)
        let postseason = NBALeaguePercentileStore.Scope(year: 2027, type: 3)
        #expect(await store.loadPrior(for: postseason).snapshot?.scope == postseason.previous)
        #expect(await log.allScopes() == [currentScope.previous!, postseason.previous!])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("prior/2026-2.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("prior/2026-3.json").path))
    }

    @Test func failedFetchPreservesCompatibleLegacyCacheAndNeverUsesOlderYear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old = board(["x": counts()], year: 2026, date: .distantPast)
        let bytes = try JSONEncoder().encode(old)
        let path = legacy.appendingPathComponent("2026-2.json")
        try bytes.write(to: path)
        let store = NBALeaguePercentileStore(directory: legacy, priorDirectory: directory.appendingPathComponent("prior")) { _,_,_ in throw URLError(.notConnectedToInternet) }
        let cached = await store.loadPrior(for: currentScope)
        #expect(cached.refreshFailed && cached.snapshot?.scope == currentScope.previous)
        #expect(try Data(contentsOf: path) == bytes) // No destructive migration.
        let failed = await store.loadPrior(for: .init(year: 2028, type: 2))
        #expect(failed.snapshot == nil && failed.refreshFailed) // Does not use available 2026 in place of 2027.
        let raw = try #require(NBASeasonPerformance(values: counts()))
        let estimate = try #require(NBASeasonEstimate(current: raw, id: "x", scope: currentScope, priorData: cached))
        #expect(estimate.priorStatus == .usable && estimate.priorDescription.contains("刷新失败"))
    }

    @Test func mismatchedOrDuplicatePriorResponsesFailWithoutInventingNoRecord() async throws {
        for duplicate in [false,true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = NBALeaguePercentileStore(directory: directory, priorDirectory: directory.appendingPathComponent("prior")) { scope,_,_ in
                try response(scope: duplicate ? scope : .init(year: 2025, type: scope.type), duplicate: duplicate)
            }
            let result = await store.loadPrior(for: currentScope)
            #expect(result.snapshot == nil && result.refreshFailed)
        }
    }

    @Test func successfulEmptyHistoryDiffersFromNetworkFailureAndSourceFieldsRemainRaw() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NBALeaguePercentileStore(directory: directory, priorDirectory: directory.appendingPathComponent("prior")) { scope,_,_ in
            let object: [String: Any] = ["pagination": ["count": 0, "page": 1, "pages": 1],
                                        "requestedSeason": ["year": scope.year, "type": ["type": scope.type]],
                                        "categories": [], "athletes": []]
            return try JSONDecoder().decode(NBALeaguePercentileStore.Response.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let result = await store.loadPrior(for: currentScope)
        #expect(result.snapshot != nil && !result.refreshFailed)
        let current = board(["early": counts(30, gp: 3, minutes: 60), "enough": counts(100)])
        let grades = NBAStatGrades(snapshot: current, priorData: result)
        #expect(grades.ratings["early"]?.estimate?.priorStatus == .noRecord)
        #expect(grades.ratings["early"]?.status == "待观察" && grades.overall["early"] == nil)
        #expect(grades.overall["enough"] != nil)
        #expect(grades.ratings["enough"]?.estimate?.historicalWeight == .init(0))
        #expect(current.players["early"]?.values["points"] == 30)
        let failed = NBAStatGrades(snapshot: current, priorData: .failed)
        #expect(failed.ratings["early"]?.estimate?.priorStatus == .unavailable)
        #expect(failed.ratings["enough"]?.estimate?.priorDescription.contains("取数失败") == true)
        #expect(failed.overall["enough"] != nil) // Explicit pure-current path, never old GP3/MIN60 ranking.
    }
}
