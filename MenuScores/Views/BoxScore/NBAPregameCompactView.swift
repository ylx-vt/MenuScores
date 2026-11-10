import SwiftUI

struct NBAPregameCompactView: View {
    let preview: NBAPregamePreview
    let refreshing: Bool
    let refresh: () -> Void
    private var teams: [NBAPregamePreview.TeamCard] { preview.teams() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.specialStatus ?? "赛前").font(.system(size: 12, weight: .semibold))
                    Text(preview.startDate.map { "北京时间 " + NBASchedulePolicy.startTime($0, includeDay: true) } ?? "开赛时间待定")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                NBARefreshButton(disabled: refreshing, label: "刷新赛前信息", action: refresh)
            }
            HStack(spacing: 14) {
                ForEach(teams) { card in
                    HStack(spacing: 8) {
                        NBATeamLogo(url: card.team.logoURL, size: 26, teamID: card.id, abbreviation: card.team.abbreviation)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.team.name).font(.system(size: 14, weight: .semibold))
                            Text((card.isHome ? "主场" : "客场") + " · " + (card.record ?? "战绩待更新"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Text("本季场均得分").foregroundStyle(.secondary)
                Spacer()
                ForEach(teams) { card in
                    Text(card.team.name + " " + (card.points.map { String(format: "%.1f", $0) } ?? "—"))
                }
            }.font(.system(size: 11)).monospacedDigit().padding(9)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            if let insight = preview.insight() {
                Text(insight).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
