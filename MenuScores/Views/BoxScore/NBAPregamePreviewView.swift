import SwiftUI

/// Standalone content for the pregame branch. It deliberately owns no network
/// tasks: the parent supplies the same cached summary and optional team schedules.
struct NBAPregamePreviewView: View {
    let preview: NBAPregamePreview
    var schedules: [String: NBAPregamePreview.Schedule] = [:]
    var updatedAt: Date?
    var isLoading = false
    var refreshFailed = false
    var showsRefreshButton = true
    var onTerra: (() -> Void)? = nil
    var onRefresh: () -> Void
    @State private var showingDetails = false

    private var teams: [NBAPregamePreview.TeamCard] { preview.teams(schedules: schedules) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("赛前前瞻").font(.system(size: 14, weight: .semibold))
                    Text(kickoff).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let onTerra {
                    Button("赛前看点", action: onTerra).buttonStyle(.borderless).font(.caption)
                }
                if showsRefreshButton {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(isLoading).help("刷新赛前前瞻")
                }
            }

            if let status = preview.specialStatus {
                Label(status, systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            if !teams.isEmpty {
                HStack(spacing: 8) {
                    ForEach(teams) { team in teamCard(team) }
                }
                comparison
                if let insight = preview.insight(schedules: schedules) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("看点").font(.system(size: 12, weight: .semibold))
                        Text(insight).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11).background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }
                if teams.contains(where: { $0.scoringLeader != nil && $0.scoringLeaderPoints != nil }) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(teams) { team in
                            VStack(alignment: .leading, spacing: 3) {
                                if let name = team.scoringLeader, let points = team.scoringLeaderPoints {
                                    Text(NBALocalization.player(name)).font(.system(size: 12, weight: .medium))
                                    Text("本季场均 \(number(points)) 分").font(.system(size: 10)).foregroundStyle(.secondary)
                                } else { Text("球员数据待更新").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 2)
                }
            } else {
                Text(isLoading ? "正在准备比赛前瞻…" : "前瞻数据待更新")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
            }

            HStack {
                if let destination = preview.officialReportURL {
                    Link(destination: destination) {
                        Label("官方伤停报告", systemImage: "arrow.up.right")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("伤停信息待更新").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if refreshFailed { Text("更新失败 · 显示缓存").foregroundStyle(.orange) }
                if isLoading { ProgressView().controlSize(.mini) }
            }.font(.system(size: 10))

            DisclosureGroup(isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ESPN · \(preview.scope?.title ?? "赛季信息待更新")")
                    Text("近况仅采用已核对赛季阶段的完赛，按最近到最远排列。")
                    Text("休息天数为两次比赛北京时间日期之间的无赛日，不是实际休息时长。")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            } label: {
                HStack {
                    Text("数据说明")
                    Spacer()
                    if let updatedAt {
                        Text("更新于 " + NBASchedulePolicy.startTime(updatedAt, includeDay: true))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var kickoff: String {
        guard let date = preview.startDate else { return "开赛时间待定" }
        return "北京时间 " + NBASchedulePolicy.startTime(date, includeDay: true)
    }

    private func teamCard(_ card: NBAPregamePreview.TeamCard) -> some View {
        HStack(spacing: 9) {
            teamLogo(card.team)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(card.team.name).font(.system(size: 13, weight: .semibold))
                    Text(card.isHome ? "主场" : "客场").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(card.record.map { "\($0) · \(preview.scope?.title ?? "战绩")" } ?? "战绩待更新")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    private var comparison: some View {
        VStack(spacing: 0) {
            comparisonRow(title: teams.contains(where: { !$0.recentGames.isEmpty && $0.recentGames.count < 5 }) ? "近期比赛" : "近5场", subtitle: "由近到远") { team in
                if team.recentGames.isEmpty {
                    Text("近况待更新").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(team.recentGames, id: \.id) { game in
                            Text(game.won ? "胜" : "负").font(.system(size: 10, weight: .medium))
                                .frame(width: 23, height: 23)
                                .background(game.won ? Color.purple.opacity(0.14) : Color.secondary.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 5))
                                .help("\(NBASchedulePolicy.dayTitle(game.date)) 对\(game.opponent) \(game.points)–\(game.opponentPoints)")
                        }
                    }.accessibilityLabel(team.team.name + "近\(team.recentGames.count)场，由近到远：" + team.recentGames.map { $0.won ? "胜" : "负" }.joined(separator: "、"))
                }
            }
            Divider().opacity(0.4)
            comparisonRow(title: "得分 / 失分", subtitle: "本季场均") { team in
                Text("\(team.points.map(number) ?? "—") / \(team.pointsAgainst.map(number) ?? "—")")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Divider().opacity(0.4)
            comparisonRow(title: "休息", subtitle: "中间无赛日") { team in
                Text(team.offDays.map { $0 == 0 ? "无休息日" : "休息\($0)天" } ?? "待更新")
                    .font(.system(size: 11)).foregroundStyle(team.offDays == nil ? .secondary : .primary)
            }
        }.padding(.horizontal, 9).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    }

    private func comparisonRow<Content: View>(title: String, subtitle: String,
                                              @ViewBuilder content: @escaping (NBAPregamePreview.TeamCard) -> Content) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(width: 84, alignment: .leading)
            ForEach(teams) { team in content(team).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minHeight: 47)
    }

    private func number(_ value: Double) -> String { String(format: "%.1f", value) }

    private func teamLogo(_ team: NBAPregamePreview.Team) -> some View {
        Group {
            if let image = localLogo(team) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "basketball").resizable().scaledToFit().foregroundStyle(.orange) }
        }.frame(width: 28, height: 28).padding(4)
            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
    }

    private func localLogo(_ team: NBAPregamePreview.Team) -> NSImage? {
        NBATeamLogo.bundledImage(url: team.logoURL, teamID: team.id, abbreviation: team.abbreviation)
    }
}
