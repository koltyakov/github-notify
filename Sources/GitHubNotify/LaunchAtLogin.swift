import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func configure(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            if enabled { throw LoginError.notBundled }
            return
        }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    private enum LoginError: LocalizedError {
        case notBundled
        var errorDescription: String? {
            "Launch at login requires the app bundle. Run make app and open GitHub Notify.app first."
        }
    }
}
