import Foundation
import XCTest
@testable import GitHubNotifyCore

final class RepositoryActivityTests: XCTestCase {
    private let account = GitHubAccount(id: 1, login: "owner")
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func repository(_ stars: Int, id: Int = 10, name: String = "owner/repo") -> OwnedRepository {
        OwnedRepository(id: id, fullName: name, stargazersCount: stars)
    }

    private func snapshot(
        _ stars: Int = 10, issues: [RepositoryIssue] = [], after seconds: Double = 0
    ) -> RepositoryActivitySnapshot {
        RepositoryActivitySnapshot(
            account: account, repositories: [repository(stars)], issues: issues,
            checkedAt: start.addingTimeInterval(seconds), pollInterval: 60
        )
    }

    private func issue(
        _ id: Int = 100, after seconds: Double = 1, repository: String = "owner/repo", pullRequest: Bool = false
    ) throws -> RepositoryIssue {
        var json: [String: Any] = [
            "id": id, "number": id, "title": "Something broke", "state": "closed",
            "created_at": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
            "repository": ["full_name": repository], "user": ["id": 2, "login": "contributor"],
        ]
        if pullRequest { json["pull_request"] = ["url": "https://api.github.com/pulls/1"] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RepositoryIssue.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testFirstCheckIsSilent() throws {
        var state = RepositoryActivityState(accountID: account.id)
        XCTAssertTrue(state.alerts(for: snapshot(500, issues: [try issue(after: -10)]), settings: Settings()).isEmpty)
        XCTAssertEqual(state.issuesCheckedAt, start)
        XCTAssertTrue(state.alerts(for: snapshot(500, after: 60), settings: Settings()).isEmpty)
    }

    func testStarsReportOnlyNetIncreasesAndLinkToStargazers() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let toast = try XCTUnwrap(state.alerts(for: snapshot(11, after: 60), settings: Settings()).first)
        XCTAssertEqual(toast.repository, "owner/repo")
        XCTAssertEqual(toast.title, "New star")
        XCTAssertEqual(toast.body, "11 total stars")
        XCTAssertEqual(toast.url.absoluteString, "https://github.com/owner/repo/stargazers")
        XCTAssertTrue(state.alerts(for: snapshot(9, after: 120), settings: Settings()).isEmpty)
        XCTAssertEqual(state.alerts(for: snapshot(12, after: 180), settings: Settings()).first?.title, "3 new stars")
    }

    func testNewRepositoriesBaselineSilentlyAndRenamesKeepStarHistory() {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let next = RepositoryActivitySnapshot(
            account: account,
            repositories: [repository(11, name: "owner/renamed"), repository(500, id: 20, name: "owner/new")],
            issues: [], checkedAt: start.addingTimeInterval(60), pollInterval: 60
        )
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.repository, "owner/renamed")
    }

    func testNewIssuesExcludePullRequestsOtherOwnersAndOldUpdates() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let issues = try [
            issue(), issue(101, pullRequest: true), issue(102, repository: "other/repo"),
            issue(103, after: -1), issue(),
        ]
        let alerts = state.alerts(for: snapshot(issues: issues, after: 60), settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "New issue #100")
        XCTAssertEqual(alerts.first?.body, "contributor: Something broke")
        XCTAssertEqual(alerts.first?.url.absoluteString, "https://github.com/owner/repo/issues/100")
        XCTAssertTrue(state.alerts(for: snapshot(issues: issues, after: 120), settings: Settings()).isEmpty)
    }

    func testDelayedIssueWithinOverlapIsDeliveredOnce() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        _ = state.alerts(for: snapshot(after: 60), settings: Settings())
        let issues = [try issue(after: 45)]
        XCTAssertEqual(state.alerts(for: snapshot(issues: issues, after: 120), settings: Settings()).count, 1)
        XCTAssertTrue(state.alerts(for: snapshot(issues: issues, after: 180), settings: Settings()).isEmpty)
        // Editing the same issue much later must not turn it into a new issue.
        XCTAssertTrue(state.alerts(for: snapshot(issues: issues, after: 600), settings: Settings()).isEmpty)
    }

    func testPersistedBaselinesDoNotReplayAlertsAfterRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RepositoryActivityStore(url: folder.appendingPathComponent("activity.json"))
        XCTAssertNil(try store.load())
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let next = snapshot(11, issues: [try issue()], after: 60)
        XCTAssertEqual(state.alerts(for: next, settings: Settings()).count, 2)
        try store.save(state)
        var restored = try XCTUnwrap(store.load())
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDisabledCategoriesRebaselineOnEnable() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyIssues = false
        state.configure(settings)
        XCTAssertNil(state.issuesCheckedAt)
        XCTAssertTrue(state.alerts(for: snapshot(100, issues: [try issue()], after: 600), settings: Settings()).isEmpty)
        XCTAssertEqual(state.alerts(for: snapshot(101, issues: [try issue(101, after: 601)], after: 660), settings: Settings()).count, 2)
    }

    func testMenuFavoritesFilterDoesNotSuppressOwnedRepositoryAlerts() {
        var state = RepositoryActivityState(accountID: account.id)
        var settings = Settings()
        settings.filtersMode = .favorite
        settings.favoriteRepos = ["^somewhere/else$"]
        _ = state.alerts(for: snapshot(), settings: settings)
        XCTAssertEqual(state.alerts(for: snapshot(11, after: 60), settings: settings).count, 1)
    }

    func testDifferentAccountCannotUsePreviousBaselines() {
        var state = RepositoryActivityState(accountID: 99)
        XCTAssertTrue(state.alerts(for: snapshot(100), settings: Settings()).isEmpty)
        XCTAssertNil(state.issuesCheckedAt)
    }

    func testMalformedRepositoryCannotProduceClickableAlert() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        for name in ["../repo", "owner/repo?redirect=evil", "owner/repo/extra", "owner/%2e%2e"] {
            let next = RepositoryActivitySnapshot(
                account: account, repositories: [repository(11, name: name)],
                issues: [try issue(repository: name)], checkedAt: start.addingTimeInterval(60), pollInterval: 60
            )
            XCTAssertTrue(state.alerts(for: next, settings: Settings()).isEmpty, name)
        }
    }
}
