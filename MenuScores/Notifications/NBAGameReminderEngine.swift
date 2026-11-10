import Foundation

/// Only successful load paths create these. Display-only cached snapshots do not.
struct NBAGameObservation {
    let game: Event
    let fetchedAt: Date
}

enum NBAMilestone: String, CaseIterable, Codable, Hashable {
    case pregame, start, halftime, clutch, overtime, final
    var title: String {
        switch self {
        case .pregame: return "赛前 10 分钟"
        case .start: return "正式开赛"
        case .halftime: return "中场休息"
        case .clutch: return "末节 / 加时最后两分钟分差不超过 5 分"
        case .overtime: return "进入加时（每个加时节）"
        case .final: return "比赛结束"
        }
    }
}

struct NBAReminderOptions: Equatable {
    var enabled = false
    var sound = false
    var nodes: Set<NBAMilestone> = [.pregame, .start, .clutch, .final]
    static let enabledKey = "nbaRemindersEnabled"
    static let soundKey = "nbaRemindersSound"
    static func key(_ node: NBAMilestone) -> String { "nbaReminder_" + node.rawValue }
    static func read(_ defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        value.enabled = defaults.bool(forKey: enabledKey)
        value.sound = defaults.bool(forKey: soundKey)
        for node in NBAMilestone.allCases {
            if let flag = defaults.object(forKey: key(node)) as? Bool {
                if flag { value.nodes.insert(node) } else { value.nodes.remove(node) }
            }
        }
        return value
    }
}

struct NBAGameReminder {
    let game: Event
    let identifier: String
    let eventID: String
    let teamIDs: Set<String>
    let node: NBAMilestone
    let title: String
    let body: String
}

/// Deterministic rules and a durable claim-before-send ledger. A crash or failed
/// send may lose a reminder; we deliberately favor silence over duplicate alerts.
@MainActor
final class NBAGameReminderEngine {
    struct Snapshot: Codable {
        let state: String
        let period: Int
        let halftime: Bool
        let fetchedAt: Date
    }
    struct Record: Codable {
        var snapshot: Snapshot?
        var consumed: Set<String> = []
        var touchedAt: Date
    }
    private var records: [String: Record] = [:]
    private var sessionSeen: Set<String> = []
    private var previousOptions: NBAReminderOptions?
    private var previousEligible: Set<String> = []
    private let file: URL
    private let write: (Data, URL) throws -> Void
    private(set) var persistenceError: String?

