import Combine
import Foundation

/// A small display snapshot survives missing date results and offline restarts.
struct NBAPinnedSelection: Codable, Equatable {
    enum Source: String, Codable { case manual, automatic }
    struct Side: Codable, Equatable {
        let id: String
        let homeAway: String?
        let score: String?
        let teamID: String
        let name: String?
        let abbreviation: String?
        let logo: String?
    }
    let eventID: String
    let date: String
    let name: String
    let shortName: String?
    let state: String
    let statusName: String?
    let completed: Bool
    let detail: String?
    let shortDetail: String?
    let period: Int?
    let clock: String?
    let remainingSeconds: Double?
    let sides: [Side]
    let source: Source

    init(game: Event, source: Source) {
        eventID = game.id; date = game.date; name = game.name; shortName = game.shortName
        state = game.status.type.state; completed = game.status.type.completed
        statusName = game.status.type.name
        detail = game.status.type.detail; shortDetail = game.status.type.shortDetail
        period = game.status.period; clock = game.status.displayClock
        remainingSeconds = game.status.clock
        sides = (game.competitions.first?.competitors ?? []).map {
            Side(id: $0.id, homeAway: $0.homeAway, score: $0.score,
                 teamID: $0.team?.id ?? $0.id, name: $0.team?.displayName,
                 abbreviation: $0.team?.abbreviation, logo: $0.team?.logo)
        }
        self.source = source
    }

    var game: Event {
        let status = Status(displayClock: clock, period: period,
                            type: type(name: statusName, state: state, completed: completed, detail: detail, shortDetail: shortDetail), clock: remainingSeconds)
        let competitors = sides.map {
            Competitor(homeAway: $0.homeAway, id: $0.id, score: $0.score, order: nil, winner: nil, athlete: nil,
                       team: Team(id: $0.teamID, displayName: $0.name, abbreviation: $0.abbreviation, name: nil,
                                  logo: $0.logo, links: [], color: nil, alternateColor: nil))
        }
        let competition = Competition(competitors: competitors, status: status, situation: nil, highlights: nil,
                                      headlines: nil, details: nil, venue: nil, notes: nil)
        return Event(id: eventID, date: date, endDate: nil, name: name, shortName: shortName,
                     competitions: [competition], weather: nil, status: status, links: nil, circuit: nil)
    }
}

@MainActor
final class NBAPinnedSelectionStore: ObservableObject {
    static let shared = NBAPinnedSelectionStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MenuScores", isDirectory: true).appendingPathComponent("nba-pinned-selection-v1.json"))
    @Published private(set) var selection: NBAPinnedSelection?
    @Published private(set) var persistenceError: String?
    private let file: URL

    init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { selection = try JSONDecoder().decode(NBAPinnedSelection.self, from: Data(contentsOf: file)) }
        catch { persistenceError = "固定比赛恢复失败" }
    }

    /// Manual ownership is explicit; subsequent updates keep it until unpinning.
    func pinManually(_ game: Event) {
        selection = NBAPinnedSelection(game: game, source: .manual)
        save()
    }

    @discardableResult
    func pinAutomatically(_ game: Event) -> Bool {
        guard selection?.source != .manual else { return false }
        let updated = NBAPinnedSelection(game: game, source: .automatic)
        guard selection != updated else { return true }
        selection = updated
        save()
        return true
    }

    func update(_ game: Event) {
        guard let old = selection, old.eventID == game.id else { return }
        let updated = NBAPinnedSelection(game: game, source: old.source)
        guard updated != old else { return }
        selection = updated
        save()
    }

    /// Absence from a response never clears a reservation.
    func update(from games: [Event]) {
        guard let id = selection?.eventID, let game = games.first(where: { $0.id == id }) else { return }
        update(game)
    }

    func update(summary: NBABoxScore, gameID: String) {
        guard let old = selection, old.eventID == gameID, let match = summary.match,
              summary.header?.id == gameID else { return }
        let oldGame = old.game
        let newType = match.status?.type
        let status = Status(displayClock: match.status?.displayClock ?? old.clock, period: match.status?.period ?? old.period,
                            type: type(name: newType?.name ?? old.statusName, state: newType?.state ?? old.state,
                                       completed: newType?.completed ?? old.completed, detail: newType?.detail ?? old.detail,
                                       shortDetail: newType?.shortDetail ?? old.shortDetail), clock: match.status?.clock)
        let competitors = match.competitors?.map { player in
            Competitor(homeAway: player.homeAway, id: player.team.id, score: player.score, order: nil, winner: nil, athlete: nil,
                       team: Team(id: player.team.id, displayName: player.team.displayName, abbreviation: player.team.abbreviation,
                                  name: nil, logo: player.team.logo, links: [], color: player.team.color, alternateColor: player.team.alternateColor))
        } ?? oldGame.competitions.first?.competitors
        let competition = Competition(competitors: competitors, status: status, situation: nil, highlights: nil,
                                      headlines: nil, details: nil, venue: nil, notes: nil)
        update(Event(id: gameID, date: match.date ?? old.date, endDate: nil, name: old.name, shortName: old.shortName,
                     competitions: [competition], weather: nil, status: status, links: nil, circuit: nil))
    }

    func clearAutomaticSelection() {
        guard selection?.source == .automatic else { return }
        unpin()
    }

    func unpin() {
        selection = nil
        save()
    }

    private func save() {
        do {
            if let selection {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(selection).write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            persistenceError = nil
        } catch { persistenceError = "固定比赛保存失败" }
    }
}
