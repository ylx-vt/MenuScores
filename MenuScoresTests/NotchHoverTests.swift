import AppKit
import SwiftUI
import Testing
@testable import DynamicNotchKit

@MainActor
struct NotchHoverTests {
    private func surface() -> DynamicNotch<Text, Text, Text> {
        let surface = DynamicNotch(hoverBehavior: [.keepVisible], style: .notch, observeScreens: false) {
            Text("expanded")
        } compactLeading: { Text("away") } compactTrailing: { Text("home") }
        surface.orderWindowFront = { _ in } // No test window is actually shown.
        surface.transitionConfiguration = .init(skipIntermediateHides: true)
        return surface
    }

    @Test func duplicateEnterDoesNotCancelPendingExpansion() async throws {
        let screen = try #require(NSScreen.screens.first)
        let surface = surface()
        defer { surface.dispose() }
        await surface.compact(on: screen)
        surface.updateHoverState(true)
        surface.updateHoverState(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(surface.isHovering)
        #expect(surface.state == .expanded)
        #expect(surface.windowController?.window?.isVisible == false)
    }

    @Test func duplicateExitDoesNotCancelPendingCollapse() async throws {
        let screen = try #require(NSScreen.screens.first)
        let surface = surface()
        defer { surface.dispose() }
        await surface.expand(on: screen)
        surface.updateHoverState(true)
        surface.updateHoverState(false)
        surface.updateHoverState(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!surface.isHovering)
        #expect(surface.state == .compact)
    }

    @Test func layoutUpdatesKeepOneStableTrackingArea() throws {
        let view = PassiveHoverTracking.TrackingView(update: { _ in })
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        view.updateTrackingAreas()
        let first = try #require(view.trackingAreas.first)
        view.frame.size.height = 180
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        #expect(view.trackingAreas.first === first)
    }

    @Test func leavingBeforeHoverDelayCancelsExpansion() async throws {
        let screen = try #require(NSScreen.screens.first)
        let surface = surface()
        defer { surface.dispose() }
        await surface.compact(on: screen)
        surface.updateHoverState(true)
        try await Task.sleep(for: .milliseconds(40))
        surface.updateHoverState(false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!surface.isHovering)
        #expect(surface.state == .compact)
    }
}
