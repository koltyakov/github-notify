import Foundation
import XCTest
@testable import GitHubNotifyCore

private actor MockTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = "[]"
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
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
}
