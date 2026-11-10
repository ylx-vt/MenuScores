import SwiftUI

struct NBAPlayerDetailView: View {
    let player: NBABoxScore.PlayerRow
    let tint: Color
    var seasonRating: NBASeasonRating? = nil
    let onBack: () -> Void
    let profileStore: NBAPlayerProfileStore
    let leagueStore: NBALeaguePercentileStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var entry: NBAPlayerProfileStore.Entry?
    @State private var refreshedRating: NBASeasonRating?
    @State private var career = false
    @State private var snapshot: NBALeagueSnapshot?
    @State private var rankingLoading = false
    @State private var loading = false
    @State private var failed = false
    @State private var requestID = UUID()
    @State private var forceRefresh = false
    @State private var profileStale = false
    @State private var profileRefreshFailed = false
    @State private var rankRefreshFailed = false
    #if DEBUG
    private var offlinePreview = false
    #endif

    init(player: NBABoxScore.PlayerRow, tint: Color, seasonRating: NBASeasonRating? = nil, profileStore: NBAPlayerProfileStore = .shared, leagueStore: NBALeaguePercentileStore = .shared, onBack: @escaping () -> Void) {
        self.player = player
        self.tint = tint
        self.seasonRating = seasonRating
        self.onBack = onBack
        self.profileStore = profileStore; self.leagueStore = leagueStore
    }

    #if DEBUG
    /// Offline QA uses the production view and archived raw data, without making
    /// network requests or changing the user's caches/preferences.
    init(preview player: NBABoxScore.PlayerRow, tint: Color, entry: NBAPlayerProfileStore.Entry,
         snapshot: NBALeagueSnapshot, priorData: NBAPriorSeasonData = .unavailable, onBack: @escaping () -> Void) {
        self.init(player: player, tint: tint, onBack: onBack)
        _entry = State(initialValue: entry)
        _snapshot = State(initialValue: snapshot)
        _refreshedRating = State(initialValue: NBAStatGrades(snapshot: snapshot, priorData: priorData).ratings[player.id])
        offlinePreview = true
    }
    #endif

    private let metrics: [(String, String)] = [
        ("avgPoints", "得分"), ("avgRebounds", "篮板"), ("avgAssists", "助攻"),
        ("avgSteals", "抢断"), ("avgBlocks", "盖帽"), ("avgTurnovers", "失误"),
        ("fieldGoalPct", "投篮命中率"), ("threePointPct", "三分命中率"), ("freeThrowPct", "罚球命中率")
    ]

    private var activeRating: NBASeasonRating? {
        if let scope = entry?.profile.rankScope {
            if let refreshedRating, refreshedRating.scope == scope { return refreshedRating }
            if let seasonRating, seasonRating.scope == scope { return seasonRating }
            return nil
        }
        return entry == nil ? seasonRating : nil
    }

    private func rankColor(_ tier: NBAPlayerProfile.RankTier) -> Color {
        NBARankCardStyle(tier: tier).color
    }

