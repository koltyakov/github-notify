import Foundation
import XCTest
@testable import GitHubNotifyCore

private actor MockTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = "[]"
        var error: (any Error)?
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        if let error = reply.error { throw error }
        return (Data(reply.body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers
        )!)
    }
}

@MainActor
final class GitHubClientTests: XCTestCase {
    func testPaginationAuthenticationDeduplicationAndPollingHint() async throws {
        let transport = MockTransport([
            .init(headers: ["X-Poll-Interval": "60", "Link": "<https://api.github.com/notifications?per_page=100&page=2>; rel=\"next\""],
                  body: #"[{"id":"1","repository":{"full_name":"org/a"}}]"#),
            .init(body: #"[{"id":"1","repository":{"full_name":"org/a"}},{"id":"2","repository":{"full_name":"org/b"}}]"#),
        ])
        let start = Date()
        let snapshot = try await GitHubClient(transport: transport).notifications(token: "test-token")
        XCTAssertEqual(snapshot.notifications.count, 2)
        XCTAssertEqual(snapshot.pollInterval, 60)
        XCTAssertGreaterThanOrEqual(snapshot.checkedAt, start)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.query, "per_page=100")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testNotificationSubjectsAreDecodedWithoutAdditionalRequests() async throws {
        let transport = MockTransport([.init(body: #"[{"id":"1","repository":{"full_name":"owner/repo"},"subject":{"title":"A bug","type":"Issue","url":"https://api.github.com/repos/owner/repo/issues/42"}},{"id":"2","repository":{"full_name":"owner/repo"},"subject":{"title":"A fix","type":"PullRequest","url":"https://api.github.com/repos/owner/repo/pulls/7"}}]"#)])
        let snapshot = try await GitHubClient(transport: transport).notifications(token: "test")
        XCTAssertEqual(snapshot.notifications.map(\.title), ["A bug", "A fix"])
        XCTAssertEqual(snapshot.notifications.map(\.browserURL?.absoluteString), [
            "https://github.com/owner/repo/issues/42", "https://github.com/owner/repo/pull/7",
        ])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPaginationNeverSendsTokenToAnotherOrigin() async throws {
        for target in ["https://example.com/notifications?page=2", "http://api.github.com/notifications?page=2", "https://api.github.com/repos", "https://api.github.com:444/notifications"] {
            let transport = MockTransport([.init(headers: ["Link": "<\(target)>; rel=\"next\""])])
            do {
                _ = try await GitHubClient(transport: transport).notifications(token: "secret")
                XCTFail("Should reject \(target)")
            } catch GitHubError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testPaginationCyclesAreRejected() async throws {
        let transport = MockTransport([.init(headers: ["Link": "<https://api.github.com/notifications?per_page=100>; rel=\"next\""])])
        do {
            _ = try await GitHubClient(transport: transport).notifications(token: "secret")
            XCTFail("Should reject cyclic pagination")
        } catch GitHubError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnauthorizedAndRateLimitErrors() async throws {
        for status in [401, 403, 429, 500] {
            let transport = MockTransport([.init(status: status, headers: ["Retry-After": "120"])])
            do {
                _ = try await GitHubClient(transport: transport).notifications(token: "secret")
                XCTFail("Should fail HTTP \(status)")
            } catch let error as GitHubError {
                XCTAssertEqual(error.isUnauthorized, status == 401)
                XCTAssertEqual(error.retryAfter, 120)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testRateLimitResetHeader() async throws {
        let reset = Date().addingTimeInterval(600).timeIntervalSince1970
        let transport = MockTransport([.init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(reset)])])
        do {
            _ = try await GitHubClient(transport: transport).notifications(token: "secret")
            XCTFail("Should fail rate limit")
        } catch let error as GitHubError {
            XCTAssertGreaterThan(error.retryAfter ?? 0, 590)
        }
    }

    func testMarkReadUsesSnapshotTimeAndRepositoryEndpoint() async throws {
        let transport = MockTransport([.init(status: 205, body: "")])
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try await GitHubClient(transport: transport).markRead(repository: "org/repo", through: date, token: "test")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/org/repo/notifications")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(body["last_read_at"], "2020-09-13T12:26:40Z")
    }

    func testInvalidRepositoriesNeverMakeRequests() async {
        let transport = MockTransport([])
        for repository in ["invalid", "owner/repo/extra", "/repo", "owner/", "../repo", "owner/repo?x=y", "owner/%2e%2e"] {
            do {
                try await GitHubClient(transport: transport).markRead(repository: repository, through: Date(), token: "test")
                XCTFail("Should reject \(repository)")
            } catch GitHubError.invalidRepository {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMarkNotificationReadUsesThreadEndpoint() async throws {
        let transport = MockTransport([.init(status: 205, body: "")])
        try await GitHubClient(transport: transport).markRead(notificationID: "12345", token: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/notifications/threads/12345")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        XCTAssertNil(request.httpBody)
    }

    func testInvalidNotificationIDsNeverMakeRequests() async {
        let transport = MockTransport([])
        for id in ["", "../1", "1/2", "1?x=y", "1#fragment", "abc", "１２３"] {
            do {
                try await GitHubClient(transport: transport).markRead(notificationID: id, token: "test")
                XCTFail("Should reject \(id)")
            } catch GitHubError.invalidNotificationID {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMarkNotificationReadReportsFailureWithoutRetrying() async {
        let transport = MockTransport([.init(status: 403)])
        do {
            try await GitHubClient(transport: transport).markRead(notificationID: "12345", token: "test")
            XCTFail("Should report the failed write")
        } catch GitHubError.http(status: 403, retryAfter: _) {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMalformedJSONFails() async {
        let transport = MockTransport([.init(body: "invalid")])
        do {
            _ = try await GitHubClient(transport: transport).notifications(token: "test")
            XCTFail("Should reject malformed JSON")
        } catch is DecodingError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationStopsBeforeNetworkRequest() async {
        let transport = MockTransport([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitHubClient(transport: transport).notifications(token: "test")
        }
        do {
            _ = try await task.value
            XCTFail("Should cancel")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testActivityFetchesOwnedRepositoriesWithPaginationAndPollingHints() async throws {
        let transport = MockTransport([
            .init(body: #"{"id":1,"login":"owner"}"#),
            .init(headers: ["X-Poll-Interval": "120", "Link": "<https://api.github.com/user/repos?page=2>; rel=\"next\""],
                  body: #"[{"id":10,"full_name":"owner/one","stargazers_count":3}]"#),
            .init(body: #"[{"id":20,"full_name":"owner/two","stargazers_count":8}]"#),
        ])
        let client = GitHubClient(transport: transport)
        let account = try await client.account(token: "test")
        let snapshot = try await client.repositoryActivity(token: "test", account: account, issuesSince: nil, settings: Settings())
        XCTAssertEqual(snapshot.repositories.map(\.stargazersCount), [3, 8])
        XCTAssertEqual(snapshot.pollInterval, 120)
        XCTAssertTrue(snapshot.issues.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/user")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "affiliation", value: "owner")) == true)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer test")
    }

    func testActivityQueriesAllIssueStatesWithOverlapAndPagination() async throws {
        let body = #"[{"id":100,"number":3,"title":"A bug","created_at":"2023-11-14T22:13:21Z","repository":{"full_name":"owner/repo"},"user":null}]"#
        let transport = MockTransport([
            .init(headers: ["Link": "<https://api.github.com/issues?page=2>; rel=\"next\""], body: body),
            .init(body: "[]"),
        ])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        let snapshot = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"),
            issuesSince: Date(timeIntervalSince1970: 1_700_000_000), settings: settings
        )
        XCTAssertEqual(snapshot.issues.first?.title, "A bug")
        XCTAssertEqual(snapshot.pollInterval, 60)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "filter", value: "all")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "state", value: "all")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "since", value: "2023-11-14T22:11:20Z")))
    }

    func testActivityPaginationRejectsForeignOriginsWrongPathsAndCycles() async {
        for target in [
            "https://example.com/user/repos?page=2", "https://api.github.com/notifications?page=2",
            "https://api.github.com/user/repos?affiliation=owner&sort=full_name&per_page=100",
        ] {
            let transport = MockTransport([.init(headers: ["Link": "<\(target)>; rel=\"next\""])])
            do {
                _ = try await GitHubClient(transport: transport).repositoryActivity(
                    token: "secret", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil, settings: Settings()
                )
                XCTFail("Should reject \(target)")
            } catch GitHubError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testDisabledActivityMakesNoRequests() async throws {
        let transport = MockTransport([])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        settings.notifyIssueComments = false
        settings.notifyPullRequests = false
        settings.notifyPullRequestComments = false
        settings.notifyWorkflowFailures = false
        _ = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: Date(),
            workflowFailuresSince: Date(), settings: settings
        )
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCommentsOnChangedOwnedIssuesAreFetchedEvenWithNewIssuesDisabled() async throws {
        let transport = MockTransport([
            .init(body: #"[{"id":100,"number":3,"title":"Old bug","comments":2,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"},"user":null},{"id":101,"number":4,"title":"PR","comments":1,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"},"pull_request":{},"user":null},{"id":102,"number":5,"title":"Other","comments":1,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"other/repo"},"user":null}]"#),
            .init(headers: ["X-Poll-Interval": "180", "Link": "<https://api.github.com/repos/owner/repo/issues/3/comments?page=2>; rel=\"next\""],
                  body: #"[{"id":200,"body":"Thanks","created_at":"2023-11-14T22:13:21Z","user":{"id":2,"login":"reader"}}]"#),
            .init(body: #"[{"id":201,"body":null,"created_at":"2023-11-14T22:13:22Z","user":null}]"#),
        ])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            commentsSince: Date(timeIntervalSince1970: 1_700_000_000), settings: settings
        )
        XCTAssertEqual(result.comments.map(\.comment.id), [200, 201])
        XCTAssertEqual(result.comments.first?.issue.number, 3)
        XCTAssertEqual(result.pollInterval, 180)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/repos/owner/repo/issues/3/comments")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "since", value: "2023-11-14T22:11:20Z")))
    }

    func testCommentPaginationCannotSendTokenToAnotherOrigin() async {
        let transport = MockTransport([
            .init(body: #"[{"id":100,"number":3,"title":"Bug","comments":1,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"},"user":null}]"#),
            .init(headers: ["Link": "<https://example.com/comments?page=2>; rel=\"next\""]),
        ])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        do {
            _ = try await GitHubClient(transport: transport).repositoryActivity(
                token: "secret", account: GitHubAccount(id: 1, login: "owner"), issuesSince: Date(),
                commentsSince: Date(), settings: settings
            )
            XCTFail("Should reject foreign comment pagination")
        } catch GitHubError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testForkOnlyPollingFetchesOwnedRepositoryCounts() async throws {
        let transport = MockTransport([.init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5,"forks_count":3},{"id":20,"full_name":"other/repo","stargazers_count":8,"forks_count":4}]"#)])
        var settings = Settings()
        settings.notifyStars = false
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil, settings: settings
        )
        XCTAssertEqual(result.repositories.count, 1)
        XCTAssertEqual(result.repositories.first?.forksCount, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPullRequestConversationAndInlineCommentsUseTheirRespectiveEndpoints() async throws {
        let transport = MockTransport([
            .init(body: #"[{"id":100,"number":3,"title":"A fix","comments":1,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"},"pull_request":{},"user":null}]"#),
            .init(body: #"[{"id":200,"body":"Thanks","created_at":"2023-11-14T22:13:21Z","user":null}]"#),
            .init(headers: ["X-Poll-Interval": "180", "Link": "<https://api.github.com/repos/owner/repo/pulls/3/comments?page=2>; rel=\"next\""],
                  body: #"[{"id":200,"body":"Change this line","created_at":"2023-11-14T22:13:21Z","user":null}]"#),
            .init(body: "[]"),
        ])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssueComments = false
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            pullRequestsSince: since, pullRequestCommentsSince: since, settings: settings
        )
        XCTAssertEqual(result.comments.map(\.kind), [.thread, .review])
        XCTAssertEqual(result.pollInterval, 180)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url?.path, "/repos/owner/repo/issues/3/comments")
        XCTAssertEqual(requests[2].url?.path, "/repos/owner/repo/pulls/3/comments")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "pulls", value: "true")))
    }

    func testInlineCommentsAreCheckedEvenWhenPullRequestHasNoConversationComments() async throws {
        let transport = MockTransport([
            .init(body: #"[{"id":100,"number":3,"title":"A fix","comments":0,"created_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"},"pull_request":{},"user":null}]"#),
            .init(headers: ["Link": "<https://example.com/comments?page=2>; rel=\"next\""]),
        ])
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        do {
            _ = try await GitHubClient(transport: transport).repositoryActivity(
                token: "secret", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
                pullRequestCommentsSince: Date(), settings: settings
            )
            XCTFail("Should reject foreign inline-comment pagination")
        } catch GitHubError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.path, "/repos/owner/repo/pulls/3/comments")
    }

    private func workflowOnlySettings() -> Settings {
        var settings = Settings()
        settings.notifyStars = false
        settings.notifyForks = false
        settings.notifyIssues = false
        settings.notifyPullRequests = false
        settings.notifyIssueComments = false
        settings.notifyPullRequestComments = false
        return settings
    }

    func testWorkflowFailurePollingUsesOwnedRepositoriesWrappedPagesAndUpdateTimes() async throws {
        let transport = MockTransport([
            .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5},{"id":10,"full_name":"owner/repo","stargazers_count":5},{"id":20,"full_name":"other/repo","stargazers_count":8}]"#),
            .init(headers: ["X-Poll-Interval": "180", "Link": "<https://api.github.com/repos/owner/repo/actions/runs?page=2&status=failure>; rel=\"next\""],
                  body: #"{"workflow_runs":[{"id":300,"name":"Build","head_branch":null,"run_number":42,"status":"completed","conclusion":"failure","created_at":"2020-01-01T00:00:00Z","updated_at":"2023-11-14T22:13:21Z","repository":{"full_name":"owner/repo"}}]}"#),
            .init(body: #"{"workflow_runs":[{"id":299,"run_number":41,"run_attempt":2,"status":"completed","conclusion":"failure","updated_at":"2020-01-01T00:00:00Z","repository":{"full_name":"owner/repo"}},{"id":301,"run_number":43,"status":"completed","conclusion":"failure","updated_at":"2023-11-14T22:13:21Z","repository":{"full_name":"owner/another"}}]}"#),
        ])
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            workflowFailuresSince: Date(timeIntervalSince1970: 1_700_000_000), settings: workflowOnlySettings()
        )
        XCTAssertEqual(result.workflowRuns.map(\.id), [300])
        XCTAssertEqual(result.workflowRuns.first?.runAttempt, 1)
        XCTAssertNil(result.workflowRuns.first?.headBranch)
        XCTAssertEqual(result.pollInterval, 180)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/repos/owner/repo/actions/runs")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "status", value: "failure")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "per_page", value: "100")))
        // Creation-time filtering would miss long-running workflows and reruns.
        XCTAssertFalse(query.contains { $0.name == "created" })
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer test")
    }

    func testWorkflowFailureBaselineAndDisabledToggleMakeNoRequests() async throws {
        let transport = MockTransport([])
        let client = GitHubClient(transport: transport)
        var settings = workflowOnlySettings()
        _ = try await client.repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil, settings: settings
        )
        settings.notifyWorkflowFailures = false
        _ = try await client.repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            workflowFailuresSince: Date(), settings: settings
        )
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testWorkflowPaginationAcceptsMatchingRepositoryIDAcrossMultiplePages() async throws {
        let firstPage = "https://api.github.com/repositories/10/actions/runs?status=failure&per_page=100&page=2"
        let secondPage = "https://api.github.com/repositories/10/actions/runs?status=failure&per_page=100&page=3"
        let transport = MockTransport([
            .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5}]"#),
            .init(headers: ["Link": "<\(firstPage)>; rel=\"next\""], body: #"{"workflow_runs":[]}"#),
            .init(headers: ["Link": "<\(secondPage)>; rel=\"next\"", "X-Poll-Interval": "180"],
                  body: #"{"workflow_runs":[{"id":300,"run_number":42,"status":"completed","conclusion":"failure","updated_at":"2023-11-14T22:13:21Z","repository":{"full_name":"owner/repo"}}]}"#),
            .init(body: #"{"workflow_runs":[{"id":301,"run_number":43,"status":"completed","conclusion":"failure","updated_at":"2023-11-14T22:13:22Z","repository":{"full_name":"owner/repo"}}]}"#),
        ])
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            workflowFailuresSince: Date(timeIntervalSince1970: 1_700_000_000), settings: workflowOnlySettings()
        )
        XCTAssertEqual(result.workflowRuns.map(\.id), [300, 301])
        XCTAssertTrue(result.workflowFailureErrors.isEmpty)
        XCTAssertEqual(result.pollInterval, 180)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }.suffix(2), [firstPage, secondPage])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test" })
    }

    func testWorkflowPaginationRejectsUnsafeLinksAndCycles() async throws {
        for target in [
            "https://example.com/repos/owner/repo/actions/runs?page=2",
            "https://api.github.com/repos/owner/another/actions/runs?page=2",
            "https://api.github.com/repos/owner/repo/actions/runs?status=failure&per_page=100",
            "https://example.com/repositories/10/actions/runs?page=2",
            "http://api.github.com/repositories/10/actions/runs?page=2",
            "https://api.github.com:444/repositories/10/actions/runs?page=2",
            "https://user:password@api.github.com/repositories/10/actions/runs?page=2",
            "https://api.github.com/repositories/20/actions/runs?page=2",
            "https://api.github.com/repositories/10/issues?page=2",
        ] {
            let transport = MockTransport([
                .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5}]"#),
                .init(headers: ["Link": "<\(target)>; rel=\"next\""], body: #"{"workflow_runs":[]}"#),
            ])
            let result = try await GitHubClient(transport: transport).repositoryActivity(
                token: "secret", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
                workflowFailuresSince: Date(), settings: workflowOnlySettings()
            )
            XCTAssertEqual(result.workflowFailureErrors.count, 1, target)
            XCTAssertTrue(result.workflowRuns.isEmpty)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testRepositoryIDPaginationCyclesAreRejected() async throws {
        let link = "<https://api.github.com/repositories/10/actions/runs?page=2>; rel=\"next\""
        let transport = MockTransport([
            .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5}]"#),
            .init(headers: ["Link": link], body: #"{"workflow_runs":[]}"#),
            .init(headers: ["Link": link], body: #"{"workflow_runs":[]}"#),
        ])
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            workflowFailuresSince: Date(), settings: workflowOnlySettings()
        )
        XCTAssertEqual(result.workflowFailureErrors.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testUnavailableActionsDoNotBlockOtherRepositoriesAndRateLimitsDelayPolling() async throws {
        for (status, retryAfter) in [(404, nil), (403, "300"), (429, "300"), (429, nil)] {
            let transport = MockTransport([
                .init(body: #"[{"id":10,"full_name":"owner/one","stargazers_count":5},{"id":20,"full_name":"owner/two","stargazers_count":8}]"#),
                .init(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:]),
                .init(body: #"{"workflow_runs":[]}"#),
            ])
            let result = try await GitHubClient(transport: transport).repositoryActivity(
                token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
                workflowFailuresSince: Date(), settings: workflowOnlySettings()
            )
            XCTAssertEqual(result.workflowFailureErrors.count, status == 404 ? 0 : 1)
            XCTAssertEqual(result.pollInterval, retryAfter == nil ? 60 : 300)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, status == 404 ? 3 : 2)
        }
    }

    func testCIFailuresStillProduceIssueAlertsWithoutAdvancingCIBaseline() async throws {
        let account = GitHubAccount(id: 1, login: "owner")
        let baseline = Date().addingTimeInterval(-60)
        let createdAt = ISO8601DateFormatter().string(from: baseline.addingTimeInterval(30))
        var settings = workflowOnlySettings()
        settings.notifyIssues = true
        for failure in [
            MockTransport.Reply(status: 500),
            .init(status: 401),
            .init(status: 429, headers: ["Retry-After": "300"]),
            .init(body: "invalid"),
            .init(headers: ["Link": "<https://example.com/runs?page=2>; rel=\"next\""], body: #"{"workflow_runs":[]}"#),
            .init(error: URLError(.timedOut)),
        ] {
            var state = RepositoryActivityState(accountID: account.id)
            _ = state.alerts(for: RepositoryActivitySnapshot(
                account: account, repositories: [], issues: [], checkedAt: baseline, pollInterval: 60
            ), settings: settings)
            let transport = MockTransport([
                .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5}]"#),
                .init(body: """
                [{"id":100,"number":3,"title":"New bug","created_at":"\(createdAt)","repository":{"full_name":"owner/repo"}}]
                """),
                failure,
            ])
            let result = try await GitHubClient(transport: transport).repositoryActivity(
                token: "test", account: account, issuesSince: state.issuesCheckedAt,
                workflowFailuresSince: state.workflowFailuresCheckedAt, settings: settings
            )
            XCTAssertEqual(result.workflowFailureErrors.count, 1)
            XCTAssertEqual(state.alerts(for: result, settings: settings).map(\.id), ["issue-100"])
            XCTAssertEqual(state.issuesCheckedAt, result.checkedAt)
            XCTAssertEqual(state.workflowFailuresCheckedAt, baseline)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3)
        }
    }

    func testCIFailureInOneRepositoryDoesNotDiscardOtherRepositoryResults() async throws {
        let transport = MockTransport([
            .init(body: #"[{"id":10,"full_name":"owner/one","stargazers_count":5},{"id":20,"full_name":"owner/two","stargazers_count":8}]"#),
            .init(status: 500),
            .init(body: #"{"workflow_runs":[{"id":300,"run_number":42,"status":"completed","conclusion":"failure","updated_at":"2023-11-14T22:13:21Z","repository":{"full_name":"owner/two"}}]}"#),
        ])
        let result = try await GitHubClient(transport: transport).repositoryActivity(
            token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
            workflowFailuresSince: Date(timeIntervalSince1970: 1_700_000_000), settings: workflowOnlySettings()
        )
        XCTAssertEqual(result.workflowRuns.map(\.id), [300])
        XCTAssertEqual(result.workflowFailureErrors.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCICancellationStillPropagates() async {
        let transport = MockTransport([
            .init(body: #"[{"id":10,"full_name":"owner/repo","stargazers_count":5}]"#),
            .init(error: CancellationError()),
        ])
        do {
            _ = try await GitHubClient(transport: transport).repositoryActivity(
                token: "test", account: GitHubAccount(id: 1, login: "owner"), issuesSince: nil,
                workflowFailuresSince: Date(), settings: workflowOnlySettings()
            )
            XCTFail("Should propagate cancellation, not return a partial snapshot")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }
}
