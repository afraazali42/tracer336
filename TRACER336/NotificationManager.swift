// ─────────────────────────────────────────────────────────────────────────────
// NotificationManager.swift — macOS Notification Delivery
// ─────────────────────────────────────────────────────────────────────────────
//
// Handles macOS notification delivery for export success events. Uses the
// UNUserNotificationCenter API with a custom action button.
//
// FEATURES:
//   - "Recording Saved" banner with filename and folder
//   - "Show in Finder" action button that highlights the file in Finder
//   - Silent delivery — sound is handled separately by AppDelegate
//   - Permission requested on-demand when the user enables the toggle
//   - Notifications appear even when the app is in the foreground
//
// ARCHITECTURE:
//   Singleton pattern (NotificationManager.shared). Call setup() once at
//   app launch to register categories and set the delegate. The manager
//   checks AppSettings.notificationsEnabled before delivering — call
//   notifyExportSuccess() unconditionally and it will no-op if disabled.
//
// FOR PLUGIN DEVELOPERS:
//   To add custom notification types:
//   1. Define a new category ID and action(s) in setup()
//   2. Add a new delivery method similar to notifyExportSuccess()
//   3. Handle the new action in userNotificationCenter(_:didReceive:...)
//
// ─────────────────────────────────────────────────────────────────────────────

import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    
    static let shared = NotificationManager()
    
    // ── Action & Category Identifiers ───────────────────────────────────────
    
    private static let showInFinderAction = "SHOW_IN_FINDER"
    private static let categoryID = "EXPORT_SUCCESS"
    
    private override init() {
        super.init()
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Setup
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Register notification categories and set the delegate. Call once at app launch.
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        // "Show in Finder" opens Finder and highlights the exported file
        let showAction = UNNotificationAction(
            identifier: Self.showInFinderAction,
            title: "Show in Finder",
            options: .foreground  // Brings the app to foreground when tapped
        )
        
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [showAction],
            intentIdentifiers: [],
            options: []
        )
        
        center.setNotificationCategories([category])
        Log.info("Notification system initialized", category: .notify)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Permission
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Request notification permission from the user. Called when the toggle
    /// is enabled in settings. The system only shows the prompt once — subsequent
    /// calls resolve immediately with the stored permission.
    func requestPermission(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    Log.warning("Notification permission error: \(error)", category: .notify)
                }
                Log.info("Notification permission \(granted ? "granted" : "denied")", category: .notify)
                completion(granted)
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Delivery
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Send a notification for a successful export. No-ops if notifications
    /// are disabled in settings or permission hasn't been granted.
    ///
    /// - Parameter filePath: Absolute path to the exported audio file.
    func notifyExportSuccess(filePath: String) {
        guard AppSettings.notificationsEnabled else { return }
        
        let center = UNUserNotificationCenter.current()
        
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            
            let url = URL(fileURLWithPath: filePath)
            let filename = url.lastPathComponent
            let folder = url.deletingLastPathComponent().lastPathComponent
            
            let content = UNMutableNotificationContent()
            content.title = "Recording Saved"
            content.body = "\(filename)\n📁 \(folder)"
            content.sound = nil  // Sound is played directly by AppDelegate, not the notification
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["filePath": filePath]
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil  // Deliver immediately
            )
            
            center.add(request) { error in
                if let error = error {
                    Log.warning("Failed to deliver notification: \(error)", category: .notify)
                }
            }
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Delegate — Action Handling
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Handle the "Show in Finder" action button press.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.showInFinderAction {
            if let filePath = response.notification.request.content.userInfo["filePath"] as? String {
                let url = URL(fileURLWithPath: filePath)
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                Log.info("Opened Finder for: \(url.lastPathComponent)", category: .notify)
            }
        }
        completionHandler()
    }
    
    /// Allow notifications to display as banners even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
