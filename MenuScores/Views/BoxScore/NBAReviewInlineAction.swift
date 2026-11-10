import SwiftUI

/// The two adjacent first-screen destinations share text metrics, icon space
/// and hit height. Their intrinsic width may grow with the conversation count.
struct NBAReviewInlineAction: View {
    let title: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .regular)).frame(width: 8)
                Text(title).font(.system(size: 13, weight: .regular)).monospacedDigit()
                    .background {
                        #if DEBUG
                        NBAReviewActionProbe(identifier: identifier + "-text").allowsHitTesting(false)
                        #endif
                    }
            }.frame(height: 24).contentShape(Rectangle())
                .background {
                    #if DEBUG
                    NBAReviewActionProbe(identifier: identifier).allowsHitTesting(false)
                    #endif
                }
        }.buttonStyle(.plain).foregroundStyle(.blue).fixedSize()
            .accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}

#if DEBUG
private struct NBAReviewActionProbe: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = .init(identifier); return view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
