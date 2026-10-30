import AppKit
import GitHubNotifyCore
import UserNotifications

@MainActor
final class NativeNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?

    override init() {
        // UserNotifications requires an app bundle, not a bare `swift run` executable.
        center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func authorize() async throws {
        guard let center else {
            throw failure("Build and launch the .app bundle to enable repository alerts.")
        }
        let authorizationStatus = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        if authorizationStatus == .notDetermined {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else {
                throw failure("Allow GitHub Notify in System Settings > Notifications.")
            }
        } else if authorizationStatus == .denied {
            throw failure("Allow GitHub Notify in System Settings > Notifications.")
        }
    }

    func show(_ toast: RepositoryToast) async throws {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = toast.repository
        content.subtitle = toast.title
        content.body = toast.body
        content.threadIdentifier = toast.repository
        content.userInfo = ["url": toast.url.absoluteString]
        // Like Varro, banners are silent and open their target when clicked.
        content.sound = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(UNNotificationRequest(identifier: toast.id, content: content, trigger: nil)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "GitHubNotify.Notifications", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
