import Foundation

/// Read-only preparation state attached to the match it belongs to.
@MainActor final class NBAArticleMenuStatus: ObservableObject {
    static let shared = NBAArticleMenuStatus()
    enum Phase: Equatable { case waiting, preparing, reviewing, ready, incomplete, paused, missing }
    struct State {
        let kind: NBARecapInput.Kind
        let phase: Phase
        let article: NBARecap?
        var label: String {
            let subject = kind == .recap ? "总结" : "看点"
            switch phase {
            case .waiting: return subject + "待准备"
            case .preparing: return "正在准备" + subject
            case .reviewing: return "正在核对" + subject
            case .ready: return subject + "已就绪"
            case .incomplete: return subject + "未完成"
            case .paused: return subject + "暂缓准备"
            case .missing: return subject + "暂不可用"
            }
        }
        var action: String { article == nil ? "查看" : kind == .recap ? "读赛后总结" : "看赛前看点" }
        var canOpen: Bool { article != nil || [.incomplete, .paused, .missing].contains(phase) }
    }
    @Published private(set) var states: [String: State] = [:]
    private let snapshot: @Sendable () async -> NBATerraAutofill.Ledger
    private let read: @Sendable (String, String, NBARecapInput.Kind) async -> NBARecap?
    private var revisions: [String: UUID] = [:]

    init(snapshot: @escaping @Sendable () async -> NBATerraAutofill.Ledger = { await NBATerraAutofill.shared.snapshot() },
         read: @escaping @Sendable (String, String, NBARecapInput.Kind) async -> NBARecap? = { id, key, kind in
             if let latest = await NBATerraRecapStore.live.latestArticle(gameID: id, kind: kind) { return latest }
             return await NBATerraRecapStore.live.storedArticle(gameID: id, cacheKey: key, kind: kind)
         }) {
        self.snapshot = snapshot; self.read = read
    }
    static func kind(for game: Event, now: Date = Date()) -> NBARecapInput.Kind? {
        guard NBAMenuPresentation.specialState(for: game) == nil else { return nil }
        if game.status.type.state == "post", game.status.type.completed { return .recap }
        if game.status.type.state == "pre", !game.status.type.completed,
           let start = NBASchedulePolicy.startDate(game.date), start > now { return .pregame }
        return nil
    }
    static func state(kind: NBARecapInput.Kind, job: NBATerraAutofill.Job?, article: NBARecap?) -> State {
        if let article { return State(kind: kind, phase: .ready, article: article) }
        let phase: Phase
        switch job?.state {
        case "running": phase = .preparing
        case "reviewing": phase = .reviewing
        case "done": phase = .missing
        case "failed", "uncertain", "stale": phase = .incomplete
        case "budget": phase = .paused
        default: phase = .waiting
        }
        return State(kind: kind, phase: phase, article: nil)
    }
    func refresh(games: [Event], now: Date = Date()) async {
        let token = UUID()
        for game in games { revisions[game.id] = token }
        let ledger = await snapshot()
        for game in games {
            guard !Task.isCancelled, revisions[game.id] == token else { continue }
            guard let kind = Self.kind(for: game, now: now) else { states[game.id] = nil; continue }
            let job = ledger.jobs[game.id + "-" + kind.rawValue]
            let article: NBARecap?
            if job == nil || ["done", "stale", "failed", "budget"].contains(job?.state ?? "") {
                article = await read(game.id, job?.fingerprint ?? "", kind)
            } else { article = nil }
            guard !Task.isCancelled, revisions[game.id] == token else { continue }
            states[game.id] = Self.state(kind: kind, job: job, article: article)
        }
    }
}
