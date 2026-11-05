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
        _ stars: Int = 10, issues: [RepositoryIssue] = [], comments: [IssueCommentActivity] = [],
        workflowRuns: [RepositoryWorkflowRun] = [], stargazers: [GitHubAccount]? = nil, after seconds: Double = 0
    ) -> RepositoryActivitySnapshot {
        RepositoryActivitySnapshot(
            account: account, repositories: [repository(stars)], issues: issues, comments: comments, workflowRuns: workflowRuns,
            stargazers: ["10": stargazers ?? (0..<stars).map { GitHubAccount(id: 1000 + $0, login: "user\($0 + 1)") }],
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

    private func comment(
        _ id: Int = 200, after seconds: Double = 1, issue: RepositoryIssue? = nil,
        body: String = "Thanks!\nThis fixes it.", user: GitHubAccount? = GitHubAccount(id: 2, login: "contributor")
    ) throws -> IssueCommentActivity {
        IssueCommentActivity(
            issue: try issue ?? self.issue(after: -600),
            comment: RepositoryIssueComment(
                id: id, body: body, createdAt: start.addingTimeInterval(seconds),
                user: user
            )
        )
    }

    func testFirstCheckIsSilent() throws {
        var state = RepositoryActivityState(accountID: account.id)
        XCTAssertTrue(state.alerts(for: snapshot(500, issues: [try issue(after: -10)]), settings: Settings()).isEmpty)
        XCTAssertTrue(state.unreadEvents.isEmpty)
        XCTAssertEqual(state.issuesCheckedAt, start)
        XCTAssertTrue(state.alerts(for: snapshot(500, after: 60), settings: Settings()).isEmpty)
    }

    func testUnreadActivityPersistsAndDismissalDoesNotReplayOrResetCheckpoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RepositoryActivityStore(url: directory.appendingPathComponent("activity.json"))
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let next = try snapshot(11, issues: [issue()], workflowRuns: [workflowRun()], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 3)
        XCTAssertEqual(state.unreadEvents, alerts)
        try store.save(state)

        var restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.accountLogin, "owner")
        XCTAssertEqual(restored.unreadEvents, alerts)
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        XCTAssertEqual(restored.unreadEvents, alerts)
        let checkpoint = restored.workflowFailuresCheckedAt
        restored.dismiss(["workflow-failure-300-1"])
        try store.save(restored)
        restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.unreadEvents.map(\.id), alerts.filter { $0.id != "workflow-failure-300-1" }.map(\.id))
        XCTAssertEqual(restored.workflowFailuresCheckedAt, checkpoint)
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        XCTAssertFalse(restored.unreadEvents.contains { $0.id == "workflow-failure-300-1" })

        let later = try snapshot(11, issues: [issue()], workflowRuns: [workflowRun(attempt: 2, after: 61)], after: 120)
        XCTAssertEqual(restored.alerts(for: later, settings: Settings()).map(\.id), ["workflow-failure-300-2"])
        XCTAssertEqual(restored.unreadEvents.count, 3)
    }

    func testLegacyActivityStartsWithEmptyUnreadListAndDisablingAlertsKeepsUnreadEvents() throws {
        var state = try JSONDecoder().decode(
            RepositoryActivityState.self, from: Data(#"{"accountID":1,"seenIssues":{}}"#.utf8)
        )
        XCTAssertTrue(state.unreadEvents.isEmpty)
        XCTAssertNil(state.accountLogin)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let alerts = state.alerts(for: snapshot(11, after: 60), settings: Settings())
        var settings = Settings()
        settings.notifyStars = false
        state.configure(settings)
        XCTAssertEqual(state.unreadEvents, alerts)
        state.dismiss(Set(alerts.map(\.id)))
        XCTAssertTrue(state.unreadEvents.isEmpty)
        XCTAssertTrue(state.alerts(for: snapshot(12, after: 120), settings: Settings()).isEmpty)
    }

    func testStarsNameAddedAndRemovedUsersAndLinkToStargazers() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let toast = try XCTUnwrap(state.alerts(for: snapshot(11, after: 60), settings: Settings()).first)
        XCTAssertEqual(toast.repository, "owner/repo")
        XCTAssertEqual(toast.title, "New star")
        XCTAssertEqual(toast.body, "@user11\n11 total stars")
        XCTAssertEqual(toast.url.absoluteString, "https://github.com/owner/repo/stargazers")
        XCTAssertEqual(state.alerts(for: snapshot(9, after: 120), settings: Settings()).first?.title, "2 stars removed")
        XCTAssertEqual(state.alerts(for: snapshot(12, after: 180), settings: Settings()).first?.title, "3 new stars")
    }

    func testStargazerSwapsAtSameCountProduceSeparateNamedAlerts() throws {
        let alice = GitHubAccount(id: 2, login: "alice")
        let bob = GitHubAccount(id: 3, login: "bob")
        var state = RepositoryActivityState(accountID: account.id)
        XCTAssertTrue(state.alerts(for: snapshot(1, stargazers: [alice]), settings: Settings()).isEmpty)
        let next = snapshot(1, stargazers: [bob, bob], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.map(\.title), ["New star", "Star removed"])
        XCTAssertEqual(alerts.map(\.body), ["@bob\n1 total stars", "@alice\n1 total stars"])
        XCTAssertEqual(Set(alerts.map(\.id)).count, 2)
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.stargazers?["10"]?.map(\.login), ["bob"])
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        XCTAssertEqual(restored.alerts(for: snapshot(0, stargazers: [], after: 120), settings: Settings()).first?.body,
                       "@bob\n0 total stars")
    }

    func testStargazerRenamesUpdateSavedLoginWithoutAlerting() {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(1, stargazers: [GitHubAccount(id: 2, login: "old-name")]), settings: Settings())
        XCTAssertTrue(state.alerts(
            for: snapshot(1, stargazers: [GitHubAccount(id: 2, login: "new-name")], after: 60), settings: Settings()
        ).isEmpty)
        XCTAssertEqual(state.stargazers?["10"]?.first?.login, "new-name")
    }

    func testCountOnlyStateMigratesToUserListsSilently() throws {
        let json = Data(#"{"accountID":1,"starCounts":{"10":99},"seenIssues":{}}"#.utf8)
        var state = try JSONDecoder().decode(RepositoryActivityState.self, from: json)
        XCTAssertNil(state.stargazers)
        XCTAssertTrue(state.alerts(for: snapshot(1), settings: Settings()).isEmpty)
        XCTAssertEqual(state.stargazers?["10"]?.map(\.login), ["user1"])
        XCTAssertEqual(state.alerts(for: snapshot(0, after: 60), settings: Settings()).first?.body, "@user1\n0 total stars")
    }

    func testMissingStargazerListKeepsBaselineAndDoesNotBlockOtherAlerts() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(1), settings: Settings())
        let failed = RepositoryActivitySnapshot(
            account: account, repositories: [repository(0)], issues: [try issue()],
            stargazerErrors: ["owner/repo: timeout"], checkedAt: start.addingTimeInterval(60), pollInterval: 60
        )
        XCTAssertEqual(state.alerts(for: failed, settings: Settings()).map(\.title), ["New issue #100"])
        XCTAssertEqual(state.stargazers?["10"]?.map(\.login), ["user1"])
        state = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.alerts(for: snapshot(0, after: 120), settings: Settings()).first?.body, "@user1\n0 total stars")
        XCTAssertTrue(state.alerts(for: snapshot(0, after: 180), settings: Settings()).isEmpty)
    }

    func testDisablingStarsClearsUserListsAndReenablingBaselinesSilently() {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(1), settings: Settings())
        var settings = Settings()
        settings.notifyStars = false
        state.configure(settings)
        XCTAssertNil(state.stargazers)
        XCTAssertTrue(state.alerts(for: snapshot(3, after: 60), settings: settings).isEmpty)
        XCTAssertNil(state.stargazers)
        XCTAssertTrue(state.alerts(for: snapshot(2, after: 120), settings: Settings()).isEmpty)
        XCTAssertEqual(state.stargazers?["10"]?.count, 2)
    }

    func testNewRepositoriesBaselineSilentlyAndRenamesKeepStarHistory() {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let next = RepositoryActivitySnapshot(
            account: account,
            repositories: [repository(11, name: "owner/renamed"), repository(500, id: 20, name: "owner/new")],
            issues: [], stargazers: ["10": snapshot(11).stargazers["10"]!, "20": [GitHubAccount(id: 2, login: "alice")]],
            checkedAt: start.addingTimeInterval(60), pollInterval: 60
        )
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.repository, "owner/renamed")
        XCTAssertEqual(state.stargazers?["20"]?.map(\.login), ["alice"])
        _ = state.alerts(for: snapshot(11, after: 120), settings: Settings())
        XCTAssertNil(state.stargazers?["20"])
    }

    func testNewIssuesExcludePullRequestsOtherOwnersAndOldUpdates() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let issues = try [
            issue(), issue(101, pullRequest: true), issue(102, repository: "other/repo"),
            issue(103, after: -1), issue(),
        ]
        var settings = Settings()
        settings.notifyPullRequests = false
        let alerts = state.alerts(for: snapshot(issues: issues, after: 60), settings: settings)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "New issue #100")
        XCTAssertEqual(alerts.first?.body, "contributor: Something broke")
        XCTAssertEqual(alerts.first?.url.absoluteString, "https://github.com/owner/repo/issues/100")
        XCTAssertTrue(state.alerts(for: snapshot(issues: issues, after: 120), settings: settings).isEmpty)
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
        settings.notifyIssueComments = false
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
                issues: [try issue(repository: name)], stargazers: snapshot(11).stargazers,
                checkedAt: start.addingTimeInterval(60), pollInterval: 60
            )
            XCTAssertTrue(state.alerts(for: next, settings: Settings()).isEmpty, name)
        }
    }

    func testNewCommentsOnExistingIssuesLinkDirectlyToCommentAndDoNotReplay() throws {
        var state = RepositoryActivityState(accountID: account.id)
        let oldComment = try comment(199, after: -1)
        XCTAssertTrue(state.alerts(for: snapshot(comments: [oldComment]), settings: Settings()).isEmpty)
        let newComment = try comment()
        let next = snapshot(comments: [oldComment, newComment, newComment], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "New comment on #100")
        XCTAssertEqual(alerts.first?.body, "contributor: Thanks! This fixes it.")
        XCTAssertEqual(alerts.first?.url.absoluteString, "https://github.com/owner/repo/issues/100#issuecomment-200")
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        _ = restored.alerts(for: snapshot(after: 240), settings: Settings())
        XCTAssertTrue(restored.alerts(for: snapshot(comments: [newComment], after: 600), settings: Settings()).isEmpty)
    }

    func testCommentsExcludePullRequestsAndOtherOwnersAndBoundPreviews() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let comments = try [
            comment(200, issue: issue(pullRequest: true)),
            comment(201, issue: issue(repository: "other/repo")),
            comment(202, body: String(repeating: "x", count: 1000)),
        ]
        var settings = Settings()
        settings.notifyPullRequestComments = false
        let alerts = state.alerts(for: snapshot(comments: comments, after: 60), settings: settings)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.body.count, "contributor: ".count + 240)
    }

    func testOwnCommentsAreExcludedAcrossIssuesPullRequestsAndReviews() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let pull = try issue(101, after: -600, pullRequest: true)
        // Account IDs remain stable even if the author has renamed their login.
        let author = GitHubAccount(id: account.id, login: "previous-login")
        let ownThread = try comment(201, issue: pull, user: author)
        let ownReview = IssueCommentActivity(issue: pull, comment: ownThread.comment, kind: .review)
        let otherThread = try comment(203, issue: pull)
        let otherReview = IssueCommentActivity(issue: pull, comment: otherThread.comment, kind: .review)
        let comments = try [
            comment(200, user: author), ownThread, ownReview,
            comment(202), otherThread, otherReview,
        ]
        let next = snapshot(comments: comments, after: 60)
        XCTAssertEqual(Set(state.alerts(for: next, settings: Settings()).map(\.id)), [
            "comment-202", "pull-comment-203", "pull-comment-review-203",
        ])
        XCTAssertEqual(state.commentsCheckedAt, next.checkedAt)
        XCTAssertEqual(state.pullRequestCommentsCheckedAt, next.checkedAt)
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
    }

    func testCommentsWithoutAuthorsStillProduceAlerts() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let next = snapshot(comments: [try comment(user: nil)], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.body, "Thanks! This fixes it.")
    }

    func testCommentToggleIsIndependentAndRebaselinesWhenEnabled() throws {
        var state = RepositoryActivityState(accountID: account.id)
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyIssues = false
        _ = state.alerts(for: snapshot(), settings: settings)
        XCTAssertEqual(state.alerts(for: snapshot(comments: [try comment()], after: 60), settings: settings).count, 1)
        XCTAssertNil(state.issuesCheckedAt)
        settings.notifyIssueComments = false
        state.configure(settings)
        XCTAssertNil(state.commentsCheckedAt)
        settings.notifyIssueComments = true
        XCTAssertTrue(state.alerts(for: snapshot(comments: [try comment(201, after: 61)], after: 120), settings: settings).isEmpty)
        XCTAssertEqual(state.alerts(for: snapshot(comments: [try comment(202, after: 121)], after: 180), settings: settings).count, 1)
    }

    func testActivityStateFromBeforeCommentSupportMigratesSilently() throws {
        let json = Data(#"{"accountID":1,"starCounts":{"10":10},"issuesCheckedAt":721692800,"issuesStartedAt":721692800,"seenIssues":{}}"#.utf8)
        var state = try JSONDecoder().decode(RepositoryActivityState.self, from: json)
        XCTAssertNil(state.commentsCheckedAt)
        XCTAssertTrue(state.alerts(for: snapshot(comments: [try comment()], after: 60), settings: Settings()).isEmpty)
        XCTAssertEqual(state.commentsCheckedAt, start.addingTimeInterval(60))
    }

    func testForkBaselinesAndNetIncreasesPersistAcrossRestart() throws {
        func forkSnapshot(_ count: Int, after seconds: Double) -> RepositoryActivitySnapshot {
            RepositoryActivitySnapshot(
                account: account, repositories: [OwnedRepository(id: 10, fullName: "owner/repo", stargazersCount: 10, forksCount: count)],
                issues: [], checkedAt: start.addingTimeInterval(seconds), pollInterval: 60
            )
        }
        var state = RepositoryActivityState(accountID: account.id)
        XCTAssertTrue(state.alerts(for: forkSnapshot(5, after: 0), settings: Settings()).isEmpty)
        let alerts = state.alerts(for: forkSnapshot(7, after: 60), settings: Settings())
        XCTAssertEqual(alerts.first?.title, "2 new forks")
        XCTAssertEqual(alerts.first?.url.absoluteString, "https://github.com/owner/repo/forks")
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.alerts(for: forkSnapshot(7, after: 120), settings: Settings()).isEmpty)
        XCTAssertTrue(restored.alerts(for: forkSnapshot(6, after: 180), settings: Settings()).isEmpty)
        XCTAssertEqual(restored.alerts(for: forkSnapshot(7, after: 240), settings: Settings()).first?.title, "New fork")
    }

    func testPullRequestsAndThreadAndReviewCommentsHaveSeparateIdentitiesAndLinks() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let pull = try issue(101, pullRequest: true)
        let thread = try comment(200, issue: pull)
        let review = IssueCommentActivity(issue: pull, comment: thread.comment, kind: .review)
        let next = snapshot(issues: [pull, pull], comments: [thread, review, thread], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 3)
        XCTAssertEqual(alerts[0].title, "New pull request #101")
        XCTAssertEqual(alerts[0].url.absoluteString, "https://github.com/owner/repo/pull/101")
        XCTAssertEqual(Set(alerts.dropFirst().map(\.url.absoluteString)), [
            "https://github.com/owner/repo/pull/101#issuecomment-200",
            "https://github.com/owner/repo/pull/101#discussion_r200",
        ])
        XCTAssertEqual(Set(alerts.map(\.id)).count, 3)
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
    }

    func testNewCategoriesRebaselineWithoutReplayingOldActivity() throws {
        let legacy = Data(#"{"accountID":1,"starCounts":{"10":10},"issuesCheckedAt":721692800,"issuesStartedAt":721692800,"seenIssues":{}}"#.utf8)
        var state = try JSONDecoder().decode(RepositoryActivityState.self, from: legacy)
        let pull = try issue(101, pullRequest: true)
        let next = snapshot(issues: [pull], comments: [try comment(issue: pull)], after: 60)
        XCTAssertTrue(state.alerts(for: next, settings: Settings()).isEmpty)
        var disabled = Settings()
        disabled.notifyForks = false
        disabled.notifyPullRequests = false
        disabled.notifyPullRequestComments = false
        state.configure(disabled)
        XCTAssertNil(state.pullRequestsCheckedAt)
        XCTAssertNil(state.pullRequestCommentsCheckedAt)
        XCTAssertTrue(state.alerts(for: next, settings: Settings()).isEmpty)
    }

    func testAllAlertTypesRejectRepositoriesOwnedBySomeoneElse() throws {
        var state = RepositoryActivityState(accountID: account.id)
        let foreign = try issue(101, repository: "other/repo", pullRequest: true)
        let next = RepositoryActivitySnapshot(
            account: account, repositories: [OwnedRepository(id: 20, fullName: "other/repo", stargazersCount: 10, forksCount: 10)],
            issues: [foreign], comments: [try comment(issue: foreign)], checkedAt: start, pollInterval: 60
        )
        _ = state.alerts(for: next, settings: Settings())
        let changed = RepositoryActivitySnapshot(
            account: account, repositories: [OwnedRepository(id: 20, fullName: "other/repo", stargazersCount: 11, forksCount: 11)],
            issues: [foreign], comments: next.comments, checkedAt: start.addingTimeInterval(60), pollInterval: 60
        )
        XCTAssertTrue(state.alerts(for: changed, settings: Settings()).isEmpty)
    }

    private func workflowRun(
        _ id: Int = 300, attempt: Int = 1, after seconds: Double = 1,
        repository: String = "owner/repo", status: String = "completed", conclusion: String? = "failure"
    ) throws -> RepositoryWorkflowRun {
        let json: [String: Any] = [
            "id": id, "name": "Build", "head_branch": "main", "run_number": 42, "run_attempt": attempt,
            "status": status, "conclusion": conclusion as Any? ?? NSNull(),
            "created_at": "2020-01-01T00:00:00Z",
            "updated_at": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
            "repository": ["full_name": repository],
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RepositoryWorkflowRun.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testWorkflowFailuresBaselineSilentlyThenLinkToFailedAttempt() throws {
        var state = RepositoryActivityState(accountID: account.id)
        XCTAssertTrue(state.alerts(for: snapshot(workflowRuns: [try workflowRun(after: -1)]), settings: Settings()).isEmpty)
        XCTAssertEqual(state.workflowFailuresCheckedAt, start)
        let run = try workflowRun()
        let next = snapshot(workflowRuns: [run, run], after: 60)
        let alerts = state.alerts(for: next, settings: Settings())
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.id, "workflow-failure-300-1")
        XCTAssertEqual(alerts.first?.repository, "owner/repo")
        XCTAssertEqual(alerts.first?.title, "CI pipeline failed")
        XCTAssertEqual(alerts.first?.body, "Build on main, run #42")
        XCTAssertEqual(alerts.first?.url.absoluteString, "https://github.com/owner/repo/actions/runs/300/attempts/1")
        var restored = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.alerts(for: next, settings: Settings()).isEmpty)
        let rerun = try workflowRun(attempt: 2, after: 61)
        XCTAssertEqual(restored.alerts(for: snapshot(workflowRuns: [rerun], after: 120), settings: Settings()).first?.id,
                       "workflow-failure-300-2")
        XCTAssertTrue(restored.alerts(for: snapshot(workflowRuns: [run, rerun], after: 600), settings: Settings()).isEmpty)
    }

    func testWorkflowFailuresIgnoreOtherConclusionsOwnersAndInvalidURLs() throws {
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: Settings())
        let runs = try [
            workflowRun(301, conclusion: "success"), workflowRun(302, conclusion: "cancelled"),
            workflowRun(303, status: "in_progress", conclusion: nil), workflowRun(304, after: -1),
            workflowRun(305, repository: "other/repo"), workflowRun(306, repository: "owner/repo?evil"),
            workflowRun(-1), workflowRun(307, attempt: 0),
        ]
        XCTAssertTrue(state.alerts(for: snapshot(workflowRuns: runs, after: 60), settings: Settings()).isEmpty)
    }

    func testPartialCICheckRetainsBaselineAndDeduplicatesUntilRecovery() throws {
        var state = RepositoryActivityState(accountID: account.id)
        let settings = Settings()
        _ = state.alerts(for: snapshot(), settings: settings)
        let run = try workflowRun()
        for seconds in [60.0, 600.0] {
            let partial = RepositoryActivitySnapshot(
                account: account, repositories: [repository(10)], issues: [], workflowRuns: [run],
                workflowFailureErrors: ["owner/another: The request timed out."],
                checkedAt: start.addingTimeInterval(seconds), pollInterval: 60
            )
            XCTAssertEqual(state.alerts(for: partial, settings: settings).map(\.id), seconds == 60 ? ["workflow-failure-300-1"] : [])
            XCTAssertEqual(state.workflowFailuresCheckedAt, start)
            XCTAssertEqual(state.issuesCheckedAt, partial.checkedAt)
            state = try JSONDecoder().decode(RepositoryActivityState.self, from: JSONEncoder().encode(state))
        }
        let recovered = snapshot(workflowRuns: [run, try workflowRun(301, after: 2)], after: 660)
        XCTAssertEqual(state.alerts(for: recovered, settings: settings).map(\.id), ["workflow-failure-301-1"])
        XCTAssertEqual(state.workflowFailuresCheckedAt, recovered.checkedAt)
    }

    func testWorkflowFailureToggleIsIndependentAndRebaselinesOnEnable() throws {
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        settings.notifyPullRequests = false
        settings.notifyIssueComments = false
        settings.notifyPullRequestComments = false
        settings.filtersMode = .favorite
        settings.favoriteRepos = ["somewhere/else"]
        var state = RepositoryActivityState(accountID: account.id)
        _ = state.alerts(for: snapshot(), settings: settings)
        _ = state.alerts(for: snapshot(after: 60), settings: settings)
        // Delayed results within the overlap are delivered, regardless of the menu filter.
        XCTAssertEqual(state.alerts(for: snapshot(workflowRuns: [try workflowRun(after: 45)], after: 120), settings: settings).count, 1)
        settings.notifyWorkflowFailures = false
        state.configure(settings)
        XCTAssertNil(state.workflowFailuresCheckedAt)
        XCTAssertTrue(state.alerts(for: snapshot(workflowRuns: [try workflowRun(301, after: 121)], after: 180), settings: settings).isEmpty)
        settings.notifyWorkflowFailures = true
        XCTAssertTrue(state.alerts(for: snapshot(workflowRuns: [try workflowRun(301, after: 121)], after: 240), settings: settings).isEmpty)
        XCTAssertEqual(state.alerts(for: snapshot(workflowRuns: [try workflowRun(302, after: 241)], after: 300), settings: settings).count, 1)
    }

    func testWorkflowFailureSupportMigratesExistingActivitySilently() throws {
        let json = Data(#"{"accountID":1,"seenIssues":{}}"#.utf8)
        var state = try JSONDecoder().decode(RepositoryActivityState.self, from: json)
        XCTAssertNil(state.workflowFailuresCheckedAt)
        XCTAssertTrue(state.alerts(for: snapshot(workflowRuns: [try workflowRun()], after: 60), settings: Settings()).isEmpty)
        XCTAssertEqual(state.workflowFailuresCheckedAt, start.addingTimeInterval(60))
    }
}
