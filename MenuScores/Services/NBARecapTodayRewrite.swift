#if DEBUG
import AppKit
import Foundation

/// An explicitly requested, once-per-game rewrite of archived current-day
/// recaps. Uses the production two-pass pipeline and production daily ledger.
@MainActor enum NBARecapTodayRewrite {
    struct Manifest: Decodable {
        struct Item: Decodable {
            let gameID: String; let oldFile: String; let summaryFile: String
            let dataAsOf: Date; let oldCacheKey: String
            let styleOnlyCacheKey: String?
        }
        let day: String; let cases: [Item]
    }
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--recap-today-rewrite"), args.indices.contains(index + 1) else {
            NSApp.terminate(nil); return
        }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                guard manifest.day == NBAHistoryStore.dayKey(Date(), calendar: NBASchedulePolicy.calendar),
                      (1...15).contains(manifest.cases.count), Set(manifest.cases.map(\.gameID)).count == manifest.cases.count else {
                    throw NBARecapError.invalidData
                }
                var inputs: [(Manifest.Item, NBARecapInput, NBARecap)] = []
                for item in manifest.cases {
                    let data = try Data(contentsOf: directory.appendingPathComponent(item.summaryFile))
                    let input = try NBARecapInput.make(data: data, gameID: item.gameID, dataAsOf: item.dataAsOf)
                    let old = try JSONDecoder().decode(NBARecap.self, from: Data(contentsOf: directory.appendingPathComponent(item.oldFile)))
                    guard old.gameID == item.gameID, old.cacheKey == item.oldCacheKey,
                          input.compatibleCacheKeys.contains(old.cacheKey),
                          let date = input.facts.matchDate.flatMap(NBASchedulePolicy.startDate),
                          NBAHistoryStore.dayKey(date, calendar: NBASchedulePolicy.calendar) == manifest.day else { throw NBARecapError.invalidData }
                    if let styleKey = item.styleOnlyCacheKey {
                        guard input.compatibleCacheKeys.contains(styleKey) else { throw NBARecapError.invalidData }
                    }
                    guard try NBATerraClient.body(for: input).count <= NBATerraClient.maxRequestBytes else { throw NBARecapError.invalidData }
                    try input.json().write(to: directory.appendingPathComponent(item.gameID + "-facts.json"), options: .atomic)
                    inputs.append((item, input, old))
                }
                try write(["day": manifest.day, "verifiedSameFacts": inputs.count, "dryRun": args.contains("--dry-run")],
                          to: directory.appendingPathComponent("preflight.json"))
                if !args.contains("--dry-run") {
                    let beforeFile = directory.appendingPathComponent("ledger-before.json")
                    let before: NBATerraAutofill.Ledger
                    if FileManager.default.fileExists(atPath: beforeFile.path) {
                        before = try JSONDecoder().decode(NBATerraAutofill.Ledger.self, from: Data(contentsOf: beforeFile))
                    } else {
                        before = await NBATerraAutofill.shared.snapshot()
                        try JSONEncoder().encode(before).write(to: beforeFile, options: .atomic)
                    }
                    if args.contains("--recover-completed-editorial") {
                        for (item, _, _) in inputs {
                            let job = await NBATerraAutofill.shared.snapshot().jobs[item.gameID + "-recap"]
                            if job?.state == "failed", job?.completedPasses == 1,
                               job?.passModel == NBATerraClient.editorialModel {
                                try await NBATerraAutofill.shared.recoverRecordedResponse(gameID: item.gameID, kind: .recap)
                            }
                        }
                    }
                    var rows: [[String: Any]] = []
                    for (item, input, _) in inputs {
                        var row: [String: Any] = ["gameID": item.gameID, "oldCacheKey": item.oldCacheKey, "newCacheKey": input.cacheKey]
                        let marker = directory.appendingPathComponent(item.gameID + "-rewrite-attempt.json")
                        do {
                            let result: NBARecap
                            if let saved = await NBATerraRecapStore.live.cached(input, allowLegacy: false) { result = saved }
                            else {
                                if FileManager.default.fileExists(atPath: marker.path) {
                                    let retryMarker = directory.appendingPathComponent(item.gameID + "-confirmed-rejection-retry.json")
                                    let job = await NBATerraAutofill.shared.snapshot().jobs[item.gameID + "-recap"]
                                    guard args.contains("--retry-confirmed-rejection"),
                                          !FileManager.default.fileExists(atPath: retryMarker.path),
                                          job?.state == "failed", job?.usageKnown == true, job?.completedPasses == 0,
                                          job?.passModel == NBATerraClient.model else { throw NBARecapError.incomplete }
                                    let receipt = try Data(contentsOf: NBATerraRecapStore.evidenceDirectory.appendingPathComponent(input.cacheKey + "-draft.json"))
                                    let raw = try JSONSerialization.jsonObject(with: receipt) as? [String: Any]
                                    guard raw?["httpStatus"] as? Int == 200, raw?["status"] as? String == "completed" else { throw NBARecapError.incomplete }
                                    try receipt.write(to: directory.appendingPathComponent(item.gameID + "-rejected-draft-receipt.json"), options: .atomic)
                                    try write(["gameID": item.gameID, "startedAt": ISO8601DateFormatter().string(from: Date()),
                                               "reason": "人工核对已完成回执后的一次显式重跑", "automaticRetries": 0], to: retryMarker)
                                }
                                try write(["gameID": item.gameID, "startedAt": ISO8601DateFormatter().string(from: Date()),
                                           "cacheKey": input.cacheKey, "automaticRetries": 0], to: marker)
                                result = try await NBATerraRecapStore.live.load(input, generateOverride: { input in
                                    try await NBATerraAutofill.shared.budgetedGenerate(input)
                                })
                            }
                            guard result.editorialPasses == 2, result.model == NBATerraClient.editorialModel,
                                  result.promptVersion == NBATerraClient.promptVersion(for: .recap) else { throw NBARecapError.invalidResponse }
                            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent(item.gameID + "-new.json"), options: .atomic)
                            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("NBATerraArticles-v2/" + result.cacheKey + ".json")
                            let persisted = try JSONDecoder().decode(NBARecap.self, from: Data(contentsOf: cache))
                            guard persisted.responseID == result.responseID else { throw NBARecapError.invalidData }
                            row["state"] = "done"; row["title"] = result.title
                            row["workflowEstimatedUSD"] = result.workflowEstimatedUSD
                            row["requestID"] = result.requestID; row["draftRequestID"] = result.draftRequestID
                        } catch {
                            row["state"] = "failed"
                            row["error"] = (error as? NBARecapError)?.localizedDescription ?? "本场未完成；保留已计费用，不自动重试。"
                        }
                        rows.append(row)
                        let current = await NBATerraAutofill.shared.snapshot()
                        try JSONEncoder().encode(current).write(to: directory.appendingPathComponent("ledger-after.json"), options: .atomic)
                        try write(["day": manifest.day, "target": inputs.count, "completed": rows.filter { $0["state"] as? String == "done" }.count,
                                   "rows": rows, "incrementalSpentOrReservedUSD": current.spentUSD - before.spentUSD],
                                  to: directory.appendingPathComponent("batch-result.json"))
                    }
                }
            } catch {
                try? write(["error": (error as? NBARecapError)?.localizedDescription ?? "批次准备未通过，没有自动重试。"],
                           to: directory.appendingPathComponent("batch-failure.json"))
            }
            NSApp.terminate(nil)
        }
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
    }
}
#endif
