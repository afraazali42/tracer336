// ─────────────────────────────────────────────────────────────────────────────
// LogsView.swift — Developer Logs Window
// ─────────────────────────────────────────────────────────────────────────────
//
// Displays a real-time, scrolling log of all app events. Uses NSTextView
// (wrapped for SwiftUI) so text is fully selectable and copyable — essential
// for developers diagnosing issues or filing bug reports.
//
// FEATURES:
//   - Color-coded entries: red (error), orange (warning), white (info), grey (debug)
//   - Auto-scrolls to the bottom as new entries arrive
//   - "Copy All" button exports the entire log to the clipboard
//   - "Clear" button wipes the log buffer
//   - Opening the window clears the "unresolved errors" flag (dismisses red dots)
//
// FOR PLUGIN DEVELOPERS:
//   The LogsView observes Log.shared.$entries via Combine. If you add custom
//   log categories, they'll appear here automatically with no changes needed.
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import AppKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LogsView (SwiftUI Container)
// ─────────────────────────────────────────────────────────────────────────────

struct LogsView: View {
    @ObservedObject private var logger = Log.shared
    
    var body: some View {
        VStack(spacing: 0) {
            
            // ── Toolbar ─────────────────────────────────────────────────
            HStack {
                Text("\(logger.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Copy All") {
                    let text = logger.exportAsText()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Clear") {
                    logger.clear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // ── Log Content (selectable NSTextView) ─────────────────────
            LogTextView(entries: logger.entries)
                .frame(minWidth: 500, minHeight: 300)
        }
        .onAppear {
            // Acknowledge errors when the user opens the logs window
            Log.shared.acknowledgeErrors()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LogTextView (NSViewRepresentable wrapping NSTextView)
// ─────────────────────────────────────────────────────────────────────────────
//
// NSTextView gives us native text selection (⌘A, ⌘C, right-click → Copy)
// which SwiftUI's Text and List don't support. Each log entry is rendered
// as an attributed string with color based on severity level.

struct LogTextView: NSViewRepresentable {
    let entries: [LogEntry]
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true         // Full text selection support
        textView.isRichText = true
        textView.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        
        // Use a monospaced font for log readability
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        
        scrollView.documentView = textView
        
        // Store reference for updates
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateContent(entries: entries)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // ── Coordinator ─────────────────────────────────────────────────────
    
    class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        /// UUID of the most recently rendered log entry. Used as an anchor for
        /// incremental updates — on each refresh we find this id in the new
        /// entries array and only render anything after it.
        private var lastRenderedId: UUID?

        /// Append only the entries newer than `lastRenderedId`, or do a full
        /// rebuild if the previous anchor is missing (Clear pressed, or buffer
        /// rotation evicted it). Avoids re-rendering hundreds of entries when a
        /// single new one arrives.
        func updateContent(entries: [LogEntry]) {
            guard let textView = textView, let storage = textView.textStorage else { return }

            // Clear case: empty entries, wipe the view.
            guard !entries.isEmpty else {
                if storage.length > 0 {
                    storage.setAttributedString(NSAttributedString())
                }
                lastRenderedId = nil
                return
            }

            // Find where to start appending.
            let startIndex: Int
            if let anchorId = lastRenderedId,
               let anchorIdx = entries.lastIndex(where: { $0.id == anchorId }) {
                startIndex = anchorIdx + 1
            } else {
                // First render OR anchor was evicted/cleared — full rebuild.
                if storage.length > 0 {
                    storage.setAttributedString(NSAttributedString())
                }
                startIndex = 0
            }

            // Nothing new to append.
            if startIndex >= entries.count { return }

            let appended = Self.buildAttributedString(for: entries[startIndex..<entries.count],
                                                      precededByExisting: storage.length > 0)
            storage.append(appended)
            lastRenderedId = entries.last?.id

            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }

        /// Build attributed string for a slice of entries. Static so the lazy
        /// monospaced font + paragraph style allocations can be shared.
        private static func buildAttributedString(for entries: ArraySlice<LogEntry>,
                                                   precededByExisting: Bool) -> NSAttributedString {
            let attributed = NSMutableAttributedString()
            let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 2

            // If we're appending to existing content, start with a newline so
            // this batch sits below the previous entries.
            var isFirstInBatch = true

            for entry in entries {
                if !isFirstInBatch || precededByExisting {
                    attributed.append(NSAttributedString(string: "\n", attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.textColor
                    ]))
                }
                isFirstInBatch = false

                let color = colorForLevel(entry.level)

                let prefix = "\(entry.formattedTime) [\(entry.category.rawValue)] "
                let prefixAttrs: [NSAttributedString.Key: Any] = [
                    .font: monoFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraphStyle
                ]
                attributed.append(NSAttributedString(string: prefix, attributes: prefixAttrs))

                let message = "\(entry.level.symbol) \(entry.message)"
                let messageAttrs: [NSAttributedString.Key: Any] = [
                    .font: monoFont,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle
                ]
                attributed.append(NSAttributedString(string: message, attributes: messageAttrs))

                if entry.level == .error || entry.level == .warning {
                    let bgColor = entry.level == .error
                        ? NSColor.red.withAlphaComponent(0.1)
                        : NSColor.orange.withAlphaComponent(0.06)

                    let lineStart = attributed.length - prefix.count - message.count
                    let lineRange = NSRange(location: lineStart, length: prefix.count + message.count)
                    attributed.addAttribute(.backgroundColor, value: bgColor, range: lineRange)
                }
            }

            return attributed
        }

        private static func colorForLevel(_ level: Log.Level) -> NSColor {
            switch level {
            case .debug:   return NSColor.systemGray
            case .info:    return NSColor.white
            case .warning: return NSColor.systemOrange
            case .error:   return NSColor.systemRed
            }
        }
    }
}
