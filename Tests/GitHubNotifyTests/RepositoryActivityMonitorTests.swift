import Foundation
import XCTest
@testable import GitHubNotify
@testable import GitHubNotifyCore

final class RepositoryActivityMonitorTests: XCTestCase {
    private func snapshot(_ users: [Int], after seconds: Double = 0, accountID: Int = 1) -> RepositoryActivitySnapshot {
        RepositoryActivitySnapshot(
            account: GitHubAccount(id: accountID, login: "owner"),
            repositories: [OwnedRepository(id: 10, fullName: "owner/repo", stargazersCount: users.count)], issues: [],
            stargazers: ["10": users.map { GitHubAccount(id: $0, login: "user\($0)") }],
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds), pollInterval: 60
        )
    }

    private func store() -> RepositoryActivityStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RepositoryActivityStore(url: directory.appendingPathComponent("activity.json"))
    }

    @MainActor
    func testChecksPersistBeforePublishingAndDoNotResurrectDismissedEvents() throws {
        let store = store()
        let monitor = RepositoryActivityMonitor(store: store)
        var published: [[RepositoryToast]] = []
        monitor.onChange = { state in
            // UI updates must only happen after the event and checkpoint are on disk.
            XCTAssertEqual(try? store.load()?.unreadEvents, state?.unreadEvents)
            published.append(state?.unreadEvents ?? [])
        }
        try monitor.restore()
        XCTAssertTrue(try monitor.receive(snapshot([]), settings: Settings()).isEmpty)
        let alerts = try monitor.receive(snapshot([2], after: 60), settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(published.last, alerts)
        try monitor.dismiss(Set(alerts.map(\.id)))
        XCTAssertEqual(published.last, [])

        // The next network result must update the current state, not a copy made before dismissal.
        XCTAssertTrue(try monitor.receive(snapshot([2], after: 120), settings: Settings()).isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.load()).unreadEvents.isEmpty)
        let next = try monitor.receive(snapshot([2, 3], after: 180), settings: Settings())
        XCTAssertEqual(next.count, 1)
        let restored = RepositoryActivityMonitor(store: store)
        try restored.restore()
        XCTAssertEqual(restored.state?.unreadEvents, next)
        XCTAssertTrue(try restored.receive(snapshot([2, 3], after: 240), settings: Settings()).isEmpty)
        XCTAssertEqual(restored.state?.unreadEvents, next)
    }

    @MainActor
    func testChangingAccountsClearsOldUnreadEventsAndEstablishesNewBaseline() throws {
        let monitor = RepositoryActivityMonitor(store: store())
        try monitor.receive(snapshot([]), settings: Settings())
        try monitor.receive(snapshot([2], after: 60), settings: Settings())
        XCTAssertEqual(monitor.state?.unreadEvents.count, 1)
        XCTAssertTrue(try monitor.receive(snapshot([2], after: 120, accountID: 9), settings: Settings()).isEmpty)
        XCTAssertEqual(monitor.state?.accountID, 9)
        XCTAssertTrue(monitor.state?.unreadEvents.isEmpty == true)
    }

    @MainActor
    func testDisabledActivityStillRestoresUnreadEvents() throws {
        let store = store()
        let monitor = RepositoryActivityMonitor(store: store)
        try monitor.receive(snapshot([]), settings: Settings())
        let alerts = try monitor.receive(snapshot([2], after: 60), settings: Settings())
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        settings.notifyPullRequests = false
        settings.notifyIssueComments = false
        settings.notifyPullRequestComments = false
        settings.notifyWorkflowFailures = false
        let restored = RepositoryActivityMonitor(store: store)
        var published: [RepositoryToast] = []
        restored.onChange = { published = $0?.unreadEvents ?? [] }
        restored.start(token: "", settings: settings)
        defer { restored.stop() }
        XCTAssertEqual(published, alerts)
        XCTAssertEqual(restored.state?.unreadEvents, alerts)
        XCTAssertEqual(try store.load()?.unreadEvents, alerts)
    }

    @MainActor
    func testFailedSaveDoesNotPublishEventsOrAdvanceInMemoryBaseline() throws {
        let store = store()
        let monitor = RepositoryActivityMonitor(store: store)
        try monitor.receive(snapshot([]), settings: Settings())
        let checkpoint = monitor.state?.issuesCheckedAt
        var updates = 0
        monitor.onChange = { _ in updates += 1 }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try monitor.receive(snapshot([2], after: 60), settings: Settings()))
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(monitor.state?.unreadEvents.isEmpty == true)
        XCTAssertEqual(monitor.state?.issuesCheckedAt, checkpoint)

        try FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(try monitor.receive(snapshot([2], after: 60), settings: Settings()).count, 1)
    }
}
