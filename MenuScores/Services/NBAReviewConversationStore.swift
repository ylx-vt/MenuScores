import Foundation

enum NBAReviewPrivacy {
    static func containsCredential(_ value: String) -> Bool {
        let pattern = #"(?i)(sk-|bearer\s+[a-z0-9._-]{8,}|(?:api[_ -]?key|password|密码|密钥)\s*[:：=]|-----BEGIN .*PRIVATE KEY)"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// User-authorized local conversation storage, separate from regenerable
/// response caches. Never prunes turns or sends anything by itself.
actor NBAReviewConversationStore {
    struct Attempt: Codable, Sendable {
        let id: UUID; let question: String; let startedAt: Date
        var state: String // pending / failed / cancelled / interrupted
        let contextLabel: String?; let evidenceFingerprint: String?
        var errorMessage: String? = nil
    }
    struct Document: Codable, Sendable {
        var version = 1
        let gameID: String
        var revision = 0
        var turns: [NBAReviewTurn] = []
        var draft = ""
        var selectedSegmentID: String?
        var selectedPointID: String?
        var attempt: Attempt?
        var updatedAt = Date()
    }
    enum Failure: Error, LocalizedError {
        case invalid, unsafe, tooLarge, unreadable, write
        var errorDescription: String? {
            switch self {
            case .unsafe: "检测到凭据样式文字，该草稿不会保存或发送。请移除密钥或密码。"
            case .tooLarge: "本场对话超过本地安全读取上限，原记录保留，未自动删除或继续调用。"
            case .invalid, .unreadable: "本场历史暂时无法安全读取，原文件保留，未覆盖。"
            case .write: "本场对话暂未保存成功，未自动重发模型请求。请重试保存。"
            }
        }
    }
    static var live: NBAReviewConversationStore? { AppRuntime.suppressesLiveWork ? nil : shared }
    private static let shared = NBAReviewConversationStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuScores/Conversations-v1"),
        legacyAnswers: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NBAReviewAnswers-v1/answers-v2"))
    let directory: URL
    private let legacyAnswers: URL?
    private var documents: [String: Document] = [:]
    static let maxBytes = 16_000_000
    init(directory: URL, legacyAnswers: URL? = nil) { self.directory = directory; self.legacyAnswers = legacyAnswers }
    private func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 20 && id.allSatisfy(\.isNumber) }
    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    func load(gameID: String) throws -> Document {
        guard validID(gameID) else { throw Failure.invalid }
        if let saved = documents[gameID] { return saved }
        let path = file(gameID)
        if FileManager.default.fileExists(atPath: path.path) {
            guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxBytes else { throw Failure.tooLarge }
            guard let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(Document.self, from: data),
                  value.version == 1, value.gameID == gameID, value.turns.allSatisfy({ $0.answer.gameID == gameID }) else { throw Failure.unreadable }
            guard !NBAReviewPrivacy.containsCredential(value.draft), value.turns.allSatisfy({ !NBAReviewPrivacy.containsCredential($0.question) && !NBAReviewPrivacy.containsCredential($0.answer.text) }) else { throw Failure.unsafe }
            documents[gameID] = value; return value
        }
        var value = Document(gameID: gameID)
        // Old caches contain answers, not reversible original question text.
        // Preserve those answers honestly; an optional local migration map can
        // recover only questions explicitly supplied by the user, by request ID.
        if let legacyAnswers {
            let mapping = (try? Data(contentsOf: directory.appendingPathComponent("legacy-question-map.json"))).flatMap { try? JSONDecoder().decode([String:String].self, from: $0) } ?? [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: legacyAnswers, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            var seen: Set<String> = []
            for path in files where path.pathExtension == "json" {
                guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 100_000,
                      let data = try? Data(contentsOf: path), let answer = try? JSONDecoder().decode(NBAReviewAnswer.self, from: data),
                      answer.gameID == gameID, !answer.text.isEmpty, !NBAReviewPrivacy.containsCredential(answer.text),
                      seen.insert(answer.requestID ?? path.lastPathComponent).inserted else { continue }
                let original = answer.requestID.flatMap { mapping[$0] }.flatMap { NBAReviewPrivacy.containsCredential($0) ? nil : $0 }
                var turn = NBAReviewTurn(question: original ?? "历史回答（原问未保存）", answer: answer, contextLabel: answer.localEvidence?.queryScope)
                turn.askedAt = answer.generatedAt; turn.questionKnown = original != nil
                value.turns.append(turn)
            }
            value.turns.sort { $0.answer.generatedAt < $1.answer.generatedAt }
        }
        documents[gameID] = value
        return value
    }
    func save(_ value: Document) throws {
        guard validID(value.gameID), value.version == 1, value.turns.allSatisfy({ $0.answer.gameID == value.gameID }) else { throw Failure.invalid }
        guard !NBAReviewPrivacy.containsCredential(value.draft), value.turns.allSatisfy({ !NBAReviewPrivacy.containsCredential($0.question) && !NBAReviewPrivacy.containsCredential($0.answer.text) }),
              !NBAReviewPrivacy.containsCredential(value.attempt?.question ?? "") else { throw Failure.unsafe }
        if documents[value.gameID] == nil { _ = try load(gameID: value.gameID) }
        if let current = documents[value.gameID] {
            if value.revision < current.revision { return }
            guard Set(current.turns.map(\.id)).isSubset(of: Set(value.turns.map(\.id))) else { throw Failure.invalid }
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file(value.gameID), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(value.gameID).path)
            documents[value.gameID] = value
        } catch { throw Failure.write }
    }
    /// Verbatim bounded older excerpts; never invents a model-written summary.
    /// Full turns and evidence remain available locally by their stable IDs.
    static func olderContext(_ turns: [NBAReviewTurn]) -> String {
        let older = Array(turns.dropLast(4)), recent = older.suffix(6)
        let corrections = older.filter { $0.question.range(of: "不是|更正|指的是|说错", options: .regularExpression) != nil }.suffix(4)
        var seen: Set<UUID> = [], rows: [String] = []
        for turn in Array(corrections) + Array(recent) where seen.insert(turn.id).inserted {
            rows.append("[\(turn.id)] \(ISO8601DateFormatter().string(from: turn.askedAt)) 原问\(turn.questionKnown ? "" : "未保存")：\(turn.question.prefix(100))；当时回答摘录：\(turn.answer.historyText.prefix(160))")
        }
        return String(rows.joined(separator: "\n").prefix(1400))
    }
}
