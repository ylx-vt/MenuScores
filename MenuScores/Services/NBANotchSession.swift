import Foundation

struct NBANotchOptions: Equatable {
    var enabled = false
    var milestones = false
    var screenID = ""
    static let enabledKey = "enableNotch"
    static let milestonesKey = "nbaNotchMilestones"
    static let screenKey = "nbaNotchScreenID"
    static func read(_ defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: enabledKey), milestones: defaults.bool(forKey: milestonesKey),
             screenID: defaults.string(forKey: screenKey) ?? "")
    }
    static func screen(preferred: String, available: [String], main: String?) -> String? {
        if available.contains(preferred) { return preferred }
        if let main, available.contains(main) { return main }
        return available.first
    }
}

/// A presentation override never writes to the persistent pin store.
struct NBANotchSession {
    struct Moment { let game: Event; let title: String; let expires: Date }
    var pinned: Event?
    private(set) var moment: Moment?
    var game: Event? { moment?.game ?? pinned }
    mutating func present(_ reminder: NBAGameReminder, now: Date) {
        moment = Moment(game: reminder.game, title: reminder.title, expires: now.addingTimeInterval(8))
    }
    @discardableResult mutating func finishIfDue(now: Date, interacting: Bool) -> Bool {
        guard let moment, now >= moment.expires, !interacting else { return false }
        self.moment = nil; return true
    }
    mutating func cancelMoment() { moment = nil }
}

struct NBANotchPresentation {
    let game: Event
    var teams: [Competitor] {
        nbaOrderedTeams(game.competitions.first?.competitors ?? [], side: { $0.homeAway }, id: { $0.team?.id ?? $0.id })
    }
    var status: String {
        if let special = NBAMenuPresentation.specialState(for: game) { return special }
        if game.status.type.state == "pre" {
            return NBASchedulePolicy.startDate(game.date).map { NBASchedulePolicy.startTime($0, includeDay: true) + " 开赛" } ?? "开赛时间待定"
        }
        if game.status.type.state == "post" { return game.status.type.completed ? "比赛结束" : "状态待更新" }
        guard game.status.type.state == "in" else { return "状态待更新" }
        let detail = [game.status.type.name, game.status.type.detail, game.status.type.shortDetail].compactMap { $0 }.joined(separator: " ").lowercased()
        if detail.contains("halftime") { return "中场休息" }
        if detail.contains("end of") || detail.contains("end_period") { return "节间休息" }
        guard let period = game.status.period, period > 0 else { return "比赛进行中" }
        return (period > 4 ? "加时 \(period - 4)" : "第 \(period) 节") + " · " + (game.status.displayClock ?? "时间待更新")
    }
    var compactBadge: String? {
        if let special = NBAMenuPresentation.specialState(for: game) { return special }
        return game.status.type.state == "post" ? "已结束" : nil
    }
    var compactTime: String? {
        guard game.status.type.state == "pre", NBAMenuPresentation.specialState(for: game) == nil else { return nil }
        return NBASchedulePolicy.startDate(game.date).map { NBASchedulePolicy.startTime($0) } ?? "待定"
    }
}
