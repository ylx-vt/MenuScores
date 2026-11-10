import AppKit
import Testing
@testable import DynamicNotchKit

@MainActor
struct NotchWindowPositionTests {
    @Test func floatingPanelKeepsScreenTopInsteadOfMenuBarBottom() throws {
        let screen = try #require(NSScreen.screens.first)
        let requested = NSRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 100,
                               width: 200, height: 100)
        let panel = DynamicNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        defer { panel.close() }
        panel.alphaValue = 0 // Exercise real ordering without showing test UI.
        panel.setFrame(requested, display: false)
        #expect(panel.constrainFrameRect(requested, to: screen) == requested)
        panel.orderFront(nil)
        #expect(panel.frame == requested)
        #expect(panel.frame.maxY == screen.frame.maxY)
        #expect(panel.level == .floating)
        #expect(!panel.canBecomeKey)
    }

    @Test func onlyHardwareNotchAnchorUsesMenuBarLayerWithoutTakingFocus() {
        let panel = DynamicNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        defer { panel.close() }
        panel.configureForHardwareNotch(true)
        #expect(panel.level == .statusBar)
        #expect(panel.level != .screenSaver)
        #expect(!panel.canBecomeKey)
        panel.configureForHardwareNotch(false)
        #expect(panel.level == .floating)
    }

    @Test func negativeAndUpperDisplayCoordinatesAreNotRebasedToMainScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let panel = DynamicNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        defer { panel.close() }
        for requested in [NSRect(x: -700, y: 1800, width: 720, height: 466),
                          NSRect(x: 320, y: -1200, width: 720, height: 466)] {
            #expect(panel.constrainFrameRect(requested, to: screen) == requested)
            #expect(panel.constrainFrameRect(requested, to: nil) == requested)
        }
    }
}
