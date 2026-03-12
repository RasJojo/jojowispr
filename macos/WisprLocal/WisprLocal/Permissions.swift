import AVFoundation
import ApplicationServices
import Foundation

enum Permissions {
    static func isAccessibilityTrusted() -> Bool {
        // Prefer the modern API on newer macOS versions.
        AXIsProcessTrustedWithOptions(nil)
    }

    static func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Log.permissions.info("Microphone: authorized")
            return true
        case .denied, .restricted:
            Log.permissions.error("Microphone: denied/restricted")
            return false
        case .notDetermined:
            Log.permissions.info("Microphone: requesting access")
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Log.permissions.info("Microphone: request result granted=\(granted)")
                    cont.resume(returning: granted)
                }
            }
        @unknown default:
            Log.permissions.error("Microphone: unknown status")
            return false
        }
    }

    static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func requestScreenRecordingIfNeeded() -> Bool {
        if isScreenRecordingGranted() {
            Log.permissions.info("Screen recording: already granted")
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        Log.permissions.info("Screen recording: request result granted=\(granted)")
        return granted
    }

    @MainActor
    static func requestAccessibilityIfNeeded() -> Bool {
        if isAccessibilityTrusted() {
            Log.permissions.info("Accessibility: already trusted")
            return true
        }

        // Avoid importing the global C var `kAXTrustedCheckOptionPrompt` (Swift 6 strict concurrency).
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt" as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)
        let ok = isAccessibilityTrusted()
        Log.permissions.info("Accessibility: prompt requested, trusted now=\(ok)")
        return ok
    }
}
