import Foundation
import XCTest
@testable import GitHubNotifyCore

final class SettingsTests: XCTestCase {
    func testMissingSettingsUseDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = try SettingsStore(url: url).load()
        XCTAssertEqual(settings, Settings())
        XCTAssertEqual(settings.pollInterval, 30)
        XCTAssertTrue(settings.notifyStars)
        XCTAssertTrue(settings.notifyIssues)
        XCTAssertTrue(settings.notifyIssueComments)
        XCTAssertTrue(settings.notifyForks)
        XCTAssertTrue(settings.notifyPullRequests)
        XCTAssertTrue(settings.notifyPullRequestComments)
        XCTAssertTrue(settings.notifyWorkflowFailures)
    }

    func testLegacySettingsKeepPreferencesButNeverPersistToken() throws {
        let legacy = Data(#"{"githubToken":"legacy-encrypted-secret","updateFrequency":"120s","favoriteRepos":["^owner/"],"filtersMode":"favorite","autoStart":true}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertEqual(settings.favoriteRepos, ["^owner/"])
        XCTAssertEqual(settings.filtersMode, .favorite)
        XCTAssertTrue(settings.autoStart)
        XCTAssertEqual(settings.pollInterval, 120)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("githubToken"))
        XCTAssertFalse(encoded.contains("secret"))
    }

    func testPartialAndNullSettingsUseDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"favoriteRepos":null,"filtersMode":"unknown"}"#.utf8))
        XCTAssertEqual(settings, Settings())
    }

    func testDurationsAreParsedAndBounded() {
        for (duration, expected) in [
            ("10s", 10.0), ("1m30s", 90), ("1.5m", 90), ("100ms", 10),
            ("0s", 30), ("-1s", 30), ("garbage30s", 30), ("", 30), ("48h", 86400),
        ] {
            var settings = Settings()
            settings.updateFrequency = duration
            XCTAssertEqual(settings.pollInterval, expected, duration)
        }
    }

    func testFavoritesRemoveBlankAndDuplicatePatterns() {
        XCTAssertEqual(Settings.parseFavorites("owner/repo, ;\n^org/; owner/repo\n"), ["owner/repo", "^org/"])
    }

    func testInvalidPatternsAreRejected() {
        var settings = Settings()
        settings.favoriteRepos = ["["]
        XCTAssertThrowsError(try settings.validate())
    }

    func testWildcardFavoritesAreParsedAndValidated() throws {
        var settings = Settings()
        settings.favoriteRepos = Settings.parseFavorites("koltyakov/*\nssnitko/varro-*")
        XCTAssertEqual(settings.favoriteRepos, ["koltyakov/*", "ssnitko/varro-*"])
        XCTAssertNoThrow(try settings.validate())
    }

    func testSettingsRoundTripAndPrivatePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        var settings = Settings()
        settings.favoriteRepos = ["^swiftlang/"]
        settings.notifyStars = false
        settings.notifyIssues = false
        settings.notifyIssueComments = false
        settings.notifyForks = false
        settings.notifyPullRequests = false
        settings.notifyPullRequestComments = false
        settings.notifyWorkflowFailures = false
        settings.filtersMode = .owned
        XCTAssertFalse(settings.hasRepositoryAlerts)
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMalformedSettingsAreNotOverwrittenOnLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let data = Data("not json".utf8)
        try data.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), data)
    }

    func testWorkflowFailureToggleMigratesAndCanEnableAlertsIndependently() throws {
        let defaults = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.notifyWorkflowFailures)
        var settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"notifyWorkflowFailures":false}"#.utf8))
        XCTAssertFalse(settings.notifyWorkflowFailures)
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        settings.notifyPullRequests = false
        settings.notifyIssueComments = false
        settings.notifyPullRequestComments = false
        XCTAssertFalse(settings.hasRepositoryAlerts)
        settings.notifyWorkflowFailures = true
        XCTAssertTrue(settings.hasRepositoryAlerts)
    }
}
