import Foundation
import Testing
@testable import MenuScores

@MainActor private final class RecapNotificationSender: NBARecapNotificationSending {
    var status: NBANotificationAuthorization = .allowed
    var sent: [NBARecapNotification] = []
    var sounds: [Bool] = []
    var fail = false
    var suspendAuthorization = false
    var waiter: CheckedContinuation<Void, Never>?
    func authorization() async -> NBANotificationAuthorization {
        if suspendAuthorization { await withCheckedContinuation { waiter = $0 } }
        return status
    }
    func send(_ notification: NBARecapNotification, sound: Bool) throws {
        if fail { throw URLError(.cannotConnectToHost) }
        sent.append(notification); sounds.append(sound)
    }
}

private actor RecapSaveProbe {
    var saved = 0
    func record(_ article: NBARecap, directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent(article.cacheKey + ".json"))
        let copy = try JSONDecoder().decode(NBARecap.self, from: data)
        #expect(copy.text == article.text)
        saved += 1
    }
}

@MainActor struct NBARecapNotificationTests {
    private func article(id: String = "123", key: String = String(repeating: "a", count: 64), model: String = NBATerraClient.editorialModel) -> NBARecap {
        var article = NBARecap(cacheKey: key, gameID: id, model: model,
            text: "主队赢球。\n\n关键回合。", evidenceIDs: ["result"], generatedAt: Date(), dataAsOf: Date(),
            sourceURL: URL(string: "https://example.com")!, inputTokens: nil, outputTokens: nil)
        article.title = "关键球带队获胜"; article.lead = "主队赢球。"; article.paragraphs = ["关键回合。"]
        article.kind = .recap; article.promptVersion = NBATerraClient.promptVersion; article.editorialPasses = 2
        return article
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "NBARecapNotificationTests." + UUID().uuidString)!
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func eachFinalGameNotifiesOnceAcrossRevisionsAndRestart() async throws {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let defaults = defaults(); defaults.set(true, forKey: NBARecapNotificationService.enabledKey)
        let sender = RecapNotificationSender()
        let service = NBARecapNotificationService(file: file, sender: sender, defaults: defaults)
        await service.articleReady(article())
        await service.articleReady(article(key: String(repeating: "b", count: 64)))
        await service.articleReady(article(id: "456"))
        let restarted = NBARecapNotificationService(file: file, sender: sender, defaults: defaults)
        await restarted.articleReady(article())
        #expect(sender.sent.map(\.gameID) == ["123", "456"])
        #expect(sender.sounds == [false, false])
        #expect(sender.sent[0].title == "关键球带队获胜" && sender.sent[0].body == "主队赢球。")
    }

    @Test func draftPregameDisabledAndUnapprovedNotificationsStaySilent() async {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let defaults = defaults(); let sender = RecapNotificationSender()
        let service = NBARecapNotificationService(file: file, sender: sender, defaults: defaults)
        await service.articleReady(article())
        defaults.set(true, forKey: NBARecapNotificationService.enabledKey)
        var draft = article(); draft.editorialPasses = 1; await service.articleReady(draft)
        var pregame = article(); pregame.kind = .pregame; await service.articleReady(pregame)
        var old = article(); old.promptVersion = 3; await service.articleReady(old)
        sender.status = .notDetermined
        await service.articleReady(article())
        #expect(sender.sent.isEmpty)
        #expect(service.message?.contains("系统尚未允许") == true)
    }

    @Test func claimsAreDurableBeforeAuthorizationAndRecheckTheSwitch() async {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let defaults = defaults(); defaults.set(true, forKey: NBARecapNotificationService.enabledKey)
        let sender = RecapNotificationSender(); sender.suspendAuthorization = true
        let service = NBARecapNotificationService(file: file, sender: sender, defaults: defaults)
        let first = Task { await service.articleReady(article()) }
        while sender.waiter == nil { await Task.yield() }
        await service.articleReady(article())
        #expect(sender.sent.isEmpty)
        defaults.set(false, forKey: NBARecapNotificationService.enabledKey)
        sender.waiter?.resume(); await first.value
        #expect(sender.sent.isEmpty)
    }

