// ─────────────────────────────────────────────────────────────────────────────
// MenuPopoverView.swift — Quick Actions Popover Menu
// ─────────────────────────────────────────────────────────────────────────────
//
// The popover that appears when the user clicks the menu bar icon. Provides
// quick access to common actions without opening the full settings window.
//
// LAYOUT:
//   ┌──────────────────────────┐
//   │ 🎵 TRACER336        v1.0 │
//   ├──────────────────────────┤
//   │ ⏺ Recording           🟢 │  ← Toggle recording on/off
//   │ ⬇ Quick Save              │  ← Export all buffered audio immediately
//   │ { } Source Code            │  ← Opens GitHub repo
//   │ ♥ Support                  │  ← Opens support page
//   ├──────────────────────────┤
//   │ ⚙ Settings...  🔴   ⌘,   │  ← Opens settings (red dot = device error)
//   │ ✕ Quit              ⌘Q   │
//   └──────────────────────────┘
//
// The `hasDeviceError` flag controls whether a pulsing red dot appears next
// to "Settings..." to alert the user that their audio device was disconnected.
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct MenuPopoverView: View {
    
    // ── Inputs ──────────────────────────────────────────────────────────────
    
    var isRecording: Bool       // Current recording state
    var hasDeviceError: Bool    // True when selected audio device is disconnected
    var hasLogErrors: Bool      // True when there are unresolved error-level logs
    var onToggleRecording: () -> Void
    var onSaveAll: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void
    
    // ── Constants ───────────────────────────────────────────────────────────
    
    /// Fixed width for the leading icon column so labels align vertically.
    private let iconWidth: CGFloat = 20

    /// "v" + CFBundleShortVersionString, e.g. "v1.0". Reads from Info.plist so it
    /// stays in sync with the MARKETING_VERSION build setting.
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "v\(version)"
    }
    
    // ── Body ────────────────────────────────────────────────────────────────
    
    var body: some View {
        VStack(spacing: 0) {
            
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
                Text("TRACER336")
                    .font(.headline)
                Spacer()
                Text(appVersionString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            
            Divider()
                .padding(.horizontal, 8)
            
            // ── Actions ─────────────────────────────────────────────────
            VStack(spacing: 2) {
                
                // Recording toggle — shows live state with colored indicator
                Button(action: onToggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(isRecording ? .red : .secondary)
                            .frame(width: iconWidth, alignment: .center)
                        Text(isRecording ? "Recording" : "Paused")
                            .foregroundStyle(isRecording ? .primary : .secondary)
                        Spacer()
                        Circle()
                            .fill(isRecording ? .green : .gray)
                            .frame(width: 7, height: 7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cornerRadius(6)
                .padding(.horizontal, 4)
                
                popoverButton(icon: "arrow.down.circle", label: "Quick Save", action: onSaveAll)
                
                popoverButton(icon: "curlybraces", label: "Source Code") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/afraazali42/TRACER336")!)
                }
                
                popoverButton(icon: "heart", label: "Support") {
                    // TODO: Replace with Ko-fi URL once set up
                    NSWorkspace.shared.open(URL(string: "https://tracer336.com")!)
                }
                
                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                
                // Settings button — shows pulsing red dot when there's any issue
                // (device disconnected or unresolved error logs)
                Button(action: onSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .frame(width: iconWidth, alignment: .center)
                        Text("Settings...")
                        if hasDeviceError || hasLogErrors {
                            PulsingDot()
                        }
                        Spacer()
                        Text("⌘,")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cornerRadius(6)
                .padding(.horizontal, 4)
                
                popoverButton(icon: "xmark.circle", label: "Quit", shortcut: "⌘Q", action: onQuit)
            }
            .padding(.vertical, 6)
        }
        .frame(width: 220)
    }
    
    // ── Reusable Button Template ────────────────────────────────────────────
    
    private func popoverButton(icon: String, label: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: iconWidth, alignment: .center)
                Text(label)
                Spacer()
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PulsingDot
// ─────────────────────────────────────────────────────────────────────────────
//
// A small red circle that continuously fades between full and 30% opacity.
// Used as an attention indicator next to "Settings..." when there's a device error.

struct PulsingDot: View {
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}
