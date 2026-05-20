// ─────────────────────────────────────────────────────────────────────────────
// AppSettings.swift — Persistent User Preferences
// ─────────────────────────────────────────────────────────────────────────────
//
// All user-facing settings are stored in a dedicated UserDefaults suite
// ("com.tracer336.settings") rather than the standard suite. This means
// preferences survive app rebuilds and bundle ID changes during development.
//
// Stored at: ~/Library/Preferences/com.tracer336.settings.plist
//
// ARCHITECTURE:
//   - Static keys: String constants for each preference, used by both SwiftUI
//     (@AppStorage) and imperative code.
//   - Static accessors: Computed properties that return the current value with
//     sensible defaults. Use these in non-SwiftUI code (AudioRecorder, etc.).
//   - Security-scoped bookmarks: The sandbox requires bookmarks to remember
//     user-chosen folders across launches. See setSaveFolderWithBookmark() and
//     resolveSaveFolderBookmark() for the full flow.
//
// FOR PLUGIN DEVELOPERS:
//   To add a new setting:
//   1. Add a static key: `static let mySettingKey = "mySetting"`
//   2. Add a static accessor with a default value
//   3. Use @AppStorage(AppSettings.mySettingKey, store: AppSettings.store)
//      in SwiftUI views for two-way binding
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

enum AppSettings {
    static let suiteName = "com.tracer336.settings"
    static let store = UserDefaults(suiteName: suiteName)!
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Keys
    // ─────────────────────────────────────────────────────────────────────────
    // Each key corresponds to a single persisted preference. Keep alphabetical.
    
    static let alwaysAskSaveKey       = "alwaysAskSave"
    static let bitRateKey             = "bitRate"
    static let clearBufferOnSaveKey   = "clearBufferOnSave"
    static let exportFormatKey        = "exportFormat"
    static let inputDeviceIDKey       = "inputDeviceID"
    static let inputDeviceNameKey     = "inputDeviceName"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let soundEnabledKey         = "soundEnabled"
    static let retentionHoursKey      = "retentionHours"
    static let saveFolderBookmarkKey  = "saveFolderBookmark"
    static let saveFolderKey          = "saveFolder"
    static let hotkeyKeyCodeKey        = "hotkeyKeyCode"
    static let hotkeyModifiersKey      = "hotkeyModifiers"
    static let startAtLoginKey        = "startAtLogin"
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Defaults
    // ─────────────────────────────────────────────────────────────────────────
    
    static let defaultRetentionHours = 1
    static let defaultBitRate = 32000  // 32 kbps AAC — good balance of size vs clarity
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Accessors
    // ─────────────────────────────────────────────────────────────────────────
    // Use these in non-SwiftUI code. Each returns the stored value or a default.
    
    /// How many hours of audio to keep in the circular buffer (1–24).
    static var retentionHours: Int {
        let val = store.integer(forKey: retentionHoursKey)
        return val > 0 ? val : defaultRetentionHours
    }
    
    /// AAC encoder bitrate in bits/sec. Options: 24000, 32000, 48000, 64000.
    static var bitRate: Int {
        let val = store.integer(forKey: bitRateKey)
        return val > 0 ? val : defaultBitRate
    }
    
    /// CoreAudio device ID for the selected input. 0 = system default.
    static var inputDeviceID: Int {
        return store.integer(forKey: inputDeviceIDKey)
    }
    
    /// Human-readable name of the selected input device. Used as a fallback
    /// to re-identify the device when CoreAudio assigns a new numeric ID
    /// (which happens across reboots and rebuilds).
    static var inputDeviceName: String? {
        return store.string(forKey: inputDeviceNameKey)
    }
    
    /// Export file format: "m4a" (default, compressed) or "wav" (uncompressed PCM).
    static var exportFormat: String {
        return store.string(forKey: exportFormatKey) ?? "m4a"
    }
    
    /// Path to the default save folder. Falls back to ~/Desktop.
    static var saveFolder: String {
        return store.string(forKey: saveFolderKey) ?? NSHomeDirectory() + "/Desktop"
    }
    
    /// When true, show an NSSavePanel for every export. When false, auto-save
    /// to the bookmarked folder. Defaults to true for new users.
    static var alwaysAskSave: Bool {
        if store.object(forKey: alwaysAskSaveKey) == nil { return true }
        return store.bool(forKey: alwaysAskSaveKey)
    }
    
    /// When true, show macOS notifications on successful export. Defaults to false.
    static var notificationsEnabled: Bool {
        return store.bool(forKey: notificationsEnabledKey)
    }
    
    /// When true, play the success sound effect on export. Defaults to true.
    static var soundEnabled: Bool {
        if store.object(forKey: soundEnabledKey) == nil { return true }
        return store.bool(forKey: soundEnabledKey)
    }
    
    /// The keyCode for the global Quick Save hotkey. 0xFFFF = not set.
    static var hotkeyKeyCode: UInt16 {
        let val = store.object(forKey: hotkeyKeyCodeKey) as? Int ?? 0xFFFF
        return UInt16(val)
    }
    
    /// The modifier flags for the global Quick Save hotkey.
    static var hotkeyModifiers: UInt {
        return UInt(store.integer(forKey: hotkeyModifiersKey))
    }
    
    /// When true (default), wipe the audio buffer after each successful export.
    /// When false, audio is kept and can be re-exported (overlapping captures).
    static var clearBufferOnSave: Bool {
        if store.object(forKey: clearBufferOnSaveKey) == nil { return true }
        return store.bool(forKey: clearBufferOnSaveKey)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Security-Scoped Bookmarks
    // ─────────────────────────────────────────────────────────────────────────
    //
    // macOS sandbox prevents file access outside the app container unless the
    // user explicitly grants permission via an open/save panel. Security-scoped
    // bookmarks persist that permission across app launches.
    //
    // Flow:
    //   1. User picks a folder via NSOpenPanel → we get a URL with temporary access
    //   2. setSaveFolderWithBookmark() serializes it into bookmark data (Data blob)
    //   3. On next launch, resolveSaveFolderBookmark() deserializes it and calls
    //      startAccessingSecurityScopedResource() to re-activate sandbox access
    //   4. Caller MUST call url.stopAccessingSecurityScopedResource() when done
    //
    // If the bookmark becomes stale (e.g. folder was moved), it's automatically
    // refreshed on resolve.
    
    /// Create and store a security-scoped bookmark for the given folder URL.
    static func setSaveFolderWithBookmark(_ url: URL) {
        store.set(url.path, forKey: saveFolderKey)
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            store.set(bookmarkData, forKey: saveFolderBookmarkKey)
        } catch {
            Log.warning("Failed to create bookmark for \(url.path): \(error)", category: .settings)
        }
    }
    
    /// Resolve the stored bookmark and activate sandbox access to the save folder.
    ///
    /// - Returns: The folder URL with security scope started, or nil if unavailable.
    /// - Important: The caller **must** call `url.stopAccessingSecurityScopedResource()`
    ///   when file operations are complete.
    static func resolveSaveFolderBookmark() -> URL? {
        guard let bookmarkData = store.data(forKey: saveFolderBookmarkKey) else {
            return nil
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                Log.info("Bookmark was stale — refreshing", category: .settings)
                setSaveFolderWithBookmark(url)
            }
            
            if url.startAccessingSecurityScopedResource() {
                return url
            }
        } catch {
            Log.warning("Failed to resolve save folder bookmark: \(error)", category: .settings)
        }
        
        return nil
    }
}
