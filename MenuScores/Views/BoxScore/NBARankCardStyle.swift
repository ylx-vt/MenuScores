import SwiftUI

/// Jewel colors with restrained gloss and glow.
struct NBARankCardStyle {
    let tier: NBAPlayerProfile.RankTier?
    var decorated: Bool { tier != nil && tier != .gray }
    var color: Color {
        switch tier {
        case .red: return Color(red: 1, green: 0.36, blue: 0.46)
        case .gold: return Color(red: 1, green: 0.76, blue: 0.22)
        case .purple: return Color(red: 0.76, green: 0.48, blue: 1)
        case .blue: return Color(red: 0.36, green: 0.70, blue: 1)
        case .green: return Color(red: 0.27, green: 0.83, blue: 0.59)
        default: return .secondary
        }
    }
    var colors: [Color] {
        switch tier {
        case .red: return [.nbaHex("79152e"), .nbaHex("a72343"), .nbaHex("611128")]
        case .gold: return [.nbaHex("fff0a3"), .nbaHex("f2bd45"), .nbaHex("d98d19")]
        case .purple: return [.nbaHex("431778"), .nbaHex("652b9c"), .nbaHex("34105f")]
        case .blue: return [.nbaHex("123e77"), .nbaHex("205789"), .nbaHex("102f5b")]
        case .green: return [.nbaHex("104c39"), .nbaHex("226447"), .nbaHex("123e30")]
        default: return [.primary.opacity(0.035), .primary.opacity(0.035)]
        }
    }
    var ink: AnyShapeStyle {
        if decorated {
            return AnyShapeStyle(LinearGradient(colors: tier == .gold
                ? [.nbaHex("392006"), .nbaHex("633603"), .nbaHex("351c02")]
                : [.white, color.opacity(0.95)], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(Color.primary)
    }
    var secondaryInk: Color {
        if tier == .gold { return .nbaHex("533007") }
        return decorated ? .white.opacity(0.85) : .secondary
    }

    func surface(cornerRadius: CGFloat = 8, compact: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if decorated {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(stops: [.init(color: .white.opacity(compact ? 0.03 : 0.08), location: 0),
                                                     .init(color: .white.opacity(0.02), location: 0.42),
                                                     .init(color: .clear, location: 0.5),
                                                     .init(color: color.opacity(0.15), location: 1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(LinearGradient(colors: decorated ? [color.opacity(compact ? 0.28 : 0.52), .white.opacity(0.15), color.opacity(0.28)] : [.secondary.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: compact ? 0.5 : 0.7)
            }
            .shadow(color: decorated ? color.opacity(compact ? 0 : 0.07) : .clear, radius: 2, y: 1)
    }
}
