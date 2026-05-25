// ─────────────────────────────────────────────────────────────────────────────
// AppDelegate.swift — App Lifecycle & Drag Interaction Controller
// ─────────────────────────────────────────────────────────────────────────────
//
// This is the central coordinator for the app. It manages:
//   1. Menu bar setup — status item, custom animated icon, click/drag gestures
//   2. Drag-to-export interaction — the core UX where users drag from the icon
//      to select how much audio to save, with real-time visual feedback
//   3. Popover menu — quick actions (record toggle, save, settings, quit)
//   4. Settings window — full preferences panel
//   5. State observation — syncs AudioRecorder state to icon appearance
//
// DRAG INTERACTION FLOW:
//   .began   → Lock in available audio, create overlay window, start tracking
//   .changed → Calculate euclidean distance from icon → ratio (0–1) → seconds
//              Update overlay line/dot/label, rotate icon rings proportionally
//              Trigger rubber band when crossing max range boundary
//   .ended   → If released outside icon: play reel-back animation, export audio
//              If released over icon: cancel (or open popover if never left)
//
// COORDINATE SYSTEM:
//   All drag math uses screen coordinates (NSEvent.mouseLocation). The overlay
//   window converts these to its local coordinate system via overlayLocalPoint().
//   Euclidean distance from the icon center determines the drag ratio, which
//   drives everything: line length, icon rotation, seconds to export.
//
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa
import SwiftUI
import Combine


