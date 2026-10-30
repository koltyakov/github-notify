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

    func testAllFavoritesTitle() throws {
        var settings = Settings()
        settings.favoriteRepos = ["^org/"]
        let summary = NotificationSummary(notifications: try notifications(["org/a", "org/b"]), settings: settings)
        XCTAssertEqual(summary.title, "[2]/2")
    }
}
