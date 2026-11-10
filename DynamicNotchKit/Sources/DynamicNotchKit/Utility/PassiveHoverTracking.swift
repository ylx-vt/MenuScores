// Local adaptation of the DynamicNotchKit input surface for passive panels.
import SwiftUI

/// SwiftUI's default tracking can depend on key-window state. This area remains
/// active without activating the application or intercepting button clicks.
struct PassiveHoverTracking: NSViewRepresentable {
    let update: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(update: update) }
    func updateNSView(_ view: TrackingView, context: Context) { view.update = update }
    final class TrackingView: NSView {
        var update: (Bool) -> Void
        private var area: NSTrackingArea?
        init(update: @escaping (Bool) -> Void) {
            self.update = update
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // inVisibleRect automatically follows geometry. Replacing an area
            // on every layout emits redundant enter/exit events under the cursor.
            guard area == nil else { return }
            let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(next); area = next
        }
        override func mouseEntered(with event: NSEvent) {
            update(true)
        }
        override func mouseExited(with event: NSEvent) { update(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
