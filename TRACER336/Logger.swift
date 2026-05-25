// ─────────────────────────────────────────────────────────────────────────────
// Logger.swift — TRACER336
// ─────────────────────────────────────────────────────────────────────────────
//
// Centralized logging system for TRACER336. Every significant app event flows
// through here, making it easy to build a logs UI, export diagnostics, or
// hook into external logging frameworks.
//
// ARCHITECTURE:
//   - Singleton: `Log.shared` (or use the convenience `Log.info(...)` etc.)
//   - Thread-safe: all writes go through a serial dispatch queue.
//   - In-memory ring buffer: keeps the last `maxEntries` log entries (default 500).
//   - Console mirror: all entries also print to stdout for Xcode debugging.
//   - Observable: publishes changes via Combine so SwiftUI views can bind to it.
//
// CATEGORIES:
//   Each log entry has a `category` tag so the future logs UI can filter by
//   subsystem. Categories map to the major components of the app:
//     .audio      — Recording engine, chunk management, device selection
//     .export     — File export pipeline (M4A, WAV, composition, save panels)
//     .ui         — Drag gestures, overlay animations, icon state changes
//     .settings   — User preference changes, bookmark management
//     .notify     — Notification delivery and permission handling
//     .system     — App lifecycle, launch, quit, general diagnostics
//
// SEVERITY LEVELS:
//     .debug    — Verbose detail useful only during development
//     .info     — Normal operational events (started recording, exported file)
//     .warning  — Recoverable issues (fallback export preset, stale bookmark)
//     .error    — Failures that need attention (export failed, engine crash)
//
// USAGE:
//     Log.info("Recording started", category: .audio)
//     Log.error("Export failed: \(error)", category: .export)
//     Log.debug("Drag ratio: \(ratio)", category: .ui)
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Combine

// MARK: - Log Entry

/// A single log entry with timestamp, severity, category, and message.
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Log.Level
    let category: Log.Category
    let message: String
    
    /// Formatted timestamp for display (HH:mm:ss.SSS). Uses a single shared
    /// DateFormatter — allocating a fresh one per call costs ~100–500μs which
    /// is meaningful when rendering hundreds of log entries.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var formattedTime: String {
        LogEntry.timestampFormatter.string(from: timestamp)
    }
    
    /// Single-line display string for console and logs UI
    var displayString: String {
        return "\(formattedTime) [\(level.symbol)] [\(category.rawValue)] \(message)"
    }
}

// MARK: - Logger

/// Centralized logger for TRACER336. Access via `Log.shared` or static convenience methods.
///
/// The logger stores entries in an in-memory ring buffer (for the live Logs
/// window) AND appends every entry to a plain-text log file on disk (for
/// post-crash forensics and bug reports). All writes — to memory and to disk
/// — are serialized on a background queue for thread safety.
///
/// On-disk path (sandboxed):
///   ~/Library/Containers/com.tracer336.app/Data/Library/Logs/TRACER336/tracer336.log
/// Public via `Log.shared.logFileURL`. Rotated to `tracer336.old.log` when it
/// exceeds 5 MB; ~10 MB of history is preserved across rotations.
class Log: ObservableObject {
    
    // MARK: Severity Levels
    
    enum Level: Int, Comparable, CaseIterable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        
        /// Emoji symbol for console output and logs UI
        var symbol: String {
            switch self {
            case .debug:   return "🔍"
            case .info:    return "ℹ️"
            case .warning: return "⚠️"
            case .error:   return "❌"
            }
        }
        
