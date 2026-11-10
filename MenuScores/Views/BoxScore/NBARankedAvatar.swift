import SwiftUI

struct NBARankedAvatar: View {
    let url: String?
    let tint: Color
    let tier: NBAPlayerProfile.RankTier?
    var size: CGFloat = 24

    var body: some View {
        let style = NBARankCardStyle(tier: tier)
        let color = tier == nil ? Color.secondary.opacity(0.25) : style.color
        let premium = tier == .red || tier == .gold || tier == .purple
        NBACachedAvatar(url: url, tint: tint)
            .scaleEffect(size / 24).frame(width: size, height: size)
            .overlay {
                Circle().stroke(LinearGradient(colors: [color, color.opacity(0.65), color],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: tier == nil ? 1 : 2,
                                                   dash: tier == nil ? [2, 2] : []))
                    .padding(-1.5)
            }
            .overlay {
                Circle().stroke(.white.opacity(premium ? 0.4 : 0.15), lineWidth: 0.5).padding(0.5)
            }
            .shadow(color: color.opacity(premium ? 0.2 : 0.07), radius: premium ? 2 : 1)
    }
}
