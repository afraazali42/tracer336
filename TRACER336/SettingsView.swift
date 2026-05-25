// ─────────────────────────────────────────────────────────────────────────────
// SettingsView.swift — User Preferences Panel
// ─────────────────────────────────────────────────────────────────────────────
//
// The main settings window for TRACER336. All preferences use @AppStorage
// backed by the shared UserDefaults suite (AppSettings.store) for automatic
// persistence and two-way binding.
//
// LAYOUT:
//   Row 1: Active toggle + Launch at Login toggle
//   Row 2: Input device picker (+ device disconnection warning)
//   Row 3: Record duration (hours) + Keep Buffer toggle
//   Row 4: Save location + Always Ask toggle
//   Row 5: Export format (M4A / WAV)
//   Row 6: Quality (AAC bitrate) + estimated file size
//   Row 7: Notifications toggle
//
// DEVICE ERROR HANDLING:
//   When the selected audio device is disconnected (recorder.isDeviceDisconnected),
//   a red warning appears below the Input picker. Selecting a new device from
//   the picker automatically resolves the error and resumes recording.
//
// SANDBOX CONSIDERATIONS:
//   Toggling "Always Ask" off requires folder-level sandbox permission.
//   The toggle presents an NSOpenPanel to acquire a security-scoped bookmark
//   before disabling the save dialog.
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    
    // ── Observed State ──────────────────────────────────────────────────────
    
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject private var logger = Log.shared
    
    /// Callback to open the logs window. Provided by AppDelegate.
    var onOpenLogs: (() -> Void)?
    
    // ── Persisted Preferences (@AppStorage) ─────────────────────────────────
    //
    // Each @AppStorage property binds directly to the shared UserDefaults suite.
    // Changes are automatically persisted and reflected in the UI.
    
    @AppStorage(AppSettings.startAtLoginKey, store: AppSettings.store)
    private var startAtLogin = false
    
    @AppStorage(AppSettings.retentionHoursKey, store: AppSettings.store)
    private var retentionHours = 1
    
    @AppStorage(AppSettings.bitRateKey, store: AppSettings.store)
    private var bitRate = 32000
    
    @AppStorage(AppSettings.inputDeviceIDKey, store: AppSettings.store)
    private var inputDeviceID = 0
    
    @AppStorage(AppSettings.exportFormatKey, store: AppSettings.store)
    private var exportFormat = "m4a"
    
    @AppStorage(AppSettings.saveFolderKey, store: AppSettings.store)
    private var saveFolder = NSHomeDirectory() + "/Desktop"
    
    @AppStorage(AppSettings.alwaysAskSaveKey, store: AppSettings.store)
    private var alwaysAskSave = true
    
    @AppStorage(AppSettings.clearBufferOnSaveKey, store: AppSettings.store)
    private var clearBufferOnSave = true
    
    @AppStorage(AppSettings.notificationsEnabledKey, store: AppSettings.store)
    private var notificationsEnabled = false
    
    @AppStorage(AppSettings.soundEnabledKey, store: AppSettings.store)
    private var soundEnabled = true
    
    @AppStorage(AppSettings.hotkeyKeyCodeKey, store: AppSettings.store)
    private var hotkeyKeyCode: Int = 0xFFFF
    
    @AppStorage(AppSettings.hotkeyModifiersKey, store: AppSettings.store)
    private var hotkeyModifiers: Int = 0
    
    // ── Local State ─────────────────────────────────────────────────────────
    
    @State private var availableDevices: [AudioInputDevice] = []
    @State private var retentionText: String = "\(AppSettings.retentionHours)"
    @State private var showClearBufferConfirmation = false
    
    // ── Constants ───────────────────────────────────────────────────────────
    
    /// AAC bitrate options: label + value in bits/sec
    private let bitRateOptions: [(label: String, value: Int)] = [
        ("24 kbps — Compact", 24000),
        ("32 kbps — Recommended", 32000),
        ("48 kbps — Detailed", 48000),
        ("64 kbps — Pro", 64000)
    ]
    
    // ── Computed Helpers ────────────────────────────────────────────────────
    
    /// Estimated disk usage for the full retention period at current settings.
    private var estimatedStorageMB: Double {
        if exportFormat == "wav" {
            let bytesPerHour = 44100.0 * 2.0 * 3600.0  // 16-bit mono PCM
            return bytesPerHour / (1024.0 * 1024.0) * Double(retentionHours)
        } else {
            let containerOverhead = 1.15  // M4A container adds ~15% overhead
            let bytesPerHour = Double(bitRate) / 8.0 * 3600.0 * containerOverhead
            return bytesPerHour / (1024.0 * 1024.0) * Double(retentionHours)
        }
    }
    
    private var storageText: String {
        if estimatedStorageMB >= 1024 {
            return String(format: "~%.1f GB", estimatedStorageMB / 1024.0)
        } else {
            return String(format: "~%.0f MB", estimatedStorageMB)
        }
    }
    
    /// Just the last path component of the save folder (e.g. "Desktop").
    private var saveFolderName: String {
        return URL(fileURLWithPath: saveFolder).lastPathComponent
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Body
    // ─────────────────────────────────────────────────────────────────────────
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            
            // ── Row 1: Active + Launch at Login + Quit ───────────────
            HStack {
                Toggle("Active", isOn: Binding(
                    get: { recorder.isRecording },
                    set: { newValue in
                        if newValue { recorder.resumeRecording() }
                        else { recorder.stopRecording() }
                    }
                ))
                .toggleStyle(.switch)
                Spacer()
                Toggle("Launch at Login", isOn: Binding(
                    get: { startAtLogin },
                    set: { newValue in
                        startAtLogin = newValue
                        toggleLoginItem(enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(height: 22)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(.red.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help("Quit TRACER336")
            }
            
            Divider()
            
            // ── Row 2: Input Device ─────────────────────────────────────
            Picker("Input:", selection: $inputDeviceID) {
                Text("System Default").tag(0)
                
                ForEach(availableDevices) { device in
                    HStack(spacing: 4) {
                        Text(device.name)
                        if device.isBluetooth {
                            Text("(Bluetooth)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Int(device.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: inputDeviceID) { newValue in
                // Save the device name alongside the ID so we can re-identify
                // the device if CoreAudio assigns a new ID after a reboot
                if let device = availableDevices.first(where: { Int($0.id) == newValue }) {
                    AppSettings.store.set(device.name, forKey: AppSettings.inputDeviceNameKey)
                } else if newValue == 0 {
                    AppSettings.store.removeObject(forKey: AppSettings.inputDeviceNameKey)
                }
                
                // Selecting a new device while in any error state resolves it.
                // Engine failures are often fixed by a fresh engine start on a
                // different input, so we treat both errors the same way here.
                if recorder.isDeviceDisconnected || recorder.engineFailed {
                    recorder.resolveDeviceError(newDeviceID: newValue)
                }
            }
            
            // Device status warnings
            if recorder.microphonePermissionDenied {
                HStack(spacing: 4) {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Microphone access denied.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else if recorder.isDeviceDisconnected {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Selected device disconnected. Choose a new input or reconnect.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if recorder.engineFailed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Audio engine stopped after recovery failed. Toggle Active off and on, or pick a different input.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if let selected = availableDevices.first(where: { Int($0.id) == inputDeviceID }),
                      selected.isBluetooth {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Bluetooth input will reduce headphone audio quality.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            Divider()
            
            // ── Row 3: Record Duration + Keep Buffer ────────────────────
            HStack {
                Text("Record:")
                TextField("", text: $retentionText)
                    .frame(width: 36)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        commitRetention()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                Text("hours")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    showClearBufferConfirmation = true
                }
                .controlSize(.small)
                .help("Discard all buffered audio now. Recording continues with a fresh buffer.")
                Spacer()
                Toggle("Keep Buffer", isOn: Binding(
                    get: { !clearBufferOnSave },
                    set: { newValue in clearBufferOnSave = !newValue }
                ))
                .toggleStyle(.switch)
            }
            .alert("Clear the audio buffer?", isPresented: $showClearBufferConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    recorder.clearBuffer()
                }
            } message: {
                Text("All buffered audio will be permanently deleted. Recording continues with a fresh buffer.")
            }
            
            Divider()
            
            // ── Row 4: Save Location + Always Ask ───────────────────────
            HStack {
                Text("Save to:")
                Button(action: chooseSaveFolder) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(saveFolderName)
                    }
                }
                Spacer()
                Toggle("Always Ask", isOn: Binding(
                    get: { alwaysAskSave },
                    set: { newValue in
                        if !newValue {
                            // Turning off "Always Ask" requires a folder bookmark
                            // for sandbox access. Show a picker to acquire it.
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = URL(fileURLWithPath: saveFolder)
                            panel.prompt = "Use This Folder"
                            panel.message = "Select the folder for auto-saving recordings."
                            
                            if panel.runModal() == .OK, let url = panel.url {
                                saveFolder = url.path
                                AppSettings.setSaveFolderWithBookmark(url)
                                alwaysAskSave = false
                            }
                            // If user cancels the picker, keep "Always Ask" on
                        } else {
                            alwaysAskSave = true
                        }
                    }
                ))
                .toggleStyle(.switch)
            }
            
            Divider()
            
            // ── Row 5: Quality (AAC Bitrate) ────────────────────────────
            Picker("Quality:", selection: $bitRate) {
                ForEach(bitRateOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(exportFormat == "wav")
            .opacity(exportFormat == "wav" ? 0.5 : 1.0)
            
            Divider()
            
            // ── Row 6: Format + Total File Size ─────────────────────────
            HStack {
                Picker("Format:", selection: $exportFormat) {
                    Text("Lightweight — M4A").tag("m4a")
                    Text("Compatible — WAV").tag("wav")
                }
                .pickerStyle(.menu)
                
                Spacer()
                
                Text("Total File Size: \(storageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // ── Row 7: Notifications + Sound ───────────────────────────
            HStack {
                Toggle("Notifications", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { newValue in
                        if newValue {
                            // Request system permission on first enable
                            NotificationManager.shared.requestPermission { granted in
                                notificationsEnabled = granted
                            }
                        } else {
                            notificationsEnabled = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                Spacer()
                Toggle("Sound", isOn: $soundEnabled)
                    .toggleStyle(.switch)
                
                // Logs button with red badge for unresolved errors
                Button(action: { onOpenLogs?() }) {
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text("Logs")
                        }
                        
                        if logger.hasUnresolvedErrors {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            Divider()
            
            // ── Row 8: Hotkey + Source + Support ───────────────────
            HStack {
                Text("Hotkey:")
                HotkeyRecorderView(
                    keyCode: $hotkeyKeyCode,
                    modifiers: Binding(
                        get: { UInt(hotkeyModifiers) },
                        set: { hotkeyModifiers = Int($0) }
                    ),
                    onChange: {
                        HotkeyManager.shared.register()
                    }
                )
                
                Spacer()
                
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/afraazali42/TRACER336")!)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                        Text("Source")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button(action: {
                    // TODO: Replace with Ko-fi URL once set up
                    NSWorkspace.shared.open(URL(string: "https://tracer336.com")!)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart")
                        Text("Support")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 420)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            // Tap anywhere to dismiss the keyboard from the retention text field
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    commitRetention()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
        )
        .onAppear {
            refreshDevices()
            retentionText = "\(retentionHours)"
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Actions
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Present a folder picker for choosing the save location.
    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveFolder)
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url.path
            AppSettings.setSaveFolderWithBookmark(url)
        }
    }
    
    /// Validate and commit the retention hours text field.
    private func commitRetention() {
        let filtered = retentionText.filter { $0.isNumber }
        if let value = Int(filtered), value > 0 {
            retentionHours = min(24, max(1, value))
        }
        retentionText = "\(retentionHours)"
    }
    
    /// Refresh the list of available audio input devices.
    /// If the saved device ID isn't found, try to match by name (device IDs
    /// can change between reboots). Only resets to system default if neither
    /// matches.
    ///
    /// The CoreAudio enumeration runs on a background queue so it can't
    /// contend with the audio I/O work loop on the main thread (which would
    /// cause audible crackles in concurrent playback on systems with HAL
    /// plugins like SoundSource).
    private func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = AudioRecorder.availableInputDevices()
            DispatchQueue.main.async {
                self.availableDevices = devices

                if self.inputDeviceID != 0 && !devices.contains(where: { Int($0.id) == self.inputDeviceID }) {
                    // Saved ID not found — try matching by name
                    if let savedName = AppSettings.inputDeviceName,
                       let match = devices.first(where: { $0.name == savedName }) {
                        self.inputDeviceID = Int(match.id)
                    } else {
                        self.inputDeviceID = 0
                    }
                }
            }
        }
    }
    
    /// Register or unregister the app as a login item via SMAppService.
    private func toggleLoginItem(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.error("Failed to toggle login item: \(error)", category: .settings)
        }
    }
}

#Preview {
    // forPreview skips CoreAudio listener registration + temp folder ops so
    // canvas re-renders are fast and don't pollute real audio system state.
    SettingsView(recorder: AudioRecorder(forPreview: true), onOpenLogs: {})
}
