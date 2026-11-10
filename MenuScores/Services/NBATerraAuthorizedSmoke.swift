#if DEBUG
import AppKit
import Foundation

/// Exactly the two human-authorized requests. No credential reaches arguments,
/// stdout or the evidence files. Attempt markers prevent accidental reruns.
@MainActor enum NBATerraAuthorizedSmoke {
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--terra-authorized-smoke"), args.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            for name in ["final", "pregame"] {
                let attempt = directory.appendingPathComponent(name + "-attempt.json")
                guard !FileManager.default.fileExists(atPath: attempt.path) else { continue }
                do {
                    let file = directory.appendingPathComponent(name + ".json")
                    let data = try Data(contentsOf: file)
                    let summary = try JSONDecoder().decode(NBABoxScore.self, from: data)
                    guard let id = summary.header?.id else { throw NBARecapError.invalidData }
                    let date = (try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
                    let input = try NBARecapInput.makeArticle(data: data, gameID: id, dataAsOf: date)
                    let body = try NBATerraClient.body(for: input)
                    guard body.count <= NBATerraClient.maxRequestBytes else { throw NBARecapError.invalidData }
                    try input.json().write(to: directory.appendingPathComponent(name + "-facts.json"), options: .atomic)
                    let outputLimit = NBATerraClient.maxOutputTokens(for: input.facts.kind)
                    let attemptFacts: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date()),
                        "model": NBATerraClient.model, "kind": input.facts.kind.rawValue, "inputBytesUpperBound": body.count,
                        "maxOutputTokens": outputLimit, "automaticRetries": 0,
                        "conservativeCostBoundUSD": (Double(body.count + 500) * 1.25 + Double(outputLimit) * 5) / 1_000_000]
                    try JSONSerialization.data(withJSONObject: attemptFacts,
                        options: [.prettyPrinted, .sortedKeys]).write(to: attempt, options: .atomic)
                    let client = NBATerraClient(authorized: true, observe: { responseData, http in
                        // Never save request headers or raw error messages (some
                        // authentication errors can quote credentials).
                        var safe: [String: Any] = ["httpStatus": http.statusCode]
                        if let requestID = http.value(forHTTPHeaderField: "x-request-id") { safe["requestID"] = requestID }
                        if let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                            for field in ["id", "model", "status", "usage", "output", "incomplete_details"] {
                                if let value = response[field] { safe[field] = value }
                            }
                            if let error = response["error"] as? [String: Any], let code = error["code"] as? String,
                               code.range(of: #"^[a-z_]{1,80}$"#, options: .regularExpression) != nil { safe["errorCode"] = code }
                        }
                        try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
                            .write(to: directory.appendingPathComponent(name + "-response.json"), options: .atomic)
                    })
                    let result = try await client.generate(input)
                    try JSONEncoder().encode(result).write(to: directory.appendingPathComponent(name + "-result.json"), options: .atomic)
                } catch {
                    let message: String
                    if error is NBARecapError || error is NBAOpenAICredential.Failure { message = error.localizedDescription }
                    else { message = "本次测试未完成；请检查已记录的非敏感状态，不自动重试。" }
                    try? JSONSerialization.data(withJSONObject: ["error": message, "automaticRetries": 0], options: [.prettyPrinted])
                        .write(to: directory.appendingPathComponent(name + "-failure.json"), options: .atomic)
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
