// ─────────────────────────────────────────────────────────────────────────────
// HotkeyManager.swift — Global Keyboard Shortcut for Quick Save
// ─────────────────────────────────────────────────────────────────────────────
//
// Manages a user-configurable global keyboard shortcut that triggers Quick Save
// from anywhere in macOS — even when another app is focused.
//
// ARCHITECTURE:
//   Uses NSEvent.addGlobalMonitorForEvents to listen for key-down events
//   system-wide. This works in the sandbox without Accessibility permissions.
//   The monitor only fires when the app is NOT focused (global events).
//   A separate local monitor catches the hotkey when the app IS focused.
//
// STORAGE:
//   The hotkey is stored as two values in AppSettings:
//     - hotkeyKeyCode (UInt16) — the physical key (e.g. 1 = "S")
//     - hotkeyModifiers (UInt) — modifier flags (⌘, ⇧, ⌥, ⌃)
//   A keyCode of 0xFFFF means "no hotkey set".
//
// FOR PLUGIN DEVELOPERS:
//   - Call HotkeyManager.shared.register() to activate the current hotkey
//   - Call HotkeyManager.shared.unregister() to deactivate
//   - Set `onHotkeyPressed` to handle the shortcut action
//   - The hotkey display string is available via displayString(keyCode:modifiers:)
//
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

class HotkeyManager {
    
    static let shared = HotkeyManager()
    
    /// Called when the global hotkey is pressed. Set by AppDelegate.
    var onHotkeyPressed: (() -> Void)?
    
    /// The currently active global event monitor (when app is NOT focused).
    private var globalMonitor: Any?
    
    /// The currently active local event monitor (when app IS focused).
    private var localMonitor: Any?
    
    private init() {}
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Registration
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Start listening for the configured hotkey. Call on app launch and
    /// whenever the hotkey setting changes.
    func register() {
        // Always unregister first to avoid duplicate monitors
        unregister()
        
        let keyCode = AppSettings.hotkeyKeyCode
        let modifiers = AppSettings.hotkeyModifiers
        
        // 0xFFFF means no hotkey is set
        guard keyCode != 0xFFFF else { return }
        
        // Convert stored UInt to NSEvent.ModifierFlags for comparison.
        // Mask to only the modifier keys we care about (⌘⇧⌥⌃).
        let requiredModifiers = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .shift, .option, .control])
        
        // Global monitor — fires when another app has focus
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == keyCode && eventModifiers == requiredModifiers {
                DispatchQueue.main.async {
                    self?.onHotkeyPressed?()
                }
            }
        }
        
        // Local monitor — fires when our app has focus
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == keyCode && eventModifiers == requiredModifiers {
                DispatchQueue.main.async {
                    self?.onHotkeyPressed?()
                }
                return nil  // Consume the event
            }
            return event  // Pass through other events
        }
        
        let display = HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
        Log.info("Global hotkey registered: \(display)", category: .system)
    }
    
    /// Stop listening for the hotkey.
    func unregister() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Display Helpers
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Convert a keyCode + modifiers into a human-readable string like "⌘⇧S".
    static func displayString(keyCode: UInt16, modifiers: UInt) -> String {
        if keyCode == 0xFFFF { return "" }
        
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        
        // Map common key codes to readable names
        let keyName: String
        switch keyCode {
        case 0:   keyName = "A"
        case 1:   keyName = "S"
        case 2:   keyName = "D"
        case 3:   keyName = "F"
        case 4:   keyName = "H"
        case 5:   keyName = "G"
        case 6:   keyName = "Z"
        case 7:   keyName = "X"
        case 8:   keyName = "C"
        case 9:   keyName = "V"
        case 11:  keyName = "B"
        case 12:  keyName = "Q"
        case 13:  keyName = "W"
        case 14:  keyName = "E"
        case 15:  keyName = "R"
        case 16:  keyName = "Y"
        case 17:  keyName = "T"
        case 18:  keyName = "1"
        case 19:  keyName = "2"
        case 20:  keyName = "3"
        case 21:  keyName = "4"
        case 22:  keyName = "6"
        case 23:  keyName = "5"
        case 24:  keyName = "="
        case 25:  keyName = "9"
        case 26:  keyName = "7"
        case 27:  keyName = "-"
        case 28:  keyName = "8"
        case 29:  keyName = "0"
        case 30:  keyName = "]"
        case 31:  keyName = "O"
        case 32:  keyName = "U"
        case 33:  keyName = "["
        case 34:  keyName = "I"
        case 35:  keyName = "P"
        case 36:  keyName = "↩"
        case 37:  keyName = "L"
        case 38:  keyName = "J"
        case 39:  keyName = "'"
        case 40:  keyName = "K"
        case 41:  keyName = ";"
        case 42:  keyName = "\\"
        case 43:  keyName = ","
        case 44:  keyName = "/"
        case 45:  keyName = "N"
        case 46:  keyName = "M"
        case 47:  keyName = "."
        case 48:  keyName = "⇥"
        case 49:  keyName = "Space"
        case 51:  keyName = "⌫"
        case 53:  keyName = "⎋"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 99:  keyName = "F3"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 103: keyName = "F11"
        case 105: keyName = "F13"
        case 107: keyName = "F14"
        case 109: keyName = "F10"
        case 111: keyName = "F12"
        case 113: keyName = "F15"
        case 118: keyName = "F4"
        case 120: keyName = "F2"
        case 122: keyName = "F1"
        case 123: keyName = "←"
        case 124: keyName = "→"
        case 125: keyName = "↓"
        case 126: keyName = "↑"
        default:  keyName = "Key\(keyCode)"
        }
        
        parts.append(keyName)
        return parts.joined()
    }
}
