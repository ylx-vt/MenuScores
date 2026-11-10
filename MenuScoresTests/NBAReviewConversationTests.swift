import Foundation
import Testing
@testable import MenuScores

private actor ConversationCalls {
    var histories: [[NBAReviewTurn]] = []
    func add(_ turns: [NBAReviewTurn]) { histories.append(turns) }
    var count: Int { histories.count }
    var last: [NBAReviewTurn] { histories.last ?? [] }
}
struct NBAReviewConversationTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func response(_ text: String = "本场记录显示文班亚马最后5分钟3分。", game: String = "401909901") -> NBAReviewAnswer {
        .init(gameID: game, text: text, sources: [], citations: [], generatedAt: Date(timeIntervalSince1970: 1793510000), requestID: "req_fixture_" + text, responseID: nil, usage: nil, searched: false)
    }
    private func fixture() throws -> Data { try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json")) }
    @Test func completeTurnsDraftAndOriginalEvidenceSurviveAFreshStore() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = NBAReviewConversationStore(directory:dir)
        var doc = try await store.load(gameID:"401909901")
        var turn = NBAReviewTurn(question:"他关键时刻怎样？",answer:response(),contextLabel:"Q4最后5分钟")
        turn.evidenceFingerprint = "facts-one";turn.selectedSegmentID = "focus";turn.selectedPointID = "play-1"
        doc.turns = [turn];doc.draft = "那他上半场呢？";doc.revision = 1;doc.selectedSegmentID = "focus"
        try await store.save(doc)
        let restored = try await NBAReviewConversationStore(directory:dir).load(gameID:"401909901")
        #expect(restored.turns.first?.id == turn.id);#expect(restored.turns.first?.question == turn.question)
        #expect(restored.turns.first?.answer.generatedAt == turn.answer.generatedAt)
        #expect(restored.turns.first?.evidenceFingerprint == "facts-one");#expect(restored.draft == doc.draft)
        #expect(try await store.load(gameID:"123").turns.isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent("401909901.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func staleSnapshotsCannotEraseCompletedTurnsAndNoAutomaticPruningOccurs() async throws {
        let dir = root();defer { try? FileManager.default.removeItem(at:dir) }
        let store = NBAReviewConversationStore(directory:dir)
        var doc = try await store.load(gameID:"401909901");doc.turns = (0..<80).map { NBAReviewTurn(question:"第\($0)轮",answer:response()) };doc.revision = 10
        try await store.save(doc)
        var old = doc;old.turns = [];old.revision = 9;try await store.save(old)
        #expect(try await store.load(gameID:doc.gameID).turns.count == 80)
        old.revision = 11
        await #expect(throws: NBAReviewConversationStore.Failure.self) { try await store.save(old) }
        #expect(try await store.load(gameID:doc.gameID).turns.count == 80)
    }
    @Test func corruptOrCrossGameFilesArePreservedAndSecretsAreNotWritten() async throws {
        let dir = root();defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let path = dir.appendingPathComponent("401909901.json"), broken = Data("not-json".utf8)
        try broken.write(to:path)
        let store = NBAReviewConversationStore(directory:dir)
        await #expect(throws:NBAReviewConversationStore.Failure.self) { try await store.load(gameID:"401909901") }
        #expect(try Data(contentsOf:path) == broken)
        var doc = NBAReviewConversationStore.Document(gameID:"123");doc.draft = "API key: fixture-private";doc.revision = 1
        await #expect(throws:NBAReviewConversationStore.Failure.self) { try await store.save(doc) }
        #expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("123.json").path))
        doc.draft = "正常问题";doc.turns = [.init(question:"你好",answer:response())]
        await #expect(throws:NBAReviewConversationStore.Failure.self) { try await store.save(doc) }
    }
    @Test func legacyAnswersAreRetainedWithoutInventingUnstoredQuestions() async throws {
        let dir = root();defer { try? FileManager.default.removeItem(at:dir) }
        let legacy = dir.appendingPathComponent("answers"), history = dir.appendingPathComponent("history")
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:history,withIntermediateDirectories:true)
        let first = response("已缓存的旧回答"),second = response("另一个旧回答")
        try JSONEncoder().encode(first).write(to:legacy.appendingPathComponent("one.json"));try JSONEncoder().encode(second).write(to:legacy.appendingPathComponent("two.json"))
        try JSONEncoder().encode([first.requestID!:"用户已核实的原问"]).write(to:history.appendingPathComponent("legacy-question-map.json"))
        let store = NBAReviewConversationStore(directory:history,legacyAnswers:legacy),doc = try await store.load(gameID:"401909901")
        #expect(doc.turns.count == 2);#expect(doc.turns.contains { $0.questionKnown && $0.question == "用户已核实的原问" })
        #expect(doc.turns.contains { !$0.questionKnown && $0.question == "历史回答（原问未保存）" })
    }
    @Test @MainActor func modelColdRestartRestoresDialogueAndUsesItForTheNextPronoun() async throws {
        let dir = root();defer { try? FileManager.default.removeItem(at:dir) }
        let data = try fixture(), calls = ConversationCalls(), answer = response()
        func model() -> NBAReviewPanelModel {
            NBAReviewPanelModel(gameID:"401909901",boxes:NBABoxScoreStore(directory:dir.appendingPathComponent("box"),fetch:{_ in data}),articles:NBATerraRecapStore{ _ in throw NBARecapError.network },questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:dir.appendingPathComponent("history")),ask:{ _,_,_,_,history in await calls.add(history);return answer })
        }
        let first = model();await first.load();first.draft = "文班亚马关键时刻怎样？";first.submit()
        for _ in 0..<100 { if !first.asking { break };try await Task.sleep(nanoseconds:5_000_000) }
        #expect(first.turns.count == 1);first.draft = "不是说他，我指另一位";first.leave();try await Task.sleep(nanoseconds:50_000_000)
        let second = model();await second.load()
        #expect(second.turns.count == 1);#expect(second.draft == "不是说他，我指另一位")
        second.draft = "他最后5分钟呢？";second.submit()
        for _ in 0..<100 { if !second.asking { break };try await Task.sleep(nanoseconds:5_000_000) }
        #expect(second.turns.count == 2);#expect(await calls.last.first?.question == "文班亚马关键时刻怎样？")
        #expect(await calls.count == 2)
    }
    @Test @MainActor func interruptedAndCancelledQuestionsRestoreAsDraftsWithoutFakeAnswers() async throws {
        let dir = root();defer { try? FileManager.default.removeItem(at:dir) }
        let store = NBAReviewConversationStore(directory:dir.appendingPathComponent("history"))
        var doc = try await store.load(gameID:"401909901");doc.revision = 1
        doc.attempt = .init(id:UUID(),question:"谁在这一段得分？",startedAt:Date(),state:"pending",contextLabel:"Q2",evidenceFingerprint:"old")
        try await store.save(doc)
        let data = try fixture(),calls = ConversationCalls()
        let model = NBAReviewPanelModel(gameID:doc.gameID,boxes:NBABoxScoreStore(directory:dir.appendingPathComponent("box"),fetch:{_ in data}),articles:NBATerraRecapStore{ _ in throw NBARecapError.network },questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:dir.appendingPathComponent("history")),ask:{ _,_,_,_,h in await calls.add(h);try await Task.sleep(nanoseconds:100_000_000);throw NBARecapError.network })
        await model.load();#expect(model.turns.isEmpty);#expect(model.draft == "谁在这一段得分？");#expect(model.historyAttempt?.state == "interrupted");#expect(await calls.count == 0)
        model.submit();model.cancelQuestion();try await Task.sleep(nanoseconds:200_000_000)
        #expect(model.turns.isEmpty);#expect(model.historyAttempt?.state == "cancelled")
        let restored = try await NBAReviewConversationStore(directory:dir.appendingPathComponent("history")).load(gameID:doc.gameID)
        #expect(restored.turns.isEmpty);#expect(restored.attempt?.state == "cancelled");#expect(restored.draft == "谁在这一段得分？")
    }
    @Test func longHistoryRetainsBoundedOlderCorrectionsAndCacheKeysReflectThem() throws {
        var turns = (0..<30).map { NBAReviewTurn(question:"第\($0)轮问题",answer:response(String(repeating:"已有事实",count:100))) }
        turns[0] = .init(question:"不是文班，我指的是福克斯",answer:response("已核对为福克斯"))
        let older = NBAReviewConversationStore.olderContext(turns)
        #expect(older.contains("福克斯"));#expect(older.count <= 1400)
        let e = try NBAReviewEvidence.make(data:fixture(),gameID:"401909901",dataAsOf:Date())
        let body = try JSONSerialization.jsonObject(with:NBAReviewQuestionClient.body(evidence:e,segmentID:nil,question:"那他呢？",turns:turns,search:false)) as! [String:Any]
        let messages = body["input"] as! [[String:Any]]
        #expect(messages.contains { ($0["content"] as? String)?.contains("不是文班，我指的是福克斯") == true })
        #expect(messages.count <= 11)
        let before = NBAReviewQuestionClient.key(evidence:e,segmentID:nil,question:"他呢",turns:turns)
        turns[0] = .init(question:"不是福克斯，我指的是文班",answer:response("已更正"))
        #expect(before != NBAReviewQuestionClient.key(evidence:e,segmentID:nil,question:"他呢",turns:turns))
    }
}
