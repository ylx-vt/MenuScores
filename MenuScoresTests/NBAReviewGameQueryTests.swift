import Foundation
import Testing
@testable import MenuScores

private actor QueryWire {
    var bodies: [[String:Any]] = []
    func record(_ value: [String:Any]) { bodies.append(value) }
    var count: Int { bodies.count }
    func types() -> [String] { bodies.map { (($0["tools"] as? [[String:Any]])?.first?["type"] as? String) ?? "none" } }
}
struct NBAReviewGameQueryTests {
    private func fixture() throws -> Data {
        try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json"))
    }
    private func evidence(_ data: Data? = nil) throws -> NBAReviewEvidence {
        try NBAReviewEvidence.make(data:data ?? fixture(),gameID:"401909901",dataAsOf:Date())
    }
    private func query(_ kind: NBAReviewGameQuery.Query.Kind = .player, _ scope: NBAReviewGameQuery.Query.Scope = .critical, player: String? = "文班亚马", period: Int? = nil) -> NBAReviewGameQuery.Query {
        .init(kind:kind,scope:scope,player:player,period:period,remainingFrom:nil,remainingTo:nil,eventTypes:[])
    }
    private func execute(_ q: NBAReviewGameQuery.Query, e: NBAReviewEvidence? = nil) throws -> (NBAReviewGameQuery.Result, [[String:Any]]) {
        let result = try NBAReviewGameQuery.execute(.init(queries:[q],needsOfficialResearch:false),evidence:e ?? evidence(),segmentID:"focus")
        let root = try NBAReviewPacketTestSupport.decode(Data(result.json.utf8))
        return (result,root["queries"] as! [[String:Any]])
    }
    @Test func unknownPlayerRequiresIdentityClarificationBeforeInjurySearch() throws {
        let e = try evidence(), request = NBAReviewGameQuery.Request(queries:[query(.availability,.game,player:"詹姆斯")],needsOfficialResearch:true)
        let candidate = NBAReviewIdentityDirectory.Identity(athlete:.init(id:"fixture-james",name:"勒布朗·詹姆斯",originalName:"LeBron James",teamID:"20",statistics:[:],didNotPlay:false),teamName:"76人",matchDate:"2026-10-31T02:00Z",fetchedAt:Date(),source:URL(string:"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=401909893")!)
        let result = try NBAReviewGameQuery.execute(request,evidence:e,segmentID:"focus",identities:[candidate])
        #expect(result.needsClarification);#expect(!result.requiresOfficial)
        #expect(result.json.contains("森林狼"));#expect(result.json.contains("lastRecordedTeam"));#expect(result.json.contains("不能直接认定伤停"))
        #expect(result.evidence.identitySources?.count == 1)
        let clarification = NBAReviewAnswer(gameID:e.gameID,text:"缓存名单记录中的勒布朗·詹姆斯属于76人。这场是森林狼对马刺，你说的是另一场吗？",sources:[],citations:[],generatedAt:Date(),requestID:nil,responseID:nil,usage:nil,searched:false)
        try NBAReviewQuestionClient.validateLocal(clarification,evidence:e,segmentID:nil,pointID:nil,extraNumbers:result.numbers,extraEntityNames:result.entityNames)
        let call = NBAReviewAnswer.ToolCall(id:nil,callID:"call_identity",name:"query_game_facts",arguments:String(decoding:try JSONEncoder().encode(request),as:UTF8.self))
        let body = try JSONSerialization.jsonObject(with:NBAReviewQuestionClient.answerBody(evidence:e,segmentID:"focus",pointID:nil,question:"詹姆斯怎么不上场",turns:[],call:call,result:result)) as! [String:Any]
        #expect(body["tools"] == nil)
        #expect((body["instructions"] as? String)?.contains("不能把本场无统计当成不属于球队") == true)
    }
    @Test func ambiguousNamesAndUnknownPronounsNeverBecomeAnUnsupportedAbsenceClaim() throws {
        for name in ["他","另一个詹姆斯","未知球员"] {
            let result = try NBAReviewGameQuery.execute(.init(queries:[query(.identity,.game,player:name)],needsOfficialResearch:true),evidence:evidence(),segmentID:nil)
            #expect(result.needsClarification);#expect(!result.requiresOfficial);#expect(!result.missingEvents)
        }
    }
    @Test func aDNPPlayerStillBelongsToTheVerifiedMatchRoster() throws {
        var raw = try JSONSerialization.jsonObject(with:fixture()) as! [String:Any],box = raw["boxscore"] as! [String:Any],teams = box["players"] as! [[String:Any]]
        for t in teams.indices {
            var blocks = teams[t]["statistics"] as! [[String:Any]]
            for b in blocks.indices {
                var rows = blocks[b]["athletes"] as! [[String:Any]]
                for r in rows.indices where (rows[r]["athlete"] as? [String:Any])?["id"] as? String == "5104157" { rows[r]["didNotPlay"] = true;rows[r]["stats"] = [] }
                blocks[b]["athletes"] = rows
            };teams[t]["statistics"] = blocks
        };box["players"] = teams;raw["boxscore"] = box
        let e = try evidence(JSONSerialization.data(withJSONObject:raw)),result = try NBAReviewGameQuery.execute(.init(queries:[query(.identity,.game)],needsOfficialResearch:false),evidence:e,segmentID:nil)
        #expect(!result.needsClarification);#expect(!result.requiresOfficial);#expect(result.json.contains("didNotPlay"));#expect(result.json.contains("true"))
    }
    @Test func actualSelectedAndLateGameUseDifferentDefinitionsAndEvents() throws {
        let (result,rows) = try execute(query())
        #expect(rows.count == 3);#expect(!result.requiresOfficial)
        let selectedPlayer = (rows[0]["players"] as! [[String:Any]])[0]
        let selected = selectedPlayer["allTypesRecordedMetrics"] as! [String:Int]
        #expect(selected["points"] == 0);#expect(selected["fieldGoalsMade"] == 0);#expect(selected["fieldGoalsAttempted"] == 2)
        #expect(rows[0]["countsAreExactForVerifiedScope"] as? Bool == true)
        let late = ((rows[1]["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"]) as! [String:Int]
        #expect(late["points"] == 3);#expect(late["assists"] == 1);#expect(late["blocks"] == 1);#expect(late["turnovers"] == 1)
        #expect(rows[2]["qualifyingClutchExists"] as? Bool == false)
        #expect(rows[2]["lastFiveRecordedMarginMin"] as? Int == 6)
        #expect(rows[2]["lastFiveRecordedMarginMax"] as? Int == 11)
        #expect(result.evidence.events.contains { $0.id == "401909901686" && $0.label.contains("2:40") })
        #expect(result.evidence.events.contains { $0.id == "401909901249" && $0.text.contains("enters") })
    }
    @Test func aParticipantWhoAssistsOrIsBlockedDoesNotGetTheShotPointsOrBlock() throws {
        let e = try evidence(), victor = try #require(e.athletes.first { $0.id == "5104157" })
        let assisted = try #require(e.points.first { $0.id == "401909901669" })
        let assist = NBAReviewGameQuery.roles(assisted,athlete:victor)
        #expect(assist.0.points == 0);#expect(assist.0.assists == 1);#expect(assist.0.fieldGoalsAttempted == 0)
        let blocked = try #require(e.points.first { $0.id == "401909901690" })
        let shot = NBAReviewGameQuery.roles(blocked,athlete:victor)
        #expect(shot.0.blocks == 0);#expect(shot.0.fieldGoalsAttempted == 1)
        let actualBlock = try #require(e.points.first { $0.id == "401909901683" })
        #expect(NBAReviewGameQuery.roles(actualBlock,athlete:victor).0.blocks == 1)
    }
    @Test func aSpecificPeriodOverridesTheSelectedQuarterAndNamesResolveByRoster() throws {
        let (_,rows) = try execute(query(.player,.period,player:"Victor Wembanyama",period:4))
        #expect((rows[0]["scope"] as? String)?.contains("Q4") == true)
        let person = (rows[0]["players"] as! [[String:Any]])[0]
        #expect(person["playerID"] as? String == "5104157")
        #expect((person["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 7)
        let (_,byGame) = try execute(query(.player,.game,player:"5104157"))
        let row = (byGame[0]["players"] as! [[String:Any]])[0]
        #expect(row["fullGameRecordedPoints"] as? Int == 43)
        #expect(row["fullGamePointsMatchBox"] as? Bool == true)
        #expect((row["recordedByPeriod"] as? [[String:Any]])?.count == 4)
    }
    @Test func whoScoredInTheSelectionIsComputedForBothTeams() throws {
        let (_,rows) = try execute(query(.player,.selected,player:nil))
        let people = rows[0]["players"] as! [[String:Any]]
        let total = people.reduce(0) { $0 + (($1["allTypesRecordedMetrics"] as? [String:Int])?["points"] ?? 0) }
        #expect(total == 14)
        #expect(people.contains { $0["playerID"] as? String == "5104157" && ($0["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 0 })
    }
    @Test func leadChangesAndRunsHaveRealSourceIDsAndNeverInferTactics() throws {
        let (lead,rows) = try execute(query(.lead_changes,.selected,player:nil))
        let changes = rows[0]["verifiedLeadChanges"] as! [[String:Any]]
        #expect(!changes.isEmpty);#expect(changes.contains { $0["newLeader"] as? String == "森林狼" })
        #expect(!lead.evidence.events.isEmpty)
        let (_,runs) = try execute(query(.runs,.selected,player:nil))
        let list = runs[0]["unansweredRuns"] as! [[String:Any]]
        #expect(list.contains { $0["unansweredPoints"] as? Int == 14 })
        #expect(runs[0]["verifiedFourMinuteSwing"] != nil)
    }
    @Test func noPlayDataTriggersResearchButNeverClaimsZeroClutchContribution() throws {
        var root = try JSONSerialization.jsonObject(with:fixture()) as! [String:Any];root["plays"] = []
        let e = try evidence(JSONSerialization.data(withJSONObject:root))
        let (result,rows) = try execute(query(.player,.clutch),e:e)
        #expect(!result.requiresOfficial);#expect(result.missingEvents)
        #expect(rows[0]["timeCovered"] as? Bool == false)
        #expect(rows[0]["countsAreExactForVerifiedScope"] as? Bool == false)
    }
    @Test func duplicateMissingMappingsAndConflictingScoreRecordsStayQualified() throws {
        var root = try JSONSerialization.jsonObject(with:fixture()) as! [String:Any]
        var plays = root["plays"] as! [[String:Any]]
        let index = plays.firstIndex { $0["id"] as? String == "401909901686" }!
        var conflict = plays[index];conflict["homeScore"] = 119;plays.append(conflict);root["plays"] = plays
        let e = try evidence(JSONSerialization.data(withJSONObject:root));let (_,rows) = try execute(query(.player,.last_five),e:e)
        #expect(rows[0]["scoreSequenceVerified"] as? Bool == false)
        plays.removeLast();plays[index]["participants"] = [];root["plays"] = plays
        let unknown = try evidence(JSONSerialization.data(withJSONObject:root));let (gap,qualified) = try execute(query(.player,.last_five),e:unknown)
        #expect(!gap.requiresOfficial);#expect((qualified[0]["playerAttributionGaps"] as? Int ?? 0)>0)
        #expect(qualified[0]["countsAreExactForVerifiedScope"] as? Bool == false)
    }
    @Test func explicitRangesAndEventTypeFiltersAreBounded() throws {
        let q = NBAReviewGameQuery.Query(kind:.events,scope:.range,player:"文班亚马",period:4,remainingFrom:300,remainingTo:120,eventTypes:["block"])
        let (_,rows) = try execute(q)
        let records = rows[0]["events"] as! [[String:Any]]
        #expect(records.count == 1);#expect(records.first?["eventID"] as? String == "401909901683")
        let invalid = "{\"queries\":[],\"needsOfficialResearch\":false}"
        #expect(throws: NBARecapError.invalidData) { try NBAReviewGameQuery.decode(invalid) }
    }
    @Test func unresolvedPronounsNeedClarificationAndRecentDataIsNotInvented() throws {
        let (unknown,_) = try execute(query(.player,.last_five,player:"他"))
        #expect(unknown.needsClarification);#expect(!unknown.requiresOfficial)
        let (recent,rows) = try execute(query(.recent,.game,player:nil))
        #expect(!recent.requiresOfficial);#expect((rows[0]["status"] as? String)?.contains("缺少") == true)
    }
    private func closeGame(overtime: Bool = false, clockCorrection: Bool = false, missingEnd: Bool = false) throws -> NBAReviewEvidence {
        func p(_ n: Int,_ period: Int,_ clock: String,_ h: Int,_ a: Int,_ team: String?,_ ids: [String],_ text: String,_ score: Int = 0,_ shot: Bool = false) -> [String:Any] {
            var x: [String:Any] = ["id":"12345\(n)","sequenceNumber":String(n),"period":["number":period],"clock":["displayValue":clock],"homeScore":h,"awayScore":a,"text":text,"scoreValue":score,"scoringPlay":score>0,"shootingPlay":shot,"participants":ids.map { ["athlete":["id":$0]] }]
            if let team { x["team"] = ["id":team] };return x
        }
        var plays = [p(0,3,"0:00",0,0,nil,[],"End Period"),p(1,4,"12:00",0,0,nil,[],"Start Period"),p(2,4,"5:01",0,0,nil,[],"Timeout"),
            p(3,4,"5:00",2,0,"1",["100"],"Alpha One makes two point jumper",2,true),
            p(4,4,"4:59",2,2,"2",["200"],"Beta Two makes two point jumper",2,true),
            p(6,4,"4:20",5,2,"1",["100","300"],"Alpha One makes three point jumper (Gamma Three assists)",3,true),
            p(7,4,"3:30",5,2,"2",["200","300"],"Gamma Three blocks Beta Two's layup",0,true),
            p(8,4,"3:29",5,2,"1",["300"],"Gamma Three defensive rebound"),
            p(9,4,"2:00",5,2,"1",["300","200"],"Gamma Three bad pass turnover (Beta Two steals)"),
            p(10,4,"0:40",5,4,"2",["200"],"Beta Two makes two point jumper",2,true),
            p(11,4,"0:00",6,4,"1",["300"],"Gamma Three makes free throw 1 of 1",1,true),p(12,4,"0:00",6,4,nil,[],"End Period")]
        if clockCorrection { plays.append(p(5,4,"5:01",2,2,nil,[],"Clock corrected")) }
        var home = 6,away = 4
        if overtime {
            plays.removeLast();plays += [p(12,4,"0:00",6,6,"2",["200"],"Beta Two makes two point jumper",2,true),p(13,4,"0:00",6,6,nil,[],"End Period"),p(14,5,"5:00",6,6,nil,[],"Start Period"),p(15,5,"4:59",9,6,"1",["100"],"Alpha One makes three point jumper",3,true),p(16,5,"0:00",9,7,"2",["200"],"Beta Two makes free throw 1 of 1",1,true),p(17,5,"0:00",9,7,nil,[],"End Game")]
            home = 9;away = 7
        }
        if missingEnd { plays.removeAll { ($0["clock"] as? [String:String])?["displayValue"] == "0:00" && ($0["period"] as? [String:Int])?["number"] == 4 } }
        func team(_ id:String,_ name:String) -> [String:Any] { ["id":id,"displayName":name] }
        func player(_ id:String,_ name:String) -> [String:Any] { ["athlete":["id":id,"displayName":name],"stats":["5","30"],"didNotPlay":false] }
        let root: [String:Any] = ["header":["id":"12345","competitions":[["date":"2026-11-01T00:00Z","status":["type":["name":overtime ? "STATUS_FINAL_OVERTIME":"STATUS_FINAL","state":"post","completed":true]],"competitors":[["homeAway":"home","score":String(home),"team":team("1","Home")],["homeAway":"away","score":String(away),"team":team("2","Away")]]]]],"boxscore":["players":[["team":team("1","Home"),"statistics":[["names":["PTS","MIN"],"athletes":[player("100","Alpha One"),player("300","Gamma Three")]]]],["team":team("2","Away"),"statistics":[["names":["PTS","MIN"],"athletes":[player("200","Beta Two")]]]]]],"plays":plays]
        return try NBAReviewEvidence.make(data:JSONSerialization.data(withJSONObject:root),gameID:"12345",dataAsOf:Date())
    }
    @Test func positiveClutchUsesPreEventMarginAndIncludesExactlyFiveMinutesAndZeroClock() throws {
        let e = try closeGame()
        let request = NBAReviewGameQuery.Request(queries:[query(.player,.clutch,player:"Alpha One")],needsOfficialResearch:false)
        let result = try NBAReviewGameQuery.execute(request,evidence:e,segmentID:nil)
        let root = try NBAReviewPacketTestSupport.decode(Data(result.json.utf8)),row = (root["queries"] as! [[String:Any]])[0]
        #expect(row["qualifyingClutchExists"] as? Bool == true);#expect(row["scoreSequenceVerified"] as? Bool == true)
        #expect(((row["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 5)
        #expect(result.evidence.events.contains { $0.id == "123453" })
        let gamma = try NBAReviewGameQuery.execute(.init(queries:[query(.player,.clutch,player:"Gamma Three")],needsOfficialResearch:false),evidence:e,segmentID:nil)
        #expect(gamma.evidence.events.contains { $0.id == "1234511" && $0.label.contains("0:00") })
    }
    @Test func overtimeUsesFiveMinutePeriodAndCarriesFourthQuarterEvidence() throws {
        let e = try closeGame(overtime:true)
        let (result,rows) = try execute(query(.player,.period,player:"Alpha One",period:5),e:e)
        #expect((rows[0]["scope"] as? String)?.contains("5:00") == true)
        #expect(((rows[0]["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 3)
        #expect(!result.requiresOfficial)
        let (_,clutch) = try execute(query(.player,.clutch,player:"Alpha One"),e:e)
        #expect(((clutch[0]["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 8)
    }
    @Test func selectedSourceEndpointsAreLeftOpenRightClosedWhileExplicitClockRangeIsInclusive() throws {
        let e = try closeGame()
        let selection = NBAReviewEvidence.Segment(id:"manual",title:"所选",time:"Q4 5:00–0:00",headline:"",detail:"",start:nil,end:nil,evidenceIDs:["play.123453","play.1234511"])
        let a = try NBAReviewGameQuery.execute(.init(queries:[query(.player,.selected,player:"Alpha One")],needsOfficialResearch:false),evidence:e,segmentID:nil,frozenSelection:selection)
        let root = try NBAReviewPacketTestSupport.decode(Data(a.json.utf8)),row = (root["queries"] as! [[String:Any]])[0]
        #expect(((row["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 3)
        #expect((row["definition"] as? String)?.contains("左开右闭") == true)
        let range = NBAReviewGameQuery.Query(kind:.player,scope:.range,player:"Alpha One",period:4,remainingFrom:300,remainingTo:0,eventTypes:[])
        let (_,rows) = try execute(range,e:e)
        #expect(((rows[0]["players"] as! [[String:Any]])[0]["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 5)
    }
    @Test func clockCorrectionOutsideFilterAndPartialEndPreventAFalseCompleteClutchClaim() throws {
        let (_,corrected) = try execute(query(.player,.clutch,player:"Alpha One"),e:closeGame(clockCorrection:true))
        #expect(corrected[0]["scoreSequenceVerified"] as? Bool == false)
        #expect(corrected[0]["qualifyingClutchExists"] is NSNull)
        let (missing,rows) = try execute(query(.player,.clutch,player:"Alpha One"),e:closeGame(missingEnd:true))
        #expect(missing.missingEvents);#expect(rows[0]["qualifyingClutchExists"] is NSNull)
    }
    @Test func aliasesAreUniqueToTheCurrentRosterAndUnsafeToolArgumentsAreRejected() throws {
        let (_,rows) = try execute(query(.player,.last_five,player:"文班"))
        #expect((rows[0]["players"] as! [[String:Any]])[0]["playerID"] as? String == "5104157")
        let request = NBAReviewGameQuery.Request(queries:[query(.player,.period,player:"Alpha One",period:5)],needsOfficialResearch:false)
        var raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
        raw["url"] = "https://example.com/private"
        #expect(throws: NBARecapError.invalidData) { try NBAReviewGameQuery.decode(String(decoding:JSONSerialization.data(withJSONObject:raw),as:UTF8.self)) }
        let invalidRange = NBAReviewGameQuery.Query(kind:.events,scope:.range,player:nil,period:5,remainingFrom:720,remainingTo:0,eventTypes:[])
        #expect(throws: NBARecapError.invalidData) { try NBAReviewGameQuery.execute(.init(queries:[invalidRange],needsOfficialResearch:false),evidence:closeGame(overtime:true),segmentID:nil) }
    }
    @Test func sourceClockLabelsKeepSubsecondEvidenceInsteadOfClaimingZeroClock() {
        #expect(NBAReviewEvidence.clock(25.6) == "0:25.6")
        #expect(NBAReviewEvidence.clock(0.3) == "0:00.3")
        #expect(NBAReviewEvidence.clock(300) == "5:00")
    }
    @Test func queryPromptReplacesTheFalseNoPlaysLimitationAndUsesStrictFunctionCalling() throws {
        let e = try evidence(), body = try NBAReviewQuestionClient.queryBody(evidence:e,segmentID:"focus",pointID:nil,question:"文班亚马在关键时刻发挥作用了吗",turns:[])
        let root = try JSONSerialization.jsonObject(with:body) as! [String:Any]
        #expect((root["tools"] as? [[String:Any]])?.first?["name"] as? String == "query_game_facts")
        #expect(root["parallel_tool_calls"] as? Bool == false)
        #expect(!(try e.questionFacts(segmentID:"focus")).contains("没有逐回合证据"))
        try NBAReviewQuestionClient.validateRequest(body,search:false)
        #expect(throws: NBARecapError.invalidData) { try NBAReviewQuestionClient.validateRequest(body,search:true) }
        let recent = try NBAReviewGameQuery.execute(.init(queries:[query(.recent,.game,player:nil)],needsExternalResearch:true,intent:.externalFact),evidence:e,segmentID:"focus")
        let call = NBAReviewAnswer.ToolCall(id:"fc_test",callID:"call_test",name:"query_game_facts",arguments:"{}")
        let final = try JSONSerialization.jsonObject(with:NBAReviewQuestionClient.answerBody(evidence:e,segmentID:"focus",pointID:nil,question:"近期表现怎么样",turns:[],call:call,result:recent)) as! [String:Any]
        #expect((final["tools"] as? [[String:Any]])?.first?["type"] as? String == "web_search")
    }
    private func response(_ output: [[String:Any]], tokens: Int = 1000) throws -> Data {
        try JSONSerialization.data(withJSONObject:["id":"resp_query_test","model":NBATerraClient.model,"status":"completed","output":output,"usage":["input_tokens":tokens,"output_tokens":50]])
    }
    @Test func twoPassResearchActuallyExecutesToolAndAccountsForBothRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let e = try evidence(), wire = QueryWire(), args = String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:[query()],needsOfficialResearch:false)),as:UTF8.self)
        let plan = try response([["type":"function_call","id":"fc_test","call_id":"call_test","name":"query_game_facts","arguments":args]])
        let final = try response([["type":"message","role":"assistant","content":[["type":"output_text","text":"所选段文班亚马0分，投篮0中2；末节最后5分钟3分、1助攻、1盖帽。没有符合分差口径的clutch回合。","annotations":[]]]]])
        let reads = CredentialProbe(), accesses = CredentialProbe()
        let lease = NBACredentialSession { mode in reads.record(mode); return "test" }
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{ accesses.record(false); return try lease.read() },send:{ request in
            let root = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1600}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            await wire.record(root)
            let isPlan = (root["tools"] as? [[String:Any]])?.first?["type"] as? String == "function"
            if !isPlan {
                let messages = root["input"] as! [[String:Any]]
                #expect(messages.contains { $0["type"] as? String == "function_call_output" && ($0["output"] as? String)?.contains("401909901686") == true })
            }
            return (isPlan ? plan : final,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":isPlan ? "req_query_test":"req_answer_test"])!)
        }),receiptDirectory:directory.appendingPathComponent("receipts"))
        let budget = NBATerraAutofill(file:directory.appendingPathComponent("ledger.json"))
        let answer = try await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"文班亚马在关键时刻发挥作用了吗",turns:[],boxes:NBABoxScoreStore(directory:directory.appendingPathComponent("boxes"),fetch:{ _ in throw NBARecapError.network }))
        #expect(answer.queryRequestID == "req_query_test");#expect(answer.localEvidence?.events.isEmpty == false)
        #expect(await wire.types() == ["function","none"])
        let ledger = await budget.snapshot();#expect(ledger.reviewOperations?.count == 2)
        #expect(abs(ledger.spentUSD-0.0025)<0.000001)
        #expect(accesses.count == 4); #expect(reads.count == 1)
        _ = try await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"那他最后5分钟呢？",turns:[.init(question:"文班亚马在关键时刻发挥作用了吗",answer:answer)],boxes:NBABoxScoreStore(directory:directory.appendingPathComponent("boxes"),fetch:{ _ in throw NBARecapError.network }))
        #expect(accesses.count == 8); #expect(reads.count == 1)
    }
    @Test func cancellationAfterAChargedPlanDoesNotDispatchTheAnswerOrRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let e = try evidence(),wire = QueryWire(),args = String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:[query()],needsOfficialResearch:false)),as:UTF8.self)
        let plan = try response([["type":"function_call","call_id":"call_cancel","name":"query_game_facts","arguments":args]])
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"test"},send:{ request in
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1600}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            await wire.record(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any])
            try? await Task.sleep(nanoseconds:100_000_000)
            return (plan,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"req_cancel_test"])!)
        }),receiptDirectory:directory.appendingPathComponent("receipts"))
        let budget = NBATerraAutofill(file:directory.appendingPathComponent("ledger.json"))
        let task = Task { try await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"这段文班发挥怎么样",turns:[],boxes:NBABoxScoreStore(directory:directory.appendingPathComponent("boxes"),fetch:{ _ in throw NBARecapError.network })) }
        for _ in 0..<100 { if await wire.count == 1 { break };try await Task.sleep(nanoseconds:1_000_000) }
        task.cancel();_ = try? await task.value
        #expect(await wire.count == 1)
        let ledger = await budget.snapshot();#expect(abs(ledger.spentUSD-0.00125)<0.000001)
        #expect(ledger.reviewOperations?.count == 1)
    }
    @Test func insufficientFollowupSearchBudgetKeepsPlanCostAndSendsNoSecondRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let existingSpend = NBATerraAutofill.dailyLimitUSD - 0.05
        var saved = NBATerraAutofill.Ledger();saved.day = NBAHistoryStore.dayKey(Date(),calendar:NBASchedulePolicy.calendar);saved.spentUSD = existingSpend
        let file = directory.appendingPathComponent("ledger.json");try JSONEncoder().encode(saved).write(to:file)
        let e = try evidence(),wire = QueryWire(),args = String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:[query(.recent,.game,player:nil)],needsOfficialResearch:true)),as:UTF8.self)
        let plan = try response([["type":"function_call","call_id":"call_budget","name":"query_game_facts","arguments":args]])
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"test"},send:{ request in
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1600}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            await wire.record(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any])
            return (plan,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"req_budget_test"])!)
        }),receiptDirectory:directory.appendingPathComponent("receipts"))
        let budget = NBATerraAutofill(file:file)
        do { _ = try await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"近期表现怎么样",turns:[],boxes:NBABoxScoreStore(directory:directory.appendingPathComponent("boxes"),fetch:{ _ in throw NBARecapError.network }));Issue.record("Search should not fit") }
        catch { #expect(error is NBAReviewResearch.Failure) }
        #expect(await wire.count == 1);#expect(abs((await budget.snapshot()).spentUSD-(existingSpend+0.00125))<0.000001)
    }
    @Test func anUnconfirmedNetworkTimeoutRetainsWorstCaseCostWithoutRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let e = try evidence(),wire = QueryWire()
        let client = NBAReviewQuestionClient(transport:NBATerraClient(authorized:true,credential:{"test"},send:{ request in
            if request.url!.path.hasSuffix("input_tokens") { return (Data("{\"input_tokens\":1600}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            await wire.record(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]);throw NBARecapError.timeout
        }),receiptDirectory:directory.appendingPathComponent("receipts"))
        let budget = NBATerraAutofill(file:directory.appendingPathComponent("ledger.json"))
        _ = try? await NBAReviewResearch(budget:budget,client:client).answer(evidence:e,segmentID:"focus",pointID:nil,question:"这一段谁得分",turns:[],boxes:NBABoxScoreStore(directory:directory.appendingPathComponent("boxes"),fetch:{ _ in throw NBARecapError.network }))
        let ledger = await budget.snapshot();#expect(await wire.count == 1)
        #expect(ledger.spentUSD > 0.006);#expect(ledger.reviewOperations?.values.first?.actualUSD == nil)
        #expect(ledger.spentUSD == ledger.reviewOperations?.values.first?.reservedUSD)
    }
    @Test func completedLocalAnswersSurviveRestartWithoutAnotherModelCall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let wire = QueryWire(),value = NBAReviewAnswer(gameID:"12345",text:"本场已核资料。",sources:[],citations:[],generatedAt:Date(),requestID:"req_cache_test",responseID:nil,usage:nil,searched:false)
        let first = NBAReviewQuestionStore(directory:directory)
        _ = try await first.answer(key:"version2samefacts",gameID:"12345") { await wire.record([:]);return value }
        let second = NBAReviewQuestionStore(directory:directory)
        let cached = try await second.answer(key:"version2samefacts",gameID:"12345") { Issue.record("Must reuse disk cache");return value }
        #expect(cached.requestID == "req_cache_test");#expect(await wire.count == 1)
        do { _ = try await second.answer(key:"../outside",gameID:"12345") { value };Issue.record("Unsafe cache path") } catch { #expect(error as? NBARecapError == .invalidData) }
    }
}
