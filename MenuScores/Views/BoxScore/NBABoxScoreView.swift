import SwiftUI

struct NBABoxScoreView: View {
    let gameID: String
    var boxStore: NBABoxScoreStore = .shared
    var profileStore: NBAPlayerProfileStore = .shared
    var leagueStore: NBALeaguePercentileStore = .shared
    var pregameStore: NBAPregameScheduleStore = .shared
    var articleStore: NBATerraRecapStore = .live
    var scheduledGame: Event?
    var onReviewRequested: (() -> Void)? = nil
    var onConversationRequested: (() -> Void)? = nil
    var conversationCount = 0
    var inlineReviewLead: String? = nil
    var embedsReviewOverview = false
    var presentationActive = true
    var onTeamSelectionChanged: (String) -> Void = { _ in }
    var initiallyShowsTerra = false
    var onTerraVisibilityChanged: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(NBATerraOptions.enabledKey) private var terraEnabled = true
    @State private var summary: NBABoxScore?
    @State private var grades: NBAStatGrades?
    @State private var showingColorExplanation = false
    @State private var selectedPlayer: NBABoxScore.PlayerRow?
    @State private var selectedTeamID = "13"
    @State private var errorMessage: String?
    @State private var updatedAt: Date?
    @State private var isLoading = false
    @State private var isVisible = false
    @State private var refreshID = UUID()
    @State private var forceRefresh = false
    @State private var cacheIsStale = false
    @State private var gradesDate: Date?
    @State private var gradesFailed = false
    @State private var pregameSchedules: [String: NBAPregameScheduleStore.Entry] = [:]
    @State private var pregameScope: NBAPregamePreview.Scope?
    @State private var pregameIsLoading = false
    @State private var pregameFailed = false
    @State private var forcePregameSchedules = false
    @State private var showingTerra = false
    @State private var articleModel: NBATerraArticleModel?
    @State private var statisticsHeight: CGFloat = 464

    private struct RefreshKey: Equatable {
        let gameID: String
        let isVisible: Bool
        let refreshID: UUID
        let playerID: String?
    }
    private struct GradesKey: Equatable {
        let scope: NBALeaguePercentileStore.Scope?
        let isVisible: Bool
        let playerID: String?
        let isPregame: Bool
    }
    private struct PregameKey: Equatable {
        let gameID: String
        let isVisible: Bool
        let scope: NBAPregamePreview.Scope?
        let date: Date?
        let refreshID: UUID
        let isPregame: Bool
    }

    private var pregame: NBAPregamePreview? {
        if let summary { return summary.hasPregamePresentation ? summary.pregame : nil }
        guard let game = scheduledGame, game.id == gameID, game.status.type.state == "pre" else { return nil }
        return NBAPregamePreview.fallback(event: game)
    }
    private var previewSchedules: [String: NBAPregamePreview.Schedule] { pregameSchedules.mapValues { $0.schedule } }
    private var pregameUpdatedAt: Date? {
        ([updatedAt].compactMap { $0 } + pregameSchedules.values.map(\.date)).min()
    }

    private var accent: Color {
        teamTint(summary?.teams.first(where: { $0.id == selectedTeamID })?.team.color)
    }

