import Foundation
import Testing
@testable import MenuScores

private actor AutofillCounts {
    var counts = 0
    var generations = 0
    func counted() { counts += 1 }
    func generated() { generations += 1 }
}

private final class TerraTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}

struct NBATerraAutofillTests {
    private func fixture(id: String = "123", date: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))) throws -> (Data, Event) {
        let status: [String: Any] = ["type": ["name": "STATUS_SCHEDULED", "state": "pre", "completed": false]]
        let sides: [[String: Any]] = [
            ["id": "1", "team": ["id": "1", "displayName": "测试主队", "links": []], "homeAway": "home"],
            ["id": "2", "team": ["id": "2", "displayName": "测试客队", "links": []], "homeAway": "away"]]
        let match: [String: Any] = ["date": date, "competitors": sides, "status": status]
        let data = try JSONSerialization.data(withJSONObject: ["header": ["id": id, "competitions": [match]]])
        let event = try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject:
            ["id": id, "date": date, "name": "匿名比赛", "status": status, "competitions": [match]]))
        return (data, event)
    }
    private func mock(_ input: NBARecapInput, model: String = NBATerraClient.model,
                      inputTokens: Int = 500, outputTokens: Int = 200, text: String = "单测内容，不是真实模型输出。") -> NBARecap {
        NBARecap(cacheKey: input.cacheKey, gameID: input.facts.gameID, model: model, text: text,
                 evidenceIDs: [input.facts.kind == .recap ? "result" : "schedule"],
                 generatedAt: Date(), dataAsOf: input.dataAsOf, sourceURL: input.sourceURL, inputTokens: inputTokens, outputTokens: outputTokens)
    }
    private func finalFixture() throws -> (Data, Event) {
        let (data, _) = try fixture()
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var header = root["header"] as! [String: Any]
        var match = (header["competitions"] as! [[String: Any]])[0]
        let status: [String: Any] = ["type": ["name": "STATUS_FINAL", "state": "post", "completed": true]]
        var sides = match["competitors"] as! [[String: Any]]
        sides[0]["score"] = "110"; sides[1]["score"] = "100"
        match["competitors"] = sides; match["status"] = status
        header["competitions"] = [match]; root["header"] = header
        let totals: [[String: Any]] = sides.map { ["team": $0["team"]!, "statistics": [["name": "totalRebounds", "displayValue": "40"]]] }
        let players: [[String: Any]] = sides.enumerated().map { index, side in
            let athlete: [String: Any] = ["athlete": ["id": String(11 + index), "displayName": "测试球员"], "stats": ["20", "5", "3"]]
            let statistics: [String: Any] = ["names": ["PTS", "REB", "AST"], "athletes": [athlete]]
            return ["team": side["team"]!, "statistics": [statistics]]
        }
        root["boxscore"] = ["teams": totals, "players": players]
        let event = try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject:
            ["id": "123", "date": match["date"]!, "name": "匿名比赛", "status": status, "competitions": [match]]))
        return (try JSONSerialization.data(withJSONObject: root), event)
    }
    @Test func reservesAtHighestInputRateAndShrinksOutputWithinRemainingBudget() {
        let limit = NBATerraAutofill.outputLimit(inputTokens: 600, remainingUSD: 0.0036)
        #expect(limit >= 300 && limit < NBATerraClient.maxOutputTokens)
        #expect(NBATerraAutofill.reserveUSD(inputTokens: 600, outputTokens: limit) <= 0.0036)
        #expect(NBATerraAutofill.outputLimit(inputTokens: 600, remainingUSD: 0.001) < 300)
    }
    @Test func recapDraftAndEditorialPassCoalesceAndUseTheirOwnModelRates() async throws {
        let (data, _) = try finalFixture(), counter = AutofillCounts()
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: Date())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"),
            count: { _ in await counter.counted(); return 500 },
            generate: { input, cap in
                #expect(cap == 4000); await counter.generated()
                try await Task.sleep(nanoseconds: 10_000_000)
                var draft = mock(input, text: "待复核初稿")
                draft.requestID = "req_draft"; return draft
            },
            editCount: { input, draft in
                #expect(draft.gameID == input.facts.gameID && draft.text == "待复核初稿")
                await counter.counted(); return 700
            }, edit: { input, draft, cap in
                #expect(draft.requestID == "req_draft" && cap == 4000)
                await counter.generated()
                var final = mock(input, model: "gpt-6.1-sol", inputTokens: 700, outputTokens: 350, text: "复核后成稿")
                final.requestID = "req_editor"; return final
            })
        async let first = engine.budgetedGenerate(input)
        async let second = engine.budgetedGenerate(input)
        let pair = try await (first, second)
        #expect(pair.0.text == "复核后成稿" && pair.1.requestID == "req_editor")
        #expect(pair.0.editorialPasses == 2 && pair.0.draftRequestID == "req_draft")
        #expect(abs((pair.0.estimatedUSD ?? 0) - 0.0049) < 0.000001)
        #expect(abs((pair.0.workflowEstimatedUSD ?? 0) - 0.0064) < 0.000001)
        #expect(await counter.counts == 2)
        #expect(await counter.generations == 2)
        let ledger = await engine.snapshot()
        #expect(abs(ledger.spentUSD - 0.0064) < 0.000001)
        #expect(ledger.jobs["123-recap"]?.state == "done")
        #expect(ledger.jobs["123-recap"]?.completedPasses == 2)
        let store = NBATerraRecapStore(directory: directory.appendingPathComponent("articles")) { _ in
            Issue.record("A completed two-pass article must be reused"); throw NBARecapError.network
        }
        await store.insertValidated(pair.0)
        #expect(try await store.load(input).text == "复核后成稿")
        let reopened = NBATerraRecapStore(directory: directory.appendingPathComponent("articles")) { _ in
            Issue.record("A disk-cached Sol editorial pass must be reused"); throw NBARecapError.network
        }
        #expect(try await reopened.load(input).model == "gpt-6.1-sol")
        #expect(await counter.generations == 2)
    }
    @Test func failedEditorialPassKeepsDraftCostAndUnknownReservationWithoutAutoRetry() async throws {
        let (data, event) = try finalFixture(), counter = AutofillCounts()
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: Date())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let boxes = NBABoxScoreStore(directory: directory.appendingPathComponent("boxes"), fetch: { _ in data })
        let articles = NBATerraRecapStore { _ in throw NBARecapError.network }
        let engine = NBATerraAutofill(file: file, boxes: boxes, articles: articles,
            count: { _ in await counter.counted(); return 500 },
            generate: { input, _ in await counter.generated(); return mock(input) },
            editCount: { _, _ in await counter.counted(); return 700 },
            edit: { _, _, _ in await counter.generated(); throw NBARecapError.timeout }, enabled: { true })
        await #expect(throws: NBARecapError.timeout) { try await engine.budgetedGenerate(input) }
        let expected = 0.0015 + NBATerraAutofill.reserveUSD(inputTokens: 700, outputTokens: 4000, model: "gpt-6.1-sol")
        let ledger = await engine.snapshot()
        #expect(abs(ledger.spentUSD - expected) < 0.000001)
        #expect(ledger.jobs["123-recap"]?.state == "failed")
        #expect(ledger.jobs["123-recap"]?.completedPasses == 1)
        #expect(await articles.cached(input) == nil)
        await engine.process(events: [event])
        #expect(await counter.generations == 2)
        // A process can also stop after dispatching the editor and before its
        // response. Reopening must retain that reservation and mark uncertainty.
        var interrupted = ledger
        interrupted.jobs["123-recap"]?.state = "reviewing"
        try JSONEncoder().encode(interrupted).write(to: file)
        let reopened = NBATerraAutofill(file: file, boxes: boxes, articles: articles,
            count: { _ in Issue.record("An editorial failure must not restart the draft"); return 500 },
            generate: { _, _ in Issue.record("An editorial failure must not restart the draft"); throw NBARecapError.network }, enabled: { true })
        #expect(await reopened.snapshot().jobs["123-recap"]?.state == "uncertain")
        await reopened.process(events: [event])
        #expect(abs(await reopened.snapshot().spentUSD - expected) < 0.000001)
        #expect(await counter.counts == 2)
        #expect(await counter.generations == 2)
    }
    @Test func draftAndEditorialPassAcrossMidnightBelongToTheirDispatchDays() async throws {
        let before = NBASchedulePolicy.startDate("2026-11-01T15:59:59Z")!
        let after = NBASchedulePolicy.startDate("2026-11-01T16:00:01Z")!
        let clock = TerraTestClock(before), (data, _) = try finalFixture()
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: before)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"),
            count: { _ in 500 }, generate: { input, _ in clock.set(after); return mock(input) },
            editCount: { _, _ in 700 },
            edit: { input, _, _ in mock(input, model: "gpt-6.1-sol", inputTokens: 700, outputTokens: 350) }, clock: { clock.get() })
        let final = try await engine.budgetedGenerate(input)
        let ledger = await engine.snapshot()
        #expect(ledger.day == "20261102")
        #expect(abs((ledger.dailySpendUSD?["20261101"] ?? 0) - 0.0015) < 0.000001)
        #expect(abs((ledger.dailySpendUSD?["20261102"] ?? 0) - 0.0049) < 0.000001)
        #expect(abs(ledger.spentUSD - 0.0049) < 0.000001)
        #expect(abs((final.workflowEstimatedUSD ?? 0) - 0.0064) < 0.000001)
    }
    @Test func exhaustedAllowanceBetweenPassesDoesNotSendOrAutoRestartTheEditor() async throws {
        let (data, event) = try finalFixture(), counter = AutofillCounts()
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: Date())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var old = NBATerraAutofill.Ledger()
        old.day = NBAHistoryStore.dayKey(Date(), calendar: NBASchedulePolicy.calendar)
        old.spentUSD = NBATerraAutofill.dailyLimitUSD - 0.021
        try JSONEncoder().encode(old).write(to: file)
        let boxes = NBABoxScoreStore(directory: directory.appendingPathComponent("boxes"), fetch: { _ in data })
        let engine = NBATerraAutofill(file: file, boxes: boxes, articles: NBATerraRecapStore { _ in throw NBARecapError.network },
            count: { _ in await counter.counted(); return 500 },
            generate: { input, _ in await counter.generated(); return mock(input, outputTokens: 4000) },
            editCount: { _, _ in await counter.counted(); return 700 },
            edit: { _, _, _ in Issue.record("The editorial reservation cannot fit"); throw NBARecapError.network }, enabled: { true })
        await #expect(throws: NBARecapError.dailyBudget) { try await engine.budgetedGenerate(input) }
        let ledger = await engine.snapshot()
        #expect(abs(ledger.spentUSD - (old.spentUSD + 0.0205)) < 0.000001)
        #expect(ledger.jobs["123-recap"]?.state == "failed")
        #expect(ledger.jobs["123-recap"]?.completedPasses == 1)
        _ = try await boxes.load(gameID: "123")
        await #expect(throws: NBARecapError.invalidData) {
            try await engine.recoverRecordedResponse(gameID: "123", kind: .recap)
        }
        await engine.process(events: [event])
        #expect(await counter.counts == 2)
        #expect(await counter.generations == 1)
    }
    @Test func budgetBlocksTransportAndPersistsReservationAcrossRelaunch() async throws {
        let (data, event) = try fixture(), counter = AutofillCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = NBABoxScoreStore(directory: directory.appendingPathComponent("box"), fetch: { _ in data })
        let articles = NBATerraRecapStore { _ in Issue.record("Unexpected default generation"); throw NBARecapError.network }
        let count: NBATerraAutofill.Count = { _ in await counter.counted(); return 600 }
        let generate: NBATerraAutofill.Generate = { _, _ in await counter.generated(); throw NBARecapError.network }
        let file = directory.appendingPathComponent("ledger.json")
        let engine = NBATerraAutofill(file: file, boxes: box, articles: articles, count: count, generate: generate, enabled: { true })
        let existingSpend = NBATerraAutofill.dailyLimitUSD - 0.0001
        await engine.process(events: [event], seedUSD: existingSpend)
        #expect(await counter.generations == 0)
        #expect(await engine.snapshot().jobs["123-pregame"]?.state == "budget")
        await engine.process(events: [event])
        #expect(await counter.counts == 1)
        let reopened = NBATerraAutofill(file: file, boxes: box, articles: articles, count: count, generate: generate, enabled: { true })
        #expect(abs(await reopened.snapshot().spentUSD - existingSpend) < 0.000001)
    }
    @Test func concurrentScansMergeAndCachedSuccessDoesNotSpendAgain() async throws {
        let (data, event) = try fixture(), counter = AutofillCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = NBABoxScoreStore(directory: directory.appendingPathComponent("box"), fetch: { _ in data })
        let articles = NBATerraRecapStore(directory: directory.appendingPathComponent("articles")) { _ in throw NBARecapError.network }
        let engine = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"), boxes: box, articles: articles,
            count: { _ in await counter.counted(); return 500 }, generate: { input, _ in
                await counter.generated(); try await Task.sleep(nanoseconds: 20_000_000); return mock(input)
            }, enabled: { true })
        async let first: Void = engine.process(events: [event])
        async let second: Void = engine.process(events: [event])
        _ = await (first, second)
        await engine.process(events: [event])
        #expect(await counter.generations == 1)
        #expect(await counter.counts == 1)
        #expect(await engine.snapshot().jobs["123-pregame"]?.state == "done")
    }
    @Test func failedGenerationKeepsWorstCaseCostAndNeverAutoRetries() async throws {
        let (data, event) = try fixture(), counter = AutofillCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = NBABoxScoreStore(directory: directory.appendingPathComponent("box"), fetch: { _ in data })
        let articles = NBATerraRecapStore { _ in throw NBARecapError.network }
        let engine = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"), boxes: box, articles: articles,
            count: { _ in 500 }, generate: { _, _ in await counter.generated(); throw NBARecapError.timeout }, enabled: { true })
        await engine.process(events: [event]); await engine.process(events: [event])
        #expect(await counter.generations == 1)
        #expect(await engine.snapshot().jobs["123-pregame"]?.state == "failed")
        #expect(await engine.snapshot().spentUSD >= NBATerraAutofill.reserveUSD(inputTokens: 500, outputTokens: NBATerraClient.maxOutputTokens(for: .pregame)))
        let file = directory.appendingPathComponent("ledger.json")
        var persisted = try JSONDecoder().decode(NBATerraAutofill.Ledger.self, from: Data(contentsOf: file))
        persisted.jobs["123-pregame"]?.state = "running"
        try JSONEncoder().encode(persisted).write(to: file)
        let reopened = NBATerraAutofill(file: file, boxes: box, articles: articles,
            count: { _ in Issue.record("Uncertain outcome must not retry"); return 500 },
            generate: { _, _ in Issue.record("Uncertain outcome must not retry"); throw NBARecapError.network }, enabled: { true })
        await reopened.process(events: [event])
        #expect(await reopened.snapshot().jobs["123-pregame"]?.state == "uncertain")
        #expect(await reopened.snapshot().spentUSD >= NBATerraAutofill.reserveUSD(inputTokens: 500, outputTokens: NBATerraClient.maxOutputTokens(for: .pregame)))
    }
    @Test func legacyBudgetBlockResumesUnderSharedDailyLimitWithoutDroppingCosts() async throws {
        let (data, event) = try fixture(), counter = AutofillCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var old = NBATerraAutofill.Ledger()
        old.day = NBAHistoryStore.dayKey(Date(), calendar: NBASchedulePolicy.calendar)
        old.spentUSD = 0.1049355; old.approvedRoundLimitUSD = 0.15
        old.jobs["123-pregame"] = .init(gameID: "123", title: "test", kind: .pregame, fingerprint: "old",
            state: "budget", message: "旧门槛", attempts: 0, date: Date(), estimatedUSD: 0, requestID: nil)
        try JSONEncoder().encode(old).write(to: file)
        let boxes = NBABoxScoreStore(directory: directory.appendingPathComponent("boxes"), fetch: { _ in data })
        let articles = NBATerraRecapStore { _ in throw NBARecapError.network }
        let engine = NBATerraAutofill(file: file, boxes: boxes, articles: articles,
            count: { _ in await counter.counted(); return 500 }, generate: { input, _ in
                await counter.generated(); return mock(input)
            }, enabled: { true })
        await engine.process(events: [event])
        let ledger = await engine.snapshot()
        #expect(NBATerraAutofill.dailyLimitUSD == 5.0)
        #expect(ledger.jobs["123-pregame"]?.state == "done")
        #expect(ledger.approvedRoundLimitUSD == nil)
        #expect(abs(ledger.spentUSD - 0.1064355) < 0.000001)
        #expect(await counter.generations == 1)
        await engine.process(events: [event])
        #expect(await counter.generations == 1)
    }
    @Test func raisedProductionLimitRechecksOldBudgetBlockWithoutResettingSpend() async throws {
        let (data, event) = try fixture(), counter = AutofillCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var old = NBATerraAutofill.Ledger()
        old.day = NBAHistoryStore.dayKey(Date(), calendar: NBASchedulePolicy.calendar)
        old.spentUSD = 1.50
        old.jobs["123-pregame"] = .init(gameID: "123", title: "test", kind: .pregame, fingerprint: "old",
            state: "budget", message: "旧正式上限", attempts: 0, date: Date(), estimatedUSD: 0, requestID: nil,
            budgetLimitUSD: 1.50)
        try JSONEncoder().encode(old).write(to: file)
        let boxes = NBABoxScoreStore(directory: directory.appendingPathComponent("boxes"), fetch: { _ in data })
        let engine = NBATerraAutofill(file: file, boxes: boxes,
            articles: NBATerraRecapStore { _ in throw NBARecapError.network },
            count: { _ in 500 }, generate: { input, _ in await counter.generated(); return mock(input) }, enabled: { true })
        await engine.process(events: [event])
        let ledger = await engine.snapshot()
        #expect(await counter.generations == 1)
        #expect(ledger.jobs["123-pregame"]?.state == "done")
        #expect(abs(ledger.spentUSD - 1.5015) < 0.000001)
    }
    @Test func manualAndAutomaticShareOneSerialAllowance() async throws {
        let (a, _) = try fixture(), (b, eventB) = try fixture(id: "124")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var old = NBATerraAutofill.Ledger()
        let existingSpend = NBATerraAutofill.dailyLimitUSD - 0.0023
        old.day = NBAHistoryStore.dayKey(Date(), calendar: NBASchedulePolicy.calendar); old.spentUSD = existingSpend
        try JSONEncoder().encode(old).write(to: file)
        let counter = AutofillCounts()
        let boxes = NBABoxScoreStore(directory: directory.appendingPathComponent("boxes"), fetch: { _ in b })
        let articles = NBATerraRecapStore { _ in throw NBARecapError.network }
        let engine = NBATerraAutofill(file: file, boxes: boxes, articles: articles,
            count: { _ in await counter.counted(); return 500 }, generate: { input, _ in
                await counter.generated(); try await Task.sleep(nanoseconds: 10_000_000); return mock(input)
            }, enabled: { true })
        let input = try NBARecapInput.makeArticle(data: a, gameID: "123", dataAsOf: Date())
        async let manual = try? engine.budgetedGenerate(input)
        async let automatic: Void = engine.process(events: [eventB])
        _ = await (manual, automatic)
        #expect(await counter.generations == 1)
        let ledger = await engine.snapshot()
        #expect(ledger.spentUSD <= NBATerraAutofill.dailyLimitUSD)
        #expect(abs(ledger.spentUSD - (existingSpend + 0.0015)) < 0.000001)
        #expect(ledger.jobs.values.filter { $0.state == "budget" }.count == 1)
        let reopened = NBATerraAutofill(file: file, count: { _ in 500 },
            generate: { _, _ in Issue.record("No budget"); throw NBARecapError.network })
        do { _ = try await reopened.budgetedGenerate(input); Issue.record("Expected shared budget error") }
        catch { #expect(error as? NBARecapError == .dailyBudget) }
    }
    @Test func midnightCompletionReconcilesOriginalBeijingDayAndResetsNextDay() async throws {
        let before = NBASchedulePolicy.startDate("2026-11-01T15:59:59Z")!
        let after = NBASchedulePolicy.startDate("2026-11-01T16:00:01Z")!
        let clock = TerraTestClock(before)
        let (data, _) = try fixture(date: "2026-11-03T01:00:00Z")
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: before, now: before)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"), count: { _ in 500 },
            generate: { input, _ in clock.set(after); return mock(input) }, clock: { clock.get() })
        _ = try await engine.budgetedGenerate(input)
        let ledger = await engine.snapshot()
        #expect(ledger.day == "20261102")
        #expect(ledger.spentUSD == 0)
        #expect(abs((ledger.dailySpendUSD?["20261101"] ?? 0) - 0.0015) < 0.000001)
        _ = try await engine.budgetedGenerate(input)
        #expect(abs(await engine.snapshot().spentUSD - 0.0015) < 0.000001)
        let reopened = NBATerraAutofill(file: directory.appendingPathComponent("ledger.json"), clock: { after })
        #expect(abs(await reopened.snapshot().spentUSD - 0.0015) < 0.000001)
    }
    @Test func corruptedLedgerBlocksEveryPaidPath() async throws {
        let (data, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        try Data("broken".utf8).write(to: file)
        let engine = NBATerraAutofill(file: file, count: { _ in Issue.record("Corrupt ledger"); return 500 },
            generate: { _, _ in Issue.record("Corrupt ledger"); throw NBARecapError.network })
        let input = try NBARecapInput.makeArticle(data: data, gameID: "123", dataAsOf: Date())
        do { _ = try await engine.budgetedGenerate(input); Issue.record("Expected ledger error") }
        catch { #expect(error as? NBARecapError == .budgetUnavailable) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    }
    @Test func automaticCandidatesUseOnlyTodayFinalsAndTomorrowScheduled() throws {
        let now = NBASchedulePolicy.startDate("2026-11-01T02:30:00Z")!
        func event(_ id: String, date: String, post: Bool) throws -> Event {
            let (data, _) = try fixture(id: id, date: date)
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let match = ((root["header"] as! [String: Any])["competitions"] as! [[String: Any]])[0]
            var json: [String: Any] = ["id": id, "date": date, "name": "匿名比赛", "status": match["status"]!, "competitions": [match]]
            if post { json["status"] = ["type": ["name": "STATUS_FINAL", "state": "post", "completed": true]] }
            return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let events = try [event("1", date: "2026-10-31T01:00:00Z", post: true),
                          event("2", date: "2026-11-01T01:00:00Z", post: true),
                          event("3", date: "2026-11-01T04:00:00Z", post: false),
                          event("4", date: "2026-11-02T01:00:00Z", post: false),
                          event("5", date: "2026-11-03T01:00:00Z", post: false)]
        #expect(NBATerraAutofill.candidates(events, now: now).map(\.id) == ["2", "4"])
    }

}
