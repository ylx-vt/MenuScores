#if DEBUG
import AppKit
import Foundation

private actor NBATerraVerificationCounts {
    var counts = 0
    var generations = 0
    func counted() { counts += 1 }
    func generated() { generations += 1 }
}

@MainActor enum NBATerraBatchRunner {
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--terra-autofill-now"), args.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent("batch-schedule.json"))
                let events = try JSONDecoder().decode(ScoreboardResponse.self, from: data).events
                if args.contains("--recover-daily-only") {
                    for event in NBATerraAutofill.candidates(events, now: Date()) {
                        let kind: NBARecapInput.Kind = event.status.type.state == "post" ? .recap : .pregame
                        let ledger = await NBATerraAutofill.shared.snapshot()
                        if ledger.jobs[event.id + "-" + kind.rawValue]?.state == "failed" {
                            try await NBATerraAutofill.shared.recoverRecordedResponse(gameID: event.id, kind: kind)
                        }
                    }
                    try await dailyReport(events: events, directory: directory)
                } else if args.contains("--daily-catch-up") {
                    await NBATerraAutofill.shared.process(events: NBATerraAutofill.candidates(events, now: Date()))
                    try await dailyReport(events: events, directory: directory)
                } else if args.contains("--daily-verify") {
                    try await dailyReport(events: events, directory: directory)
                } else if args.contains("--verify-cached-only") {
                    try await verifyCached(events: events, directory: directory)
                } else if args.contains("--finish-editorial-review") {
                    let ledger = await NBATerraAutofill.shared.snapshot()
                    for job in ledger.jobs.values where job.state == "failed" && !["401909279", "401909281"].contains(job.gameID) {
                        try? await NBATerraAutofill.shared.recoverRecordedResponse(gameID: job.gameID, kind: job.kind)
                    }
                    for (id, note) in [
                        ("401909279", "上一版同一句先说篮网末节追回10分，又说仍未缩小分差，逻辑矛盾。比分证据是三节落后26分、最终落后16分：准确说缩小分差但未能扭转败局，或直接删去这句。不要编造其他过程。"),
                        ("401909281", "上一版称巴恩斯41分仍未能帮猛龙缩小最终分差，无法据总分判断这种个人得分的反事实效果。只可说巴恩斯41分仍告负，不宣称他的得分没有缩小分差。保持统计事实，正文不要虚构反事实因果。")
                    ] {
                        try? await NBATerraAutofill.shared.repairWording(gameID: id, note: note)
                    }
                } else if args.contains("--recover-editorial-902") {
                    try await NBATerraAutofill.shared.recoverRecordedResponse(gameID: "401909902", kind: .pregame)
                } else if args.contains("--editorial-review") {
                    await NBATerraAutofill.shared.process(events: events.filter { ["401909285", "401909902"].contains($0.id) }, editorialUpgrade: true, approvedRoundLimitUSD: 0.15)
                } else if args.contains("--editorial-all") {
                    await NBATerraAutofill.shared.process(events: events, editorialUpgrade: true, approvedRoundLimitUSD: 0.15)
                } else if args.contains("--only-unrequested-902") {
                    // This game hit the reservation guard before any generation.
                    // Failed/uncertain requests are never retried by this path.
                    await NBATerraAutofill.shared.process(events: events.filter { $0.id == "401909902" }, resumeBudget: true)
                } else {
                    await NBATerraAutofill.shared.process(events: events, seedUSD: 0.0044355)
                }
                let ledger = await NBATerraAutofill.shared.snapshot()
                let output = args.contains("--finish-editorial-review") ? "editorial-finished-result.json" : args.contains("--editorial-review") ? "editorial-review-result.json" : args.contains("--editorial-all") ? "editorial-all-result.json" : args.contains("--only-unrequested-902") ? "remaining-902-result.json" : "batch-result.json"
                try JSONEncoder().encode(ledger).write(to: directory.appendingPathComponent(output), options: .atomic)
            } catch {
                let ns = error as NSError
                let report: [String: Any] = ["error": "批次未完成，未自动重试", "type": String(reflecting: Swift.type(of: error)),
                    "domain": ns.domain, "code": ns.code, "reason": (error as? NBARecapError)?.localizedDescription ?? "本地文件或数据读取失败"]
                try? JSONSerialization.data(withJSONObject: report).write(to: directory.appendingPathComponent("batch-failure.json"))
            }
            NSApp.terminate(nil)
        }
    }
    private static func dailyReport(events: [Event], directory: URL) async throws {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let store = NBATerraRecapStore(directory: cache.appendingPathComponent("NBATerraArticles-v2")) { _ in throw NBARecapError.authorizationRequired }
        let ledger = await NBATerraAutofill.shared.snapshot()
        var rows: [[String: Any]] = []
        for event in NBATerraAutofill.candidates(events, now: Date()) {
            let kind: NBARecapInput.Kind = event.status.type.state == "post" ? .recap : .pregame
            let job = ledger.jobs[event.id + "-" + kind.rawValue]
            var row: [String: Any] = ["gameID": event.id, "kind": kind.rawValue, "title": event.name,
                "state": job?.state ?? "missing", "message": job?.message ?? "无准备状态"]
            if let data = try? Data(contentsOf: cache.appendingPathComponent("NBABoxScores/" + event.id + ".json")),
               let input = try? NBARecapInput.makeArticle(data: data, gameID: event.id, dataAsOf: Date()),
               let article = await store.cached(input, allowLegacy: false) {
                row["ready"] = true; row["cacheKey"] = article.cacheKey; row["requestID"] = article.requestID ?? ""
                row["articleTitle"] = article.title; row["lead"] = article.lead; row["paragraphs"] = article.paragraphs
                row["model"] = article.model; row["estimatedUSD"] = article.estimatedUSD
            } else { row["ready"] = false }
            rows.append(row)
        }
        let report: [String: Any] = ["day": ledger.day, "dailyLimitUSD": NBATerraAutofill.dailyLimitUSD,
            "spentOrReservedUSD": ledger.spentUSD, "tokenCountRequests": ledger.tokenCountRequests ?? 0,
            "rows": rows, "ready": rows.filter { $0["ready"] as? Bool == true }.count,
            "target": rows.count, "remaining": rows.filter { $0["ready"] as? Bool != true }.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("daily-result.json"), options: .atomic)
    }
    private static func verifyCached(events: [Event], directory: URL) async throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let ledgerData = try Data(contentsOf: appSupport.appendingPathComponent("MenuScores/TerraAutofill-v1.json"))
        let qa = directory.appendingPathComponent("cold-cache-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        var dataByID: [String: Data] = [:]
        var rows: [[String: Any]] = []
        let articles = NBATerraRecapStore(directory: caches.appendingPathComponent("NBATerraArticles-v2")) { _ in throw NBARecapError.authorizationRequired }
        for event in events {
            let data = try Data(contentsOf: caches.appendingPathComponent("NBABoxScores/" + event.id + ".json"))
            dataByID[event.id] = data
            let input = try NBARecapInput.makeArticle(data: data, gameID: event.id, dataAsOf: Date())
            guard let result = await articles.cached(input, allowLegacy: false), !result.isLegacy,
                  result.cacheKey == input.cacheKey, result.gameID == event.id, result.model == NBATerraClient.model,
                  result.title != nil, result.lead != nil, (2...3).contains(result.paragraphs?.count ?? 0),
                  let date = input.facts.matchDate.flatMap(NBASchedulePolicy.startDate) else { throw NBARecapError.invalidData }
            let day = NBAHistoryStore.dayKey(date, calendar: NBASchedulePolicy.calendar)
            guard day == (input.facts.kind == .recap ? "20261031" : "20261101") else { throw NBARecapError.invalidData }
            rows.append(["gameID": event.id, "kind": input.facts.kind.rawValue, "BeijingDay": day,
                         "cacheKey": result.cacheKey, "model": result.model, "promptVersion": result.promptVersion ?? 0,
                         "source": result.sourceURL.absoluteString, "requestID": result.requestID ?? ""])
        }
        let counter = NBATerraVerificationCounts(), payloads = dataByID
        let boxes = NBABoxScoreStore(directory: qa.appendingPathComponent("boxes"), fetch: { id in
            guard let data = payloads[id] else { throw NBARecapError.invalidData }; return data
        })
        let file = qa.appendingPathComponent("ledger.json"); try ledgerData.write(to: file, options: .atomic)
        let count: NBATerraAutofill.Count = { _ in await counter.counted(); throw NBARecapError.authorizationRequired }
        let generate: NBATerraAutofill.Generate = { _, _ in await counter.generated(); throw NBARecapError.authorizationRequired }
        let enabled = NBATerraAutofill(file: file, boxes: boxes, articles: articles, count: count, generate: generate, enabled: { true })
        await enabled.process(events: events)
        let disabled = NBATerraAutofill(file: qa.appendingPathComponent("disabled.json"), boxes: boxes, articles: articles,
            count: count, generate: generate, enabled: { false })
        await disabled.process(events: events)
        let report: [String: Any] = ["verifiedCurrentArticles": rows.count, "rows": rows,
            "coldStartAutomaticTokenCountRequests": await counter.counts, "coldStartAutomaticGenerations": await counter.generations,
            "automaticSwitchOffNoWork": await disabled.snapshot().jobs.isEmpty, "keychainReads": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("current-cache-verification.json"), options: .atomic)
    }
}
#endif