        var label: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .warning: return "WARNING"
            case .error:   return "ERROR"
            }
        }
        
        static func < (lhs: Level, rhs: Level) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    
    // MARK: Categories
    
    /// Log categories map to app subsystems. Extend this to add custom categories.
    struct Category: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        
        static let audio    = Category(rawValue: "audio")
        static let export   = Category(rawValue: "export")
        static let ui       = Category(rawValue: "ui")
        static let settings = Category(rawValue: "settings")
        static let notify   = Category(rawValue: "notify")
        static let system   = Category(rawValue: "system")
    }
    
    // MARK: Singleton
    
    static let shared = Log()
    
    // MARK: Configuration
    
    /// Maximum number of entries to keep in memory. Oldest entries are dropped first.
    var maxEntries: Int = 500
    
    /// Minimum severity level to record. Entries below this level are discarded.
    /// Debug builds default to `.debug` for verbose diagnostics during dev.
    /// Release builds default to `.info` so the ring buffer isn't filled with
    /// internal trace noise that ships to end users.
    #if DEBUG
    var minimumLevel: Level = .debug
    #else
    var minimumLevel: Level = .info
    #endif
    
    // MARK: Storage
    
    /// The in-memory log buffer. Published so SwiftUI views can observe changes.
    @Published private(set) var entries: [LogEntry] = []
    
    /// True when an .error-level log has been recorded that the user hasn't seen yet.
    /// Flips true on any .error log, flips false when the logs window is opened.
    /// Observed by AppDelegate to show the pulsing red dot in the popover.
    @Published private(set) var hasUnresolvedErrors = false
    
    /// Serial queue for thread-safe writes. All file I/O happens here too so
    /// writes are naturally ordered without extra locking.
    private let queue = DispatchQueue(label: "com.tracer336.logger", qos: .utility)

    // ── Persistent file logging ────────────────────────────────────────────
    //
    // In addition to the in-memory ring buffer, every log entry is appended to
    // a plain-text file so logs survive crashes and app restarts. For sandboxed
    // builds the file lives inside the app container:
    //   ~/Library/Containers/com.tracer336.app/Data/Library/Logs/TRACER336/tracer336.log
    // The previous log (after rotation) is preserved as tracer336.old.log so
    // the most recent ~10 MB of history is always retrievable.

    /// Public so other code (e.g. a future "Show Log File" button) can find it.
    let logFileURL: URL

    /// Open file handle for appending. Kept open for the app's lifetime to
    /// avoid open/close churn on every log entry.
    private var fileHandle: FileHandle?

    /// Rotate the active log file when it reaches this size.
    private let rotationThreshold: UInt64 = 5 * 1024 * 1024  // 5 MB

    private init() {
        // ~/Library/Logs/TRACER336/ inside the sandbox container.
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("TRACER336", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        self.logFileURL = logsDir.appendingPathComponent("tracer336.log")

        // Rotate at startup if the existing file is too large. We keep one
        // generation of history as tracer336.old.log; older logs are discarded.
        if let size = try? FileManager.default
            .attributesOfItem(atPath: logFileURL.path)[.size] as? UInt64,
           size > rotationThreshold {
            let oldURL = logsDir.appendingPathComponent("tracer336.old.log")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.moveItem(at: logFileURL, to: oldURL)
        }

        // Create the file if missing, then open for appending.
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            self.fileHandle = handle
        }
    }
    
    // MARK: Core Write
    
    /// Append a log entry. Thread-safe — can be called from any queue.
    func log(_ message: String, level: Level, category: Category) {
        guard level >= minimumLevel else { return }
        
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        
        // Print to console immediately (for Xcode). Debug builds only — release
        // builds keep entries in the in-memory buffer without spamming stdout.
        #if DEBUG
        print(entry.displayString)
        #endif
        
        // Append to buffer on the serial queue, then publish on main. Same
        // queue also handles the file write so writes are naturally ordered
        // and never contend with each other.
        queue.async { [weak self] in
            guard let self = self else { return }

            // Persist to disk so logs survive crashes / restarts.
            if let handle = self.fileHandle,
               let data = (entry.displayString + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }

            var updated = self.entries
            updated.append(entry)
            
            // Trim if over capacity
            if updated.count > self.maxEntries {
                updated.removeFirst(updated.count - self.maxEntries)
            }
            
            DispatchQueue.main.async {
                self.entries = updated
                // Flag unresolved errors so the UI can show an alert indicator
                if level == .error {
                    self.hasUnresolvedErrors = true
                }
            }
        }
    }
    
    /// Synchronously flush all queued writes to disk and fsync the file. Call
    /// before the process is about to die (uncaught exception handler) so the
    /// last few log lines actually make it into the persistent log file.
    func flushToDisk() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    /// Remove all log entries. Useful for a "Clear Logs" button in the UI.
    func clear() {
        queue.async { [weak self] in
            DispatchQueue.main.async {
                self?.entries = []
                self?.hasUnresolvedErrors = false
            }
        }
    }
    
    /// Mark all current errors as "seen". Called when the logs window is opened.
    /// Clears the red dot indicator without removing any log entries.
    func acknowledgeErrors() {
        hasUnresolvedErrors = false
    }
    
    /// Export all entries as a plain-text string for copying to clipboard or saving.
    func exportAsText() -> String {
        return entries.map { $0.displayString }.joined(separator: "\n")
    }
    
    // MARK: Convenience — Static Methods
    //
    // These are the primary API. Use these instead of `Log.shared.log(...)`.
    
    static func debug(_ message: String, category: Category) {
        shared.log(message, level: .debug, category: category)
    }
    
    static func info(_ message: String, category: Category) {
        shared.log(message, level: .info, category: category)
    }
    
    static func warning(_ message: String, category: Category) {
        shared.log(message, level: .warning, category: category)
    }
    
    static func error(_ message: String, category: Category) {
        shared.log(message, level: .error, category: category)
    }
}
