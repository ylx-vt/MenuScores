import SwiftUI

@MainActor
final class NBANotchViewModel: ObservableObject {
    @Published var game: Event?
    @Published var momentTitle: String?
    @Published var stale = true
    var openDetails: () -> Void = {}
}

struct NBANotchCompactSide: View {
    @ObservedObject var model: NBANotchViewModel
    let away: Bool
    var body: some View {
        if let game = model.game {
            let presentation = NBANotchPresentation(game: game)
            let side = presentation.teams.dropFirst(away ? 0 : 1).first
            HStack(spacing: 7) {
                if away { logo(side) }
                Text(presentation.compactTime.map { away ? $0 : "待赛" } ?? side?.score ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                if !away, let badge = presentation.compactBadge {
                    Text(badge).font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
                }
                if away && model.stale { Image(systemName: "clock").font(.system(size: 9)) }
                if !away { logo(side) }
            }.foregroundStyle(.white).padding(.horizontal, 3)
                .opacity(model.stale ? 0.65 : 1)
                .accessibilityLabel(NBAMenuPresentation.title(for: game) + (model.stale ? "，等待更新" : ""))
        }
    }
    private func logo(_ side: Competitor?) -> some View {
        NotchTeamLogo(side: side, size: 19)
            .padding(2).background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct NBANotchExpanded: View {
    @ObservedObject var model: NBANotchViewModel
    var body: some View {
        if let game = model.game {
            let presentation = NBANotchPresentation(game: game)
            VStack(spacing: 12) {
                HStack {
                    Text(model.momentTitle ?? "NBA · 固定比赛")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    if model.stale { Text("等待更新").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)) }
                }
                HStack(spacing: 12) {
                    team(presentation.teams.first)
                    VStack(spacing: 5) {
                        if let time = presentation.compactTime {
                            Text(time).font(.system(size: 25, weight: .semibold, design: .rounded))
                            Text("北京时间").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        } else {
                            Text("\(presentation.teams.first?.score ?? "—") : \(presentation.teams.dropFirst().first?.score ?? "—")")
                                .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity)
                    team(presentation.teams.dropFirst().first)
                }
                HStack {
                    Text(presentation.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer()
                    Button(action: model.openDetails) {
                        HStack(spacing: 4) { Text("查看比赛"); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).foregroundStyle(.white)
                }
            }.padding(5).frame(width: 350).foregroundStyle(.white)
        }
    }
    private func team(_ side: Competitor?) -> some View {
        VStack(spacing: 6) {
            NotchTeamLogo(side: side, size: 30)
                .padding(5).background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 9))
            Text(side.map { NBAMenuPresentation.teamName($0.team?.abbreviation, fallback: $0.team?.displayName ?? "球队") } ?? "球队待更新")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
        }.frame(width: 76)
    }
}

private struct NotchTeamLogo: View {
    let side: Competitor?
    let size: CGFloat
    var body: some View {
        Group {
            if let image = NBATeamLogo.normalizedImage(url: side?.team?.logo, teamID: side?.team?.id, abbreviation: side?.team?.abbreviation) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "basketball").resizable().scaledToFit().foregroundStyle(.orange) }
        }.frame(width: size, height: size)
    }
}
