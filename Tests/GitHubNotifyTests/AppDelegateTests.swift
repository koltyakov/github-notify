import AppKit
import XCTest
@testable import GitHubNotify

final class AppDelegateTests: XCTestCase {
    @MainActor
    func testReopenDoesNotOpenSettingsOrRequestDefaultWindowHandling() async {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))

        // Notification activation may reopen a running app, with or without windows.
        // Repeat the events to catch settings appearing on subsequent activations too.
        for hasVisibleWindows in [false, true, false] {
            XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: hasVisibleWindows))
            XCTAssertEqual(Set(application.windows.map(ObjectIdentifier.init)), existingWindows)
        }
    }
}