class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Properties
    // ─────────────────────────────────────────────────────────────────────────
    
    var statusItem: NSStatusItem!
    var overlayWindow: OverlayWindow?
    var recorder = AudioRecorder()
    var popover: NSPopover?
    var settingsWindow: NSWindow?
    var logsWindow: NSWindow?
    var menuBarIcon: MenuBarIconView?
    var initialLocation: NSPoint?

    /// Cached success sound. Loaded once at launch so we don't hit disk on every
    /// export. Volume is preset; just call .play() (after .stop() for re-trigger).
    private var successSound: NSSound?
    
    /// Combine subscription for observing recording state + device connection.
    private var recordingObserver: AnyCancellable?
    
    // ── Drag State ──────────────────────────────────────────────────────────
    // These are reset at the start of each drag gesture and used throughout.
    
    /// True while a drag gesture is active. Prevents click from firing after drag.
    var isDragging = false
    
    /// The screen where the drag started — used for consistent range scaling.
    var dragScreen: NSScreen?
    
    /// The icon's frame in screen coordinates, captured at drag start.
    var iconScreenRect: NSRect = .zero
    
    /// Whether the cursor has moved outside the icon at any point during this drag.
    /// If false when the drag ends, it's treated as a click (open popover).
    var hasLeftIcon = false
    
    /// Previous frame's over-icon state — used to detect enter/leave transitions
    /// which trigger expand/retract animations on the overlay.
    var wasOverIcon = true
    
    /// Audio seconds available, locked in at drag start so the range doesn't
    /// shift mid-gesture as new audio accumulates.
    var snapshotAvailableSeconds: Int = 0
    
    /// Whether the cursor was past the max drag range on the previous frame.
    /// Used to detect the boundary crossing that triggers rubber band animation.
    var wasPastMax = false
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - App Lifecycle
    // ─────────────────────────────────────────────────────────────────────────
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar accessory — no dock icon, no main window
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        
        recorder.startRecording()
        Log.info("App launched, recording started", category: .system)
        
        // Set up notification system (registers categories and delegate)
        NotificationManager.shared.setup()

        // Preload the success sound — avoids hitting disk + allocating NSSound
        // on every export. byReference: true makes NSSound stream from the bundle
        // instead of loading the entire WAV into memory.
        if let soundURL = Bundle.main.url(forResource: "successful_audio_capture", withExtension: "wav") {
            successSound = NSSound(contentsOf: soundURL, byReference: true)
            successSound?.volume = 0.7
        }

        // Observe recording state and device connection to update the menu bar icon.
        // Uses combineLatest so the icon reflects whichever state takes priority:
        //   error (red) > paused (dimmed) > active (full white)
        // "error" covers both device disconnection and engine failure — they're
        // visually identical (red icon) but have separate messaging in Settings.
        recordingObserver = recorder.$isRecording
            .combineLatest(recorder.$isDeviceDisconnected, recorder.$engineFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isDisconnected, engineFailed in
                if isDisconnected || engineFailed {
                    self?.menuBarIcon?.setState(.error)
                } else if isRecording {
                    self?.menuBarIcon?.setState(.active)
                } else {
                    self?.menuBarIcon?.setState(.paused)
                }
            }
        
        // On successful export: play the icon pulse animation and optional sound
        recorder.onExportSuccess = { [weak self] in
            self?.menuBarIcon?.pulseSuccess()

            // Play the bundled success sound (independent of notifications).
            // stop() before play() so a fast-fire export still plays from start.
            if AppSettings.soundEnabled {
                self?.successSound?.stop()
                self?.successSound?.play()
            }
        }
        
        // Register global hotkey for Quick Save
        HotkeyManager.shared.onHotkeyPressed = { [weak self] in
            guard let self = self else { return }
            guard self.recorder.isRecording, !self.recorder.isDeviceDisconnected else { return }
            let totalMinutes = max(1, Int(ceil(Double(self.recorder.availableSeconds) / 60.0)))
            self.recorder.exportLast(minutes: totalMinutes, forceAutoSave: true)
            Log.info("Global hotkey triggered Quick Save", category: .export)
        }
        HotkeyManager.shared.register()
        
        // On first launch (or lost bookmark), prompt for save folder
        promptForSaveFolderIfNeeded()
    }
    
    /// Present a folder picker if we don't have a valid sandbox bookmark.
    /// This runs once on first launch and never again unless the bookmark is lost.
    func promptForSaveFolderIfNeeded() {
        if let url = AppSettings.resolveSaveFolderBookmark() {
            url.stopAccessingSecurityScopedResource()
            return
        }
        
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
            panel.prompt = "Use This Folder"
            panel.message = "Choose where TRACER336 should save recordings."
            panel.title = "TRACER336 Setup"
            panel.level = .floating
            
            if panel.runModal() == .OK, let url = panel.url {
                AppSettings.setSaveFolderWithBookmark(url)
                AppSettings.store.set(url.path, forKey: AppSettings.saveFolderKey)
                AppSettings.store.set(false, forKey: AppSettings.alwaysAskSaveKey)
                Log.info("Save folder set to: \(url.path)", category: .settings)
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Menu Bar Setup
    // ─────────────────────────────────────────────────────────────────────────
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        
        guard let button = statusItem.button else { return }
        
        // The icon is a custom NSView with three independently animated CALayers
        // (outer ring, middle ring, center dot). It's added as a subview of the
        // status bar button and centered within it.
        let iconSize: CGFloat = 18
        let iconView = MenuBarIconView(frame: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
        iconView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(iconView)
        iconView.frame.origin.x = (button.bounds.width - iconSize) / 2
        iconView.frame.origin.y = (button.bounds.height - iconSize) / 2
        menuBarIcon = iconView
        
        // Left-click and right-click both trigger the popover
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusBarClicked(_:))
        button.target = self
        
        // Pan gesture handles the drag-to-export interaction
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        button.addGestureRecognizer(pan)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Coordinate Helpers
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Returns the screen containing the current mouse position.
    func screenForCurrentMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
    
    /// Converts a screen-space point to the overlay window's local coordinate system.
    func overlayLocalPoint(from screenPoint: NSPoint) -> NSPoint {
        guard let window = overlayWindow else { return screenPoint }
        return NSPoint(
            x: screenPoint.x - window.frame.origin.x,
            y: screenPoint.y - window.frame.origin.y
        )
    }
    
    /// Returns true if the given screen-space point is inside the menu bar icon.
    func cursorIsOverIcon(_ screenPoint: NSPoint) -> Bool {
        return iconScreenRect.contains(screenPoint)
    }
    
    /// Calculates the maximum drag distance in points for the current gesture.
    ///
    /// At 10+ minutes of recorded audio, the full range is 50% of the screen height.
    /// For shorter recordings, the range scales down proportionally so the visual
    /// line length reflects how much audio is actually available.
    ///
    /// - Parameter screen: The screen where the drag started.
    /// - Returns: Maximum drag distance in points (minimum 60pt).
    func dragRange(for screen: NSScreen) -> CGFloat {
        let fullRange = screen.visibleFrame.height * 0.5
        let tenMinutes = 600.0
        
        if snapshotAvailableSeconds >= Int(tenMinutes) {
            return fullRange
        }
        
        let ratio = CGFloat(snapshotAvailableSeconds) / CGFloat(tenMinutes)
        return max(60.0, fullRange * ratio)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Click → Popover
    // ─────────────────────────────────────────────────────────────────────────
    
    @objc func statusBarClicked(_ sender: Any?) {
        // If we just finished a drag, consume the click event
        if isDragging {
            isDragging = false
            return
        }
        togglePopover()
    }
    
    func togglePopover() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        
        guard let button = statusItem.button else { return }
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 220, height: 140)
        popover.behavior = .transient  // Closes when user clicks outside
        popover.delegate = self
        popover.animates = true
        
        let popoverView = MenuPopoverView(
            isRecording: recorder.isRecording,
            hasDeviceError: recorder.isDeviceDisconnected || recorder.engineFailed,
            hasLogErrors: Log.shared.hasUnresolvedErrors,
            onToggleRecording: { [weak self] in
                guard let self = self else { return }
                if self.recorder.isRecording {
                    self.recorder.stopRecording()
                } else {
                    self.recorder.resumeRecording()
                }
                popover.performClose(nil)
            },
            onSaveAll: { [weak self] in
                popover.performClose(nil)
                guard let self = self else { return }
                let totalMinutes = max(1, Int(ceil(Double(self.recorder.availableSeconds) / 60.0)))
                self.recorder.exportLast(minutes: totalMinutes, forceAutoSave: true)
            },
            onSettings: { [weak self] in
                popover.performClose(nil)
                self?.openSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
        
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    
    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Drag → Export
    // ─────────────────────────────────────────────────────────────────────────
    //
    // The drag gesture is the core interaction of TRACER336. The user drags
    // downward (or in any direction) from the menu bar icon, and the distance
    // determines how much audio to export:
    //
    //   Distance from icon → ratio (0–1) → seconds → minutes to export
    //
    // Visual feedback:
    //   - A white line extends from the icon to the cursor position
    //   - A dot at the end of the line shows the current drag position
    //   - A pill-shaped label shows the selected duration (e.g. "3 min 22 sec")
    //   - The icon's rings rotate proportionally like a tape spool
    //   - A rubber band snap plays when the cursor hits the maximum range
    //
    // On release:
    //   - The line and dot reel back to the icon (tape-measure animation)
    //   - The icon rings get a momentum bounce from the reel-back
    //   - The audio export begins (immediately for auto-save, after animation
    //     for save-dialog mode)
    
    @objc func handleDrag(_ gesture: NSPanGestureRecognizer) {
        let currentLocation = NSEvent.mouseLocation
        
        switch gesture.state {
            
        case .began:
            // Block drag when recording is paused or device is disconnected
            guard recorder.isRecording, !recorder.isDeviceDisconnected else { return }
            
            isDragging = true
            hasLeftIcon = false
            wasOverIcon = true
            wasPastMax = false
            initialLocation = currentLocation
            dragScreen = screenForCurrentMouse()
            
            // Snapshot the available audio so the range doesn't shift mid-drag
            snapshotAvailableSeconds = recorder.availableSeconds
            Log.debug("Drag started: \(snapshotAvailableSeconds)s available, range=\(dragRange(for: dragScreen!))pt", category: .ui)
            
            // Capture the icon's screen-space rect for hit-testing throughout the drag
            if let button = statusItem.button, let buttonWindow = button.window {
                let rectInWindow = button.convert(button.bounds, to: nil)
                iconScreenRect = buttonWindow.convertToScreen(rectInWindow)
            }
            
            popover?.performClose(nil)
            
            // Create a full-screen transparent overlay window for drawing the line/dot/label
            let screen = dragScreen!
            let window = OverlayWindow(for: screen)
            window.makeKeyAndOrderFront(nil)
            overlayWindow = window
            
            // Set the overlay's anchor point (icon center) and initial cursor position
            let iconCenter = NSPoint(x: iconScreenRect.midX, y: iconScreenRect.midY)
            if let view = window.contentView as? OverlayView {
                view.startPoint = overlayLocalPoint(from: iconCenter)
                view.currentPoint = overlayLocalPoint(from: currentLocation)
            }
            
        case .changed:
            guard let screen = dragScreen else { return }
            
            let overIcon = cursorIsOverIcon(currentLocation)
            if !overIcon { hasLeftIcon = true }
            
            let maxSeconds = snapshotAvailableSeconds
            let range = dragRange(for: screen)
            
            if let view = overlayWindow?.contentView as? OverlayView {
                // Calculate euclidean distance from icon center to cursor.
                // This single distance drives: line length, icon rotation, and seconds.
                let iconCenter = NSPoint(x: iconScreenRect.midX, y: iconScreenRect.midY)
                let dx = currentLocation.x - iconCenter.x
                let dy = currentLocation.y - iconCenter.y
                let distance = sqrt(dx * dx + dy * dy)
                let isPastMax = distance > range
                
                let ratio = min(1.0, max(0.0, distance / range))
                let seconds = overIcon ? 0 : max(1, Int(ratio * CGFloat(maxSeconds)))
                
                // Rotate the icon rings proportionally to distance (spool metaphor)
                menuBarIcon?.setDragRatio(overIcon ? 0 : min(1.0, ratio))
                
                // Trigger rubber band when cursor first crosses the max boundary
                if isPastMax && !wasPastMax {
                    let vel = gesture.velocity(in: gesture.view)
                    let speed = sqrt(vel.x * vel.x + vel.y * vel.y)
                    let dirLen = max(0.001, distance)
                    let dir = NSPoint(x: dx / dirLen, y: dy / dirLen)
                    view.triggerRubberBand(velocity: speed, direction: dir)
                }
                wasPastMax = isPastMax
                
                // Clamp the visual endpoint to the max range
                let clampedLocation: NSPoint
                if distance > range {
                    let scale = range / distance
                    clampedLocation = NSPoint(
                        x: iconCenter.x + dx * scale,
                        y: iconCenter.y + dy * scale
                    )
                } else {
                    clampedLocation = currentLocation
                }
                let localPoint = overlayLocalPoint(from: clampedLocation)
                
                view.currentPoint = localPoint
                if !overIcon {
                    view.seconds = seconds
                }
                
                // Detect icon enter/leave transitions for expand/retract animations
                if wasOverIcon && !overIcon {
                    view.startExpand()
                } else if !wasOverIcon && overIcon {
                    view.startRetract()
                }
                
                wasOverIcon = overIcon
                view.needsDisplay = true
            }
            
        case .ended:
            let savedScreen = dragScreen
            let releasePoint = NSEvent.mouseLocation
            let releasedOverIcon = cursorIsOverIcon(releasePoint)
            
            // ── Cancel cases ────────────────────────────────────────────────
            
            // Never left the icon → treat as a click (open popover)
            if !hasLeftIcon {
                cleanupDragState()
                menuBarIcon?.snapBack()
                dismissOverlay()
                isDragging = false
                togglePopover()
                return
            }
            
            // Dragged out but returned to icon → cancel silently
            if releasedOverIcon {
                cleanupDragState()
                menuBarIcon?.snapBack()
                dismissOverlay()
                isDragging = false
                return
            }
            
            hasLeftIcon = false
            
            guard let screen = savedScreen else {
                menuBarIcon?.snapBack()
                dismissOverlay()
                isDragging = false
                return
            }
            
            // ── Calculate export parameters ─────────────────────────────────
            
            let maxSeconds = snapshotAvailableSeconds
            let range = dragRange(for: screen)
            let iconCenter = NSPoint(x: iconScreenRect.midX, y: iconScreenRect.midY)
            let dx = releasePoint.x - iconCenter.x
            let dy = releasePoint.y - iconCenter.y
            let distance = sqrt(dx * dx + dy * dy)
            let releaseRatio = min(1.0, max(0.0, distance / range))
            let seconds = max(1, Int(releaseRatio * CGFloat(maxSeconds)))
            let exportMinutes = max(1, Int(ceil(Double(seconds) / 60.0)))
            
            Log.info("Drag export: \(seconds) seconds (\(exportMinutes) minutes)", category: .export)
            
            // Check if this will auto-save (no dialog) or need user input
            let hasBookmark = AppSettings.store.data(forKey: AppSettings.saveFolderBookmarkKey) != nil
            let willAutoSave = !AppSettings.alwaysAskSave && hasBookmark
            
            // ── Reel-back animation ─────────────────────────────────────────
            // The line and dot retract back to the icon like a tape measure.
            // Duration scales with distance: short drag = instant, full = ~180ms.
            
            if let view = overlayWindow?.contentView as? OverlayView {
                view.cancelRubberBand()
                
                // Sync icon rotation with the reel-back progress
                view.onReelProgress = { [weak self] ratio in
                    self?.menuBarIcon?.setDragRatio(ratio)
                }
                
                // When reel completes: momentum bounce + dismiss + maybe show save dialog
                let capturedWindow = overlayWindow
                view.onReelComplete = { [weak self] in
                    guard let self = self else { return }
                    
                    self.menuBarIcon?.momentumBounce(fromRatio: releaseRatio)
                    
                    if let window = capturedWindow {
                        NSAnimationContext.runAnimationGroup({ context in
                            context.duration = 0.08
                            window.animator().alphaValue = 0
                        }, completionHandler: {
                            window.orderOut(nil)
                        })
                    }
                    
                    // For save-dialog mode, wait until animation completes
                    if !willAutoSave {
                        self.recorder.exportLast(minutes: exportMinutes)
                    }
                }
                
                view.startReelBack(fromRatio: releaseRatio)
            }
            
            // For auto-save mode, start export immediately (runs in background)
            if willAutoSave {
                recorder.exportLast(minutes: exportMinutes)
            }
            
            initialLocation = nil
            dragScreen = nil
            overlayWindow = nil
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isDragging = false
            }
            
        default:
            break
        }
    }
    
    /// Reset drag-tracking flags when a drag is cancelled.
    private func cleanupDragState() {
        if let view = overlayWindow?.contentView as? OverlayView {
            view.cancelRubberBand()
            view.cancelReel()
        }
        hasLeftIcon = false
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Overlay Helpers
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Fade out and remove the overlay window.
    func dismissOverlay() {
        let window = overlayWindow
        overlayWindow = nil
        initialLocation = nil
        dragScreen = nil
        if let window = window {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Settings Window
    // ─────────────────────────────────────────────────────────────────────────
    
    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(recorder: recorder, onOpenLogs: { [weak self] in
                self?.openLogs()
            })
            let hostingController = NSHostingController(rootView: view)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "TRACER336"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            
            settingsWindow = window
        }
        
        // Temporarily show in dock so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        
        // Prevent the retention text field from auto-focusing
        DispatchQueue.main.async {
            self.settingsWindow?.makeFirstResponder(nil)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        
        // Track which window is closing
        let isSettingsClosing = closingWindow === settingsWindow
        let isLogsClosing = closingWindow === logsWindow
        
        if isLogsClosing { logsWindow = nil }
        
        // Check if the OTHER window is still open
        let otherStillOpen: Bool
        if isSettingsClosing {
            otherStillOpen = logsWindow?.isVisible ?? false
        } else if isLogsClosing {
            otherStillOpen = settingsWindow?.isVisible ?? false
        } else {
            otherStillOpen = false
        }
        
        // Hide from dock only when no windows remain
        if !otherStillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Logs Window
    // ─────────────────────────────────────────────────────────────────────────────
    
    func openLogs() {
        if logsWindow == nil {
            let logsView = LogsView()
            let hostingController = NSHostingController(rootView: logsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "TRACER336 — Logs"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 600, height: 400))
            window.minSize = NSSize(width: 400, height: 250)
            window.center()
            
            logsWindow = window
        }
        
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        logsWindow?.makeKeyAndOrderFront(nil)
        
        // Opening the logs window clears the error indicator
        Log.shared.acknowledgeErrors()
    }
}
