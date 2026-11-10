import AppKit

/// Render a single non-template status image: native menu bar labels otherwise
/// collapse multiple SwiftUI images and can tint full-color team logos.
@MainActor
enum NBAMenuBarBadge {
    static func image(for game: Event) -> NSImage {
        let teams = nbaOrderedTeams(game.competitions.first?.competitors ?? [], side: { $0.homeAway }, id: { $0.team?.id ?? $0.id })
        let away = teams.first
        let home = teams.count > 1 ? teams[1] : nil
        let text: String
        if let special = NBAMenuPresentation.specialState(for: game) {
            text = special
        } else if game.status.type.state == "pre" {
            text = NBASchedulePolicy.startDate(game.date).map { NBASchedulePolicy.startTime($0) } ?? "待赛"
        } else {
            text = "\(away?.score ?? "—") – \(home?.score ?? "—")"
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 48, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            drawLogo(away?.team?.logo, in: NSRect(x: 0, y: 1, width: 18, height: 18))
            (text as NSString).draw(at: NSPoint(x: 24, y: floor((20 - textSize.height) / 2)), withAttributes: attributes)
            drawLogo(home?.team?.logo, in: NSRect(x: size.width - 18, y: 1, width: 18, height: 18))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = NBAMenuPresentation.title(for: game)
        return image
    }

    private static func drawLogo(_ url: String?, in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        if let logo = NBATeamLogo.normalizedImage(url: url) {
            let available = rect.insetBy(dx: 1, dy: 1)
            let scale = min(available.width / logo.size.width, available.height / logo.size.height)
            let size = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
            let target = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                width: size.width, height: size.height)
            logo.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSImage(systemSymbolName: "basketball", accessibilityDescription: nil)?.draw(in: rect)
        }
    }
}
