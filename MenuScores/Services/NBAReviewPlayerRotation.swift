import Foundation

/// Individual recorded substitutions, never an inferred five-player lineup.
struct NBAReviewPlayerRotation {
    let json: [String:Any]
    let events: [NBAReviewEvidence.Point]
    let numbers: Set<Double>
    static func direction(_ p: NBAReviewEvidence.Point, athlete: NBAReviewEvidence.Athlete) -> String? {
        guard p.participantIDs.contains(athlete.id) else { return nil }
        let text = NBAReviewGameQuery.normalized(p.text), name = NBAReviewGameQuery.normalized(athlete.originalName)
        if text.hasPrefix(name + " enters the game for ") { return "on" }
        if text.contains(" enters the game for " + name) { return "off" }
        return nil
    }
    static func make(athlete: NBAReviewEvidence.Athlete,evidence e: NBAReviewEvidence,selected: Set<Int>) -> Self {
        let all = e.points.enumerated().compactMap { index,p -> (Int,NBAReviewEvidence.Point,String)? in direction(p,athlete:athlete).map { (index,p,$0) } }
        let chosen = all.filter { selected.contains($0.0) }
        let records: [[String:Any]] = chosen.prefix(20).map { _,p,dir in ["eventID":p.id,"direction":dir,"time":p.label,"score":"\(p.away)–\(p.home)","text":p.text] }
        var stints: [[String:Any]] = [], start: NBAReviewEvidence.Point?, fromTipoff = athlete.starter == true
        for (_,p,dir) in all {
            if dir == "on" { start = p;fromTipoff = false }
            else {
                if fromTipoff || start != nil {
                    stints.append(["start":fromTipoff ? "开场（boxscore首发标记）" : start!.label,"startEventID":start?.id as Any? ?? NSNull(),"end":p.label,"endEventID":p.id,"coverage":e.coverage == .complete ? "逐回合覆盖已核，未发现漏换人" : "已记录边界，期间可能缺换人；不据此精算上场时间"])
                }
                start = nil;fromTipoff = false
            }
        }
        if let start { stints.append(["start":start.label,"startEventID":start.id,"end":NSNull(),"coverage":"未配对到后续换出；不把缺失结束当一直在场"]) }
        let first = all.first(where:{$0.2 == "on"})?.1
        let teamEntries = e.points.filter { p in e.athletes.contains { $0.teamID == athlete.teamID && direction(p,athlete:$0) == "on" } }
        let firstTeam = teamEntries.first
        let sameFirstBatch = first.map { p in firstTeam.map { $0.elapsed == p.elapsed } ?? false }
        let json: [String:Any] = ["playerID":athlete.id,"player":athlete.name,"starter":athlete.starter as Any? ?? NSNull(),"role":athlete.lineupRole,"didNotPlay":athlete.didNotPlay,"substitutions":records,"recordedSubstitutionCount":chosen.count,"examplesLimited":chosen.count > 20,"fullGameRecordedStints":Array(stints.prefix(12)),"fullGameFirstRecordedEntry":first.map { ["eventID":$0.id,"time":$0.label] } as Any? ?? NSNull(),"inFirstRecordedTeamEntryBatch":sameFirstBatch as Any? ?? NSNull(),"firstEntryIsProvenActualFirst":e.coverage == .complete,"limit":"substitutions按所选范围筛选；fullGame字段仅为该球员全场记录背景，不混作所选时段。首发标记与长期第六人角色分开；已记录首个换入不必然是实际首轮替补，不推算在场正负值。"]
        var numbers: Set<Double> = [Double(chosen.count)]
        for (_,p,_) in all {
            [p.period,p.home,p.away,Int(p.remaining)/60,Int(p.remaining)%60].forEach { numbers.insert(Double($0)) }
            numbers.insert((p.remaining.truncatingRemainder(dividingBy:60)*1000).rounded()/1000)
        }
        let references = (chosen + all).reduce(into:[NBAReviewEvidence.Point]()) { rows, item in if !rows.contains(where:{$0.id == item.1.id}) { rows.append(item.1) } }
        return .init(json:json,events:Array(references.prefix(24)),numbers:numbers)
    }
}
