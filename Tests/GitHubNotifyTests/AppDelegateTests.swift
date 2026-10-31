import AppKit
import XCTest
@testable import GitHubNotify
@testable import GitHubNotifyCore

private actor NotificationReadTransport: HTTPTransport {
    private var request: URLRequest?
    private var requestWaiter: CheckedContinuation<URLRequest, Never>?
    private var reply: CheckedContinuation<(Data, HTTPURLResponse), any Error>?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        requestWaiter?.resume(returning: request)
        requestWaiter = nil
        return try await withCheckedThrowingContinuation { reply = $0 }
    }

    func waitForRequest() async -> URLRequest {
        if let request { return request }
        return await withCheckedContinuation { requestWaiter = $0 }
    }

    func finish(status: Int = 205) {
        reply?.resume(returning: (Data(), HTTPURLResponse(
            url: request!.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!))
        reply = nil
    }
}

final class AppDelegateTests: XCTestCase {
    private func snapshot(_ ids: [String], checkedAt: Date = Date()) throws -> NotificationSnapshot {
        let objects = ids.map { ["id": $0, "repository": ["full_name": "owner/repo"]] as [String: Any] }
        let notifications = try JSONDecoder().decode(
            [GitHubNotification].self, from: JSONSerialization.data(withJSONObject: objects)
        )
        return NotificationSnapshot(notifications: notifications, checkedAt: checkedAt, pollInterval: 60)
    }

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

    @MainActor
    func testClickImmediatelyRemovesLastNotificationAndCounterBeforeWriteFinishes() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        var openedURLs: [URL] = []
        let delegate = AppDelegate(client: GitHubClient(transport: transport), openURL: { openedURLs.append($0) })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        let stale = try snapshot(["1"])
        delegate.receive(stale)
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        let menu = delegate.notificationsMenu()
        XCTAssertEqual((menu.items[1].representedObject as? GitHubNotification)?.id, "1")

        menu.performActionForItem(at: 1)

        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://github.com/owner/repo"])
        XCTAssertEqual(delegate.statusItem.button?.title, "")
        XCTAssertEqual(delegate.statusItem.button?.toolTip, "No unread notifications")
        XCTAssertEqual(delegate.statusItem.button?.image?.accessibilityDescription, "bell")
        XCTAssertFalse(delegate.notificationsMenu().items.contains { $0.representedObject is GitHubNotification })
        let task = try XCTUnwrap(delegate.notificationReadTasks["1"])
        let request = await transport.waitForRequest()
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/notifications/threads/1")

        // A check already in flight must not bring the opened thread back.
        delegate.receive(stale)
        XCTAssertEqual(delegate.statusItem.button?.title, "")
        await transport.finish()
        await task.value
        delegate.receive(stale)
        XCTAssertEqual(delegate.statusItem.button?.title, "")

        // A later check can show genuinely new unread activity on the same thread.
        delegate.receive(try snapshot([], checkedAt: Date().addingTimeInterval(1)))
        delegate.receive(try snapshot(["1"], checkedAt: Date().addingTimeInterval(2)))
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
    }

    @MainActor
    func testClickOnlyRemovesSelectedThreadAndUpdatesRepositoryCount() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let delegate = AppDelegate(client: GitHubClient(transport: transport), openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        delegate.receive(try snapshot(["1", "2"]))
        let menu = delegate.notificationsMenu()
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 1)

        XCTAssertEqual(delegate.notificationReadTasks.count, 1)
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        XCTAssertEqual(delegate.statusItem.button?.toolTip, "owner/repo (1)")
        let remaining = delegate.notificationsMenu()
        XCTAssertEqual(remaining.items[0].title, "owner/repo (1)")
        XCTAssertEqual(remaining.items.compactMap { ($0.representedObject as? GitHubNotification)?.id }, ["2"])

        let task = try XCTUnwrap(delegate.notificationReadTasks["1"])
        _ = await transport.waitForRequest()
        await transport.finish()
        await task.value
        XCTAssertTrue(delegate.notificationReadTasks.isEmpty)
    }

    @MainActor
    func testFailedWriteRestoresNotificationAndCounter() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let delegate = AppDelegate(client: GitHubClient(transport: transport), openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        delegate.receive(try snapshot(["1"]))
        delegate.notificationsMenu().performActionForItem(at: 1)
        XCTAssertEqual(delegate.statusItem.button?.title, "")

        let task = try XCTUnwrap(delegate.notificationReadTasks["1"])
        _ = await transport.waitForRequest()
        await transport.finish(status: 403)
        await task.value

        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        XCTAssertTrue(delegate.statusItem.button?.toolTip?.contains("Could not mark notification as read") == true)
        XCTAssertEqual(delegate.notificationsMenu().items.compactMap {
            ($0.representedObject as? GitHubNotification)?.id
        }, ["1"])
        XCTAssertTrue(delegate.notificationReadTasks.isEmpty)
    }
}
