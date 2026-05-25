// ─────────────────────────────────────────────────────────────────────────────
// AudioRecorder.swift — Continuous Audio Recording Engine
// ─────────────────────────────────────────────────────────────────────────────
//
// The heart of TRACER336. Continuously records audio from the user's selected
// input device into a circular buffer of 1-minute AAC (.m4a) chunk files stored
// in the system temp directory. Old chunks are pruned based on the retention
// setting (default: 1 hour).
//
// ARCHITECTURE:
//
//   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
//   │ AVAudioEngine │ ──▶ │  Audio Tap   │ ──▶ │  Chunk File  │
//   │  (hardware)   │     │ (4096 buffer)│     │ (.m4a, AAC)  │
//   └──────────────┘     └──────────────┘     └──────────────┘
//                                                     │
//                                              Every 60 seconds:
//                                              close current chunk,
//                                              start new chunk,
//                                              prune oldest if over limit
//
// CHUNK SYSTEM:
//   - Each chunk is a 1-minute .m4a file named by Unix timestamp
//   - Stored in: ~/Library/Caches/.../TRACER336Chunks/
//   - Output format: AAC mono, 22050 Hz, user-selected bitrate (24–64 kbps)
//   - The audio tap captures at the hardware's native sample rate (44.1/48 kHz)
//     and the AAC encoder handles downsampling automatically
//
// EXPORT PIPELINE:
//   1. rotateChunk() — closes the current file so it's safe to read
//   2. getSortedFiles() — lists chunks by creation date
//   3. AVMutableComposition — concatenates the requested number of chunks
//   4. AVAssetExportSession — writes the final file (passthrough for M4A,
//      decode+re-encode for WAV)
//
// THREAD SAFETY:
//   The audio tap runs on a real-time audio thread. All access to `audioFile`
//   is protected by `fileLock` (NSLock). The rest of the class runs on the
//   main thread.
//
// DEVICE MONITORING:
//   A CoreAudio property listener watches for device connect/disconnect events.
//   If the user's selected device disappears, recording pauses automatically
//   and the icon turns red. Reconnecting auto-resumes. The app never silently
//   switches to a different device.
//
// ─────────────────────────────────────────────────────────────────────────────

import AVFoundation
import AppKit
import CoreAudio
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Audio Input Device Model
// ─────────────────────────────────────────────────────────────────────────────

/// Represents a physical audio input device discovered via CoreAudio.
/// Used to populate the Input picker in SettingsView.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID        // CoreAudio device ID (unique per device)
    let name: String             // Human-readable name (e.g. "MacBook Pro Microphone")
    let isBuiltIn: Bool          // True for built-in mic/speakers
    let isBluetooth: Bool        // True for Bluetooth devices (may affect audio quality)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AudioRecorder
// ─────────────────────────────────────────────────────────────────────────────

class AudioRecorder: NSObject, ObservableObject {
    
    // ── Engine & File State ─────────────────────────────────────────────────
    
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?      // Currently open chunk file being written to
    private var chunkTimer: Timer?           // Fires every 60s to rotate chunks
    private var currentFormat: AVAudioFormat? // The recording format (matches hardware sample rate)
    
    /// NSLock protecting `audioFile` — both the audio tap and the disk-write
    /// queue need to swap/read it safely against chunk rotations.
    private let fileLock = NSLock()

    /// Serial queue that handles all AAC encoding + disk writes. The tap
    /// callback only does a cheap memcpy and dispatches here, so even slow
    /// disk I/O can't stall the audio engine's real-time thread (which is
    /// what causes HAL "skipping cycle due to overload" crackles).
    private let diskWriteQueue = DispatchQueue(label: "com.tracer336.disk-write", qos: .utility)
    
    // ── Chunk Storage ───────────────────────────────────────────────────────
    
    private let fileManager = FileManager.default
    private var recordingsFolder: URL!       // Temp directory for chunk files
    
    /// Holds the security-scoped folder URL during async export so sandbox
    /// access stays open until the export session completes.
    private var activeScopedFolder: URL?
    
    // ── Settings (live from UserDefaults) ───────────────────────────────────
    
    /// Maximum number of 1-minute chunks to keep (derived from retention hours).
    private var maxMinutes: Int {
        return AppSettings.retentionHours * 60
    }
    
    /// AAC encoder bitrate (read live so mid-session changes take effect on next chunk).
    private var bitRate: Int {
        return AppSettings.bitRate
    }
    
