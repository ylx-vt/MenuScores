import Foundation
import Testing
@testable import MenuScores

private actor ReviewBackgroundGate {
    var entered = false, calls = 0
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async { calls += 1;entered = true;await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume();continuation = nil }
}
struct NBAReviewBackgroundTests {
    private func data() throws -> Data { try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json")) }
    private func response(_ e: NBAReviewEvidence,_ text: String) -> NBAReviewAnswer { .init(gameID:e.gameID,text:text,sources:[],citations:[],generatedAt:Date(),requestID:"req_offline",responseID:nil,usage:nil,searched:false) }
    @Test @MainActor func appSessionFinishesAfterViewLeavesSwitchesGameAndReloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let data = try data(),gate = ReviewBackgroundGate(),history = NBAReviewConversationStore(directory:root.appendingPathComponent("history"))
        let boxes = NBABoxScoreStore(directory:root.appendingPathComponent("box"),fetch:{_ in data})
        let sessions = NBAReviewSessions { id in NBAReviewPanelModel(gameID:id,boxes:boxes,articles:NBATerraRecapStore{_ in throw NBARecapError.network},questions:NBAReviewQuestionStore(),history:history,ask:{ e,_,_,_,_ in await gate.wait();return response(e,"哈珀本场首发。") }) }
        var model: NBAReviewPanelModel? = sessions.session(gameID:"401909901");await model!.load();model!.draft = "哈珀本场首发吗？";model!.submit();model!.submit()
        for _ in 0..<200 { if await gate.entered { break };try await Task.sleep(nanoseconds:1_000_000) }
        #expect(model!.asking);#expect(model!.conversationCount == 1)
        let pending = try await NBAReviewConversationStore(directory:root.appendingPathComponent("history")).load(gameID:"401909901")
        #expect(pending.attempt?.state == "pending");#expect(pending.attempt?.question == "哈珀本场首发吗？")
        let identity = ObjectIdentifier(model!);model!.leave();model = nil
        _ = sessions.session(gameID:"401909899") // switching does not cancel the first game's task
        let returned = sessions.session(gameID:"401909901");#expect(ObjectIdentifier(returned) == identity)
        await returned.load(force:true);#expect(returned.asking)
        await gate.release()
        for _ in 0..<200 { if !returned.asking { break };try await Task.sleep(nanoseconds:2_000_000) }
        #expect(returned.turns.count == 1);#expect(returned.historyAttempt == nil);#expect(await gate.calls == 1)
        let restored = try await NBAReviewConversationStore(directory:root.appendingPathComponent("history")).load(gameID:"401909901")
        #expect(restored.turns.count == 1 && restored.attempt == nil)
    }
    @Test @MainActor func failedBackgroundAttemptPersistsItsQuestionAndErrorAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let data = try data(),gate = ReviewBackgroundGate()
        func make() -> NBAReviewPanelModel { NBAReviewPanelModel(gameID:"401909901",boxes:NBABoxScoreStore(directory:root.appendingPathComponent("box"),fetch:{_ in data}),articles:NBATerraRecapStore{_ in throw NBARecapError.network},questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:root.appendingPathComponent("history")),ask:{_,_,_,_,_ in await gate.wait();throw NBARecapError.timeout}) }
        let model = make();await model.load();model.draft = "这场谁最关键？";model.submit()
        for _ in 0..<200 { if await gate.entered { break };try await Task.sleep(nanoseconds:1_000_000) }
        model.leave();await gate.release()
        for _ in 0..<200 { if !model.asking { break };try await Task.sleep(nanoseconds:2_000_000) }
        let restored = make();await restored.load()
        #expect(restored.historyAttempt?.state == "failed");#expect(restored.historyAttempt?.errorMessage?.contains("超时") == true)
        #expect(restored.hasConversation && restored.conversationCount == 1);#expect(restored.turns.isEmpty)
        #expect(restored.draft == "这场谁最关键？");#expect(await gate.calls == 1)
    }
    @Test @MainActor func explicitCancellationRemainsDistinctFromViewDisappearance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let data = try data(),gate = ReviewBackgroundGate()
        let model = NBAReviewPanelModel(gameID:"401909901",boxes:NBABoxScoreStore(directory:root.appendingPathComponent("box"),fetch:{_ in data}),articles:NBATerraRecapStore{_ in throw NBARecapError.network},questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:root.appendingPathComponent("history")),ask:{ e,_,_,_,_ in await gate.wait();try Task.checkCancellation();return response(e,"取消后不能写入的回答") })
        await model.load();model.draft = "请分析本场";model.submit()
        for _ in 0..<200 { if await gate.entered { break };try await Task.sleep(nanoseconds:1_000_000) }
        model.leave();#expect(model.asking);model.cancelQuestion();await gate.release()
        try await Task.sleep(nanoseconds:30_000_000)
        #expect(!model.asking && model.turns.isEmpty);#expect(model.historyAttempt?.state == "cancelled")
        let restored = try await NBAReviewConversationStore(directory:root.appendingPathComponent("history")).load(gameID:"401909901")
        #expect(restored.attempt?.state == "cancelled" && restored.turns.isEmpty)
    }
}
