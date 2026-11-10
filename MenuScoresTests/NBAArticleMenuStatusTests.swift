import Foundation
import Testing
@testable import MenuScores

private actor ArticleMenuGate {
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
    var waiting: Bool { waiter != nil }
}

@MainActor struct NBAArticleMenuStatusTests {
    private let now = Date(timeIntervalSince1970: 1_794_268_800)
    private func event(state: String = "post", date: String = "2026-11-10T02:00Z", name: String = "STATUS_FINAL") throws -> Event {
        let status: [String: Any] = ["type": ["state": state, "name": name, "completed": state == "post"]]
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject:
            ["id": "123", "name": "NBA", "date": date, "status": status,
             "competitions": [["status": status, "competitors": []]]]))
    }
    private func job(_ state: String) -> NBATerraAutofill.Job {
        .init(gameID: "123", title: "NBA", kind: .recap, fingerprint: String(repeating: "a", count: 64),
              state: state, message: state, attempts: 1, date: now, estimatedUSD: 0, requestID: nil)
    }
    private func article() -> NBARecap {
        var value = NBARecap(cacheKey: String(repeating: "a", count: 64), gameID: "123", model: NBATerraClient.editorialModel,
            text: "主队取胜。", evidenceIDs: ["result"], generatedAt: now, dataAsOf: now,
            sourceURL: URL(string: "https://example.com")!, inputTokens: nil, outputTokens: nil)
        value.kind = .recap; value.editorialPasses = 2; value.promptVersion = NBATerraClient.promptVersion
        return value
    }

    @Test func kindFollowsTheActualGameAndExpiredPregameCannotStayReadable() throws {
        #expect(NBAArticleMenuStatus.kind(for: try event(), now: now) == .recap)
        #expect(NBAArticleMenuStatus.kind(for: try event(state: "in", name: "STATUS_IN_PROGRESS"), now: now) == nil)
        let future = try event(state: "pre", date: "2099-11-11T04:00Z", name: "STATUS_SCHEDULED")
        #expect(NBAArticleMenuStatus.kind(for: future, now: now) == .pregame)
        #expect(NBAArticleMenuStatus.kind(for: future, now: Date(timeIntervalSince1970: 5_000_000_000)) == nil)
        #expect(NBAArticleMenuStatus.kind(for: try event(name: "STATUS_POSTPONED"), now: now) == nil)
    }

    @Test func completedJobWithoutItsCacheIsNeverReportedReady() {
        let state = NBAArticleMenuStatus.state(kind: .recap, job: job("done"), article: nil)
        #expect(state.phase == .missing && state.canOpen)
        #expect(NBAArticleMenuStatus.state(kind: .recap, job: job("running"), article: nil).phase == .preparing)
        #expect(NBAArticleMenuStatus.state(kind: .recap, job: job("reviewing"), article: nil).phase == .reviewing)
        #expect(NBAArticleMenuStatus.state(kind: .recap, job: job("failed"), article: nil).phase == .incomplete)
        #expect(NBAArticleMenuStatus.state(kind: .recap, job: job("budget"), article: nil).phase == .paused)
    }

    @Test func oldValidArticleRemainsReadableWhenAnUpdateFailed() {
        let state = NBAArticleMenuStatus.state(kind: .recap, job: job("failed"), article: article())
        #expect(state.phase == .ready && state.canOpen && state.article?.gameID == "123")
        #expect(state.action == "读赛后总结")
    }

    @Test func lateRefreshCannotOverwriteANewerReadyState() async throws {
        let gate = ArticleMenuGate(); let final = article(); let game = try event()
        var ledger = NBATerraAutofill.Ledger(); ledger.jobs["123-recap"] = job("done"); let frozen = ledger
        let status = NBAArticleMenuStatus(snapshot: { frozen }, read: { _, _, _ in
            await gate.wait(); return final
        })
        let first = Task { await status.refresh(games: [game], now: now) }
        while !(await gate.waiting) { await Task.yield() }
        let live = try event(state: "in", name: "STATUS_IN_PROGRESS")
        await status.refresh(games: [live], now: now)
        await gate.release(); await first.value
        #expect(status.states["123"] == nil)
    }

    @Test func exactCachedArticleReadChecksIdentityAndNeverGenerates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = article()
        let store = NBATerraRecapStore(directory: directory) { _ in
            Issue.record("Reading match status must not generate an article")
            throw NBARecapError.authorizationRequired
        }
        await store.insertValidated(final)
        #expect(await store.storedArticle(gameID: "123", cacheKey: final.cacheKey, kind: .recap)?.text == final.text)
        #expect(await store.storedArticle(gameID: "456", cacheKey: final.cacheKey, kind: .recap) == nil)
        #expect(await store.storedArticle(gameID: "123", cacheKey: final.cacheKey, kind: .pregame) == nil)
        #expect(await store.storedArticle(gameID: "123", cacheKey: "../article", kind: .recap) == nil)
    }

    @Test func latestSavedEditionWinsOverAnOlderLedgerFingerprint() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = article()
        var latest = NBARecap(cacheKey: String(repeating: "b", count: 64), gameID: old.gameID, model: old.model,
            text: "新稿主线。", evidenceIDs: ["result"], generatedAt: old.generatedAt.addingTimeInterval(60), dataAsOf: now,
            sourceURL: old.sourceURL, inputTokens: nil, outputTokens: nil)
        latest.kind = .recap; latest.editorialPasses = 2; latest.promptVersion = NBATerraClient.promptVersion
        let store = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
        await store.insertValidated(old); await store.insertValidated(latest)
        let reopened = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
        #expect(await reopened.latestArticle(gameID: "123", kind: .recap)?.cacheKey == latest.cacheKey)
        #expect(await reopened.latestArticle(gameID: "123", kind: .pregame) == nil)
        #expect(await reopened.latestArticle(gameID: "456", kind: .recap) == nil)
        var ledger = NBATerraAutofill.Ledger(); ledger.jobs["123-recap"] = job("done"); let frozen = ledger
        let state = NBAArticleMenuStatus(snapshot: { frozen }, read: { id, _, kind in await reopened.latestArticle(gameID: id, kind: kind) })
        await state.refresh(games: [try! event()], now: now)
        #expect(state.states["123"]?.article?.text == "新稿主线。")
    }
}
