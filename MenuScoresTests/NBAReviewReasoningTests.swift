import Foundation
import Testing
@testable import MenuScores

private actor ReasoningWire {
    var tools: [String] = []
    func record(_ type: String) { tools.append(type) }
}
struct NBAReviewReasoningTests {
    private func evidence(emptyPlays: Bool = false) throws -> NBAReviewEvidence {
        let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json")
        var root = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        if emptyPlays { root["plays"] = [] }
        return try .make(data:JSONSerialization.data(withJSONObject:root),gameID:"401909901",dataAsOf:Date())
    }
    private func query(_ kind: NBAReviewGameQuery.Query.Kind = .impact, _ scope: NBAReviewGameQuery.Query.Scope = .game, period: Int? = nil) -> NBAReviewGameQuery.Query {
        .init(kind:kind,scope:scope,player:nil,period:period,remainingFrom:nil,remainingTo:nil,eventTypes:[])
    }
    private func answer(_ text: String, searched: Bool = false, sources: [NBAReviewAnswer.Source] = []) -> NBAReviewAnswer {
        .init(gameID:"401909901",text:text,sources:sources,citations:[],generatedAt:Date(),requestID:"req_fixture",responseID:nil,usage:nil,searched:searched)
    }
    private func response(_ output: [[String:Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["model":NBATerraClient.model,"status":"completed","output":output,"usage":["input_tokens":1000,"output_tokens":100]])
    }
    @Test func partialGlobalCoverageDoesNotForceSearchForAnInMatchJudgment() throws {
        let e = try evidence();#expect(e.coverage == .partial)
        let result = try NBAReviewGameQuery.execute(.init(queries:[query()],needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:"focus")
        #expect(!result.requiresOfficial);#expect(!result.evidence.events.isEmpty)
        let raw = try NBAReviewPacketTestSupport.decode(Data(result.json.utf8))
        let rows = raw["queries"] as! [[String:Any]],candidates = rows[0]["candidates"] as! [[String:Any]]
        #expect(candidates.count >= 6);#expect(rows[0]["strictClutchExists"] as? Bool == false)
        #expect(candidates.contains { $0["name"] as? String == "维克托·文班亚马" && $0["teamPointSharePercent"] as? Double == 35.5 })
        #expect(result.numbers.contains(35.5));#expect(result.evidence.events.contains { $0.id == "401909901647" })
    }
    @Test func closePlayScopeIncludesEarlierTightScoringWhenStrictClutchIsEmpty() throws {
        let e = try evidence(),q = query(.events,.close,period:4)
        let result = try NBAReviewGameQuery.execute(.init(queries:[q],needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:nil)
        #expect(!result.requiresOfficial);#expect(result.json.contains("不限最后5分钟"));#expect(result.json.contains("回合前分差≤5"))
        let w = NBAReviewGameQuery.window(q,evidence:e,segmentID:nil)
        #expect(w.indices.contains { e.points[$0].id == "401909901647" })
        let clutch = NBAReviewGameQuery.window(query(.events,.clutch),evidence:e,segmentID:nil)
        #expect(clutch.complete && clutch.indices.isEmpty)
    }
    @Test func missingPlaysStillAllowsBoxAnalysisAndDoesNotFabricateClutchAbsence() throws {
        let result = try NBAReviewGameQuery.execute(.init(queries:[query()],needsExternalResearch:false,intent:.matchAnalysis),evidence:evidence(emptyPlays:true),segmentID:nil)
        #expect(!result.requiresOfficial);#expect(result.evidence.events.isEmpty)
        let raw = try NBAReviewPacketTestSupport.decode(Data(result.json.utf8))
        let row = (raw["queries"] as! [[String:Any]])[0]
        #expect(row["strictClutchExists"] is NSNull);#expect(result.json.contains("playersByID"))
    }
    @Test func injuryHistoryDoesNotReplaceCurrentPerformanceIntentOrReinjectTheBadPlaceholder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:dir) }
        let e = try evidence(),wire = ReasoningWire()
        let old = answer("本次未取得足以核实的 NBA／球队官方引用，外部信息暂不能确认。不会据缺失资料推断缺阵原因或复出时间。",searched:true)
        let turns = [NBAReviewTurn(question:"詹姆斯怎么不上场",answer:old)]
        let args = String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:[query()],needsExternalResearch:false,intent:.matchAnalysis)),as:UTF8.self)
        let plan = try response([["type":"function_call","name":"query_game_facts","call_id":"fixture_call","arguments":args]])
        let final = try response([["type":"message","role":"assistant","content":[["type":"output_text","text":"我会选文班亚马。他全场43分、6盖帽；末节6:15扣篮把领先扩大，2:40命中三分。哈珀和福克斯也有贡献。","annotations":[]]]]])
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"fixture"},send:{ request in
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1000}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            let type = (body["tools"] as? [[String:Any]])?.first?["type"] as? String ?? "none";await wire.record(type)
            #expect(!String(decoding:request.httpBody!,as:UTF8.self).contains("不会据缺失资料推断缺阵原因或复出时间"))
            return (type == "function" ? plan : final,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"req_fixture_"+type])!)
        }),receiptDirectory:dir.appendingPathComponent("receipts"))
        let result = try await NBAReviewResearch(budget:NBATerraAutofill(file:dir.appendingPathComponent("ledger.json")),client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"那你觉得今天谁最关键，是制胜之钥",turns:turns,boxes:NBABoxScoreStore(directory:dir.appendingPathComponent("box"),fetch:{_ in throw NBARecapError.network}))
        #expect(await wire.tools == ["function","none"]);#expect(!result.isEvidenceNotice);#expect(result.text.hasPrefix("我会选文班"));#expect(!result.searched)
    }
    @Test func mixedQuestionKeepsLocalJudgmentWhenExternalEvidenceIsAbsent() {
        var external = answer("外部点暂不能确认",searched:true);external.responseFiltered = true
        let combined = NBAReviewResearch.combine(local:answer("我的判断是文班最关键，依据43分和具体回合。"),external:external,warning:nil)
        #expect(combined.text == "我的判断是文班最关键，依据43分和具体回合。")
        #expect(combined.searchWarning != nil);#expect(!combined.isEvidenceNotice)
    }
    @Test func mediaAndReporterCitationsAreAcceptedWithoutAnOfficialDomainGate() throws {
        for url in ["https://www.espn.com/nba/story/report","https://www.reuters.com/sports/report","https://x.com/reporter/status/123"] {
            let data = try response([["type":"message","role":"assistant","content":[["type":"output_text","text":"据记者报道，情况仍待球队确认。","annotations":[["type":"url_citation","url":url,"title":"报道来源","start_index":0,"end_index":6]]]]]])
            let parsed = try NBAReviewQuestionClient.parse(data,gameID:"401909901",searched:true,requestID:nil)
            #expect(!parsed.isEvidenceNotice);#expect(parsed.sources.first?.url.absoluteString == url);#expect(parsed.sources.first?.evidenceKind != nil)
        }
        for url in ["https://127.0.0.1/report","https://localhost/report","https://nba.com@private.example/report","file:///etc/passwd"] { #expect(!NBAReviewQuestionClient.publicSource(URL(string:url)!)) }
    }
    @Test func mixedWorkflowAccountsForAllThreePassesAndKeepsAnalysisWithoutWebCitations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:dir) }
        let wire = ReasoningWire(),e = try evidence()
        let args = String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:[query()],needsExternalResearch:true,intent:.mixed)),as:UTF8.self)
        let plan = try response([["type":"function_call","name":"query_game_facts","call_id":"mixed_call","arguments":args]])
        let local = try response([["type":"message","role":"assistant","content":[["type":"output_text","text":"我的判断是文班亚马，他全场43分、6盖帽，其他球员也有贡献。","annotations":[]]]]])
        let external = try response([["type":"web_search_call","status":"completed","action":["type":"search"]],["type":"message","role":"assistant","content":[["type":"output_text","text":"未找到可核实报道。","annotations":[]]]]])
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"fixture"},send:{ request in
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1000}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],type = (body["tools"] as? [[String:Any]])?.first?["type"] as? String ?? "none"
            await wire.record(type)
            return (type == "function" ? plan : type == "none" ? local : external,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"req_mixed_"+type])!)
        }),receiptDirectory:dir.appendingPathComponent("receipts"))
        let budget = NBATerraAutofill(file:dir.appendingPathComponent("ledger.json"))
        let answer = try await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:nil,pointID:nil,question:"谁最关键，媒体赛后怎么评价？",turns:[],boxes:NBABoxScoreStore(directory:dir.appendingPathComponent("box"),fetch:{_ in throw NBARecapError.network}))
        #expect(await wire.tools == ["function","none","web_search"])
        #expect(answer.text.hasPrefix("我的判断是文班"));#expect(answer.searchWarning != nil);#expect(!answer.isEvidenceNotice)
        #expect(answer.requestIDs?.count == 3)
        let ledger = await budget.snapshot();#expect(ledger.reviewOperations?.count == 3);#expect(abs(ledger.spentUSD-0.0145)<0.000001)
    }
    @Test @MainActor func explicitRetryAppendsAResponseAndPreservesTheOldBadTurn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:dir) }
        let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json"),data = try Data(contentsOf:file)
        let store = NBAReviewConversationStore(directory:dir.appendingPathComponent("history"))
        var doc = try await store.load(gameID:"401909901")
        let old = NBAReviewTurn(question:"谁最关键？",answer:answer("本次未取得足以核实的 NBA／球队官方引用，外部信息暂不能确认。",searched:true))
        doc.turns = [old];doc.revision = 1;try await store.save(doc)
        let fresh = answer("我会选文班亚马，依据本场43分和具体回合。")
        let model = NBAReviewPanelModel(gameID:doc.gameID,boxes:NBABoxScoreStore(directory:dir.appendingPathComponent("box"),fetch:{_ in data}),articles:NBATerraRecapStore{_ in throw NBARecapError.network},questions:NBAReviewQuestionStore(),history:store,ask:{_,_,_,_,history in #expect(history.count==1);return fresh})
        await model.load();model.draft = old.question;model.submit()
        #expect(!model.asking);#expect(model.turns.count == 1)
        model.retry(old)
        for _ in 0..<100 { if !model.asking { break };try await Task.sleep(nanoseconds:5_000_000) }
        #expect(model.turns.count == 2);#expect(model.turns.first?.id == old.id);#expect(model.turns.first?.answer.text == old.answer.text)
        #expect(model.turns.last?.answer.text == fresh.text)
    }
}
