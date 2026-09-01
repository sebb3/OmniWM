// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa

@MainActor
final class QuakeTerminalFocusBorderWindow: NSPanel {
    static let borderWidth: CGFloat = 3

    convenience init() {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let border = NSView(frame: .zero)
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.borderWidth = Self.borderWidth
        border.layer?.borderColor = NSColor.systemYellow.cgColor
        border.layer?.cornerRadius = 9 + Self.borderWidth
        contentView = border
    }

    static func frame(around frame: CGRect) -> CGRect {
        frame.insetBy(dx: -borderWidth, dy: -borderWidth)
    }

    func show(around target: NSWindow) {
        setFrame(Self.frame(around: target.frame), display: true)
        level = target.level
        if parent !== target {
            parent?.removeChildWindow(self)
            target.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

final class QuakeTerminalWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    var initialFrame: NSRect?
    var isAnimating: Bool = false

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        setup()
    }

    private func setup() {
        identifier = NSUserInterfaceItemIdentifier(rawValue: "com.omniwm.quakeTerminal")
        setAccessibilitySubrole(.floatingWindow)
        styleMask.remove(.titled)
        styleMask.insert(.nonactivatingPanel)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if isAnimating {
            super.setFrame(initialFrame ?? frameRect, display: flag)
        } else {
            super.setFrame(frameRect, display: flag)
        }
    }

}
