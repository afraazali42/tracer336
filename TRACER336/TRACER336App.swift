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
        .commands {
            // SwiftUI auto-generates a full standard menu bar (App menu with
            // About/Settings/Services/Hide/Quit, plus View/Window/Help) for any
            // App that declares a Scene. That conflicts with the custom single-
            // menu design we build in AppDelegate.setupMainMenu(). Clear the
            // default command groups so SwiftUI contributes nothing. (@CommandsBuilder
            // supports max 10 items, so only the groups actually contributing
            // menus are listed.)
            CommandGroup(replacing: .appInfo)           { }
            CommandGroup(replacing: .appSettings)       { }
            CommandGroup(replacing: .systemServices)    { }
            CommandGroup(replacing: .appVisibility)     { }
            CommandGroup(replacing: .windowList)        { }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .toolbar)           { }
            CommandGroup(replacing: .sidebar)           { }
            CommandGroup(replacing: .help)              { }
            CommandGroup(replacing: .undoRedo)          { }
        }
    }
}
