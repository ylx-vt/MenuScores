import Foundation

/// Bounded reads of public game summaries the app already owns. No new feed,
/// credential, remote fetch or claim that the sample is a complete season.
actor NBAReviewPlayerHistory {
    struct Appearance: Sendable {
        let playerID: String, name: String, gameID: String, matchDate: String
        let starter: Bool?, didNotPlay: Bool, points: Int?, minutes: Int?
        let fetchedAt: Date
        var source: URL { URL(string:"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(gameID)")! }
        private var parts: DateComponents { NBASchedulePolicy.calendar.dateComponents([.year,.month,.day],from:NBASchedulePolicy.startDate(matchDate) ?? .distantPast) }
        var year: Int? { parts.year };var month: Int? { parts.month };var day: Int? { parts.day }
        var json: [String:Any] { ["playerID":playerID,"player":name,"gameID":gameID,"matchDate":matchDate,"starter":starter as Any? ?? NSNull(),"didNotPlay":didNotPlay,"points":points as Any? ?? NSNull(),"minutes":minutes as Any? ?? NSNull(),"source":source.absoluteString,"fetchedAt":ISO8601DateFormatter().string(from:fetchedAt)] }
    }
    static let shared = NBAReviewPlayerHistory(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("NBABoxScores"))
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func lookup(playerIDs: Set<String>, now: Date = Date()) -> [Appearance] {
        guard !playerIDs.isEmpty else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey])) ?? []
        var rows: [Appearance] = []
        for f in files.filter({$0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.allSatisfy(\.isNumber)}).sorted(by:{$0.lastPathComponent > $1.lastPathComponent}).prefix(128) {
            guard let attrs = try? f.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),(attrs.fileSize ?? Int.max) <= 2_000_000,
                  let data = try? Data(contentsOf:f),let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let header = root["header"] as? [String:Any],let id = header["id"] as? String,id == f.deletingPathExtension().lastPathComponent,
                  let match = (header["competitions"] as? [[String:Any]])?.first,let date = match["date"] as? String,
                  let when = NBASchedulePolicy.startDate(date),when <= now,
                  ((match["status"] as? [String:Any])?["type"] as? [String:Any])?["completed"] as? Bool == true else { continue }
            let sides = Set((match["competitors"] as? [[String:Any]] ?? []).compactMap { ($0["team"] as? [String:Any])?["id"] as? String })
            for team in (root["boxscore"] as? [String:Any])?["players"] as? [[String:Any]] ?? [] {
                guard let teamID = (team["team"] as? [String:Any])?["id"] as? String,sides.contains(teamID) else { continue }
                for block in team["statistics"] as? [[String:Any]] ?? [] {
                    let names = block["names"] as? [String] ?? block["labels"] as? [String] ?? []
                    for row in block["athletes"] as? [[String:Any]] ?? [] {
                        guard let a = row["athlete"] as? [String:Any],let playerID = a["id"] as? String,playerIDs.contains(playerID),let name = a["displayName"] as? String,name.count <= 100,!rows.contains(where:{$0.playerID == playerID && $0.gameID == id}) else { continue }
                        let values = row["stats"] as? [String] ?? []
                        func stat(_ field: String) -> Int? { guard let i = names.firstIndex(of:field),values.indices.contains(i) else { return nil };return Int(values[i]) }
                        rows.append(.init(playerID:playerID,name:NBALocalization.player(name),gameID:id,matchDate:date,starter:row["starter"] as? Bool,didNotPlay:row["didNotPlay"] as? Bool == true,points:stat("PTS"),minutes:stat("MIN"),fetchedAt:attrs.contentModificationDate ?? .distantPast))
                    }
                }
            }
        }
        return playerIDs.sorted().flatMap { id in rows.filter{$0.playerID == id}.sorted{(NBASchedulePolicy.startDate($0.matchDate) ?? .distantPast) > (NBASchedulePolicy.startDate($1.matchDate) ?? .distantPast)}.prefix(6) }
    }
}
