import SwiftUI

@main
struct MenuScoresApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var nbaVM = GamesListView()
    @State private var showingHistory = false
    @State private var selectedArticle: NBARecap?
    @State private var selectedDetail: (id: String, route: NBAReviewPanelModel.Route)?
    @StateObject private var pins = NBAPinnedSelectionStore.shared
    @State private var scheduleRefreshID = UUID()
    @State private var recoveryID = ""
    @State private var recoveryAfter = Date.distantPast
    @AppStorage("refreshInterval") private var refreshInterval = "15 seconds"

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppRuntime.isTerraSummaryDemo && !AppRuntime.isCredentialSetup && !AppRuntime.isRecapNotificationSetup)) {
            NBAMainMenuNavigation(showingDetail: Binding(get: { selectedArticle != nil || selectedDetail != nil }, set: { if !$0 { selectedArticle = nil; selectedDetail = nil } }), showingHistory: $showingHistory,
                                  showSettings: { SettingsWindowController.shared.showWindow() }) {
            if let article = selectedArticle {
                NBARecapNotificationReader(article: article) {
                    selectedArticle = nil; selectedDetail = (article.gameID, .statistics)
                }.frame(width: 600, height: 540)
            } else if let detail = selectedDetail {
                NBAReviewPanelView(gameID: detail.id, initialRoute: detail.route).id(detail.id + detail.route.rawValue)
            } else if showingHistory {
                NBAHistoryBrowser { showingHistory = false }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("NBA").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("北京时间").font(.caption).foregroundStyle(.secondary)
                    }
                    NBAFlatMenu(viewModel: nbaVM, selectedGameID: currentGameID, onSelect: pin,
                                heading: "今日赛程", maxVisibleGames: nbaVM.showsTomorrow ? 4 : 8,
                                onOpenArticle: openArticle)
                    if nbaVM.showsTomorrow {
                        Divider()
                        NBAFlatMenu(viewModel: nbaVM, selectedGameID: currentGameID, onSelect: pin,
                                    heading: "明日赛程", emptyMessage: "明天暂无 NBA 比赛",
                                    selectionHint: "点击预约到菜单栏", tomorrowSection: true, maxVisibleGames: 4,
                                    onOpenArticle: openArticle)
                    }
                    if let error = pins.persistenceError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Button { showingHistory = true } label: {
                        HStack {
                            Label("历史比赛", systemImage: "calendar")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.font(.system(size: 12)).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                    HStack {
                        Button { SettingsWindowController.shared.showWindow() } label: {
                            Label("设置", systemImage: "gearshape")
                        }.keyboardShortcut(",")
                        Spacer()
                        if !currentGameID.isEmpty {
                            Button("取消固定") {
                                FavoritesManager.shared.dismissAutoPinnedGame(currentGameID)
                                pins.unpin()
                            }
                        }
                        Button("退出") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                    }.buttonStyle(.borderless).font(.caption).padding(.top, 2)
                }.padding(12).frame(width: 420)
                    .modifier(NBAPanelSurface())
            }
            }
        } label: {
            Image(systemName: "basketball")
                .accessibilityLabel("NBA 比赛")
                // Fetch from the persistent status item, so closing the menu does
                // not stop score updates or favorite-team detection.
                .task(priority: .utility) {
                    guard !AppRuntime.suppressesLiveWork else { return }
                    let favoriteTeams = Set(FavoritesManager.shared.favorites.filter { $0.leagueKey == "NBA" }.map(\.id))
                    let pinnedTeams = Set(pins.selection?.game.competitions.first?.competitors?.compactMap { $0.team?.id } ?? [])
                    await NBAAvatarCache.shared.prepareLeague(priorityTeams: favoriteTeams.union(pinnedTeams))
                }
                .task(id: currentGameID) {
                    guard !AppRuntime.suppressesLiveWork else { return }
                    guard let game = pins.selection?.game else { return }
                    await NBAAvatarCache.shared.prioritizeTeams(Set(game.competitions.first?.competitors?.compactMap { $0.team?.id } ?? []))
                    await NBAAvatarCache.shared.prewarmGame(game.id)
                }
                .task(id: scheduleRefreshID) {
                    guard !AppRuntime.suppressesLiveWork else { return }
                    FavoritesManager.shared.registerNBA(nbaVM)
                    while !Task.isCancelled {
                        let requestedAt = Date()
                        await nbaVM.refreshSchedule(now: requestedAt)
                        guard !Task.isCancelled else { return }
                        // A slow request can straddle noon/midnight. Re-evaluate
                        // the window immediately, reusing the raw date cache.
                        if Date() >= NBASchedulePolicy.window(now: requestedAt).nextTransition { continue }
                        pins.update(from: nbaVM.knownGames)
                        let recovered = await recoverPinnedGameIfNeeded()
                        guard !Task.isCancelled else { return }
                        FavoritesManager.shared.updateNBASelection(pins)
                        let observations = nbaVM.notificationObservations + (recovered.map { [$0] } ?? [])
                        await NBATerraAutofill.shared.observe(now: requestedAt)
                        NBANotchController.shared.observe(observations, refreshFailed: nbaVM.errorMessage != nil)
                        await NBAGameReminderService.shared.process(observations, eligibleIDs: reminderEligibleIDs,
                                                                   options: NBAReminderOptions.read()) {
                            (reminderEligibleIDs, NBAReminderOptions.read())
                        }
                        do {
                            let delay = nextRefreshDelay
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        } catch { return }
                    }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    scheduleRefreshID = UUID()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                    scheduleRefreshID = UUID()
                }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("设置…") { SettingsWindowController.shared.showWindow() }
                    .keyboardShortcut(",")
            }
        }

        MenuBarExtra(isInserted: .constant(!AppRuntime.isTerraSummaryDemo && !AppRuntime.isCredentialSetup && !AppRuntime.isRecapNotificationSetup && pins.selection != nil)) {
            NBAReviewPanelView(gameID: currentGameID).id(currentGameID)
        } label: {
            if let game = pins.selection?.game {
                Image(nsImage: NBAMenuBarBadge.image(for: game))
                    .renderingMode(.original)
                    .help(currentTitle)
                    .accessibilityLabel("\(currentTitle)，点击查看球员技术统计")
            } else {
                Image(systemName: "basketball")
                    .accessibilityLabel("正在更新比分，点击查看球员技术统计")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var currentGameID: String { pins.selection?.eventID ?? "" }
    private func openArticle(_ game: Event, _ article: NBARecap?) {
        if let article { selectedArticle = article; selectedDetail = nil }
        else { selectedDetail = (game.id, .recap); selectedArticle = nil }
    }
    private var currentTitle: String { pins.selection.map { NBAMenuPresentation.title(for: $0.game) } ?? "" }
    private var reminderEligibleIDs: Set<String> {
        NBAGameReminderEngine.eligibleIDs(games: nbaVM.knownGames,
            manualID: pins.selection?.source == .manual ? currentGameID : nil,
            favoriteTeamIDs: Set(FavoritesManager.shared.favorites.filter { $0.leagueKey == "NBA" }.map(\.id)))
    }

    /// An ID-specific summary keeps a reservation useful even after rescheduling
    /// moves it outside the visible dates. Errors keep the persisted snapshot.
    @MainActor
    private func recoverPinnedGameIfNeeded() async -> NBAGameObservation? {
        let id = currentGameID
        guard !id.isEmpty,
              !nbaVM.knownGames.contains(where: { $0.id == id }) || nbaVM.errorMessage != nil,
              recoveryID != id || Date() >= recoveryAfter else { return nil }
        recoveryID = id
        if let cached = await NBABoxScoreStore.shared.cached(gameID: id), !Task.isCancelled {
            pins.update(summary: cached.summary, gameID: id)
        }
        var failed = true
        var observation: NBAGameObservation?
        if let entry = try? await NBABoxScoreStore.shared.load(gameID: id), !Task.isCancelled {
            pins.update(summary: entry.summary, gameID: id)
            failed = entry.refreshFailed
            // Do not treat the display snapshot's fallback fields as evidence.
            if !entry.refreshFailed, !entry.isStale, entry.summary.header?.id == id,
               let game = pins.selection?.game, let match = entry.summary.match, let status = match.status,
               let teams = match.competitors, teams.count == 2, let date = match.date,
               let state = status.type?.state, let completed = status.type?.completed {
                let freshStatus = Status(displayClock: status.displayClock, period: status.period,
                    type: type(name: status.type?.name, state: state, completed: completed,
                               detail: status.type?.detail, shortDetail: status.type?.shortDetail), clock: status.clock)
                let competitors = teams.map { player in
                    Competitor(homeAway: player.homeAway, id: player.team.id, score: player.score, order: nil, winner: nil, athlete: nil,
                        team: Team(id: player.team.id, displayName: player.team.displayName, abbreviation: player.team.abbreviation,
                                   name: nil, logo: nil, links: [], color: nil, alternateColor: nil))
                }
                let competition = Competition(competitors: competitors, status: freshStatus, situation: nil, highlights: nil,
                                              headlines: nil, details: nil, venue: nil, notes: nil)
                let freshGame = Event(id: id, date: date, endDate: nil,
                    name: game.name, shortName: game.shortName, competitions: [competition],
                    weather: nil, status: freshStatus, links: nil, circuit: nil)
                observation = NBAGameObservation(game: freshGame, fetchedAt: entry.date)
            }
        }
        guard !Task.isCancelled, currentGameID == id else { return nil }
        let selection = pins.selection
        var delay: TimeInterval = selection?.state == "in" ? TimeInterval(refreshSeconds) : 300
        if selection?.state == "post" { delay = NBABoxScoreStore.completedTTL }
        if let start = selection.flatMap({ NBASchedulePolicy.startDate($0.date) }),
           selection?.state == "pre", abs(start.timeIntervalSinceNow) <= 900 { delay = 30 }
        recoveryAfter = Date().addingTimeInterval(failed ? 60 : delay)
        return observation
    }

    private var nextRefreshDelay: TimeInterval {
        let schedule = nbaVM.scheduleDelay(liveInterval: TimeInterval(refreshSeconds))
        guard !currentGameID.isEmpty,
              !nbaVM.knownGames.contains(where: { $0.id == currentGameID }) || nbaVM.errorMessage != nil else { return schedule }
        return max(1, min(schedule, recoveryAfter.timeIntervalSinceNow))
    }

    private var refreshSeconds: UInt64 {
        ScoreRefreshInterval.seconds(for: refreshInterval)
    }

    private func pin(_ game: Event) {
        pins.pinManually(game)
    }
}