    @Test func unreadableOrUnwritableLedgerCannotSendAndFailureDoesNotLoop() async throws {
        let defaults = defaults(); defaults.set(true, forKey: NBARecapNotificationService.enabledKey)
        let sender = RecapNotificationSender(); let file = location()
        defer { try? FileManager.default.removeItem(at: file) }
        let unwritable = NBARecapNotificationService(file: file, sender: sender, defaults: defaults,
            write: { _, _ in throw URLError(.cannotWriteToFile) })
        await unwritable.articleReady(article()); #expect(sender.sent.isEmpty)
        try Data("broken".utf8).write(to: file)
        await NBARecapNotificationService(file: file, sender: sender, defaults: defaults).articleReady(article())
        #expect(sender.sent.isEmpty)
        try FileManager.default.removeItem(at: file)
        let service = NBARecapNotificationService(file: file, sender: sender, defaults: defaults)
        sender.fail = true; await service.articleReady(article())
        sender.fail = false; await service.articleReady(article()); #expect(sender.sent.isEmpty)
    }

    @Test func notificationRoutePinsTheExactLocalEditionAndRejectsTraversal() {
        let notification = NBARecapNotification(article())!
        #expect(NBANotificationRoute.destination(userInfo: notification.userInfo, identifier: notification.identifier)
            == .recap(gameID: "123", cacheKey: notification.cacheKey))
        #expect(NBANotificationRoute.destination(userInfo: notification.userInfo, identifier: "foreign") == nil)
        var info = notification.userInfo; info["cacheKey"] = "../article"
        #expect(NBANotificationRoute.destination(userInfo: info, identifier: notification.identifier) == nil)
        info = notification.userInfo; info["eventID"] = "https://example.com"
        #expect(NBANotificationRoute.destination(userInfo: info, identifier: notification.identifier) == nil)
    }

    @Test func acceptedDatedModelEditionsCanNotifyAndOpenFromDisk() async {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let final = article(model: NBATerraClient.editorialModel + "-2026-11-01")
        #expect(NBARecapNotification(final) != nil)
        #expect(NBARecapNotification(article(model: NBATerraClient.editorialModel + "-untrusted")) == nil)
        let store = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
        await store.insertValidated(final)
        let reopened = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
        #expect(await reopened.savedArticle(gameID: final.gameID, cacheKey: final.cacheKey)?.model == final.model)
    }

    @Test func completionHookWaitsForDiskAndCacheReadsDoNotReplayIt() async throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = NBARecapInput(facts: .init(version: 6, kind: .recap, gameID: "123", matchDate: nil,
            teams: [], periods: [], limitations: []), dataAsOf: Date())
        let final = article(key: input.cacheKey); let probe = RecapSaveProbe()
        let store = NBATerraRecapStore(directory: directory, onSaved: { article in
            try? await probe.record(article, directory: directory)
        }) { _ in final }
        _ = try await store.load(input); _ = try await store.load(input)
        #expect(await probe.saved == 1)
        let reopened = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
        #expect(await reopened.savedArticle(gameID: "123", cacheKey: input.cacheKey)?.text == final.text)
        #expect(await reopened.savedArticle(gameID: "456", cacheKey: input.cacheKey) == nil)
        #expect(await reopened.savedArticle(gameID: "123", cacheKey: "../anything") == nil)
        let invalidDirectory = directory.appendingPathComponent(input.cacheKey + ".json")
        let failed = NBATerraRecapStore(directory: invalidDirectory, onSaved: { article in
            try? await probe.record(article, directory: directory)
        }) { _ in final }
        _ = try await failed.load(input)
        #expect(await probe.saved == 1)
    }
}
