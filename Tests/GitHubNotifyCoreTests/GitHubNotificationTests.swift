import Foundation
import XCTest
@testable import GitHubNotifyCore

final class GitHubNotificationTests: XCTestCase {
    private func notification(
        url: String? = nil, type: String = "Issue", title: String = "Fix a bug", repository: String = "owner/repo"
    ) throws -> GitHubNotification {
        var subject: [String: Any] = ["title": title, "type": type]
        if let url { subject["url"] = url }
        return try JSONDecoder().decode(GitHubNotification.self, from: JSONSerialization.data(withJSONObject: [
            "id": "1", "repository": ["full_name": repository], "subject": subject,
        ]))
    }

    func testIssueAndPullRequestSubjectsOpenTheirWebPages() throws {
        let issue = try notification(url: "https://api.github.com/repos/owner/repo/issues/42")
        XCTAssertEqual(issue.title, "Fix a bug")
        XCTAssertEqual(issue.browserURL?.absoluteString, "https://github.com/owner/repo/issues/42")
        let pull = try notification(url: "https://api.github.com/repos/owner/repo/pulls/7", type: "PullRequest")
        XCTAssertEqual(pull.browserURL?.absoluteString, "https://github.com/owner/repo/pull/7")
    }

    func testDiscussionCommitReleaseAndCheckSubjectsHaveWebDestinations() throws {
        for (resource, expected) in [
            ("discussions/3", "discussions/3"), ("commits/abcdef1234567", "commit/abcdef1234567"),
            ("releases/10", "releases"), ("check-suites/12", "actions"),
        ] {
            let entry = try notification(url: "https://api.github.com/repos/owner/repo/\(resource)")
            XCTAssertEqual(entry.browserURL?.absoluteString, "https://github.com/owner/repo/\(expected)")
        }
    }

    func testMissingSubjectAndNullURLRemainCompatible() throws {
        let legacy = try JSONDecoder().decode(GitHubNotification.self, from: Data(#"{"id":"1","repository":{"full_name":"owner/repo"}}"#.utf8))
        XCTAssertNil(legacy.subject)
        XCTAssertEqual(legacy.title, "Notification")
        XCTAssertEqual(legacy.browserURL?.absoluteString, "https://github.com/owner/repo")
        let null = try JSONDecoder().decode(GitHubNotification.self, from: Data(#"{"id":"2","repository":{"full_name":"owner/repo"},"subject":{"title":"Invitation","type":"RepositoryInvitation","url":null}}"#.utf8))
        XCTAssertEqual(null.title, "Invitation")
        XCTAssertEqual(null.browserURL?.absoluteString, "https://github.com/owner/repo")
    }

    func testTitlesAreSingleLineAndEmptyTitlesHaveFallbacks() throws {
        XCTAssertEqual(try notification(title: " A bug\n with\tspaces ").title, "A bug with spaces")
        XCTAssertEqual(try notification(title: " \n ").title, "Notification")
    }

    func testUntrustedSubjectURLsNeverOpenAnotherOriginOrRepository() throws {
        for url in [
            "https://evil.example/repos/owner/repo/issues/42", "http://api.github.com/repos/owner/repo/issues/42",
            "https://api.github.com:444/repos/owner/repo/issues/42", "https://user@api.github.com/repos/owner/repo/issues/42",
            "https://api.github.com/repos/other/repo/issues/42", "https://api.github.com/repos/owner/repo/issues/../42",
            "https://api.github.com/repos/owner/repo/issues/42?redirect=evil", "https://api.github.com/repos/owner/repo/issues/nope",
            "https://api.github.com/repos/owner/repo/issues/0", "https://api.github.com/repos/owner/repo/commits/not-a-sha",
        ] {
            XCTAssertEqual(try notification(url: url).browserURL?.absoluteString, "https://github.com/owner/repo", url)
        }
        for repository in ["../repo", "owner/repo/extra", "owner/repo?redirect=evil", "owner/%2e%2e"] {
            XCTAssertNil(try notification(repository: repository).browserURL)
        }
    }
}
