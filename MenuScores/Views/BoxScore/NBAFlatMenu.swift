import SwiftUI

struct NBAFlatMenu: View {
    @ObservedObject var viewModel: GamesListView
    let selectedGameID: String
    let onSelect: (Event) -> Void
    var heading = "NBA 比赛"
    var emptyMessage = "今天暂无 NBA 比赛"
    var selectionHint = "点击固定到菜单栏"
    var tomorrowSection = false
    var maxVisibleGames = 8
    var onOpenArticle: ((Event, NBARecap?) -> Void)? = nil
    @ObservedObject var articleStatus: NBAArticleMenuStatus = .shared
    @ObservedObject private var favorites = FavoritesManager.shared
    @AppStorage(NBATerraOptions.enabledKey) private var articlesEnabled = true
    @State private var hoveredGameID: String?

    private var favoriteIDs: Set<String> {
        Set(favorites.favorites.filter { $0.leagueKey == "NBA" }.map(\.id))
    }
    private var orderedGames: [Event] {
        displayedGames.enumerated().sorted { lhs, rhs in
            let left = Self.isFavorite(lhs.element, teamIDs: favoriteIDs)
            let right = Self.isFavorite(rhs.element, teamIDs: favoriteIDs)
            return left == right ? lhs.offset < rhs.offset : left
        }.map(\.element)
    }
    private var displayedGames: [Event] { tomorrowSection ? viewModel.tomorrowGames : viewModel.games }
    private var displayedError: String? { tomorrowSection ? viewModel.tomorrowError : viewModel.errorMessage }
    private var loading: Bool { tomorrowSection ? viewModel.tomorrowIsLoading : viewModel.isLoading }

    var body: some View {
        HStack {
            Text(heading).font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("\(displayedGames.count) 场").font(.caption).foregroundStyle(.secondary)
        }
        if let error = displayedError {
            Text(displayedGames.isEmpty ? error : "\(error) · 保留上次数据")
                .font(.caption).foregroundStyle(.secondary)
        } else if displayedGames.isEmpty {
            Text(loading ? "正在加载比赛…" : emptyMessage)
                .font(.caption).foregroundStyle(.secondary)
        }
        if !displayedGames.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(orderedGames, id: \.id) { game in
                        gameRow(game)
                        Divider().frame(height: 1).opacity(0.4)
                    }
                }
            }
            .frame(height: CGFloat(min(displayedGames.count, maxVisibleGames)) * 45)
            .task(id: displayedGames.map(\.id).joined(separator: ",") + String(articlesEnabled)) {
                guard articlesEnabled else { return }
                while !Task.isCancelled {
                    await articleStatus.refresh(games: displayedGames)
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terraArticlePrepared).receive(on: RunLoop.main)) { _ in
                if articlesEnabled { Task { await articleStatus.refresh(games: displayedGames) } }
            }
        }
    }

    private func gameRow(_ game: Event) -> some View {
        HStack(spacing: 0) {
            gamePinButton(game)
            if articlesEnabled, let kind = NBAArticleMenuStatus.kind(for: game) {
                let status = articleStatus.states[game.id].flatMap { $0.kind == kind ? $0 : nil }
                    ?? NBAArticleMenuStatus.state(kind: kind, job: nil, article: nil)
                Group {
                    if status.phase == .preparing || status.phase == .reviewing {
                        ProgressView().controlSize(.mini).scaleEffect(0.75)
                            .accessibilityLabel(status.label)
                    } else if status.article != nil, let onOpenArticle {
                        Button { onOpenArticle(game, status.article) } label: {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12, weight: .regular)).frame(width: 22, height: 30)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .foregroundStyle(status.article == nil ? Color.secondary : .blue)
                            .accessibilityLabel(status.article == nil ? status.label + "，查看本场解读" : status.action)
                            .accessibilityIdentifier("article-action." + game.id)
                    } else { Color.clear.accessibilityHidden(true) }
                }.frame(width: 22, height: 30).padding(.trailing, 4)
            }
        }
            // Reserve the scrollbar lane inside the full-width row highlight.
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(game.id == selectedGameID ? Color.purple.opacity(0.10) : hoveredGameID == game.id ? Color.primary.opacity(0.045) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hoveredGameID = $0 ? game.id : nil }
    }

    private func gamePinButton(_ game: Event) -> some View {
        let teams = nbaOrderedTeams(game.competitions.first?.competitors ?? [], side: { $0.homeAway }, id: { $0.team?.id ?? $0.id })
        let away = teams.first
        let home = teams.count > 1 ? teams[1] : nil
        let selected = game.id == selectedGameID
        return Button { onSelect(game) } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark" : "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.purple)
                    .opacity(selected || Self.isFavorite(game, teamIDs: favoriteIDs) ? 1 : 0)
                    .frame(width: 10)
                mark(away?.team?.logo)
                Text(name(away)).frame(width: 54, alignment: .leading)
                HStack(spacing: 4) {
                    Text(game.status.type.state == "pre" ? "—" : away?.score ?? "—").frame(width: 27, alignment: .trailing)
                    Text(":").foregroundStyle(.tertiary)
                    Text(game.status.type.state == "pre" ? "—" : home?.score ?? "—").frame(width: 27, alignment: .leading)
                }.font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(name(home)).frame(width: 54, alignment: .trailing)
                mark(home?.team?.logo)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(state(game))
                    if game.status.type.state == "in", let clock = game.status.displayClock { Text(clock).monospacedDigit() }
                }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 42)
            }
            .font(.system(size: 12)).lineLimit(1)
            .frame(height: 36).padding(.horizontal, 7).padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("game-select." + game.id)
        .contextMenu {
            if articlesEnabled, let kind = NBAArticleMenuStatus.kind(for: game),
               let status = articleStatus.states[game.id], status.kind == kind, status.canOpen, let onOpenArticle {
                Button(status.article == nil ? "查看本场解读" : status.action) { onOpenArticle(game, status.article) }
            }
        }
        .task(id: game.id) {
            guard !AppRuntime.suppressesLiveWork else { return }
            let teamIDs = Set(game.competitions.first?.competitors?.compactMap { $0.team?.id } ?? [])
            await NBAAvatarCache.shared.prioritizeTeams(teamIDs, priority: .menu)
            await NBAAvatarCache.shared.prewarmGame(game.id)
        }
        .accessibilityLabel(NBAMenuPresentation.title(for: game))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func mark(_ url: String?) -> some View {
        Group {
            if let image = NBATeamLogo.bundledImage(url: url) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "basketball").resizable().scaledToFit().foregroundStyle(.orange) }
        }.frame(width: 19, height: 19).padding(2)
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
    private func name(_ competitor: Competitor?) -> String {
        NBAMenuPresentation.teamName(competitor?.team?.abbreviation, fallback: competitor?.team?.displayName ?? "待定")
    }
    private func state(_ game: Event) -> String {
        if let special = NBAMenuPresentation.specialState(for: game) { return special }
        if game.status.type.state == "post" { return "已结束" }
        if game.status.type.state == "pre" {
            return NBASchedulePolicy.startDate(game.date).map { NBASchedulePolicy.startTime($0) } ?? "待赛"
        }
        let period = game.status.period ?? 1
        return period > 4 ? "加时\(period - 4)" : "第\(period)节"
    }
    static func isFavorite(_ game: Event, teamIDs: Set<String>) -> Bool {
        game.competitions.first?.competitors?.contains { teamIDs.contains($0.team?.id ?? $0.id) } ?? false
    }
}
