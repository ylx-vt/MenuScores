import Foundation

/// Query-sized facts, not a transcript of the feed. Aggregate rows remain
/// complete for the requested, explicitly covered scopes; event details are
/// bounded examples. Shared tables remove repetition across up to 3 queries.
enum NBAReviewQueryPacket {
    static let targetBytes = 18_000
    static let hardBytes = 24_000
    static func make(_ root: [String:Any], athletes: [NBAReviewEvidence.Athlete], references: [NBAReviewEventReference]) throws -> Data {
        func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes,.fragmentsAllowed]) }
        let original = try encode(root)
        let fields = NBAReviewGameQuery.Metrics().dictionary.keys.sorted()
        let statFields = Set(athletes.flatMap { $0.statistics.keys }).sorted()
        var profiles: [String:Any] = [:]
        let boxStatistics = Dictionary(uniqueKeysWithValues:athletes.map { ($0.id,$0.statistics) })
        for a in athletes { profiles[a.id] = ["name":a.name,"originalName":a.originalName,"teamID":a.teamID,"starter":a.starter as Any? ?? NSNull(),"didNotPlay":a.didNotPlay,"statistics":statFields.map { a.statistics[$0] as Any? ?? NSNull() }] }
        var rules: [String] = [], aggregateRows: [[String:Any]] = [], aggregateIndex: [String:Int] = [:]
        var scopeDefinitions: [[String:Any]] = [],scopeIndex: [String:Int] = [:]
        var eventActors: [[String:Any]] = [],eventActorIndex: [String:Int] = [:]
        var substitutions: [[String:Any]] = [],substitutionIndex: [String:Int] = [:]
        var rotationRows: [[String:Any]] = [],rotationIndex: [String:Int] = [:]
        var eventPool: [String:[String:Any]] = [:], eventOrder: [String] = []
        func event(_ id: String,_ row: [String:Any]) { if eventPool[id] == nil { eventOrder.append(id);eventPool[id] = row } }
        for r in references { event(r.id,["id":r.id,"time":r.label,"score":r.score,"text":r.text]) }
        func rule(_ text: String) -> Int { if let i = rules.firstIndex(of:text) { return i };rules.append(text);return rules.count-1 }
        func project(_ value: Any) throws -> Any {
            if let array = value as? [Any] { return try array.map(project) }
            guard var row = value as? [String:Any] else { return value }
            let playerID = (row["playerID"] ?? row["id"]) as? String
            if let playerID,profiles[playerID] != nil {
                row["fullGameBoxStatistics"] = nil;row["name"] = nil;row["player"] = nil;row["teamID"] = nil
                if let stats = row["statistics"] as? [String:String],stats == boxStatistics[playerID] { row["statistics"] = nil }
                if var profile = profiles[playerID] as? [String:Any] {
                    for key in ["fullGameRecordedPoints","fullGamePointsMatchBox"] { if let item = row.removeValue(forKey:key) { profile[key] = item } }
                    profiles[playerID] = profile
                }
            }
            if let id = row["eventID"] as? String,let text = row["text"] as? String {
                event(id,["id":id,"time":row["time"] ?? "未提供","score":row["score"] ?? "未提供","text":text])
                row["text"] = nil;row["time"] = nil;row["score"] = nil;row["attribution"] = nil
            }
            if row["kind"] as? String == "overview" { row["facts"] = nil;row["matchFactsReference"] = "current_match_input" }
            if row["kind"] as? String == "availability",let players = row["players"] as? [[String:Any]],players.count > 1 {
                row["playerIDs"] = players.compactMap { $0["id"] as? String };row["players"] = nil
                row["availabilitySource"] = "playersByID的starter/didNotPlay，以及statistics中的MIN；不重复整份名单统计。"
            }
            if let players = row["players"] as? [[String:Any]],players.count > 1,row["kind"] as? String == "rotation" {
                row["players"] = players.map { r in var r = r;r["recordedStintCount"] = (r["fullGameRecordedStints"] as? [Any])?.count ?? 0;r["fullGameRecordedStints"] = nil;r["stintDetailsAvailableByPlayerQuery"] = true;return r }
            }
            if row["substitutions"] != nil,let playerID,var profile = profiles[playerID] as? [String:Any] {
                var background: [String:Any] = [:]
                for key in row.keys.sorted() where !["playerID","substitutions","recordedSubstitutionCount","examplesLimited"].contains(key) {
                    if let value = row.removeValue(forKey:key) { background[key] = try project(value) }
                }
                profile["rotationBackground"] = try project(background);profiles[playerID] = profile
            }
            for key in row.keys.sorted() {
                if ["events","substitutions"].contains(key),let events = row[key] as? [[String:Any]] {
                    var indices: [Int] = []
                    for source in events {
                        var item = try project(source) as! [String:Any]
                        if key == "substitutions" { item["playerID"] = playerID }
                        let canonical = String(decoding:try encode(item),as:UTF8.self)
                        let index: Int
                        if key == "events" {
                            if let old = eventActorIndex[canonical] { index = old }
                            else { index = eventActors.count;eventActorIndex[canonical] = index;eventActors.append(item) }
                        } else {
                            if let old = substitutionIndex[canonical] { index = old }
                            else { index = substitutions.count;substitutionIndex[canonical] = index;substitutions.append(item) }
                        }
                        indices.append(index)
                    }
                    row[key == "events" ? "eventActorRefs":"substitutionRefs"] = indices;row[key] = nil
                } else if ["recordedMetrics","allTypesRecordedMetrics","metrics"].contains(key),let metrics = row[key] as? [String:Int] {
                    row[key == "allTypesRecordedMetrics" ? "metrics" : key] = fields.map { metrics[$0] ?? 0 }
                    if key == "allTypesRecordedMetrics" { row[key] = nil }
                } else if ["limits","definition","attribution","coverage","limit"].contains(key),let text = row[key] as? String {
                    row[key] = nil;row[key + "Rule"] = rule(text)
                } else if let item = row[key] { row[key] = try project(item) }
            }
            if row["recordedMetrics"] is [Int],let scope = row.removeValue(forKey:"scope") {
                var definition: [String:Any] = ["scope":scope]
                for key in ["completeCoverage","definitionRule"] { definition[key] = row.removeValue(forKey:key) }
                let canonical = String(decoding:try encode(definition),as:UTF8.self)
                let index: Int
                if let old = scopeIndex[canonical] { index = old }
                else { index = scopeDefinitions.count;scopeIndex[canonical] = index;scopeDefinitions.append(definition) }
                row["scopeRef"] = index
            }
            if row["metrics"] is [Int],row["playerID"] != nil {
                let canonical = String(decoding:try encode(row),as:UTF8.self)
                let index: Int
                if let old = aggregateIndex[canonical] { index = old }
                else { index = aggregateRows.count;aggregateIndex[canonical] = index;aggregateRows.append(row) }
                return ["aggregateRef":index]
            }
            if row["substitutionRefs"] != nil,row["playerID"] != nil {
                let canonical = String(decoding:try encode(row),as:UTF8.self)
                let index: Int
                if let old = rotationIndex[canonical] { index = old }
                else { index = rotationRows.count;rotationIndex[canonical] = index;rotationRows.append(row) }
                return ["rotationRef":index]
            }
            return row
        }
        var packet = try project(root) as! [String:Any]
        packet["packetVersion"] = 2;packet["summaryMode"] = "complete_aggregates_bounded_event_examples"
        packet["metricFields"] = fields;packet["statisticFields"] = statFields
        let backgroundFields = Set(profiles.values.flatMap { (($0 as? [String:Any])?["rotationBackground"] as? [String:Any])?.keys.map { $0 } ?? [] }).sorted()
        for id in profiles.keys.sorted() {
            if var p = profiles[id] as? [String:Any],let background = p["rotationBackground"] as? [String:Any] { p["rotationBackground"] = backgroundFields.map { background[$0] ?? NSNull() };profiles[id] = p }
        }
        packet["rotationBackgroundFields"] = backgroundFields
        let profileFields = Set(profiles.values.flatMap { ($0 as? [String:Any])?.keys.map { $0 } ?? [] }).sorted()
        let aggregateFields = Set(aggregateRows.flatMap { $0.keys }).sorted()
        packet["playerFields"] = profileFields;packet["aggregateFields"] = aggregateFields
        packet["playersByID"] = profiles.mapValues { value in let row = value as! [String:Any];return profileFields.map { row[$0] ?? NSNull() } }
        packet["aggregates"] = aggregateRows.map { row in aggregateFields.map { row[$0] ?? NSNull() } }
        packet["scopeDefinitions"] = scopeDefinitions;packet["rules"] = rules
        packet["eventActors"] = eventActors
        let substitutionFields = Set(substitutions.flatMap { $0.keys }).sorted(),rotationFields = Set(rotationRows.flatMap { $0.keys }).sorted()
        packet["substitutionFields"] = substitutionFields;packet["rotationFields"] = rotationFields
        packet["substitutions"] = substitutions.map { row in substitutionFields.map { row[$0] ?? NSNull() } }
        packet["rotations"] = rotationRows.map { row in rotationFields.map { row[$0] ?? NSNull() } }
        packet["payloadCompactedFromBytes"] = original.count
        packet["allComputedAggregateRowsRetained"] = true
        packet["readingGuide"] = "playersByID/aggregates/substitutions/rotations行分别按playerFields/aggregateFields/substitutionFields/rotationFields解码；rotationBackground按rotationBackgroundFields，metrics按metricFields，statistics按statisticFields，0与null缺失分开。aggregateRef/scopeRef/*Rule/eventActorRefs/substitutionRefs/rotationRef分别引用aggregates/scopeDefinitions/rules/eventActors/substitutions/rotations零起始索引。rotationBackground是全场背景，所选换人范围看substitutionRefs。覆盖标记保留，不把聚合计算当完整比赛覆盖。eventDetails只是实例，未列细节不推断不存在；current_match_input为当前已提供的比赛事实。"
        // Prefer examples from each actual period over dozens of nearly
        // identical events for the first player in a roster.
        var preferred: [String] = []
        let groups = Dictionary(grouping:eventOrder) { id in String((eventPool[id]?["time"] as? String ?? "").split(separator:" ").first ?? "") }
        for group in groups.keys.sorted() { if let first = groups[group]?.first { preferred.append(first) };if let last = groups[group]?.last,last != preferred.last { preferred.append(last) } }
        let remaining = eventOrder.filter { !preferred.contains($0) };preferred += remaining
        func withExamples(_ count: Int) throws -> Data {
            let ids = Array(preferred.prefix(count))
            packet["eventDetails"] = ids.compactMap { eventPool[$0] }
            packet["eventExampleCoverage"] = ["available":eventOrder.count,"returned":ids.count,"examplesLimited":ids.count < eventOrder.count]
            return try encode(packet)
        }
        var data = try withExamples(24)
        for count in [16,12,8,4] where data.count > targetBytes { data = try withExamples(count) }
        guard data.count <= hardBytes else { throw NBAReviewGameQuery.Failure.resultTooLarge(data.count) }
        return data
    }
}
