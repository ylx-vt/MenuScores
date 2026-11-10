//
// DynamicNotchPanel.swift
// DynamicNotchKit
//
// Created by <Huy D.> on 2024-11-01.
//

import AppKit

final class DynamicNotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    // This surface intentionally straddles the hardware camera area. AppKit's
    // default floating-panel constraint moves it below the menu bar when shown.
    // The controller supplies a validated target-screen frame; keep that frame
    // without inheriting floating-window menu avoidance or activating the app.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func configureForHardwareNotch(_ anchored: Bool) {
        // The notch occupies the menu-bar band. Use its standard UI layer,
        // never the upstream screenSaver layer; external floating cards stay low.
        level = anchored ? .statusBar : .floating
    }

    override var canBecomeKey: Bool {
        false
    }
}
