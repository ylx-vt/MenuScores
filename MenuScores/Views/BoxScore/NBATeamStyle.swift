import SwiftUI

extension Color {
    static func nbaHex(_ hex: String?) -> Color {
        guard let hex, hex.count == 6, let number = UInt64(hex, radix: 16) else { return .purple }
        return Color(red: Double((number >> 16) & 255) / 255,
                     green: Double((number >> 8) & 255) / 255,
                     blue: Double(number & 255) / 255)
    }
}

struct NBATeamLogo: View {
    private static let logoCache = NSCache<NSString, NSImage>()
    static func normalizedImage(url: String?, teamID: String? = nil, abbreviation: String? = nil) -> NSImage? {
        let key = [url ?? "", teamID ?? "", abbreviation ?? ""].joined(separator: "|") as NSString
        if let cached = logoCache.object(forKey: key) { return cached }
        guard let image = bundledImage(url: url, teamID: teamID, abbreviation: abbreviation),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var minX = cg.width, minY = cg.height, maxX = 0, maxY = 0
        for y in stride(from: 0, to: cg.height, by: 2) {
            for x in stride(from: 0, to: cg.width, by: 2) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                width: min(cg.width - minX, maxX - minX + 2),
                height: min(cg.height - minY, maxY - minY + 2))) else { return image }
        let result = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        logoCache.setObject(result, forKey: key)
        return result
    }

    let url: String?
    var size: CGFloat = 36
    var teamID: String?
    var abbreviation: String?
    static func bundledImage(url: String?, teamID: String? = nil, abbreviation: String? = nil) -> NSImage? {
        let identities = ["13": "lal", "9": "gs"]
        let aliases = ["gsw": "gs", "nyk": "ny", "nop": "no", "sas": "sa", "uta": "utah", "was": "wsh", "pho": "phx"]
        let abbr = abbreviation?.lowercased()
        let filename = url.flatMap(URL.init(string:))?.deletingPathExtension().lastPathComponent.lowercased()
        let candidates = [identities[teamID ?? ""], abbr.map { aliases[$0] ?? $0 }, filename].compactMap { $0 }
        for candidate in candidates where candidate.range(of: "^[a-z]{2,5}$", options: .regularExpression) != nil {
            if let path = Bundle.main.url(forResource: "nba-" + candidate, withExtension: "png")
                ?? Bundle.main.url(forResource: "nba-" + candidate, withExtension: "png", subdirectory: "NBATeamLogos"),
               let image = NSImage(contentsOf: path) { return image }
        }
        return nil
    }
    var body: some View {
        Group {
            if let image = Self.bundledImage(url: url, teamID: teamID, abbreviation: abbreviation) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "basketball.fill").resizable().scaledToFit().foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .padding(6)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: size * 0.3))
        .accessibilityHidden(true)
    }
}

/// Use the same SwiftUI appearance for ink and an opaque surface. A status
/// window's vibrancy can otherwise leave light-mode text on a dark backdrop.
struct NBAPanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.985))
            .foregroundStyle(scheme == .dark ? Color(white: 0.92) : Color(white: 0.10))
    }
}

/// A quiet team-colored canvas shared by the game table and player detail.
struct NBAStatsSurface: ViewModifier {
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    scheme == .dark ? Color(white: 0.085) : Color.nbaHex("f1f2f7")
                    RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.17 : 0.085), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 370)
                    LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.025 : 0.35), .clear, tint.opacity(0.025)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .foregroundStyle(scheme == .dark ? Color(white: 0.93) : Color(white: 0.10))
    }
}

/// Static light stays inside the matchup identity area; the data canvas remains
/// neutral. Each appearance has its own opacity, without animated glow or blur.
struct NBAMatchIdentityLight: View {
    let colors: [Color]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(colors.prefix(2).enumerated()), id: \.offset) { index, color in
                    RadialGradient(colors: [color.opacity(scheme == .dark ? 0.14 : 0.085), .clear],
                        center: UnitPoint(x: index == 0 ? 0.24 : 0.76, y: 0.5),
                        startRadius: 0, endRadius: max(80, geometry.size.width * 0.3))
                }
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.035 : 0.5), .clear],
                    startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .top) {
                LinearGradient(colors: [.clear, .white.opacity(scheme == .dark ? 0.11 : 0.75), .clear],
                    startPoint: .leading, endPoint: .trailing).frame(height: 0.5).padding(.horizontal, 16)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct NBARefreshButton: View {
    let disabled: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)
            ).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).disabled(disabled).help(label).accessibilityLabel(label)
    }
}