    init(file: URL, write: @escaping (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.file = file; self.write = write
        if FileManager.default.fileExists(atPath: file.path) {
            do { records = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: file)) }
            catch { persistenceError = "提醒记录读取失败，本次启动暂停提醒" }
        }
    }

    static func eligibleIDs(games: [Event], manualID: String?, favoriteTeamIDs: Set<String>) -> Set<String> {
        var ids = Set(games.filter { !teamIDs($0).isDisjoint(with: favoriteTeamIDs) }.map(\.id))
        if let manualID { ids.insert(manualID) }
        return ids
    }

    static func teamIDs(_ game: Event) -> Set<String> {
        Set(game.competitions.first?.competitors?.compactMap { $0.team?.id } ?? [])
    }

    func resetTracking() { sessionSeen = [] }

    func process(_ observations: [NBAGameObservation], eligibleIDs: Set<String>, options: NBAReminderOptions,
                 now: Date) -> [NBAGameReminder] {
        guard persistenceError != "提醒记录读取失败，本次启动暂停提醒" else { return [] }
        if previousOptions != options { sessionSeen = [] }
        sessionSeen.subtract(previousEligible.subtracting(eligibleIDs))
        previousOptions = options; previousEligible = eligibleIDs
        guard options.enabled else { sessionSeen = []; return [] }
        var latest: [String: NBAGameObservation] = [:]
        for observation in observations where eligibleIDs.contains(observation.game.id) {
            if latest[observation.game.id].map({ $0.fetchedAt < observation.fetchedAt }) ?? true {
                latest[observation.game.id] = observation
            }
        }
        var reminders: [NBAGameReminder] = []
        for observation in latest.values.sorted(by: { $0.game.id < $1.game.id }) {
            let game = observation.game
            let age = now.timeIntervalSince(observation.fetchedAt)
            // HTTP receipt time is evidence of freshness, not a guarantee that
            // the upstream score itself is current. Never use old disk playback.
            guard age >= -5, age <= 60,
                  NBANotificationRoute.validEventID(game.id) else { continue }
            var record = records[game.id] ?? Record(touchedAt: now)
            if let old = record.snapshot, observation.fetchedAt <= old.fetchedAt { continue }
            let old = record.snapshot
            let continuous = sessionSeen.contains(game.id) && old.map {
                observation.fetchedAt.timeIntervalSince($0.fetchedAt) <= 300
            } == true
            let period = game.status.period ?? 0
            let half = Self.isHalftime(game)
            let state = game.status.type.state
            let normal = NBAMenuPresentation.specialState(for: game) == nil
            // A later HTTP receipt can still contain a regressed provider
            // snapshot. Do not let it reopen an earlier phase of this event.
            if normal, let old {
                if old.state == "post", state != "post" { continue }
                if old.state == "in", state == "pre" { continue }
                if old.state == "in", state == "in", old.period > 0, period < old.period { continue }
            }
            let snapshot = Snapshot(state: state, period: period, halftime: half, fetchedAt: observation.fetchedAt)
            var candidates: [(NBAMilestone, String)] = []
            func key(_ node: NBAMilestone, _ p: Int? = nil) -> String {
                p.map { "\(node.rawValue):\($0)" } ?? node.rawValue
            }
            if normal {
                if state == "pre", let start = NBASchedulePolicy.startDate(game.date),
                   start > now, start.timeIntervalSince(now) <= 600 {
                    candidates.append((.pregame, key(.pregame)))
                }
                if continuous, let old {
                    if state == "post", game.status.type.completed, old.state == "in" {
                        candidates.append((.final, key(.final)))
                    } else if state == "in", !game.status.type.completed {
                        if old.state == "in", period > 4, period > old.period {
                            candidates.append((.overtime, key(.overtime, period)))
                        }
                        if old.state == "in", Self.isClutch(game) {
                            candidates.append((.clutch, key(.clutch, period)))
                        }
                        if half, !old.halftime, old.state == "in" {
                            candidates.append((.halftime, key(.halftime)))
                        }
                        if old.state == "pre", period == 1, !half, !Self.isIntermission(game) {
                            candidates.append((.start, key(.start)))
                        }
                    }
                }
            }
            // Highest priority first. Mark every reached node, even disabled or
            // suppressed ones, so enabling a switch cannot replay old events.
            let priority: [NBAMilestone] = [.final, .overtime, .clutch, .halftime, .start, .pregame]
            candidates.sort { priority.firstIndex(of: $0.0)! < priority.firstIndex(of: $1.0)! }
            if let chosen = candidates.first(where: { options.nodes.contains($0.0) && !record.consumed.contains($0.1) }) {
                reminders.append(Self.reminder(game: game, node: chosen.0, key: chosen.1, now: now))
            }
            record.consumed.formUnion(candidates.map(\.1))
            if state == "in" || state == "post" {
                record.consumed.formUnion([key(.pregame), key(.start)])
            }
            if half || period >= 3 || state == "post" { record.consumed.insert(key(.halftime)) }
            if period > 4 {
                for p in 5...min(period, 20) { record.consumed.insert(key(.overtime, p)) }
            }
            if period > 4 {
                for p in 4..<min(period, 21) { record.consumed.insert(key(.clutch, p)) }
            }
            if !continuous, Self.isClutch(game) { record.consumed.insert(key(.clutch, period)) }
            if state == "post" { record.consumed.insert(key(.final)) }
            record.snapshot = snapshot; record.touchedAt = now
            records[game.id] = record; sessionSeen.insert(game.id)
        }
        records = records.filter { now.timeIntervalSince($0.value.touchedAt) < 14 * 86400 }
        do {
            try write(JSONEncoder().encode(records), file)
            persistenceError = nil
            return reminders
        } catch {
            persistenceError = "提醒记录保存失败，已暂停本轮提醒"
            return []
        }
    }

    private static func isHalftime(_ game: Event) -> Bool {
        let status = game.status.type
        return status.name?.uppercased() == "STATUS_HALFTIME" || [status.detail, status.shortDetail].compactMap { $0 }
            .contains { ["halftime", "half time", "中场休息"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    private static func isIntermission(_ game: Event) -> Bool {
        let status = game.status.type
        let name = status.name?.uppercased() ?? ""
        let text = [status.detail, status.shortDetail].compactMap { $0 }.joined(separator: " ").lowercased()
        return isHalftime(game) || name == "STATUS_END_PERIOD" || text.contains("end of") || text.contains("break")
    }

    private static func isClutch(_ game: Event) -> Bool {
        guard game.status.type.state == "in", !game.status.type.completed,
              let period = game.status.period, period >= 4, period <= 20,
              !isIntermission(game), let seconds = game.status.clock, seconds.isFinite,
              seconds > 0, seconds <= 120,
              let teams = game.competitions.first?.competitors, teams.count == 2,
              let a = Int(teams[0].score ?? ""), let b = Int(teams[1].score ?? ""),
              (0...1000).contains(a), (0...1000).contains(b) else { return false }
        return abs(a - b) <= 5
    }

    private static func reminder(game: Event, node: NBAMilestone, key: String, now: Date) -> NBAGameReminder {
        let title: String
        switch node {
        case .pregame:
            let minutes = max(1, Int(ceil((NBASchedulePolicy.startDate(game.date)?.timeIntervalSince(now) ?? 0) / 60)))
            title = "约 \(minutes) 分钟后开赛"
        case .start: title = "比赛已开赛"
        case .halftime: title = "中场休息"
        case .clutch: title = "比分胶着 · \((game.status.period ?? 4) > 4 ? "加时" : "第四节")剩 \(game.status.displayClock ?? "两分钟内")"
        case .overtime: title = "进入第 \((game.status.period ?? 5) - 4) 个加时"
        case .final: title = "比赛结束"
        }
        return NBAGameReminder(game: game, identifier: "nba.milestone.\(game.id).\(key)", eventID: game.id,
                               teamIDs: teamIDs(game), node: node, title: title, body: NBAMenuPresentation.title(for: game))
    }
}

/// Only our own numeric NBA event payload is accepted; never an arbitrary URL.
enum NBANotificationRoute {
    enum Destination: Equatable {
        case game(String)
        case recap(gameID: String, cacheKey: String)
    }
    static func destination(userInfo: [AnyHashable: Any], identifier: String) -> Destination? {
        if let id = eventID(userInfo: userInfo, identifier: identifier) { return .game(id) }
        guard userInfo["kind"] as? String == "nba.recap.v1",
              let id = userInfo["eventID"] as? String, validEventID(id), identifier == "nba.recap." + id,
              let key = userInfo["cacheKey"] as? String, NBARecapNotification.validCacheKey(key) else { return nil }
        return .recap(gameID: id, cacheKey: key)
    }
    static func validEventID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func eventID(userInfo: [AnyHashable: Any], identifier: String) -> String? {
        guard userInfo["kind"] as? String == "nba.milestone.v1", let id = userInfo["eventID"] as? String,
              validEventID(id), identifier.hasPrefix("nba.milestone.\(id).") else { return nil }
        return id
    }
}
