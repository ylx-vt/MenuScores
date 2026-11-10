#if DEBUG
import AppKit
import Foundation

/// Explicit local quality evaluation. Public fixtures and response receipts go
/// to the requested directory; production articles and their ledger are untouched.
@MainActor enum NBARecapEditorialEvaluation {
    struct Case: Decodable { let label: String; let file: String }
    struct Ledger: Codable {
        var spentOrReservedUSD = 0.0
        var completed = 0
        let limitUSD = 0.75
    }
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--recap-editorial-evaluate"), args.indices.contains(index + 1) else {
            NSApp.terminate(nil); return
        }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            do {
                let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
                guard (1...2).contains(cases.count) else { throw NBARecapError.invalidData }
                let ledgerFile = directory.appendingPathComponent("validation-ledger.json")
                var ledger = Ledger()
                if FileManager.default.fileExists(atPath: ledgerFile.path) {
                    guard let saved = try? Data(contentsOf: ledgerFile), let prior = try? JSONDecoder().decode(Ledger.self, from: saved) else {
                        throw NBARecapError.budgetUnavailable
                    }
                    ledger = prior
                }
                for (caseIndex, sample) in cases.enumerated() {
                    let input = try NBARecapInput.make(data: Data(contentsOf: directory.appendingPathComponent(sample.file)),
                                                       gameID: sample.label, dataAsOf: Date())
                    try input.json().write(to: directory.appendingPathComponent(sample.label + "-facts.json"), options: .atomic)
                    let draft = try await request(input, draft: nil, model: NBATerraClient.model, name: sample.label + "-draft",
                                                  directory: directory, ledger: &ledger, ledgerFile: ledgerFile)
                    let recheck = args.contains("--editorial-focus-recheck")
                    let models = recheck ? [NBATerraClient.editorialModel] : caseIndex == 0
                        ? [NBATerraClient.model, NBATerraClient.editorialModel, "gpt-6-astra"] : [NBATerraClient.editorialModel]
                    for model in models {
                        _ = try await request(input, draft: draft, model: model, name: sample.label + (recheck ? "-focus-v2-" : "-edit-") + model,
                                              directory: directory, ledger: &ledger, ledgerFile: ledgerFile)
                    }
                }
            } catch {
                let message = (error as? NBARecapError)?.localizedDescription ?? "评估未完成；不自动重试，保留已记费用。"
                try? JSONSerialization.data(withJSONObject: ["error": message]).write(to: directory.appendingPathComponent("failure.json"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }
    private static func request(_ input: NBARecapInput, draft: NBARecap?, model: String, name: String, directory: URL,
                                ledger: inout Ledger, ledgerFile: URL) async throws -> NBARecap {
        let resultFile = directory.appendingPathComponent(name + "-result.json")
        if let saved = try? Data(contentsOf: resultFile), let result = try? JSONDecoder().decode(NBARecap.self, from: saved) { return result }
        let marker = directory.appendingPathComponent(name + "-attempt.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            // A locally rejected completed response may become verifiable after
            // a guardrail repair. Re-parse its receipt without another API call.
            let receipt = try Data(contentsOf: directory.appendingPathComponent(input.cacheKey + "-" + name + ".json"))
            var recovered = try NBATerraClient.parse(receipt, input: input, now: Date(), allowLegacy: false, expectedModel: model)
            let raw = try JSONSerialization.jsonObject(with: receipt) as? [String: Any]
            recovered.requestID = raw?["requestID"] as? String
            try JSONEncoder().encode(recovered).write(to: resultFile, options: .atomic)
            ledger.completed += 1
            try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
            return recovered
        }
        let note = draft.map(NBATerraClient.editorialReviewNote)
        let client = NBATerraClient(authorized: true, observe: { data, response in
            NBATerraClient.savePublicEvidence(data, response: response, input: input, directory: directory, suffix: "-" + name)
        }, requestModel: model)
        let tokens = try await client.inputTokenCount(input, editorialNote: note)
        let reserve = NBATerraAutofill.reserveUSD(inputTokens: tokens, outputTokens: NBATerraClient.maxOutputTokens, model: model)
        guard ledger.spentOrReservedUSD + reserve <= ledger.limitUSD else { throw NBARecapError.dailyBudget }
        ledger.spentOrReservedUSD += reserve
        try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["model": model, "inputTokens": tokens, "reservedUSD": reserve,
            "startedAt": ISO8601DateFormatter().string(from: Date()), "automaticRetries": 0]).write(to: marker, options: .atomic)
        try NBATerraClient.body(for: input, editorialNote: note, model: model)
            .write(to: directory.appendingPathComponent(name + "-request.json"), options: .atomic)
        var settled = false
        do {
            let result = try await client.generate(input, editorialNote: note)
            ledger.spentOrReservedUSD += (result.estimatedUSD ?? reserve) - reserve
            settled = true
            ledger.completed += 1
            try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
            try JSONEncoder().encode(result).write(to: resultFile, options: .atomic)
            return result
        } catch {
            if !settled, let actual = NBATerraClient.observedCost(input, directory: directory, suffix: "-" + name) {
                ledger.spentOrReservedUSD += actual - reserve
                try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
            }
            throw error
        }
    }
}
#endif
