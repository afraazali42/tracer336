// ─────────────────────────────────────────────────────────────────────────────
// HotkeyRecorderView.swift — Keyboard Shortcut Capture Widget
// ─────────────────────────────────────────────────────────────────────────────
//
// A compact button that records keyboard shortcuts. Click it to enter
// "recording" mode, then press any key combo (e.g. ⌘⇧S). Press Escape
// to cancel, or Delete/Backspace to clear the current shortcut.
//
// Uses NSViewRepresentable wrapping a custom NSButton subclass because
// SwiftUI doesn't have native key event capture.
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Cocoa

struct HotkeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: UInt
    var onChange: (() -> Void)?
    
    @State private var isRecording = false
    
    private var displayText: String {
        if isRecording {
            return "Press shortcut..."
        }
        if keyCode == 0xFFFF {
            return "Click to set"
        }
        return HotkeyManager.displayString(keyCode: UInt16(keyCode), modifiers: modifiers)
    }
    
    var body: some View {
        HotkeyRecorderButton(
            isRecording: $isRecording,
            onKeyCombo: { code, mods in
                keyCode = Int(code)
                modifiers = mods
                isRecording = false
                onChange?()
            },
            onClear: {
                keyCode = 0xFFFF
                modifiers = 0
                isRecording = false
                onChange?()
            },
            onCancel: {
                isRecording = false
            }
        )
        .frame(width: 120, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
        )
        .overlay(
            Text(displayText)
                .font(.system(size: 11, weight: isRecording ? .medium : .regular))
                .foregroundStyle(keyCode == 0xFFFF && !isRecording ? .secondary : .primary)
        )
        .onTapGesture {
            isRecording = true
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NSViewRepresentable Bridge
// ─────────────────────────────────────────────────────────────────────────────

struct HotkeyRecorderButton: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onKeyCombo: (UInt16, UInt) -> Void
    var onClear: () -> Void
    var onCancel: () -> Void
    
    func makeNSView(context: Context) -> HotkeyCapturingView {
        let view = HotkeyCapturingView()
        view.onKeyCombo = onKeyCombo
        view.onClear = onClear
        view.onCancel = onCancel
        return view
    }
    
    func updateNSView(_ nsView: HotkeyCapturingView, context: Context) {
        nsView.onKeyCombo = onKeyCombo
        nsView.onClear = onClear
        nsView.onCancel = onCancel
        
        if isRecording && nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Key-Capturing NSView
// ─────────────────────────────────────────────────────────────────────────────
//
// This NSView becomes first responder to capture raw key events.
// It intercepts keyDown to record the shortcut, Escape to cancel,
// and Delete/Backspace to clear.

class HotkeyCapturingView: NSView {
    
    var onKeyCombo: ((UInt16, UInt) -> Void)?
    var onClear: (() -> Void)?
    var onCancel: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        
        // Escape → cancel recording
        if keyCode == 53 {
            onCancel?()
            window?.makeFirstResponder(nil)
            return
        }
        
        // Delete/Backspace → clear the shortcut
        if keyCode == 51 || keyCode == 117 {
            onClear?()
            window?.makeFirstResponder(nil)
            return
        }
        
        // Require at least one modifier key (⌘, ⌥, or ⌃) to avoid
        // capturing plain letter keys that would conflict with text input
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) else {
            // Plain key without modifiers — ignore
            return
        }
        
        onKeyCombo?(keyCode, mods.rawValue)
        window?.makeFirstResponder(nil)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // Transparent — the SwiftUI overlay handles appearance
    }
}
