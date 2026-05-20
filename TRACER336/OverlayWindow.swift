// ─────────────────────────────────────────────────────────────────────────────
// OverlayWindow.swift — Full-Screen Transparent Drawing Surface
// ─────────────────────────────────────────────────────────────────────────────
//
// A borderless, transparent NSWindow that covers an entire screen. Used as the
// drawing surface for the drag-to-export visual feedback (line, dot, label).
//
// The window is:
//   - Fully transparent (no background)
//   - Ignores mouse events (passthrough to the underlying desktop)
//   - At the .statusBar level (above normal windows, below sheets/alerts)
//   - Active across all spaces and full-screen apps
//
// A new OverlayWindow is created at the start of each drag gesture and
// destroyed when the drag ends (or the reel-back animation completes).
//
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

class OverlayWindow: NSWindow {
    
    init(for screen: NSScreen) {
        let screenFrame = screen.frame
        
        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.contentView = OverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
    }
}
