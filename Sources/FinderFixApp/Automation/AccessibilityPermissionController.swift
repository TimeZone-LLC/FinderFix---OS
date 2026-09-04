import ApplicationServices
import AppKit
import Foundation

public enum AccessibilityPermissionController {
    public static var status: AccessibilityAuthorizationStatus {
        AXIsProcessTrusted() ? .authorized : .notAuthorized
    }

    /// Requests the system Accessibility prompt when needed. The prompt is asynchronous,
    /// so callers must continue monitoring `status` until macOS records the user's choice.
    @discardableResult
    public static func requestIfNeeded() -> AccessibilityAuthorizationStatus {
        let options: CFDictionary = [
            // Referencing the imported CF global directly is diagnosed as shared
            // mutable state under Swift 6 strict concurrency.
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .notAuthorized
    }

    @MainActor
    public static func openSystemSettings() {
        guard let settingsURL: URL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }
}
