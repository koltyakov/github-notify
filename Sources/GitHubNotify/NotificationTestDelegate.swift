import AppKit
import Darwin

// The test path does not acquire the instance lock, load tokens, or touch activity baselines.
@MainActor
final class NotificationTestDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NativeNotifications()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task {
            do {
                let delivered = try await notifications.showTest()
                print(delivered
                    ? "Test notification delivered to Notification Center."
                    : "Test notification submitted. Notification Center has not confirmed delivery.")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Test notification failed: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
}
