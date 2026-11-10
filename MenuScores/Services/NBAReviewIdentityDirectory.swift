import Foundation

/// Public match-roster observations already downloaded by this app. These are
/// dated identity hints, never a static roster or proof of a present injury.
actor NBAReviewIdentityDirectory {
    struct Identity: Sendable {
        let athlete: NBAReviewEvidence.Athlete
        let teamName: String; let matchDate: String; let fetchedAt: Date; let source: URL
        var json: [String: Any] { ["id": athlete.id, "name": athlete.name, "originalName": athlete.originalName,
            "lastRecordedTeamID": athlete.teamID, "lastRecordedTeam": teamName, "lastRecordedMatchDate": matchDate,
            "dataFetchedAt": ISO8601DateFormatter().string(from: fetchedAt), "source": source.absoluteString,
            "limit": "这是有日期的比赛名单记录，不等于今天的完整球队注册名单或伤病状态。"] }
    }
    static let shared = NBAReviewIdentityDirectory(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NBABoxScores"))
    let directory: URL
    private var refreshedAt = Date.distantPast
    private var identities: [Identity] = []
    init(directory: URL) { self.directory = directory }
    func lookup(_ names: [String], now: Date = Date()) -> [Identity] {
        guard !names.isEmpty else { return [] }
        if now.timeIntervalSince(refreshedAt) >= 300 {
            refreshedAt = now
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            var latest: [String: Identity] = [:]
            for file in files.prefix(128) where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent.allSatisfy(\.isNumber) {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), (attrs.fileSize ?? Int.max) <= 2_000_000,
                      let data = try? Data(contentsOf: file), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let header = raw["header"] as? [String: Any], let id = header["id"] as? String, id == file.deletingPathExtension().lastPathComponent,
                      let match = (header["competitions"] as? [[String: Any]])?.first, let date = match["date"] as? String,
                      let when = NBASchedulePolicy.startDate(date), when <= now else { continue }
                let sideIDs = Set((match["competitors"] as? [[String: Any]] ?? []).compactMap { ($0["team"] as? [String: Any])?["id"] as? String })
                for block in (raw["boxscore"] as? [String: Any])?["players"] as? [[String: Any]] ?? [] {
                    guard let team = block["team"] as? [String: Any], let teamID = team["id"] as? String, sideIDs.contains(teamID), let teamName = team["displayName"] as? String else { continue }
                    for stats in block["statistics"] as? [[String: Any]] ?? [] {
                        for row in stats["athletes"] as? [[String: Any]] ?? [] {
                            guard let person = row["athlete"] as? [String: Any], let playerID = person["id"] as? String, let name = person["displayName"] as? String,
                                  name.count <= 100, playerID.allSatisfy(\.isNumber) else { continue }
                            if let old = latest[playerID], (NBASchedulePolicy.startDate(old.matchDate) ?? .distantPast) > when { continue }
                            let athlete = NBAReviewEvidence.Athlete(id: playerID, name: NBALocalization.player(name), originalName: name, teamID: teamID, statistics: [:], didNotPlay: row["didNotPlay"] as? Bool == true)
                            latest[playerID] = .init(athlete: athlete, teamName: NBAMenuPresentation.teamName(team["abbreviation"] as? String, fallback: teamName), matchDate: date, fetchedAt: attrs.contentModificationDate ?? .distantPast,
                                source: URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(id)")!)
                        }
                    }
                }
            }
            identities = Array(latest.values)
        }
        return Array(identities.filter { item in names.contains { NBAReviewGameQuery.matches($0, athlete: item.athlete) } }.sorted { $0.athlete.id < $1.athlete.id }.prefix(8))
    }
}
