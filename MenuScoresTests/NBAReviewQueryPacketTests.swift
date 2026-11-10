import Foundation
import Testing
@testable import MenuScores

struct NBAReviewQueryPacketTests {
    private func evidence(_ name: String = "NBA-review-Grizzlies-Kings-final",id: String = "401909899") throws -> NBAReviewEvidence {
        let f = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+name+".json")
        return try .make(data:Data(contentsOf:f),gameID:id,dataAsOf:Date())
    }
    private func q(_ kind: NBAReviewGameQuery.Query.Kind,scope: NBAReviewGameQuery.Query.Scope = .game,period: Int? = nil) -> NBAReviewGameQuery.Query { .init(kind:kind,scope:scope,player:nil,period:period,remainingFrom:nil,remainingTo:nil,eventTypes:["score"]) }
    @Test func bothObservedMemphisPlansAndBroadCriticalQueriesHaveHeadroom() throws {
        let e = try evidence()
        let plans = [[q(.impact),q(.player,scope:.period,period:1),q(.player,scope:.period,period:3)],
                     [q(.impact),q(.player,scope:.period,period:3),q(.runs)],
                     [q(.player,scope:.critical),q(.events,scope:.critical),q(.player,scope:.critical)]]
        for queries in plans {
            let r = try NBAReviewGameQuery.execute(.init(queries:queries,needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:"focus")
            #expect(r.json.utf8.count <= NBAReviewQueryPacket.targetBytes)
            let raw = try JSONSerialization.jsonObject(with:Data(r.json.utf8)) as! [String:Any]
            #expect(raw["packetVersion"] as? Int == 2);#expect(raw["allComputedAggregateRowsRetained"] as? Bool == true)
            #expect(!(raw["eventDetails"] as! [Any]).isEmpty)
            let fields = raw["statisticFields"] as! [String],profileFields = raw["playerFields"] as! [String],profiles = raw["playersByID"] as! [String:[Any]]
            let boozer = profiles["5041935"]![profileFields.firstIndex(of:"statistics")!] as! [Any]
            #expect(boozer[fields.firstIndex(of:"PTS")!] as? String == "27")
            #expect((raw["queries"] as! [Any]).count == (queries.first?.scope == .critical ? 9 : 3))
            let call = NBAReviewAnswer.ToolCall(id:nil,callID:"offline",name:"query_game_facts",arguments:String(decoding:try JSONEncoder().encode(NBAReviewGameQuery.Request(queries:queries,needsExternalResearch:false,intent:.matchAnalysis)),as:UTF8.self))
            #expect(try NBAReviewQuestionClient.answerBody(evidence:e,segmentID:"focus",pointID:nil,question:"今天是谁帮助灰熊建立了这么大的领先优势？",turns:[],call:call,result:r).count < 60_000)
        }
    }
    @Test func sharedMetricReferencesPreserveEveryScopesScoringTotals() throws {
        let e = try evidence(),queries = [q(.player,scope:.period,period:1),q(.player,scope:.period,period:3),q(.player,scope:.period,period:1)]
        let r = try NBAReviewGameQuery.execute(.init(queries:queries,needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:nil)
        let decoded = try NBAReviewPacketTestSupport.decode(Data(r.json.utf8)),rows = decoded["queries"] as! [[String:Any]]
        let totals = rows.map { row in (row["players"] as! [[String:Any]]).reduce(0) { $0 + (($1["allTypesRecordedMetrics"] as! [String:Int])["points"] ?? 0) } }
        #expect(totals[0] == e.points.filter{$0.period == 1 && $0.scoringPlay}.reduce(0){$0+$1.scoreValue})
        #expect(totals[1] == e.points.filter{$0.period == 3 && $0.scoringPlay}.reduce(0){$0+$1.scoreValue})
        #expect(totals[2] == totals[0])
        let packet = try JSONSerialization.jsonObject(with:Data(r.json.utf8)) as! [String:Any]
        let refs = (packet["queries"] as! [[String:Any]]).flatMap { $0["players"] as! [[String:Any]] }
        #expect((packet["aggregates"] as! [Any]).count < refs.count)
    }
    @Test func eventExamplesNeverClaimToBeACompletePlayByPlayFeed() throws {
        let e = try evidence(),r = try NBAReviewGameQuery.execute(.init(queries:[q(.impact),q(.events),q(.player)],needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:nil)
        let packet = try JSONSerialization.jsonObject(with:Data(r.json.utf8)) as! [String:Any],coverage = packet["eventExampleCoverage"] as! [String:Any]
        #expect((coverage["returned"] as! Int) <= 24)
        #expect((coverage["available"] as! Int) >= (coverage["returned"] as! Int))
        #expect(packet["readingGuide"] as? String != nil)
        #expect(r.json.utf8.count <= NBAReviewQueryPacket.targetBytes)
    }
    @Test func multipleMatchAndQueryShapesStayBoundedWithEveryAggregateAvailable() throws {
        let games = [("NBA-review-Grizzlies-Kings-final","401909899"),("NBA-review-Spurs-Timberwolves-final","401909901"),("NBA-match-final","401909893")]
        let shapes = [[q(.overview),q(.overview),q(.overview)],
                      [q(.impact),q(.player,scope:.period,period:3),q(.lead_changes)],
                      [q(.rotation),q(.rotation,scope:.period,period:1),q(.availability)],
                      [q(.player,scope:.critical),q(.events,scope:.critical),q(.runs)]]
        for (name,id) in games { for shape in shapes {
            let e = try evidence(name,id:id),r = try NBAReviewGameQuery.execute(.init(queries:shape,needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:"focus")
            #expect(r.json.utf8.count <= NBAReviewQueryPacket.targetBytes)
            let raw = try JSONSerialization.jsonObject(with:Data(r.json.utf8)) as! [String:Any]
            #expect((raw["playersByID"] as! [String:Any]).count == e.athletes.count)
            #expect(raw["allComputedAggregateRowsRetained"] as? Bool == true)
        } }
    }
}
