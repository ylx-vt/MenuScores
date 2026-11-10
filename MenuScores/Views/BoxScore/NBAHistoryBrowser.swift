import SwiftUI

struct NBAHistoryBrowser: View {
    let onClose: () -> Void
    let historyStore: NBAHistoryStore
    let boxStore: NBABoxScoreStore
    let profileStore: NBAPlayerProfileStore
    let leagueStore: NBALeaguePercentileStore
    @StateObject private var viewModel = GamesListView()
    @State private var day = NBASchedulePolicy.calendar.date(byAdding: .day, value: -1, to: Date())!
    @State private var selectedGameID: String?
    @State private var selectedArticle: NBARecap?
    @State private var selectedRoute: NBAReviewPanelModel.Route = .score
    @State private var refreshID = UUID()
    @State private var force = false
    @State private var displayedDayKey: String?
    @State private var updatedAt: Date?
    @State private var cacheIsStale = false

    init(historyStore: NBAHistoryStore = .shared, boxStore: NBABoxScoreStore = .shared,
         profileStore: NBAPlayerProfileStore = .shared, leagueStore: NBALeaguePercentileStore = .shared,
         onClose: @escaping () -> Void) {
        self.onClose = onClose; self.historyStore = historyStore; self.boxStore = boxStore
        self.profileStore = profileStore; self.leagueStore = leagueStore
    }
    private var latest: Date { NBASchedulePolicy.calendar.startOfDay(for: Date()) }
    private var requestKey: String { NBAHistoryStore.dayKey(day, calendar: NBASchedulePolicy.calendar) + refreshID.uuidString }

    var body: some View {
        Group {
            if let article = selectedArticle {
                VStack(spacing: 0) {
                    NBAHistoryNavigation(day: day, onBack: { selectedArticle = nil }, onToday: onClose)
                    NBARecapNotificationReader(article: article) {
                        selectedArticle = nil; selectedRoute = .statistics; selectedGameID = article.gameID
                    }.frame(width: 600, height: 540)
                }.modifier(NBAPanelSurface())
            } else if let selectedGameID {
                VStack(spacing: 0) {
                    NBAHistoryNavigation(day: day, onBack: { self.selectedGameID = nil }, onToday: onClose)
                    NBAReviewPanelView(gameID: selectedGameID, initialRoute: selectedRoute).id(selectedGameID + selectedRoute.rawValue)
                }.modifier(NBAPanelSurface())
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(action: onClose) { Label("今日", systemImage: "chevron.left") }
                        Spacer()
                        Text("历史比赛").fontWeight(.semibold)
                        Spacer()
                        Button { force = true; refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(viewModel.isLoading).accessibilityLabel("刷新历史比赛")
                    }.font(.system(size: 12)).buttonStyle(.plain)
                    HStack(spacing: 8) {
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("前一天")
                        Spacer()
                        DatePicker("比赛日期", selection: $day, in: ...latest, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .environment(\.calendar, NBASchedulePolicy.calendar)
                            .environment(\.timeZone, NBASchedulePolicy.timeZone)
                            .fixedSize()
                        Spacer()
                        Button { move(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(NBASchedulePolicy.calendar.isDate(day, inSameDayAs: latest))
                            .accessibilityLabel("后一天")
                    }.buttonStyle(.borderless).font(.system(size: 12))
                    NBAFlatMenu(viewModel: viewModel, selectedGameID: "", onSelect: { selectedRoute = .score; selectedGameID = $0.id },
                                heading: NBASchedulePolicy.dayTitle(day, weekdayOnly: true), emptyMessage: "当天暂无 NBA 比赛",
                                selectionHint: "点击查看比赛统计", onOpenArticle: { game, article in
                                    if let article { selectedArticle = article }
                                    else { selectedRoute = .recap; selectedGameID = game.id }
                                })
                    if let updatedAt {
                        HStack {
                            if cacheIsStale && viewModel.errorMessage == nil { Text("缓存数据").foregroundStyle(.orange) }
                            if viewModel.isLoading { ProgressView().controlSize(.mini) }
                            Spacer()
                            Text("更新于 " + updatedAt.formatted(.dateTime.month().day().hour().minute().second()))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(width: 420).modifier(NBAPanelSurface())
            }
        }
        .task(id: requestKey) {
            let key = requestKey
            let requestedDay = day
            let forced = force
            force = false
            let dayKey = NBAHistoryStore.dayKey(requestedDay, calendar: NBASchedulePolicy.calendar)
            if displayedDayKey != dayKey {
                viewModel.games = []; updatedAt = nil; cacheIsStale = false
            }
            displayedDayKey = dayKey
            viewModel.errorMessage = nil; viewModel.isLoading = true
            defer { if requestKey == key { viewModel.isLoading = false } }
            if let cached = await historyStore.cached(day: requestedDay, calendar: NBASchedulePolicy.calendar) {
                guard !Task.isCancelled, requestKey == key else { return }
                apply(cached)
            }
            do {
                let result = try await historyStore.loadEntry(day: requestedDay, calendar: NBASchedulePolicy.calendar, force: forced)
                guard !Task.isCancelled, requestKey == key else { return }
                apply(result)
            } catch {
                guard !Task.isCancelled, requestKey == key else { return }
                viewModel.errorMessage = "历史比赛加载失败，请点击刷新重试"
            }
        }
    }
    private func apply(_ entry: NBAHistoryStore.Entry) {
        viewModel.games = entry.games; updatedAt = entry.date; cacheIsStale = entry.isStale
        viewModel.errorMessage = entry.refreshFailed ? "刷新失败" : nil
    }

    private func move(_ offset: Int) {
        guard let next = NBASchedulePolicy.calendar.date(byAdding: .day, value: offset, to: day) else { return }
        day = min(next, latest)
    }
}
