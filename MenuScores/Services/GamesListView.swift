//
//  gamesListView.swift
//  MenuScores
//
//  Created by Daniyal Master on 2025-05-03.
//

import Foundation

@MainActor
class GamesListView: ObservableObject {
    @Published var games: [Event] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var tomorrowGames: [Event] = []
    @Published var tomorrowError: String?
    @Published var tomorrowIsLoading = false
    @Published var showsTomorrow = false
    @Published private(set) var knownGames: [Event] = []
    private(set) var notificationObservations: [NBAGameObservation] = []
    private var refreshGeneration = UUID()
    private var todayKey = ""
    private var tomorrowKey = ""
    private var todayResponse: [Event] = []
    private var tomorrowResponse: [Event] = []

    func refreshSchedule(now: Date = Date(), store: NBAScheduleStore = .shared) async {
        let generation = UUID()
        refreshGeneration = generation
        notificationObservations = []
        let window = NBASchedulePolicy.window(now: now)
        let key = NBAHistoryStore.dayKey(window.today.start, calendar: NBASchedulePolicy.calendar)
        if todayKey != key {
            // Previously loaded tomorrow becomes today immediately at midnight.
            let retained = knownGames
            todayKey = key; todayResponse = retained; tomorrowResponse = []
            games = NBASchedulePolicy.groups(retained, now: now).today
            errorMessage = nil
        }
        showsTomorrow = window.tomorrow != nil
        let nextKey = window.tomorrow.map { NBAHistoryStore.dayKey($0.start, calendar: NBASchedulePolicy.calendar) } ?? ""
        if tomorrowKey != nextKey {
            tomorrowKey = nextKey; tomorrowGames = []; tomorrowError = nil
        }
        isLoading = true; tomorrowIsLoading = showsTomorrow
        defer { isLoading = false; tomorrowIsLoading = false }
        // Both UI groups share raw provider-date cache entries.
        async let today: Void = refreshDay(window.today.start, tomorrow: false, now: now, store: store, generation: generation)
        async let next: Void = refreshTomorrow(window.tomorrow?.start, now: now, store: store, generation: generation)
        _ = await (today, next)
    }

    private func refreshTomorrow(_ day: Date?, now: Date, store: NBAScheduleStore, generation: UUID) async {
        guard let day else { return }
        await refreshDay(day, tomorrow: true, now: now, store: store, generation: generation)
    }

    private func refreshDay(_ day: Date, tomorrow: Bool, now: Date, store: NBAScheduleStore, generation: UUID) async {
        let liveDates = tomorrow ? [] : knownGames.filter { $0.status.type.state == "in" }.compactMap { NBASchedulePolicy.startDate($0.date) }
        if let cached = await store.cached(day: day, extraDays: liveDates), !Task.isCancelled, generation == refreshGeneration {
            apply(cached, tomorrow: tomorrow, now: now)
        }
        do {
            let entry = try await store.load(day: day, extraDays: liveDates)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            notificationObservations += entry.notificationObservations
            apply(entry, tomorrow: tomorrow, now: now)
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if tomorrow { tomorrowError = "明日赛程更新失败" }
            else { errorMessage = "赛程更新失败，稍后重试" }
        }
    }

    private func apply(_ entry: NBAScheduleStore.Entry, tomorrow: Bool, now: Date) {
        if tomorrow {
            tomorrowResponse = entry.games
            tomorrowError = entry.refreshFailed ? "明日赛程更新失败" : nil
        } else {
            todayResponse = entry.games
            errorMessage = entry.refreshFailed ? "赛程更新失败，稍后重试" : nil
        }
        var seen: Set<String> = []
        knownGames = (todayResponse + tomorrowResponse).filter { seen.insert($0.id).inserted }
        let groups = NBASchedulePolicy.groups(knownGames, now: now)
        games = groups.today; tomorrowGames = groups.tomorrow
    }

    func scheduleDelay(now: Date = Date(), liveInterval: TimeInterval = 15) -> TimeInterval {
        var delay = errorMessage != nil || tomorrowError != nil ? 60.0 : 900.0
        if games.contains(where: { $0.status.type.state == "in" }) { delay = min(delay, liveInterval) }
        for game in games + tomorrowGames where game.status.type.state == "pre" {
            guard NBAMenuPresentation.specialState(for: game) == nil,
                  let start = NBASchedulePolicy.startDate(game.date) else { continue }
            let remaining = start.timeIntervalSince(now)
            if abs(remaining) <= 900 { delay = min(delay, 30) }
            else if remaining > 900 { delay = min(delay, remaining - 900) }
        }
        return max(1, min(delay, NBASchedulePolicy.window(now: now).nextTransition.timeIntervalSince(now)))
    }

}