    // ── Recording Timeline ──────────────────────────────────────────────────
    
    /// When recording started (or was last resumed). Used to calculate `availableSeconds`.
    private var recordingStartTime: Date?
    
    // ── Published State (observed by AppDelegate & SettingsView) ─────────────
    
    /// Whether the engine is actively recording.
    @Published private(set) var isRecording = false
    
    /// Whether the user's selected audio device has been disconnected.
    /// When true, recording is paused and the icon turns red.
    @Published private(set) var isDeviceDisconnected = false

    /// Whether the audio engine has died and the auto-recovery attempts have
    /// been exhausted. Distinct from device disconnection — this fires when
    /// AVAudioEngine fails to restart `maxRestartAttempts` times after a
    /// config change or unexpected stop, for reasons unrelated to the user's
    /// device choice (Bluetooth glitch, sample rate change, system audio reset,
    /// etc.). User must toggle Active off/on or pick a different input to retry.
    @Published private(set) var engineFailed = false

    /// Whether the user has denied (or revoked) microphone access in macOS's
    /// privacy settings. When true, recording is impossible until the user
    /// enables the permission in System Settings → Privacy & Security →
    /// Microphone. UI surfaces this with a deep-link button to that pane.
    @Published private(set) var microphonePermissionDenied = false
    
    // ── Callbacks ───────────────────────────────────────────────────────────
    
    /// Fires on the main thread after every successful export. AppDelegate uses
    /// this to trigger the icon pulse animation and success sound.
    var onExportSuccess: (() -> Void)?
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Initialization
    // ─────────────────────────────────────────────────────────────────────────
    
    /// CoreAudio listener block for device connect/disconnect events.
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    
    /// Periodic timer that checks if the engine is still running.
    /// Catches silent engine deaths that don't trigger any notification.
    private var engineHealthTimer: Timer?
    
    /// Tracks whether the user intentionally paused recording.
    /// Prevents the health check from trying to restart a deliberately paused engine.
    private var isIntentionallyPaused = false
    
    /// How many consecutive restart attempts have failed. Resets on success.
    /// After 3 failures, stops retrying and enters error state.
    private var restartAttempts = 0
    private let maxRestartAttempts = 3
    
    /// - Parameter forPreview: When true, skip all real-world setup (temp folder
    ///   creation, chunk wipe, CoreAudio device listener). Use this from SwiftUI
    ///   `#Preview` blocks so canvas re-renders don't touch real audio APIs.
    init(forPreview: Bool = false) {
        super.init()
        guard !forPreview else { return }
        setupFolder()
        clearFolder()
        startDeviceMonitoring()
    }

    deinit {
        stopDeviceMonitoring()
        stopEngineHealthMonitor()
    }
    
    /// Create the temp directory for chunk storage.
    private func setupFolder() {
        let tempDir = fileManager.temporaryDirectory
        recordingsFolder = tempDir.appendingPathComponent("TRACER336Chunks")
        try? fileManager.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
    }
    
