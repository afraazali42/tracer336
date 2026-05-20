// ─────────────────────────────────────────────────────────────────────────────
// TRACER336App.swift — App Entry Point
// ─────────────────────────────────────────────────────────────────────────────
//
// This is the SwiftUI app lifecycle entry point. TRACER336 is a menu bar app,
// so there is no main window — the UI lives entirely in the status bar icon,
// its popover menu, and the settings window.
//
// The `@NSApplicationDelegateAdaptor` bridges to AppDelegate.swift, which handles
// all AppKit-level work (status bar item, drag gestures, overlay windows) that
// SwiftUI can't manage natively.
//
// The `Settings` scene provides the standard ⌘, shortcut and makes SettingsView
// accessible from the system menu when the app is activated.
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import AppKit

@main
struct TRACER336App: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView(recorder: appDelegate.recorder, onOpenLogs: {
                self.appDelegate.openLogs()
            })
        }
    }
}