    private func teamTint(_ hex: String?) -> Color {
        let color = Color.nbaHex(hex)
        guard colorScheme == .dark else { return color }
        let native = NSColor(color)
        return Color(nsColor: native.blended(withFraction: 0.35, of: .white) ?? native)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showingTerra, let articleModel {
                NBATerraArticleView(model: articleModel) { showingTerra = false }
                    .frame(height: max(320, statisticsHeight - 24))
            } else if let selectedPlayer {
                NBAPlayerDetailView(player: selectedPlayer, tint: accent, seasonRating: grades?.ratings[selectedPlayer.id], profileStore: profileStore, leagueStore: leagueStore) { self.selectedPlayer = nil }
                    .id(selectedPlayer.id)
            } else if let pregame {
                NBAPregamePreviewView(preview: pregame, schedules: previewSchedules, updatedAt: pregameUpdatedAt,
                                      isLoading: isLoading || pregameIsLoading, refreshFailed: errorMessage != nil || pregameFailed,
                                      onTerra: terraEnabled && summary.flatMap({ NBATerraOptions.kind(for: $0) }) == .pregame ? {
                                          showTerra()
                                      } : nil) {
                    forceRefresh = true; forcePregameSchedules = true; refreshID = UUID()
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本场技术统计").font(.system(size: 13, weight: .semibold))
                        Label(summary?.chineseStatus ?? "正在加载比赛", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !embedsReviewOverview, terraEnabled, let summary, NBATerraOptions.kind(for: summary) == .recap {
                        Button("赛后总结") { showTerra() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    NBARefreshButton(disabled: isLoading, label: "刷新技术统计") { forceRefresh = true; refreshID = UUID() }
                }
                if let summary {
                    HStack(spacing: 5) {
                        ForEach(nbaOrderedTeams(summary.match?.competitors ?? [], side: { $0.homeAway }, id: { $0.team.id }), id: \.team.id) { competitor in
                            teamCard(competitor)
                        }
                    }
                    if embedsReviewOverview {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(inlineReviewLead ?? (summary.match?.status?.type?.state == "in" ? "比赛进行中，先看本场统计。" : "赛后解读暂未准备，可先查看本场统计。"))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if terraEnabled, NBATerraOptions.kind(for: summary) == .recap {
                                NBAReviewInlineAction(title: "详细复盘", identifier: "review-action-recap") { showTerra() }
                            }
                            if let onConversationRequested, conversationCount > 0 {
                                NBAReviewInlineAction(title: "对话 \(conversationCount)", identifier: "review-action-conversation", action: onConversationRequested)
                            }
                        }.padding(.vertical, 3)
                        gameStatistics(summary)
                    }
                    if let team = summary.teams.first(where: { $0.id == selectedTeamID }), !team.rows.isEmpty {
                        playerTable(team.rows)
                    } else {
                        Text(summary.match?.status?.type?.state == "pre"
                             ? "比赛尚未开始，球员技术统计将在开赛后显示。"
                             : "暂未提供球员技术统计，稍后自动重试。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                    }
                } else if isLoading {
                    HStack { Spacer(); ProgressView("加载球员数据…"); Spacer() }.frame(height: 100)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("ESPN · 点击球员查看个人统计 · 投篮：命中/出手")
                    Button("颜色说明") { showingColorExplanation.toggle() }
                        .buttonStyle(.borderless).keyboardShortcut("i", modifiers: [.command, .shift])
                        .popover(isPresented: $showingColorExplanation) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("颜色说明").font(.headline)
                                Text("单项本场数据对比联盟赛季场均分布。")
                                Text("正负值仅比较本场两队出场球员。")
                                Text("头像环按球员数据表现分档，结合上季与本季数据；虚线表示样本积累中。")
                                Text("历史比赛也显示当前可用的赛季评级，并非比赛当日评级。点球员可查看表现说明。")
                                Button("关闭") { showingColorExplanation = false }.keyboardShortcut(.cancelAction)
                            }.padding(16).frame(width: 280, alignment: .leading)
                        }
                    Spacer()
                    if let gradesDate, gradesFailed || Date().timeIntervalSince(gradesDate) >= 900 {
                        Text("评级缓存").foregroundStyle(.orange)
                            .help("评级数据：" + gradesDate.formatted(date: .abbreviated, time: .standard))
                    }
                    if cacheIsStale && errorMessage == nil { Text("缓存数据").foregroundStyle(.orange) }
                    if let updatedAt { Text("更新于 \(updatedAt.formatted(.dateTime.month().day().hour().minute().second()))") }
                    if isLoading && summary != nil { ProgressView().controlSize(.small) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: selectedPlayer == nil ? 620 : 480)
        .modifier(NBAStatsSurface(tint: accent))
        .background(GeometryReader { geometry in Color.clear.preference(key: NBATerraCardHeight.self, value: geometry.size.height) })
        .onPreferenceChange(NBATerraCardHeight.self) { if !showingTerra, selectedPlayer == nil, $0 > 100 { statisticsHeight = $0 } }
        .onChange(of: terraEnabled) { if !$0 { showingTerra = false; articleModel?.cancel() } }
        .onChange(of: showingTerra) { onTerraVisibilityChanged($0) }
        .onAppear { isVisible = presentationActive }
        .onDisappear { isVisible = false }
        .onChange(of: presentationActive) { isVisible = $0 }
        .onChange(of: selectedTeamID) { onTeamSelectionChanged($0) }
        .task(id: RefreshKey(gameID: gameID, isVisible: isVisible, refreshID: refreshID, playerID: selectedPlayer?.id)) {
            guard isVisible, selectedPlayer == nil else { isLoading = false; return }
            let forced = forceRefresh
            forceRefresh = false
            await refreshLoop(force: forced)
        }
        .task(id: GradesKey(scope: summary?.rankScope, isVisible: isVisible, playerID: selectedPlayer?.id, isPregame: pregame != nil)) {
            guard isVisible, selectedPlayer == nil, pregame == nil, let scope = summary?.rankScope else { return }
            if grades?.scope != scope { grades = nil; gradesDate = nil; gradesFailed = false }
            await applyGrades(await leagueStore.cachedPair(scope: scope), scope: scope)
            while !Task.isCancelled {
                await applyGrades(await leagueStore.loadPair(scope: scope), scope: scope)
                do { try await Task.sleep(nanoseconds: UInt64(NBALoadingPolicy.rankingInterval * 1_000_000_000)) }
                catch { return }
            }
        }
        .task(id: PregameKey(gameID: gameID, isVisible: isVisible, scope: pregame?.scope, date: updatedAt,
                            refreshID: refreshID, isPregame: pregame != nil)) {
            await loadPregameSchedules()
        }
        .onChange(of: gameID) { _ in
            selectedPlayer = nil; summary = nil; updatedAt = nil; errorMessage = nil; selectedTeamID = "13"
            cacheIsStale = false; grades = nil; gradesDate = nil; gradesFailed = false
            pregameSchedules = [:]; pregameScope = nil; pregameFailed = false; pregameIsLoading = false
        }
    }

    private func teamCard(_ competitor: NBABoxScore.Competitor) -> some View {
        let team = competitor.team
        let color = teamTint(team.color)
        let selected = selectedTeamID == team.id
        return Button { selectedTeamID = team.id } label: {
            HStack(spacing: 7) {
                NBATeamLogo(url: team.logo ?? summary?.teams.first(where: { $0.id == team.id })?.team.logo,
                            size: 22, teamID: team.id, abbreviation: team.abbreviation)
                VStack(alignment: .leading, spacing: 5) {
                    Text(team.chineseName).font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Text(competitor.score ?? "—").font(.system(size: embedsReviewOverview ? 28 : 21, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(8)
            .background(selected ? Color.purple.opacity(0.10) : color.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.purple.opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
        .accessibilityLabel("\(team.chineseName)，\(competitor.score ?? "暂无")分，查看球员统计")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func playerTable(_ rows: [NBABoxScore.PlayerRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("球员").frame(maxWidth: .infinity, alignment: .leading)
                cell("分钟", 30); cell("得分", 30); cell("篮板", 30); cell("助攻", 30)
                cell("投篮", 44); cell("命中率", 50); cell("正负值", 42)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(accent.opacity(0.07))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { selectedPlayer = row } label: {
                        HStack(spacing: 5) {
                            playerIdentity(row)
                            gradedCell(row.minutes, 30, key: "avgMinutes", row: row)
                            gradedCell(row.points, 30, key: "avgPoints", row: row)
                            gradedCell(row.rebounds, 30, key: "avgRebounds", row: row)
                            gradedCell(row.assists, 30, key: "avgAssists", row: row)
                            gradedCell(row.fieldGoals, 44, key: "fieldGoalPct", row: row, comparison: row.fieldGoalPercentage)
                            gradedCell(row.fieldGoalPercentage, 50, key: "fieldGoalPct", row: row)
                            gradedCell(row.plusMinus, 42, key: "plusMinus", row: row)
                        }
                        .font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 5)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
                        .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .help("点击查看\(row.name)的个人统计")
                        .accessibilityLabel("\(row.name)，查看个人统计")
                        Divider().opacity(0.35)
                    }
                }
                .background {
                    #if DEBUG
                    NBABoxScoreScrollProbe().frame(width: 0, height: 0)
                    #endif
                }
            }.frame(height: 292)
        }.clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private func gameStatistics(_ summary: NBABoxScore) -> some View {
        let sides = nbaOrderedTeams(summary.match?.competitors ?? [], side: { $0.homeAway }, id: { $0.team.id })
        let count = min(20, sides.compactMap { $0.linescores?.count }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if count > 0 {
                    HStack(spacing: 8) {
                        statisticsSideLabels("单节比分", sides: sides)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(0..<count, id: \.self) { index in
                                    VStack(spacing: 5) {
                                        Text(index < 4 ? "Q\(index + 1)" : "OT\(index - 3)").font(.system(size: 11)).foregroundStyle(.secondary)
                                        ForEach(sides, id: \.team.id) { side in
                                            Text(side.linescores?.indices.contains(index) == true ? side.linescores![index].text : "—")
                                                .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                                        }
                                    }.frame(width: max(44, 500 / CGFloat(max(4, count))))
                                }
                            }
                        }
                    }
                } else { Text("单节比分暂未提供").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            Group {
                if !summary.statisticNames.isEmpty {
                    HStack(spacing: 8) {
                        statisticsSideLabels("球队统计", sides: sides)
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 8) {
                                ForEach(summary.statisticNames, id: \.self) { name in
                                    VStack(spacing: 5) {
                                        Text(summary.statisticLabel(name)).font(.system(size: 11)).foregroundStyle(.secondary).help(summary.statisticLabel(name))
                                        ForEach(sides, id: \.team.id) { side in
                                            Text(summary.statistic(name, teamID: side.team.id)).font(.system(size: 12)).monospacedDigit()
                                        }
                                    }.lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 60)
                                }
                            }.padding(.bottom, 2)
                        }
                    }
                } else { Text("球队统计暂未提供").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func statisticsSideLabels(_ title: String, sides: [NBABoxScore.Competitor]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(sides, id: \.team.id) { side in Text(side.team.chineseName).font(.system(size: 12)).lineLimit(1) }
        }.frame(width: 65, alignment: .leading)
    }

    private func playerIdentity(_ row: NBABoxScore.PlayerRow) -> some View {
        HStack(spacing: 5) {
            let rating = grades?.ratings[row.id]
            let position = rating?.position
            NBARankedAvatar(url: row.headshot, tint: accent, tier: position?.tier)
                .padding(.horizontal, 3)
                .help(rating?.helpText ?? "暂无近期数据表现估计，中性虚线环不代表末档。")
                .accessibilityLabel("\(row.name)，\(rating?.helpText ?? "暂无近期数据表现估计")")
            Text(row.jersey.map { "#\($0)" } ?? "—")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 25, height: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).fontWeight(.medium).lineLimit(1).help([row.originalName, row.starter ? "首发" : "替补", row.position].filter { !$0.isEmpty }.joined(separator: " · "))
                if row.didNotPlay {
                    Text(row.absence).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gradedCell(_ text: String, _ width: CGFloat, key: String, row: NBABoxScore.PlayerRow, comparison: String? = nil) -> some View {
        let value = NBAStatGrades.number(comparison ?? text)
        let position: NBALeaguePosition? = {
            guard !row.didNotPlay, let value else { return nil }
            if key == "plusMinus" {
                let values = summary?.teams.flatMap(\.rows).filter { !$0.didNotPlay }.compactMap { NBAStatGrades.number($0.plusMinus) } ?? []
                return NBAStatDistribution(values: values).position(for: value)
            }
            return grades?.performancePosition(value: value, key: key)
        }()
        let tier = position?.tier
        let style = NBARankCardStyle(tier: tier)
        let emphasized = NBAStatGrades.isEmphasized(tier)
        let ink: Color = {
            guard emphasized else { return .primary }
            if colorScheme == .dark { return style.color }
            switch tier {
            case .red: return .nbaHex("a62241")
            case .gold: return .nbaHex("815100")
            default: return .nbaHex("69339b")
            }
        }()
        return Text(text).monospacedDigit().fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(ink)
            .frame(width: width, height: 20, alignment: .trailing)
            .help(position.map { "\(key == "plusMinus" ? "本场正负值" : "对比联盟赛季场均") · \($0.text)" } ?? "")
    }

    private func cell(_ text: String, _ width: CGFloat) -> some View {
        Text(text).monospacedDigit().frame(width: width, alignment: .trailing)
    }

    @MainActor
    private func applyGrades(_ pair: NBALeaguePercentileStore.Pair, scope: NBALeaguePercentileStore.Scope) async {
        guard !Task.isCancelled, summary?.rankScope == scope, let snapshot = pair.snapshot else { return }
        let prior = pair.prior
        let result = await Task.detached(priority: .userInitiated) { NBAStatGrades(snapshot: snapshot, priorData: prior) }.value
        guard !Task.isCancelled, summary?.rankScope == scope else { return }
        grades = result; gradesDate = snapshot.date
        gradesFailed = pair.currentRefreshFailed || prior.refreshFailed
    }

    @MainActor
    private func apply(_ entry: NBABoxScoreStore.Entry) {
        let result = entry.summary
        if let model = articleModel, let old = model.input?.facts.kind, NBATerraOptions.kind(for: result) != old { model.invalidateState() }
        summary = result
        updatedAt = entry.date
        cacheIsStale = entry.isStale
        errorMessage = entry.refreshFailed ? "更新失败 · 显示缓存" : nil
        if initiallyShowsTerra, articleModel == nil, terraEnabled, NBATerraOptions.kind(for: result) != nil { showTerra() }
        if !result.teams.contains(where: { $0.id == selectedTeamID }) {
            selectedTeamID = result.teams.first(where: { $0.id == "13" })?.id ?? result.teams.first?.id ?? "13"
        }
    }

    @MainActor private func showTerra() {
        if let onReviewRequested { onReviewRequested(); return }
        if articleModel == nil { articleModel = NBATerraArticleModel(gameID: gameID, boxStore: boxStore, articles: articleStore) }
        showingTerra = true
    }

    @MainActor
    private func loadPregameSchedules() async {
        guard isVisible, let preview = pregame, preview.eventID == gameID,
              preview.specialStatus == nil, let scope = preview.scope else { return }
        let requestedID = gameID
        if pregameScope != scope { pregameSchedules = [:]; pregameScope = scope }
        let ids = preview.teams().filter(\.needsSchedule).map(\.id)
        guard !ids.isEmpty else { return }
        pregameIsLoading = true
        defer {
            if !Task.isCancelled { pregameIsLoading = false; forcePregameSchedules = false }
        }
        let forced = forcePregameSchedules
        for id in ids {
            if let cached = await pregameStore.cached(teamID: id, scope: scope) {
                guard !Task.isCancelled, gameID == requestedID else { return }
                pregameSchedules[id] = cached
            }
        }
        let store = pregameStore
        await withTaskGroup(of: (String, NBAPregameScheduleStore.Entry?).self) { group in
            for id in ids {
                group.addTask { (id, try? await store.load(teamID: id, scope: scope, force: forced)) }
            }
            var failed = false
            for await (id, entry) in group {
                guard !Task.isCancelled, gameID == requestedID, pregame?.scope == scope else { continue }
                if let entry { pregameSchedules[id] = entry; failed = failed || entry.refreshFailed }
                else { failed = true }
            }
            if !Task.isCancelled, gameID == requestedID { pregameFailed = failed }
        }
    }

    @MainActor
    private func refreshLoop(force: Bool) async {
        let requestedGameID = gameID
        var forced = force
        defer { if !Task.isCancelled { isLoading = false } }
        if let cached = await boxStore.cached(gameID: requestedGameID, liveInterval: summaryInterval) {
            guard !Task.isCancelled else { return }
            apply(cached)
        }
        while !Task.isCancelled {
            isLoading = true
            var delay = NBALoadingPolicy.liveInterval
            do {
                let entry = try await boxStore.load(gameID: requestedGameID, force: forced, liveInterval: summaryInterval)
                try Task.checkCancellation()
                apply(entry)
                if entry.summary.hasPregamePresentation {
                    delay = entry.refreshFailed ? 60 : summaryInterval
                } else {
                    let urls = entry.summary.teams.flatMap(\.rows).compactMap { $0.headshot.flatMap(URL.init(string:)) }
                    Task { await NBAAvatarCache.shared.prewarm(urls) }
                    delay = NBALoadingPolicy.summaryDelay(state: entry.summary.match?.status?.type?.state,
                                                          fetchedAt: entry.date, refreshFailed: entry.refreshFailed)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = summary == nil ? "技术统计加载失败，请点击刷新重试。" : "更新失败 · 显示缓存"
                if pregame != nil { delay = 60 }
            }
            forced = false
            isLoading = false
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    private var summaryInterval: TimeInterval {
        guard let preview = pregame else { return NBALoadingPolicy.liveInterval }
        return NBAPregamePreview.pollingInterval(start: preview.startDate)
    }
}

#if DEBUG
private struct NBABoxScoreScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier("boxscore-players"); return view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

private struct NBATerraCardHeight: PreferenceKey {
    static var defaultValue: CGFloat = 464
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
