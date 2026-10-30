import Foundation
import XCTest
@testable import GitHubNotifyCore

final class NotificationSummaryTests: XCTestCase {
    private func notifications(_ repositories: [String]) throws -> [GitHubNotification] {
        let objects = repositories.enumerated().map { index, repo in
            ["id": String(index), "repository": ["full_name": repo]] as [String: Any]
        }
        return try JSONDecoder().decode([GitHubNotification].self, from: JSONSerialization.data(withJSONObject: objects))
    }

    func testEmptySummary() {
        let summary = NotificationSummary(notifications: [], settings: Settings())
        XCTAssertEqual(summary.title, "0")
        XCTAssertEqual(summary.tooltip, "No unread notifications")
    }

    func testCountersAndSortedTooltipMatchOriginalBehavior() throws {
        var settings = Settings()
        settings.favoriteRepos = ["^org/", "org/favorite"]
        let summary = NotificationSummary(
            notifications: try notifications(["zzz/repo", "org/favorite", "org/favorite"]), settings: settings
        )
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.favoriteCount, 2)
        XCTAssertEqual(summary.title, "[2]/3/2")
        XCTAssertEqual(summary.tooltip, "org/favorite (2)\nzzz/repo (1)")
    }

    func testFavoriteFilterOnlyExposesFavoriteRepositoriesForMarkingRead() throws {
        var settings = Settings()
        settings.favoriteRepos = ["^org/"]
        settings.filtersMode = .favorite
        let summary = NotificationSummary(
            notifications: try notifications(["org/one", "org/one", "other/two"]), settings: settings
        )
        XCTAssertEqual(summary.visibleRepositories, ["org/one": 2])
        XCTAssertEqual(summary.visibleNotifications.map(\.repository.fullName), ["org/one", "org/one"])
        XCTAssertEqual(summary.title, "2")
        XCTAssertEqual(summary.tooltip, "org/one (2)")
    }

    func testEmptyAndInvalidPatternsDoNotMatchEveryRepository() throws {
        var settings = Settings()
        settings.favoriteRepos = ["", "["]
        settings.filtersMode = .favorite
        let summary = NotificationSummary(notifications: try notifications(["org/one"]), settings: settings)
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(summary.title, "0")
    }

    func testWildcardFavoritesMatchOwnersAndRepositoryPrefixes() throws {
        var settings = Settings()
        settings.favoriteRepos = ["koltyakov/*", "ssnitko/varro-*"]
        settings.filtersMode = .favorite
        let summary = NotificationSummary(
            notifications: try notifications([
                "koltyakov/github-notify", "koltyakov/another", "ssnitko/varro-app", "ssnitko/varro-app",
                "ssnitko/varro-", "ssnitko/varro", "ssnitko/other", "other/varro-app",
                "notkoltyakov/repo", "other/koltyakov/repo", "ssnitko/varr-app",
            ]), settings: settings
        )
        XCTAssertEqual(summary.visibleRepositories, [
            "koltyakov/github-notify": 1, "koltyakov/another": 1,
            "ssnitko/varro-app": 2, "ssnitko/varro-": 1,
        ])
        XCTAssertEqual(summary.favoriteCount, 5)
    }

    func testWildcardFavoritesEscapeDotsAndMatchTheWholeName() throws {
        var settings = Settings()
        settings.favoriteRepos = ["owner/repo.v*-docs"]
        settings.filtersMode = .favorite
        let summary = NotificationSummary(
            notifications: try notifications([
                "owner/repo.v1-docs", "owner/repoXv1-docs", "owner/repo.v1-docs-extra",
            ]), settings: settings
        )
        XCTAssertEqual(summary.visibleRepositories, ["owner/repo.v1-docs": 1])
    }

    func testExplicitRegularExpressionsKeepTheirMeaning() throws {
        var settings = Settings()
        settings.favoriteRepos = ["^owner/varro-*", "other/repo.*", "^org/(one|two)$"]
        settings.filtersMode = .favorite
        let summary = NotificationSummary(
            notifications: try notifications([
                "owner/varro", "owner/varro---", "other/repository", "org/one", "org/two", "org/three",
            ]), settings: settings
        )
        XCTAssertEqual(summary.visibleRepositories, [
            "owner/varro": 1, "owner/varro---": 1, "other/repository": 1, "org/one": 1, "org/two": 1,
        ])
    }

    func testAllFavoritesTitle() throws {
        var settings = Settings()
        settings.favoriteRepos = ["^org/"]
        let summary = NotificationSummary(notifications: try notifications(["org/a", "org/b"]), settings: settings)
        XCTAssertEqual(summary.title, "[2]/2")
    }

    func testOwnedModeFiltersCountsTooltipsAndMarkReadTargets() throws {
        var settings = Settings()
        settings.filtersMode = .owned
        settings.favoriteRepos = ["^other/"]
        let summary = NotificationSummary(
            notifications: try notifications(["Owner/one", "Owner/one", "owner/two", "other/favorite", "owner-extra/three"]),
            settings: settings, accountLogin: "owner"
        )
        XCTAssertEqual(summary.visibleRepositories, ["Owner/one": 2, "owner/two": 1])
        XCTAssertEqual(summary.visibleNotifications.map(\.repository.fullName), ["Owner/one", "Owner/one", "owner/two"])
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.favoriteCount, 0)
        XCTAssertEqual(summary.title, "3/2")
        XCTAssertEqual(summary.tooltip, "Owner/one (2)\nowner/two (1)")
    }

    func testOwnedModeFailsClosedUntilAccountIsKnown() throws {
        var settings = Settings()
        settings.filtersMode = .owned
        let summary = NotificationSummary(notifications: try notifications(["owner/repo", "other/repo"]), settings: settings)
        XCTAssertEqual(summary.count, 0)
        XCTAssertTrue(summary.visibleRepositories.isEmpty)
        XCTAssertTrue(summary.visibleNotifications.isEmpty)
    }
}
