import Foundation
import Testing
@testable import MenuScores

private actor ReviewRequestCounts {
    var calls = 0
    func called() { calls += 1 }
}
struct NBAReviewQuestionTests {
    private func evidence() throws -> NBAReviewEvidence {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-match-final.json")
        return try NBAReviewEvidence.make(data: Data(contentsOf:file),gameID:"401909893",dataAsOf:Date())
    }
    private func response(search: Bool = false, citations: Bool = true) throws -> Data {
        var output: [[String: Any]] = []
        if search { output.append(["type":"web_search_call","action":["type":"search"]]) }
        output.append(["type":"message","role":"assistant","content":[["type":"output_text","text":"官方资料未公布复出日期。", "annotations": citations ? [["type":"url_citation","url":"https://www.nba.com/news/test","title":"NBA 公告","start_index":0,"end_index":4]] : []]]])
        return try JSONSerialization.data(withJSONObject:["id":"resp_test","model":NBATerraClient.model,"status":"completed","output":output,"usage":["input_tokens":1000,"output_tokens":120]])
    }
    @Test func requestOnlyEnablesBoundedOfficialSearchWhenNeeded() throws {
        let e = try evidence()
        let local = try JSONSerialization.jsonObject(with: NBAReviewQuestionClient.body(evidence:e,segmentID:nil,question:"双方篮板相差多少？",turns:[],search:false)) as! [String:Any]
        #expect(local["tools"] == nil); #expect(local["store"] as? Bool == false)
        let web = try JSONSerialization.jsonObject(with: NBAReviewQuestionClient.body(evidence:e,segmentID:nil,question:"查NBA官方伤停公告",turns:[],search:true)) as! [String:Any]
        #expect(web["max_tool_calls"] as? Int == 1)
        #expect(web["max_output_tokens"] as? Int == 6000)
        #expect(web["tool_choice"] as? String == "required")
        let tools = web["tools"] as! [[String:Any]]
        #expect(tools[0]["filters"] == nil)
    }
    @Test func budgetRejectsARequestThatCouldBypassItsToolOrTokenReservation() throws {
        let e = try evidence()
        let data = try NBAReviewQuestionClient.body(evidence:e,segmentID:nil,question:"查NBA官方",turns:[],search:true)
        #expect(throws: NBARecapError.invalidData) { try NBAReviewQuestionClient.validateRequest(data,search:false) }
        var body = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        body["max_tool_calls"] = 50
        #expect(throws: NBARecapError.invalidData) { try NBAReviewQuestionClient.validateRequest(JSONSerialization.data(withJSONObject:body),search:true) }
        body["max_tool_calls"] = 1;body["max_output_tokens"] = 10000
        #expect(throws: NBARecapError.invalidData) { try NBAReviewQuestionClient.validateRequest(JSONSerialization.data(withJSONObject:body),search:true) }
    }
    @Test func externalSourcesRequireOfficialHTTPSAndNativeAnnotations() throws {
        #expect(NBAReviewQuestionClient.official(URL(string:"https://official.nba.com/report")!))
        #expect(!NBAReviewQuestionClient.official(URL(string:"https://nba.com.evil.example/report")!))
        #expect(!NBAReviewQuestionClient.official(URL(string:"https://nba.com@evil.example/report")!))
        #expect(!NBAReviewQuestionClient.official(URL(string:"http://nba.com/report")!))
        let answer = try NBAReviewQuestionClient.parse(response(search:true),gameID:"123",searched:true,requestID:"req_test")
        #expect(answer.sources.count == 1); #expect(answer.citations.count == 1)
        #expect(answer.usage?.searches == 1)
        #expect(abs((answer.usage?.usd ?? 0) - 0.0116) < 0.0000001)
        let absent = try NBAReviewQuestionClient.parse(response(search:true,citations:false),gameID:"123",searched:true,requestID:nil)
        #expect(absent.text.contains("暂不能确认")); #expect(absent.sources.isEmpty)
        var opened = try JSONSerialization.jsonObject(with: response(search:true)) as! [String:Any]
        var output = opened["output"] as! [[String:Any]]; output[0]["action"] = ["type":"open_page"]; opened["output"] = output
        #expect(NBAReviewQuestionClient.usage(opened)?.searches == 1)
    }
    @Test func answerFormattingKeepsEmphasisAndOnlyVerifiedCitationLinks() {
        let text = "**篮板**差距。[官方](https://www.nba.com/news/test) [伪链接](https://example.com)"
        let start = text.distance(from: text.startIndex, to: text.range(of: "[官方]")!.lowerBound)
        let end = text.distance(from: text.startIndex, to: text.range(of: ")")!.upperBound)
        let url = URL(string: "https://www.nba.com/news/test")!
        let answer = NBAReviewAnswer(gameID: "123", text: text, sources: [], citations: [.init(start: start, end: end, url: url)], generatedAt: Date(), requestID: nil, responseID: nil, usage: nil, searched: true)
        let formatted = answer.formattedText
        #expect(String(formatted.characters) == "篮板差距。官方 伪链接")
        #expect(formatted.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(formatted.runs.compactMap(\.link) == [url])
    }
    @Test func sharedBudgetIncludesToolCostAndReleasesOnlyKnownUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let counter = ReviewRequestCounts(), data = try response(search:true,citations:false)
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"test"},send:{ request in
            await counter.called()
            let count = request.url!.path.hasSuffix("input_tokens")
            return (count ? Data("{\"input_tokens\":1000}".utf8) : data, HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"req_test"])!)
        }), receiptDirectory:directory.appendingPathComponent("receipts"))
        let engine = NBATerraAutofill(file:directory.appendingPathComponent("ledger.json"))
        _ = try await engine.reviewAnswer(gameID:"123",key:UUID().uuidString,body:try NBAReviewQuestionClient.body(evidence:evidence(),segmentID:nil,question:"查NBA官方",turns:[],search:true),search:true,client:client)
        let ledger = await engine.snapshot()
        #expect(abs(ledger.spentUSD - 0.0116) < 0.0000001)
        #expect(ledger.reviewOperations?.values.first?.reservedUSD ?? 0 > 0.33)
        #expect(ledger.reviewOperations?.values.first?.state == "done")
        #expect(await counter.calls == 2)
    }
    @Test func insufficientSearchReservationMakesZeroCredentialOrNetworkCalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let existingSpend = NBATerraAutofill.dailyLimitUSD - 0.1
        var ledger = NBATerraAutofill.Ledger();ledger.day = NBAHistoryStore.dayKey(Date(),calendar:NBASchedulePolicy.calendar);ledger.spentUSD = existingSpend
        let file = directory.appendingPathComponent("ledger.json");try JSONEncoder().encode(ledger).write(to:file)
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{ Issue.record("Must not read key");return nil },send:{ _ in Issue.record("Must not call API");throw NBARecapError.network }))
        let engine = NBATerraAutofill(file:file)
        do { _ = try await engine.reviewAnswer(gameID:"123",key:"blocked",body:try NBAReviewQuestionClient.body(evidence:evidence(),segmentID:nil,question:"查NBA官方",turns:[],search:true),search:true,client:client);Issue.record("Budget should block") }
        catch { #expect(error as? NBARecapError == .dailyBudget) }
        #expect(await engine.snapshot().spentUSD == existingSpend)
    }
    @Test func questionCacheCoalescesDuplicateClicksAndRejectsCrossGameAnswer() async throws {
        let store = NBAReviewQuestionStore(), counter = ReviewRequestCounts()
        let answer = try NBAReviewQuestionClient.parse(response(),gameID:"123",searched:false,requestID:nil)
        let generate: NBAReviewQuestionStore.Generate = { await counter.called();try await Task.sleep(nanoseconds:10_000_000);return answer }
        async let a = store.answer(key:"same",gameID:"123",generate:generate)
        async let b = store.answer(key:"same",gameID:"123",generate:generate)
        _ = try await (a,b)
        _ = try await store.answer(key:"same",gameID:"123",generate:generate)
        #expect(await counter.calls == 1)
        do { _ = try await store.answer(key:"other",gameID:"999",generate:generate);Issue.record("Cross-game answer") }
        catch { #expect(error as? NBARecapError == .invalidResponse) }
    }
    @Test @MainActor func perGameDraftRoutesAndCancelledResponsesStayIsolated() async throws {
        let data = try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-match-final.json"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let boxes = NBABoxScoreStore(directory:directory,fetch:{ _ in data })
        let articles = NBATerraRecapStore { _ in throw NBARecapError.network }
        let answer = try NBAReviewQuestionClient.parse(response(),gameID:"401909893",searched:false,requestID:nil)
        let model = NBAReviewPanelModel(gameID:"401909893",boxes:boxes,articles:articles,questions:NBAReviewQuestionStore(),ask:{ _,_,_,_,_ in try? await Task.sleep(nanoseconds:100_000_000);return answer })
        await model.load();model.route = .evidence;model.draft = "这一段如何？";model.submit();model.submit()
        #expect(model.asking);#expect(model.questionBack == .evidence)
        model.cancelQuestion();try await Task.sleep(nanoseconds:150_000_000)
        #expect(model.turns.isEmpty);#expect(model.draft == "这一段如何？")
        let other = NBAReviewPanelModel(gameID:"999",boxes:boxes,articles:articles)
        #expect(other.turns.isEmpty);#expect(other.draft.isEmpty)
    }
}
