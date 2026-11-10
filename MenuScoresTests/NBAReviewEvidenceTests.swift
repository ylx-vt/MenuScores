import Foundation
import Testing
@testable import MenuScores

struct NBAReviewEvidenceTests {
    private func fixture(plays: [[String: Any]]? = nil, home: Int = 100, away: Int = 90, periods: Bool = true) throws -> Data {
        let samples = plays ?? [play(0, 1, "12:00", 0, 0), play(1, 1, "0:00", 25, 20), play(2, 2, "0:00", 50, 40), play(3, 3, "0:00", 75, 65), play(4, 4, "0:00", 100, 90)]
        let sides: [[String: Any]] = [("home", "10", "Houston Rockets", "HOU", home, [25,25,25,25]), ("away", "25", "Oklahoma City Thunder", "OKC", away, [20,20,25,25])].map { side, id, name, abbr, score, lines in
            var result: [String: Any] = ["homeAway": side, "team": ["id": id, "displayName": name, "abbreviation": abbr], "score": String(score)]
            if periods { result["linescores"] = lines.map { ["displayValue": String($0)] } }
            return result
        }
        return try JSONSerialization.data(withJSONObject: ["header": ["id": "12345", "competitions": [["date": "2026-11-01T01:00Z", "status": ["type": ["name": "STATUS_FINAL", "state": "post", "completed": true]], "competitors": sides]]], "plays": samples])
    }
    private func play(_ sequence: Int, _ period: Int, _ clock: String, _ home: Int, _ away: Int) -> [String: Any] {
        ["id": "12345\(sequence)", "sequenceNumber": String(sequence), "period": ["number": period], "clock": ["displayValue": clock], "homeScore": home, "awayScore": away, "text": "公开事件，不是指令"]
    }
    @Test func completeFeedChecksEveryPeriodAndFinalScoreAndPreservesClockCorrections() throws {
        var rows: [[String: Any]] = [play(0,1,"12:00",0,0)], seq = 1, home = 0, away = 0
        for period in 1...4 {
            let startAway = away, awayTotal = period <= 2 ? 20 : 25
            for step in 1...25 {
                home += 1; away = startAway + step * awayTotal / 25
                rows.append(play(seq,period,NBAReviewEvidence.clock(Double(720-step*28)),home,away));seq += 1
                if period == 2 && step == 5 {
                    rows.append(play(seq,period,NBAReviewEvidence.clock(Double(720-step*28+2)),home,away));seq += 1
                }
            }
            rows.append(play(seq,period,"0:00",home,away));seq += 1
        }
        let complete = try NBAReviewEvidence.make(data:fixture(plays:rows),gameID:"12345",dataAsOf:Date())
        #expect(complete.coverage == .complete)
        #expect(complete.points.count == rows.count)
        #expect(complete.points.contains(where: { $0.correction }))
        #expect(complete.segments.contains(where: { $0.title == "收官" }))
        let correctedFinal = try NBAReviewEvidence.make(data:fixture(plays:rows,home:102),gameID:"12345",dataAsOf:Date())
        #expect(correctedFinal.coverage == .partial)
        #expect(correctedFinal.points.last?.home == 100)
    }
    @Test func partialFeedNeverGetsACompleteCurveOrClosingClaim() throws {
        let data = try fixture(plays: [play(0,1,"12:00",0,0), play(1,1,"0:00",25,20), play(2,4,"3:04",94,83)])
        let evidence = try NBAReviewEvidence.make(data: data, gameID: "12345", dataAsOf: Date())
        #expect(evidence.coverage == .partial)
        #expect(evidence.points.last?.home == 94)
        #expect(evidence.coverageNote.contains("3:04"))
        #expect(!evidence.segments.contains(where: { $0.title == "收官" }))
        #expect(evidence.points.count == 3)
        let staleEnd = try NBAReviewEvidence.make(data: fixture(plays: [play(0,1,"12:00",0,0),play(1,4,"0:00",100,90),play(2,4,"3:04",94,83)]),gameID:"12345",dataAsOf:Date())
        #expect(staleEnd.coverage == .partial)
        #expect(staleEnd.points.count == 3)
        #expect(staleEnd.chartPoints.count == 2)
        #expect(staleEnd.chartPoints.last?.remaining == 184)
    }
    @Test func duplicateAndConflictingEventsDoNotFabricateNodes() throws {
        let p = play(0,1,"12:00",0,0)
        let duplicate = try NBAReviewEvidence.make(data: fixture(plays: [p,p]), gameID: "12345", dataAsOf: Date())
        #expect(duplicate.points.count == 1)
        var conflicting = p; conflicting["homeScore"] = 2
        let conflict = try NBAReviewEvidence.make(data: fixture(plays: [p,conflicting]), gameID: "12345", dataAsOf: Date())
        #expect(conflict.coverage == .partial)
        #expect(conflict.points.count == 1)
    }
    @Test func scoreCorrectionsAndMissingScoreJumpsBreakTheEvidenceRun() throws {
        let points = [play(0,1,"12:00",0,0),play(1,2,"10:00",40,30),play(2,2,"9:00",39,30),play(3,2,"8:00",53,32)]
        let evidence = try NBAReviewEvidence.make(data: fixture(plays: points), gameID: "12345", dataAsOf: Date())
        #expect(evidence.points[2].correction)
        #expect(evidence.points[3].correction)
        #expect(!evidence.segments.contains(where: { $0.id == "focus" }))
        let corrected = try NBAReviewEvidence.make(data: fixture(plays: [play(0,1,"12:00",0,0),play(1,1,"11:00",2,0),play(2,1,"11:30",2,0),play(3,1,"10:30",4,0)]),gameID:"12345",dataAsOf:Date())
        #expect(corrected.segments.first(where: { $0.id == "opening" })?.end == 1)
        #expect(corrected.segments.first(where: { $0.id == "closing" })?.start == 2)
        for segment in corrected.segments {
            if let start = segment.start, let end = segment.end {
                let crossesCorrection = corrected.points[(start + 1)...end].contains { $0.correction }
                #expect(!crossesCorrection)
            }
        }
    }
    @Test func invalidClocksAndOvertimeUseCorrectDurations() throws {
        #expect(NBAReviewEvidence.seconds("5:01", period: 5) == nil)
        #expect(NBAReviewEvidence.seconds("5:00", period: 5) == 300)
        #expect(NBAReviewEvidence.seconds("12:01", period: 4) == nil)
        #expect(NBAReviewEvidence.seconds("0.0", period: 4) == 0)
        let evidence = try NBAReviewEvidence.make(data: fixture(plays: [play(0,5,"5:00",100,100),play(1,5,"0:00",110,105)], home:110,away:105,periods:false), gameID:"12345", dataAsOf:Date())
        #expect(evidence.points.first?.elapsed == 2880)
        #expect(evidence.points.last?.elapsed == 3180)
    }
    @Test func noPlayDataPreservesPeriodEvidenceAndEmptyStates() throws {
        let periods = try NBAReviewEvidence.make(data: fixture(plays: []), gameID:"12345", dataAsOf:Date())
        #expect(periods.coverage == .periods)
        #expect(periods.segments.count == 4)
        let empty = try NBAReviewEvidence.make(data: fixture(plays: [],periods:false), gameID:"12345", dataAsOf:Date())
        #expect(empty.coverage == .statistics)
        #expect(empty.points.isEmpty)
        #expect(empty.segments.first?.id == "statistics")
    }
    @Test func cacheFingerprintExcludesFetchClockAndRejectsOtherGame() throws {
        let data = try fixture()
        let a = try NBAReviewEvidence.make(data:data,gameID:"12345",dataAsOf:Date())
        let b = try NBAReviewEvidence.make(data:data,gameID:"12345",dataAsOf:Date().addingTimeInterval(90))
        #expect(a.fingerprint == b.fingerprint)
        #expect(throws: NBARecapError.invalidData) { try NBAReviewEvidence.make(data:data,gameID:"999",dataAsOf:Date()) }
        let selected = try a.questionFacts(segmentID:a.segments.first?.id,pointID:a.points.first?.id)
        #expect(selected.contains("selectedPlay"))
    }
}