    /// Delete all chunk files (called on init and when clearing the buffer).
    private func clearFolder() {
        let files = (try? fileManager.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Public API
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Clear a device disconnection error by switching to a new device and resuming.
    /// Called from SettingsView when the user picks a replacement device.
    func resolveDeviceError(newDeviceID: Int) {
        isDeviceDisconnected = false
        engineFailed = false
        restartAttempts = 0
        if newDeviceID > 0 {
            setInputDevice(AudioDeviceID(newDeviceID))
        }
        resumeRecording()
        Log.info("Device error resolved, switched to device \(newDeviceID)", category: .audio)
    }
    
    /// Wipe all cached audio chunks and reset the recording start time.
    /// The engine keeps running — new audio starts accumulating immediately.
    ///
    /// Ordering matters under the off-thread disk-write model:
    ///   1. nil out audioFile under fileLock so any new tap callbacks bail
    ///   2. drain the disk-write queue so writes from in-flight tap callbacks
    ///      complete before we delete the underlying files
    ///   3. delete chunks from disk
    ///   4. open a fresh chunk so recording continues immediately
    func clearBuffer() {
        fileLock.lock()
        audioFile = nil
        fileLock.unlock()

        diskWriteQueue.sync { }

        clearFolder()
        recordingStartTime = Date()
        startNewChunk()
        Log.info("Buffer cleared — recording timer reset", category: .audio)
    }
    
    /// How many seconds of audio are actually available right now.
    /// This is the lesser of: time since recording started, or the retention limit.
    var availableSeconds: Int {
        guard let start = recordingStartTime else { return 0 }
        let elapsed = Int(Date().timeIntervalSince(start))
        let retentionLimit = AppSettings.retentionHours * 3600
        return min(elapsed, retentionLimit)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Recording Lifecycle
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Start the audio engine and begin recording. Called once at app launch.
    ///
    /// Sets up the audio tap on the engine's input node, opens the first chunk
    /// file, and starts a 60-second timer for chunk rotation.
    func startRecording() {
        // Gate engine setup on the user's microphone privacy permission.
        // If not yet asked, prompt; if denied/restricted, set the flag and
        // bail (UI shows a deep-link to System Settings → Microphone); if
        // authorized, proceed directly.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphonePermissionDenied = false
            startEngineWithMicrophoneAccess()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.microphonePermissionDenied = false
                        self.startEngineWithMicrophoneAccess()
                    } else {
                        self.microphonePermissionDenied = true
                        self.isRecording = false
                        Log.warning("Microphone access denied at prompt — recording disabled until enabled in System Settings", category: .audio)
                    }
                }
            }
        case .denied, .restricted:
            microphonePermissionDenied = true
            isRecording = false
            Log.warning("Microphone access not granted — recording disabled. Enable in System Settings → Privacy & Security → Microphone.", category: .audio)
        @unknown default:
            microphonePermissionDenied = true
            isRecording = false
        }
    }

    /// Recheck the current microphone authorization status and update the
    /// published flag. If the user just granted access after being blocked,
    /// auto-start recording so they don't have to find a toggle. Call from
    /// `applicationDidBecomeActive` so we catch the user coming back from
    /// System Settings.
    func refreshMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let nowDenied = (status == .denied || status == .restricted)
        let nowAuthorized = (status == .authorized)
        let wasBlocked = microphonePermissionDenied

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.microphonePermissionDenied = nowDenied

            if wasBlocked && nowAuthorized && !self.isRecording {
                Log.info("Microphone access granted — auto-starting recording", category: .audio)
                self.startRecording()
            }
        }
    }

    /// The full engine-start path, gated by `startRecording()`'s permission
    /// check. Don't call this directly — it skips the privacy gate.
    private func startEngineWithMicrophoneAccess() {
        // Apply saved input device preference (0 = system default).
        // CoreAudio device IDs can change between reboots/rebuilds, so if
        // the saved ID isn't found, fall back to matching by device name.
        let savedDeviceID = AppSettings.inputDeviceID
        if savedDeviceID > 0 {
            let devices = AudioRecorder.availableInputDevices()
            let idMatch = devices.contains(where: { Int($0.id) == savedDeviceID })
            
            if idMatch {
                setInputDevice(AudioDeviceID(savedDeviceID))
            } else if let savedName = AppSettings.inputDeviceName,
                      let nameMatch = devices.first(where: { $0.name == savedName }) {
                // Device ID changed but the same device is still connected under a new ID
                Log.info("Device ID changed — resolved '\(savedName)' to new ID \(nameMatch.id)", category: .audio)
                setInputDevice(nameMatch.id)
                // Update the stored ID to the new one
                AppSettings.store.set(Int(nameMatch.id), forKey: AppSettings.inputDeviceIDKey)
            } else {
                Log.warning("Saved device not found (ID: \(savedDeviceID), name: \(AppSettings.inputDeviceName ?? "unknown")) — using system default", category: .audio)
            }
        }
        
        let inputNode = engine.inputNode
        
        // Use the hardware's native sample rate for the tap. This avoids
        // mismatches that can cause crashes. The AAC encoder in the output
        // file handles downsampling to 22050 Hz.
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1)!
        currentFormat = recordingFormat
        
        startNewChunk()
        
        // Install the audio tap. Runs on a real-time audio thread; we keep its
        // work tiny (copy buffer + capture current chunk file + async dispatch)
        // so AAC encoding + disk I/O happen off-thread on diskWriteQueue. This
        // prevents disk-pressure and main-thread stalls from making the HAL
        // I/O work loop miss deadlines (which is what causes audible crackles
        // in concurrent playback). Buffer size is set generously large (~372ms
        // at 44.1kHz) to maximise tolerance for system-level stalls — especially
        // important when users have HAL plugins like Rogue Amoeba's ACE in the
        // audio chain. Latency is irrelevant for buffer-style recording.
        inputNode.installTap(onBus: 0, bufferSize: 16384, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let copy = self.copyBuffer(buffer) else { return }

            // Brief lock to capture the file reference. Avoids racing with
            // chunk rotation, which swaps audioFile under the same lock.
            self.fileLock.lock()
            let targetFile = self.audioFile
            self.fileLock.unlock()

            guard let file = targetFile else { return }

            self.diskWriteQueue.async {
                try? file.write(from: copy)
            }
        }
        
        engine.prepare()
        do {
            try engine.start()
            recordingStartTime = Date()
            isRecording = true
            isIntentionallyPaused = false
            restartAttempts = 0
            Log.info("Audio engine started", category: .audio)
        } catch {
            Log.error("Audio engine failed to start: \(error)", category: .audio)
        }
        
        // Rotate chunks every 60 seconds
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }
        
        // Start monitoring engine health
        startEngineHealthMonitor()
    }

    /// Copy an AVAudioPCMBuffer to a fresh, independently-owned buffer so we
    /// can hold it past the audio tap callback (the system reuses the original
    /// for subsequent callbacks). Pure memcpy per channel — runs on the audio
    /// thread and must stay fast.
    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameCapacity
        ) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)

        if let srcData = source.floatChannelData, let dstData = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dstData[ch], srcData[ch], frameCount * MemoryLayout<Float32>.size)
            }
        }

        return copy
    }

    /// Pause recording. Uses engine.pause() instead of full teardown so the
    /// audio graph stays intact and resuming is instant.
    func stopRecording() {
        isIntentionallyPaused = true
        engine.pause()
        chunkTimer?.invalidate()
        chunkTimer = nil
        isRecording = false
        stopEngineHealthMonitor()
        Log.info("Recording paused", category: .audio)
    }
    
    /// Resume recording after a pause. The engine was only paused (not torn down),
    /// so we just restart it and open a new chunk file.
    func resumeRecording() {
        // Reset before the guard — the user toggling Active back on is an
        // explicit "try again" signal even if the engine technically died.
        engineFailed = false

        guard !isRecording else { return }

        startNewChunk()
        
        do {
            try engine.start()
            isRecording = true
            isIntentionallyPaused = false
            restartAttempts = 0
            Log.info("Recording resumed", category: .audio)
        } catch {
            Log.error("Failed to resume recording: \(error)", category: .audio)
        }
        
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }
        
        startEngineHealthMonitor()
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Input Device Selection
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Enumerate all audio input devices on the system via CoreAudio.
    ///
    /// Returns devices sorted with built-in first, then alphabetical.
    /// Each device includes its transport type (built-in, Bluetooth, USB, etc.).
    static func availableInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }
        
        var results: [AudioInputDevice] = []
        
        for deviceID in deviceIDs {
            guard hasInputChannels(deviceID) else { continue }
            
            let name = deviceName(deviceID) ?? "Unknown Device"
            let transportType = deviceTransportType(deviceID)
            
            results.append(AudioInputDevice(
                id: deviceID,
                name: name,
                isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth
                    || transportType == kAudioDeviceTransportTypeBluetoothLE
            ))
        }
        
        results.sort { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name < b.name
        }
        
        return results
    }
    
    /// Set a specific CoreAudio device as the engine's input source.
    func setInputDevice(_ deviceID: AudioDeviceID) {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Log.warning("Audio unit not available yet", category: .audio)
            return
        }
        
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        if status == noErr {
            Log.info("Input device set to ID: \(deviceID)", category: .audio)
        } else {
            Log.warning("Failed to set input device (error: \(status))", category: .audio)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Device Monitoring
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Watches for audio device connect/disconnect via CoreAudio's property
    // listener system. When the user's selected device disappears, recording
    // stops and the app enters an error state (red icon). The app does NOT
    // silently fall back to a different device — the user must explicitly
    // choose a new one or reconnect the original.
    
    /// Register a CoreAudio listener for device list changes.
    private func startDeviceMonitoring() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.checkSelectedDevice()
            }
        }
        deviceListenerBlock = block
        
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, DispatchQueue.main, block
        )
    }
    
    /// Unregister the CoreAudio device listener.
    private func stopDeviceMonitoring() {
        guard let block = deviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
    }
    
    /// Called when the system device list changes. Checks if the user's
    /// selected device is still connected and updates state accordingly.
    private func checkSelectedDevice() {
        let savedDeviceID = AppSettings.inputDeviceID
        
        // System default (0) always works — nothing to check
        guard savedDeviceID > 0 else {
            if isDeviceDisconnected { isDeviceDisconnected = false }
            return
        }
        
        let availableDevices = AudioRecorder.availableInputDevices()
        let stillConnected = availableDevices.contains(where: { Int($0.id) == savedDeviceID })
        
        if !stillConnected && !isDeviceDisconnected {
            // Device just disappeared
            isDeviceDisconnected = true
            if isRecording {
                engine.pause()
                chunkTimer?.invalidate()
                chunkTimer = nil
                isRecording = false
            }
            Log.warning("Audio device \(savedDeviceID) disconnected", category: .audio)
            
        } else if stillConnected && isDeviceDisconnected {
            // Device came back
            isDeviceDisconnected = false
            Log.info("Audio device \(savedDeviceID) reconnected — resuming", category: .audio)
            resumeRecording()
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Engine Health Monitoring
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Two complementary systems watch for engine failures:
    //
    // 1. Configuration change observer — AVAudioEngine posts a notification
    //    when the audio hardware config changes (sample rate, device mode, etc.).
    //    This can indicate the engine needs to be restarted.
    //
    // 2. Periodic heartbeat timer — checks engine.isRunning every 5 seconds.
    //    Catches silent deaths that don't trigger any notification (rare but
    //    possible with Bluetooth devices or macOS audio subsystem issues).
    //
    // Recovery behavior:
    //   - Attempts to restart the engine on the SAME device (never switches)
    //   - Retries up to 3 times with 2-second delays between attempts
    //   - If all retries fail, enters error state (red icon) so the user knows
    //   - Intentional pauses (user toggled off) are never treated as failures
    
    /// Start both the config change observer and heartbeat timer.
    private func startEngineHealthMonitor() {
        // Stop any existing monitors first
        stopEngineHealthMonitor()
        
        // 1. Listen for audio hardware configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        
        // 2. Periodic heartbeat every 5 seconds
        // Heartbeat every 60s. The AVAudioEngineConfigurationChange notification
        // catches most engine deaths immediately; this is just the safety net
        // for silent failures that don't fire the notification.
        engineHealthTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkEngineHealth()
        }
    }
    
    /// Stop the config change observer and heartbeat timer.
    private func stopEngineHealthMonitor() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engineHealthTimer?.invalidate()
        engineHealthTimer = nil
    }
    
    /// Called when AVAudioEngine's hardware configuration changes.
    /// The engine may have stopped itself — attempt to restart.
    @objc private func handleEngineConfigChange(_ notification: Notification) {
        Log.warning("Audio engine configuration changed", category: .audio)
        
        // If the engine stopped due to the config change, try to restart.
        // Skip if we've already given up (engineFailed) or can't access the
        // mic — the user has to act in those cases.
        if !engine.isRunning && isRecording && !isIntentionallyPaused && !isDeviceDisconnected && !engineFailed && !microphonePermissionDenied {
            Log.warning("Engine stopped after config change — attempting recovery", category: .audio)
            attemptEngineRestart()
        }
    }
    
    /// Periodic check that the engine is still alive.
    private func checkEngineHealth() {
        // Only check if we expect the engine to be running
        guard isRecording && !isIntentionallyPaused && !isDeviceDisconnected && !engineFailed && !microphonePermissionDenied else { return }
        
        if !engine.isRunning {
            Log.warning("Engine health check: engine unexpectedly stopped", category: .audio)
            attemptEngineRestart()
        }
    }
    
    /// Try to restart the engine on the current device. If it fails after
    /// maxRestartAttempts, enter error state and stop retrying.
    private func attemptEngineRestart() {
        guard restartAttempts < maxRestartAttempts else {
            // Give up — surface a distinct engine-failure state (not a device
            // disconnect, since the device is still there). UI maps both to
            // the red error icon but with different messaging.
            isRecording = false
            engineFailed = true
            stopEngineHealthMonitor()
            Log.error("Engine restart failed after \(maxRestartAttempts) attempts — entering engine-failure state", category: .audio)
            return
        }
        
        restartAttempts += 1
        Log.info("Engine restart attempt \(restartAttempts)/\(maxRestartAttempts)", category: .audio)
        
        // Small delay before retry — gives the audio subsystem time to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            // Double-check we still need to restart
            guard !self.engine.isRunning && !self.isIntentionallyPaused && !self.isDeviceDisconnected && !self.engineFailed && !self.microphonePermissionDenied else { return }
            
            self.startNewChunk()
            
            do {
                try self.engine.start()
                self.isRecording = true
                self.restartAttempts = 0
                Log.info("Engine recovered successfully", category: .audio)
            } catch {
                Log.warning("Engine restart attempt \(self.restartAttempts) failed: \(error)", category: .audio)
                // Will retry on next health check or config change
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - CoreAudio Helpers
    // ─────────────────────────────────────────────────────────────────────────
    // Low-level CoreAudio property queries for device enumeration.
    
    /// Returns true if the device has at least one input channel.
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var bufferListSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
        guard status == noErr, bufferListSize > 0 else { return false }
        
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }
        
        status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPointer)
        guard status == noErr else { return false }
        
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        return inputChannels > 0
    }
    
    /// Returns the human-readable name of a CoreAudio device.
    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let cfName = name else { return nil }
        
        return cfName as String
    }
    
    /// Returns the transport type of a device (built-in, Bluetooth, USB, etc.).
    private static func deviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType)
        return transportType
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Chunk Management
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Audio is recorded into sequential 1-minute chunk files. Each chunk is a
    // standalone .m4a file that can be read independently. The chunk timer
    // rotates to a new file every 60 seconds.
    //
    // File naming: Unix timestamp at creation (e.g. "1772933726.m4a")
    // This ensures natural chronological sorting by filename.
    
    /// Close the current chunk (if any) and open a fresh one.
    private func startNewChunk() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = recordingsFolder.appendingPathComponent("\(timestamp).m4a")
        
        // Output at 22050 Hz mono AAC — compatible with all bitrate options (24–64 kbps).
        // The AAC encoder handles downsampling from the hardware tap rate (44.1/48 kHz).
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]
        
        let newFile = try? AVAudioFile(
            forWriting: fileURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        
        // Thread-safe swap — the audio tap may be writing to the old file right now
        fileLock.lock()
        audioFile = newFile
        fileLock.unlock()
        
        cleanupOldFiles()
    }
    
    /// Alias for startNewChunk — called by the 60-second timer.
    private func rotateChunk() {
        startNewChunk()
    }
    
    /// Returns all chunk files sorted by creation date (oldest first).
    private func getSortedFiles() -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(
            at: recordingsFolder,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        
        return files.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 < date2
        }
    }
    
    /// Delete the oldest chunks if we've exceeded the retention limit.
    private func cleanupOldFiles() {
        let sorted = getSortedFiles()
        if sorted.count > maxMinutes {
            let excess = sorted.count - maxMinutes
            for i in 0..<excess {
                try? fileManager.removeItem(at: sorted[i])
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Export Pipeline
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Export flow:
    //   1. exportLast(minutes:) — entry point, rotates current chunk and waits
    //   2. performExportSetup() — builds an AVComposition from chunk files
    //   3. showSavePanel() — decides auto-save vs NSSavePanel
    //   4. exportToURL() — dispatches to M4A or WAV exporter
    //   5. handleExportResult() — releases sandbox, notifies, clears buffer
    
    /// Export the last N minutes of audio. This is the main entry point for
    /// both drag-to-export and Quick Save.
    ///
    /// - Parameters:
    ///   - minutes: Number of minutes to export (rounded up from seconds).
    ///   - forceAutoSave: If true, skip the save dialog even if "Always Ask" is on.
    func exportLast(minutes: Int, forceAutoSave: Bool = false) {
        // Drain pending tap writes for the current chunk before we release it.
        // Each queued write holds a strong reference to the file, which would
        // otherwise delay deinit (and the M4A trailer write) until the queue
        // catches up. sync{} blocks until the serial queue is idle.
        diskWriteQueue.sync { }

        // Capture the URL of the current chunk before we release it, so we can
        // verify it actually finalized before reading. Setting audioFile = nil
        // triggers AVAudioFile's deinit, which closes the file and tells the
        // underlying AAC encoder to write the M4A trailer.
        fileLock.lock()
        let finalizingURL = audioFile?.url
        audioFile = nil
        fileLock.unlock()

        // Start a new chunk so the audio tap keeps writing while we export.
        startNewChunk()

        // AVAudioFile's deinit *initiates* the trailer write but the AAC encoder
        // may finalize asynchronously. Poll the just-closed chunk until it parses
        // as a valid AVURLAsset, or bail out after ~250ms. Most disks finish in
        // a single poll cycle (<40ms); the bound stops a busted encoder from
        // hanging the UI indefinitely.
        waitForChunkReadable(finalizingURL) { [weak self] in
            self?.performExportSetup(minutes: minutes, forceAutoSave: forceAutoSave)
        }
    }

    /// Polls until the given chunk file is readable as an `AVURLAsset` (track
    /// metadata + non-zero duration present), or gives up after a bounded number
    /// of attempts. Always invokes `completion` exactly once on the main queue.
    private func waitForChunkReadable(_ url: URL?, attempt: Int = 0, completion: @escaping () -> Void) {
        // No file means nothing was being written — proceed immediately.
        guard let url = url else {
            completion()
            return
        }

        let asset = AVURLAsset(url: url)
        if asset.tracks(withMediaType: .audio).first != nil, asset.duration.seconds > 0 {
            completion()
            return
        }

        let maxAttempts = 10  // 10 × 25ms = 250ms ceiling.
        guard attempt < maxAttempts else {
            Log.warning("Chunk \(url.lastPathComponent) didn't finalize within 250ms — exporting without it", category: .export)
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForChunkReadable(url, attempt: attempt + 1, completion: completion)
        }
    }
    
    /// Build an AVComposition from the requested number of chunk files.
    private func performExportSetup(minutes: Int, forceAutoSave: Bool = false) {
        let allFiles = getSortedFiles()
        guard !allFiles.isEmpty else {
            Log.warning("No audio files to export", category: .export)
            return
        }
        
        // The newest file was just created by rotateChunk() and is empty — skip it
        let exportableFiles = Array(allFiles.dropLast())
        guard !exportableFiles.isEmpty else {
            Log.warning("No completed audio files to export", category: .export)
            return
        }
        
        // Take the most recent N chunks (1 chunk ≈ 1 minute)
        let filesToExport = Array(exportableFiles.suffix(max(1, minutes)))
        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            Log.error("Failed to create composition track", category: .export)
            return
        }
        
        var currentTime = CMTime.zero
        
        for fileURL in filesToExport {
            let asset = AVURLAsset(url: fileURL)
            // Using synchronous tracks/duration API — the async loadTracks variant
            // throws -12780 on freshly-rotated chunk files that are still being finalized.
            guard let assetTrack = asset.tracks(withMediaType: .audio).first else { continue }
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            do {
                try compositionAudioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentTime)
                currentTime = CMTimeAdd(currentTime, asset.duration)
            } catch {
                Log.warning("Skipping chunk \(fileURL.lastPathComponent): \(error)", category: .export)
            }
        }
        
        guard currentTime.seconds > 0 else {
            Log.error("No valid audio data to export", category: .export)
            return
        }
        
        showSavePanel(for: composition, forceAutoSave: forceAutoSave)
    }
    
    /// Decide where to save the export file, then start the export.
    ///
    /// If auto-save is enabled and we have a valid bookmark, save directly.
    /// Otherwise, show an NSSavePanel for the user to pick a location.
    private func showSavePanel(for composition: AVComposition, forceAutoSave: Bool = false) {
        let format = AppSettings.exportFormat
        let ext = format == "wav" ? "wav" : "m4a"
        let filename = "TRACER336_\(Int(Date().timeIntervalSince1970)).\(ext)"
        
        // Auto-save path: no dialog, write directly to bookmarked folder
        if forceAutoSave || !AppSettings.alwaysAskSave {
            if let folder = AppSettings.resolveSaveFolderBookmark() {
                let url = folder.appendingPathComponent(filename)
                Log.info("Auto-saving to: \(url.path)", category: .export)
                activeScopedFolder = folder
                exportToURL(composition: composition, format: format, url: url)
                return
            }
            Log.warning("No bookmark for save folder — showing save panel", category: .export)
        }
        
        // Manual save path: show NSSavePanel
        let savePanel = NSSavePanel()
        
        if format == "wav" {
            if let wavType = UTType("com.microsoft.waveform-audio") {
                savePanel.allowedContentTypes = [wavType]
            }
        } else {
            if let m4aType = UTType("com.apple.m4a-audio") {
                savePanel.allowedContentTypes = [m4aType]
            }
        }
        
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.title = "Save TRACER336 Recording"
        savePanel.nameFieldStringValue = filename
        savePanel.directoryURL = URL(fileURLWithPath: AppSettings.saveFolder)
        savePanel.level = .floating

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                let folder = url.deletingLastPathComponent()
                AppSettings.setSaveFolderWithBookmark(folder)
                self.exportToURL(composition: composition, format: format, url: url)
            }
        }
    }
    
    /// Dispatch to the appropriate exporter based on format.
    private func exportToURL(composition: AVComposition, format: String, url: URL) {
        // Remove existing file — AVAssetExportSession fails if the output exists
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        
        if format == "wav" {
            exportAsWAV(composition: composition, to: url)
        } else {
            exportAsM4A(composition: composition, to: url)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - M4A Export (passthrough, near-instant)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Attempts passthrough first (copies AAC data without re-encoding — instant).
    // Falls back to AppleM4A preset if passthrough fails (re-encodes, slower).
    
    private func exportAsM4A(composition: AVComposition, to destinationURL: URL) {
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
        
        for preset in presets {
            guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            session.outputURL = destinationURL
            session.outputFileType = .m4a
            
            Log.debug("Attempting M4A export with preset: \(preset)", category: .export)
            session.exportAsynchronously {
                DispatchQueue.main.async {
                    if session.status == .completed {
                        self.handleExportResult(success: true, error: nil, url: destinationURL)
                    } else {
                        Log.warning("Export with \(preset) failed: \(session.error?.localizedDescription ?? "unknown")", category: .export)
                        if preset == AVAssetExportPresetPassthrough {
                            try? self.fileManager.removeItem(at: destinationURL)
                            self.exportAsM4A_fallback(composition: composition, to: destinationURL)
                        } else {
                            self.handleExportResult(success: false, error: session.error, url: destinationURL)
                        }
                    }
                }
            }
            return
        }
        
        handleExportResult(success: false, error: NSError(domain: "TRACER336", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "No compatible export preset found"
        ]), url: destinationURL)
    }
    
    /// Fallback M4A exporter using the AppleM4A preset (re-encodes audio).
    private func exportAsM4A_fallback(composition: AVComposition, to destinationURL: URL) {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            handleExportResult(success: false, error: NSError(domain: "TRACER336", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "AppleM4A preset not available"
            ]), url: destinationURL)
            return
        }
        
        session.outputURL = destinationURL
        session.outputFileType = .m4a
        
        Log.debug("Attempting M4A export with fallback preset", category: .export)
        session.exportAsynchronously {
            DispatchQueue.main.async {
                self.handleExportResult(success: session.status == .completed, error: session.error, url: destinationURL)
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - WAV Export (decode AAC → uncompressed PCM)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // WAV export is slower because it decodes the AAC chunks and re-writes
    // them as uncompressed 16-bit PCM at 44.1 kHz. The file will be significantly
    // larger but is compatible with more audio software.
    
    private func exportAsWAV(composition: AVComposition, to destinationURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let asset = composition as AVAsset
                guard let reader = try? AVAssetReader(asset: asset),
                      let track = asset.tracks(withMediaType: .audio).first else {
                    throw NSError(domain: "TRACER336", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to read audio tracks"
                    ])
                }
                
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1
                ]
                
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                reader.add(readerOutput)
                
                guard let writer = try? AVAssetWriter(outputURL: destinationURL, fileType: .wav) else {
                    throw NSError(domain: "TRACER336", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to create WAV writer"
                    ])
                }
                
                let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
                writer.add(writerInput)
                
                reader.startReading()
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                
                let group = DispatchGroup()
                group.enter()
                
                writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.tracer336.wavExport")) {
                    while writerInput.isReadyForMoreMediaData {
                        if let buffer = readerOutput.copyNextSampleBuffer() {
                            writerInput.append(buffer)
                        } else {
                            writerInput.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
                
                group.wait()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        self?.handleExportResult(success: writer.status == .completed, error: writer.error, url: destinationURL)
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    self?.handleExportResult(success: false, error: error, url: destinationURL)
                }
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Export Result Handler
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Called when any export completes (success or failure). Handles sandbox
    /// cleanup, notifications, buffer clearing, and the success callback.
    private func handleExportResult(success: Bool, error: Error?, url: URL) {
        // Release sandbox access to the save folder
        activeScopedFolder?.stopAccessingSecurityScopedResource()
        activeScopedFolder = nil
        
        if success {
            Log.info("Export success: \(url.lastPathComponent)", category: .export)
            NotificationManager.shared.notifyExportSuccess(filePath: url.path)
            if AppSettings.clearBufferOnSave {
                clearBuffer()
            }
            onExportSuccess?()
        } else {
            Log.error("Export failed: \(error?.localizedDescription ?? "unknown")", category: .export)
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error?.localizedDescription ?? "Unknown error"
            alert.runModal()
        }
    }
}
