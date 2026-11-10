import Foundation
import Testing
@testable import MenuScores

struct NBAReviewPayloadAndRoleTests {
    private func fixture() throws -> Data { try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NBA-review-Spurs-Timberwolves-final.json")) }
    private func evidence() throws -> NBAReviewEvidence { try .make(data:fixture(),gameID:"401909901",dataAsOf:Date()) }
    private func query(_ kind: NBAReviewGameQuery.Query.Kind,player: String? = nil,scope: NBAReviewGameQuery.Query.Scope = .game,period: Int? = nil) -> NBAReviewGameQuery.Query { .init(kind:kind,scope:scope,player:player,period:period,remainingFrom:nil,remainingTo:nil,eventTypes:[]) }
    @Test func observedLiveThreeQueryPlanFitsWithoutDroppingPlayersOrCounts() throws {
        // Exact successful planner receipt req_afd4aff...; the old app rejected
        // its >30KB result with the unrelated recap identity error.
        let arguments = #"{"intent":"match_analysis","needsExternalResearch":false,"queries":[{"eventTypes":[],"kind":"impact","period":null,"player":null,"remainingFrom":null,"remainingTo":null,"scope":"game"},{"eventTypes":["score"],"kind":"player","period":null,"player":null,"remainingFrom":null,"remainingTo":null,"scope":"close"},{"eventTypes":["score"],"kind":"player","period":4,"player":null,"remainingFrom":null,"remainingTo":null,"scope":"close"}]}"#
        let request = try NBAReviewGameQuery.decode(arguments),e = try evidence()
        let result = try NBAReviewGameQuery.execute(request,evidence:e,segmentID:"focus")
        let json = try JSONSerialization.jsonObject(with:Data(result.json.utf8)) as! [String:Any]
        #expect(result.json.utf8.count <= 30_000)
        #expect((json["payloadCompactedFromBytes"] as? Int ?? 0) > 30_000)
        #expect(json["packetVersion"] as? Int == 2)
        let rows = json["queries"] as! [[String:Any]]
        #expect(rows.count == 3)
        let decoded = try NBAReviewPacketTestSupport.decode(Data(result.json.utf8))
        let players = (decoded["queries"] as! [[String:Any]])[1]["players"] as! [[String:Any]]
        let wemb = try #require(players.first { $0["playerID"] as? String == "5104157" })
        #expect((wemb["allTypesRecordedMetrics"] as? [String:Int])?["points"] == 26)
        #expect((wemb["fullGameBoxStatistics"] as? [String:Any])?["PTS"] as? String == "43")
        let call = NBAReviewAnswer.ToolCall(id:nil,callID:"replay",name:"query_game_facts",arguments:arguments)
        let body = try NBAReviewQuestionClient.answerBody(evidence:e,segmentID:"focus",pointID:nil,question:"谁是关键时刻制胜之钥，给我论据",turns:[],call:call,result:result)
        #expect(body.count <= 80_000);#expect(!result.requiresOfficial)
    }
    @Test func starterFlagSurvivesParsingEvenWithPartialPlayCoverage() throws {
        let e = try evidence(),harper = try #require(e.athletes.first { $0.originalName == "Dylan Harper" })
        #expect(e.coverage == .partial);#expect(harper.starter == true);#expect(harper.lineupRole == "首发")
        let result = try NBAReviewGameQuery.execute(.init(queries:[query(.availability,player:"哈珀")],needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:nil)
        let root = try JSONSerialization.jsonObject(with:Data(result.json.utf8)) as! [String:Any]
        let rows = root["queries"] as! [[String:Any]],players = rows[0]["players"] as! [[String:Any]]
        #expect(players[0]["starter"] as? Bool == true);#expect(players[0]["bench"] as? Bool == false)
        let facts = try JSONSerialization.jsonObject(with:Data(e.questionFacts(segmentID:nil).utf8)) as! [String:Any]
        #expect((facts["rosterForMatching"] as? String)?.contains("迪伦·哈珀 / Dylan Harper · 本场首发") == true)
    }
    @Test func rotationSeparatesOnOffAndDoesNotInventFirstBenchRole() throws {
        let e = try evidence(),harper = try #require(e.athletes.first { $0.originalName == "Dylan Harper" })
        let r = NBAReviewPlayerRotation.make(athlete:harper,evidence:e,selected:Set(e.points.indices))
        let events = r.json["substitutions"] as! [[String:Any]]
        #expect(events.contains { $0["direction"] as? String == "off" && ($0["time"] as? String)?.contains("4:23") == true })
        #expect(events.contains { $0["direction"] as? String == "on" && ($0["time"] as? String)?.contains("0:35.6") == true })
        #expect(r.json["starter"] as? Bool == true)
        #expect(r.json["firstEntryIsProvenActualFirst"] as? Bool == false)
        #expect((r.json["fullGameRecordedStints"] as? [[String:Any]])?.first?["start"] as? String == "开场（boxscore首发标记）")
    }
    @Test func missingStarterAndDNPRemainDistinctFromBench() throws {
        var root = try JSONSerialization.jsonObject(with:fixture()) as! [String:Any],box = root["boxscore"] as! [String:Any],teams = box["players"] as! [[String:Any]]
        for t in teams.indices { var blocks = teams[t]["statistics"] as! [[String:Any]];for b in blocks.indices { var rows = blocks[b]["athletes"] as! [[String:Any]];for i in rows.indices { rows[i]["starter"] = nil };blocks[b]["athletes"] = rows };teams[t]["statistics"] = blocks };box["players"] = teams;root["boxscore"] = box
        let e = try NBAReviewEvidence.make(data:JSONSerialization.data(withJSONObject:root),gameID:"401909901",dataAsOf:Date())
        #expect(e.athletes.allSatisfy{$0.starter == nil})
        let a = NBAReviewEvidence.Athlete(id:"fixture",name:"测试",originalName:"Fixture",teamID:"24",statistics:[:],didNotPlay:true,starter:false)
        #expect(a.lineupRole == "未出场")
    }
    @Test func recentRolesUseDatedCachedSamplesNotALongTermRoleAssertion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try fixture().write(to:folder.appendingPathComponent("401909901.json"))
        let history = NBAReviewPlayerHistory(directory:folder),e = try evidence(),harper = try #require(e.athletes.first { $0.originalName == "Dylan Harper" })
        let rows = await history.lookup(playerIDs:[harper.id],now:Date(timeIntervalSince1970:1_900_000_000))
        #expect(rows.count == 1);#expect(rows[0].starter == true);#expect(rows[0].points == 25)
        let r = try NBAReviewGameQuery.execute(.init(queries:[query(.recent,player:"哈珀")],needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:nil,recentRoles:rows)
        #expect(r.json.contains("cachedAppearances"));#expect(r.json.contains("不代表完整赛季"));#expect(r.evidence.identitySources?.count == 1)
    }
}
