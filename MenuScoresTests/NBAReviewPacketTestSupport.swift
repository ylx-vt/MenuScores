import Foundation

/// Expand the wire references for the pre-existing independent numerical
/// assertions. Packet-size and wire-shape tests inspect the actual JSON.
enum NBAReviewPacketTestSupport {
    static func decode(_ data: Data) throws -> [String:Any] {
        let root = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        guard root["packetVersion"] as? Int == 2 else { return root }
        let fields = root["metricFields"] as! [String],statFields = root["statisticFields"] as! [String]
        let profileFields = root["playerFields"] as! [String],aggregateFields = root["aggregateFields"] as! [String]
        let profiles = (root["playersByID"] as! [String:[Any]]).mapValues { Dictionary(uniqueKeysWithValues:zip(profileFields,$0)) }
        let aggregates = (root["aggregates"] as! [[Any]]).map { Dictionary(uniqueKeysWithValues:zip(aggregateFields,$0)) }
        let scopes = root["scopeDefinitions"] as! [[String:Any]],rules = root["rules"] as! [String]
        let eventActors = root["eventActors"] as! [[String:Any]],subFields = root["substitutionFields"] as! [String],rotationFields = root["rotationFields"] as! [String]
        let substitutions = (root["substitutions"] as! [[Any]]).map { Dictionary(uniqueKeysWithValues:zip(subFields,$0)) }
        let rotations = (root["rotations"] as! [[Any]]).map { Dictionary(uniqueKeysWithValues:zip(rotationFields,$0)) }
        func expand(_ item: Any) -> Any {
            if let array = item as? [Any] { return array.map(expand) }
            guard var row = item as? [String:Any] else { return item }
            if let i = row["aggregateRef"] as? Int { row = aggregates[i] }
            if let i = row["rotationRef"] as? Int { row = rotations[i] }
            if let i = row["scopeRef"] as? Int { row.merge(scopes[i]) { a,_ in a };row["scopeRef"] = nil }
            if let refs = row["eventActorRefs"] as? [Int] { row["events"] = refs.map { eventActors[$0] };row["eventActorRefs"] = nil }
            if let refs = row["substitutionRefs"] as? [Int] { row["substitutions"] = refs.map { substitutions[$0] };row["substitutionRefs"] = nil }
            for key in Array(row.keys) {
                if key.hasSuffix("Rule"),let i = row[key] as? Int { row[String(key.dropLast(4))] = rules[i];row[key] = nil }
                else if ["metrics","recordedMetrics"].contains(key),let values = row[key] as? [Int] {
                    row[key == "metrics" ? "allTypesRecordedMetrics" : key] = Dictionary(uniqueKeysWithValues:zip(fields,values));if key == "metrics" { row[key] = nil }
                } else if let value = row[key] { row[key] = expand(value) }
            }
            if let id = (row["playerID"] ?? row["id"]) as? String,let p = profiles[id] {
                row["name"] = p["name"];row["player"] = p["name"];row["teamID"] = p["teamID"]
                if let values = p["statistics"] as? [Any] { row["fullGameBoxStatistics"] = Dictionary(uniqueKeysWithValues:zip(statFields,values)) }
                row["fullGameRecordedPoints"] = p["fullGameRecordedPoints"];row["fullGamePointsMatchBox"] = p["fullGamePointsMatchBox"]
            }
            return row
        }
        return expand(root) as! [String:Any]
    }
}