    private func rankLegend(_ text: String, _ tier: NBAPlayerProfile.RankTier) -> some View {
        HStack(spacing: 3) {
            Circle().fill(rankColor(tier)).frame(width: 4, height: 4)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func metricTile(key: String, label: String, profile: NBAPlayerProfile, split: String) -> some View {
        let board = career ? nil : snapshot
        let position = board?.position(id: player.id, key: key)
        let style = NBARankCardStyle(tier: position?.tier)
        let value = board?.display(id: player.id, key: key) ?? profile.statistics?.value(key, split: split) ?? "—"
        let status = career ? "生涯统计" : rankingLoading ? "…" : board?.rankingStatus(id: player.id, key: key) ?? "暂无排名"
        let detail = position.map {
            "第\($0.rank) / \($0.population)名，\($0.text)"
        } ?? status
        let qualificationHelp = career ? "" : "。仅比较该项ESPN资格内有效数据，未达标或零出手不参与排名；与综合准入不同。"
        let turnoverHelp = key == "avgTurnovers" && !career ? "低值仅表示失误数量较少，不代表控球能力。" : ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label + (key == "avgTurnovers" ? "↓" : "")).foregroundStyle(style.secondaryInk)
                Spacer(minLength: 0)

            }.font(.system(size: 9))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(style.ink)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Text(position?.text ?? (career ? " " : status))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(style.secondaryInk)
                Spacer(minLength: 0)

            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity)
        .background(style.surface())
        .help("\(label)：\(value)。\(detail)\(qualificationHelp)\(turnoverHelp)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(value)，\(detail)\(qualificationHelp)\(turnoverHelp)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onBack) { Label("返回比赛", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                Spacer()
                NBARefreshButton(disabled: loading, label: "刷新球员资料") { forceRefresh = true; requestID = UUID() }
            }
            HStack(spacing: 8) {
                NBARankedAvatar(url: player.headshot, tint: tint, tier: activeRating?.position?.tier, size: 48)
                    .padding(.horizontal, 3)
                    .help(activeRating?.helpText ?? "暂无近期数据表现估计，中性虚线环不代表末档。")
                    .accessibilityLabel(activeRating?.helpText ?? "暂无近期数据表现估计")
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(entry?.profile.measurements ?? player.originalName)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("#\(entry?.profile.athlete.jersey ?? player.jersey ?? "—") · \(NBALocalization.position(entry?.profile.athlete.position?.abbreviation).isEmpty ? player.position : NBALocalization.position(entry?.profile.athlete.position?.abbreviation))")
                        .font(.system(size: 11, weight: .medium))
                    if let team = entry?.profile.athlete.team {
                        Text(NBAMenuPresentation.teamName(team.abbreviation, fallback: team.displayName ?? ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if let entry {
                let profile = entry.profile
                NBASeasonPerformanceSummary(rating: activeRating)
                NBAStatsScopeControl(career: $career, seasonTitle: profile.seasonSplitTitle)
                    .frame(height: 24)
                Text(career ? "生涯场均（命中率为百分比）" : "单项场均 · 各按同项有效达标池比较").font(.system(size: 9)).foregroundStyle(.secondary)
                let split = career ? "Career" : profile.seasonSplit ?? "Regular Season"
                if profile.statistics?.splits?.contains(where: { $0.displayName == split }) == true {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(metrics, id: \.0) { key, label in
                            metricTile(key: key, label: label, profile: profile, split: split)
                        }
                    }
                    HStack {
                        Text("出场 \((career ? nil : snapshot?.display(id: player.id, key: "gamesPlayed")) ?? profile.statistics?.value("gamesPlayed", split: split) ?? "—") 场")
                        Spacer()
                        Text("场均 \((career ? nil : snapshot?.display(id: player.id, key: "avgMinutes")) ?? profile.statistics?.value("avgMinutes", split: split) ?? "—") 分钟")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("暂无该范围统计").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
                HStack(spacing: 8) {
                        Text("档位·前").foregroundStyle(.secondary)
                        ForEach(NBAPlayerProfile.RankTier.allCases, id: \.rawValue) { tier in
                            rankLegend(tier.legend, tier)
                        }
                    }.font(.system(size: 9)).opacity(career ? 0 : 0.75).accessibilityHidden(career)
                HStack {
                    Text("ESPN")
                    Spacer()
                    if loading { ProgressView().controlSize(.mini) }
                    Text("资料 " + entry.date.formatted(.dateTime.hour().minute().second()))
                        .help(entry.date.formatted(date: .abbreviated, time: .standard))
                    if !career, let snapshot {
                        Text("统计 " + snapshot.date.formatted(.dateTime.month().day().hour().minute().second()))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let caption = NBALoadingPolicy.cacheCaption(
                    stale: profileStale || (!career && snapshot.map { Date().timeIntervalSince($0.date) >= 900 } == true),
                    failed: profileRefreshFailed || (!career && rankRefreshFailed)) {
                    Text(caption).font(.system(size: 10)).foregroundStyle(.orange)
                }
            } else if loading {
                ProgressView("加载个人统计…").frame(maxWidth: .infinity, minHeight: 240)
            } else if failed {
                VStack(spacing: 10) {
                    Text("个人统计加载失败").foregroundStyle(.secondary)
                    Button("重新加载") { forceRefresh = true; requestID = UUID() }
                }.frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: requestID) {
            #if DEBUG
            if offlinePreview { return }
            #endif
            let forced = forceRefresh
            forceRefresh = false
            loading = true; failed = false
            defer { if !Task.isCancelled { loading = false } }
            if let cached = await profileStore.cached(id: player.id) {
                guard !Task.isCancelled else { return }
                entry = cached.entry; profileStale = cached.isStale; profileRefreshFailed = cached.refreshFailed
            }
            do {
                let result = try await profileStore.loadResult(id: player.id, force: forced)
                try Task.checkCancellation()
                entry = result.entry; profileStale = result.isStale; profileRefreshFailed = result.refreshFailed
            } catch { if !Task.isCancelled { failed = true; profileRefreshFailed = true } }
        }
        .task(id: entry?.profile.rankScope) {
            #if DEBUG
            if offlinePreview { return }
            #endif
            guard let scope = entry?.profile.rankScope else {
                snapshot = nil; refreshedRating = nil; rankRefreshFailed = false
                return
            }
            if snapshot?.scope != scope { snapshot = nil; refreshedRating = nil }
            await applyPair(await leagueStore.cachedPair(scope: scope), scope: scope)
            while !Task.isCancelled {
                rankingLoading = true
                await applyPair(await leagueStore.loadPair(scope: scope), scope: scope)
                guard !Task.isCancelled else { return }
                rankingLoading = false
                do { try await Task.sleep(nanoseconds: UInt64(NBALoadingPolicy.rankingInterval * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    @MainActor
    private func applyPair(_ pair: NBALeaguePercentileStore.Pair, scope: NBALeaguePercentileStore.Scope) async {
        guard !Task.isCancelled, entry?.profile.rankScope == scope else { return }
        rankRefreshFailed = pair.currentRefreshFailed || pair.prior.refreshFailed
        guard let board = pair.snapshot else { return }
        let prior = pair.prior
        let playerID = player.id
        let rating = await Task.detached(priority: .userInitiated) {
            NBAStatGrades(snapshot: board, priorData: prior).ratings[playerID]
        }.value
        guard !Task.isCancelled, entry?.profile.rankScope == scope else { return }
        snapshot = board; refreshedRating = rating

    }
}

/// Segmented single selection with a separate keyboard focus indicator.
private struct NBAStatsScopeControl: View {
    @Binding var career: Bool
    let seasonTitle: String
    @FocusState private var focused: Bool?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 0) {
            segment(seasonTitle, value: false)
            segment("生涯常规赛", value: true)
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("统计范围")
    }
    private func segment(_ title: String, value: Bool) -> some View {
        Button { career = value } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(career == value ? Color.secondary.opacity(scheme == .dark ? 0.32 : 0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused == value ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused, equals: value)
        .keyboardShortcut(value ? "2" : "1", modifiers: [.command, .shift])
        .accessibilityAddTraits(career == value ? .isSelected : [])
        .onMoveCommand { direction in
            if direction == .left { career = false; focused = false }
            if direction == .right { career = true; focused = true }
        }
    }
}
