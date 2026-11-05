import AppKit
import XCTest
@testable import GitHubNotify
@testable import GitHubNotifyCore

private actor NotificationReadTransport: HTTPTransport {
    private var request: URLRequest?
    private var requests: [URLRequest] = []
    private var requestWaiter: CheckedContinuation<URLRequest, Never>?
    private var reply: CheckedContinuation<(Data, HTTPURLResponse), any Error>?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        requests.append(request)
        requestWaiter?.resume(returning: request)
        requestWaiter = nil
        return try await withCheckedThrowingContinuation { reply = $0 }
    }

    func receivedRequests() -> [URLRequest] { requests }

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
    private func event(_ id: String = "1", repository: String = "owner/repo") -> RepositoryToast {
        RepositoryToast(
            id: id, repository: repository, title: "CI pipeline failed", body: "Build on main, run #1",
            url: URL(string: "https://github.com/\(repository)/actions/runs/42/attempts/1")!
        )
    }

    @MainActor
    private func activityMonitor(_ events: [RepositoryToast]) throws -> (RepositoryActivityMonitor, RepositoryActivityStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = RepositoryActivityStore(url: directory.appendingPathComponent("activity.json"))
        struct SavedActivity: Encodable {
            let accountID = 1
            let accountLogin = "owner"
            let seenIssues: [String: Date] = [:]
            let unreadActivity: [RepositoryToast]
        }
        let state = try JSONDecoder().decode(
            RepositoryActivityState.self, from: JSONEncoder().encode(SavedActivity(unreadActivity: events))
        )
        try store.save(state)
        return (RepositoryActivityMonitor(store: store), store)
    }

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

    @MainActor
    func testRestoredLocalActivityAppearsWithoutGitHubSnapshotAndDismissesWithoutRequests() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let (monitor, store) = try activityMonitor([event()])
        var openedURLs: [URL] = []
        let delegate = AppDelegate(
            client: GitHubClient(transport: transport), activityMonitor: monitor, openURL: { openedURLs.append($0) }
        )
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        let menu = delegate.notificationsMenu()
        XCTAssertEqual(menu.items[0].title, "owner/repo (1)")
        XCTAssertTrue(menu.items[1].title.hasPrefix("CI pipeline failed"))
        XCTAssertEqual(menu.items[1].toolTip, "owner/repo\nCI pipeline failed\nBuild on main, run #1")
        menu.performActionForItem(at: 1)
        XCTAssertEqual(openedURLs, [event().url])
        XCTAssertEqual(delegate.statusItem.button?.title, "")
        XCTAssertTrue(try XCTUnwrap(store.load()).unreadEvents.isEmpty)
        XCTAssertTrue(delegate.notificationReadTasks.isEmpty)
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
        try monitor.restore()
        XCTAssertFalse(delegate.notificationsMenu().items.contains { $0.representedObject is RepositoryToast })
    }

    @MainActor
    func testLocalClickDoesNotMarkGitHubThreadWithSameIDAsRead() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let (monitor, _) = try activityMonitor([event()])
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor, openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        delegate.receive(try snapshot(["1"]))
        XCTAssertEqual(delegate.statusItem.button?.title, " 2")
        let menu = delegate.notificationsMenu()
        XCTAssertEqual(menu.items[0].title, "owner/repo (2)")
        let localIndex = try XCTUnwrap(menu.items.firstIndex { $0.representedObject is RepositoryToast })
        menu.performActionForItem(at: localIndex)
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        XCTAssertTrue(monitor.state?.unreadEvents.isEmpty == true)
        XCTAssertTrue(delegate.notificationReadTasks.isEmpty)
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(delegate.notificationsMenu().items.compactMap { ($0.representedObject as? GitHubNotification)?.id }, ["1"])
    }

    @MainActor
    func testGitHubClickLeavesLocalActivityWithSameIDUnread() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let (monitor, store) = try activityMonitor([event()])
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor, openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        delegate.receive(try snapshot(["1"]))
        delegate.notificationsMenu().performActionForItem(at: 1)
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        XCTAssertEqual(try store.load()?.unreadEvents, [event()])
        let request = await transport.waitForRequest()
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/notifications/threads/1")
        let task = try XCTUnwrap(delegate.notificationReadTasks["1"])
        await transport.finish()
        await task.value
        XCTAssertEqual(delegate.notificationsMenu().items.compactMap { $0.representedObject as? RepositoryToast }, [event()])
    }

    @MainActor
    func testFailedGitHubWriteRestoresOnlyTheThreadAndLeavesLocalActivityUnread() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let (monitor, store) = try activityMonitor([event()])
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor, openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        delegate.receive(try snapshot(["1"]))
        delegate.notificationsMenu().performActionForItem(at: 1)
        let task = try XCTUnwrap(delegate.notificationReadTasks["1"])
        _ = await transport.waitForRequest()
        await transport.finish(status: 403)
        await task.value
        XCTAssertEqual(delegate.statusItem.button?.title, " 2")
        XCTAssertEqual(try store.load()?.unreadEvents, [event()])
        let menu = delegate.notificationsMenu()
        XCTAssertEqual(menu.items.compactMap { ($0.representedObject as? GitHubNotification)?.id }, ["1"])
        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? RepositoryToast }, [event()])
    }

    @MainActor
    func testLocalOnlyMarkReadDismissesOnlyVisibleEventsWithoutGitHubRequests() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let hidden = event("hidden", repository: "owner/hidden")
        let (monitor, store) = try activityMonitor([event(), hidden])
        var settings = Settings()
        settings.filtersMode = .favorite
        settings.favoriteRepos = ["^owner/repo$"]
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor, settings: settings)
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        delegate.markRead()
        XCTAssertEqual(delegate.statusItem.button?.title, "")
        XCTAssertEqual(try store.load()?.unreadEvents, [hidden])
        XCTAssertNil(delegate.markingTask)
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testMixedMarkReadOnlyTargetsGitHubRepositoriesAndKeepsLaterLocalEvents() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let local = event("local", repository: "owner/local-only")
        let (monitor, store) = try activityMonitor([local])
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor)
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        let snapshot = try snapshot(["1"])
        delegate.receive(snapshot)
        delegate.markRead()
        XCTAssertTrue(try XCTUnwrap(store.load()).unreadEvents.isEmpty)
        let task = try XCTUnwrap(delegate.markingTask)
        let request = await transport.waitForRequest()
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/repos/owner/repo/notifications")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(body["last_read_at"], ISO8601DateFormatter().string(from: snapshot.checkedAt))

        // A check completing while the GitHub write is suspended adds a new local event.
        let account = GitHubAccount(id: 1, login: "owner")
        let repository = OwnedRepository(id: 10, fullName: "owner/local-only", stargazersCount: 0)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try monitor.receive(RepositoryActivitySnapshot(
            account: account, repositories: [repository], issues: [], stargazers: ["10": []], checkedAt: start, pollInterval: 60
        ), settings: Settings())
        try monitor.receive(RepositoryActivitySnapshot(
            account: account, repositories: [repository], issues: [],
            stargazers: ["10": [GitHubAccount(id: 2, login: "someone")]],
            checkedAt: start.addingTimeInterval(60), pollInterval: 60
        ), settings: Settings())
        await transport.finish()
        await task.value
        XCTAssertEqual(try store.load()?.unreadEvents.count, 1)
        XCTAssertEqual(delegate.notificationsMenu().items.compactMap { $0.representedObject as? RepositoryToast }.count, 1)
        let requests = await transport.receivedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testFailedLocalSaveKeepsEventVisibleAndDoesNotCallGitHub() async throws {
        _ = NSApplication.shared
        let transport = NotificationReadTransport()
        let (monitor, store) = try activityMonitor([event()])
        let delegate = AppDelegate(client: GitHubClient(transport: transport), activityMonitor: monitor, openURL: { _ in })
        delegate.buildMenu()
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        try monitor.restore()
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        delegate.notificationsMenu().performActionForItem(at: 1)
        XCTAssertEqual(monitor.state?.unreadEvents, [event()])
        XCTAssertEqual(delegate.statusItem.button?.title, " 1")
        XCTAssertTrue(delegate.statusItem.button?.toolTip?.contains("Could not dismiss activity") == true)
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
    }
}
