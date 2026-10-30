import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        // Do not follow redirects with a personal access token.
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        return (data, response)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }
}

public struct NotificationSnapshot: Sendable {
    public let notifications: [GitHubNotification]
    public let checkedAt: Date
    public let pollInterval: TimeInterval
}

public enum GitHubError: LocalizedError, Sendable {
    case invalidResponse
    case invalidRepository
    case http(status: Int, retryAfter: TimeInterval?)

    public var isUnauthorized: Bool {
        if case .http(status: 401, retryAfter: _) = self { return true }
        return false
    }

    public var retryAfter: TimeInterval? {
        if case .http(_, let interval) = self { return interval }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case .invalidRepository: return "The repository name must be owner/repository."
        case .http(let status, _):
            switch status {
            case 401: return "GitHub rejected the token. Enter a valid token in Settings."
            case 403: return "GitHub denied access. Check token permissions or wait for the rate limit to reset."
            case 429: return "GitHub's rate limit was reached. Checks will resume automatically."
            default: return "GitHub request failed with HTTP \(status)."
            }
        }
    }
}

public struct GitHubClient: Sendable {
    private let transport: any HTTPTransport
    private let baseURL = URL(string: "https://api.github.com")!

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func notifications(token: String) async throws -> NotificationSnapshot {
        let checkedAt = Date()
        var next: URL? = baseURL.appendingPathComponent("notifications")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        var visited = Set<URL>()
        var seenIDs = Set<String>()
        var notifications: [GitHubNotification] = []
        var pollInterval: TimeInterval = 0
        while let url = next {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { throw GitHubError.invalidResponse }
            let (data, response) = try await send(request(url: url, token: token))
            if let value = response.value(forHTTPHeaderField: "X-Poll-Interval"),
               let seconds = Double(value), seconds.isFinite, seconds > 0 {
                pollInterval = max(pollInterval, seconds)
            }
            let page = try JSONDecoder().decode([GitHubNotification].self, from: data)
            notifications += page.filter { seenIDs.insert($0.id).inserted }
            next = try nextPage(response.value(forHTTPHeaderField: "Link"))
        }
        return NotificationSnapshot(notifications: notifications, checkedAt: checkedAt, pollInterval: pollInterval)
    }

    public func markRead(repository: String, through date: Date, token: String) async throws {
        let url = baseURL.appendingPathComponent(try repositoryPath(repository))
            .appendingPathComponent("notifications")
        var request = request(url: url, token: token)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let timestamp = ISO8601DateFormatter().string(from: date)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["last_read_at": timestamp])
        _ = try await send(request)
    }

    public func account(token: String) async throws -> GitHubAccount {
        let (data, _) = try await send(request(url: baseURL.appendingPathComponent("user"), token: token))
        return try JSONDecoder().decode(GitHubAccount.self, from: data)
    }

    public func repositoryActivity(
        token: String, account: GitHubAccount, issuesSince: Date?, commentsSince: Date? = nil, settings: Settings
    ) async throws -> RepositoryActivitySnapshot {
        let checkedAt = Date()
        var repositories: [OwnedRepository] = []
        var issues: [RepositoryIssue] = []
        var comments: [IssueCommentActivity] = []
        var interval: TimeInterval = 60
        if settings.notifyStars {
            let result: ([OwnedRepository], TimeInterval) = try await pages(
                path: "user/repos", query: [
                    URLQueryItem(name: "affiliation", value: "owner"),
                    URLQueryItem(name: "sort", value: "full_name"),
                ], token: token
            )
            repositories = result.0
            interval = max(interval, result.1)
        }
        let issueDates = [settings.notifyIssues ? issuesSince : nil, settings.notifyIssueComments ? commentsSince : nil]
            .compactMap { $0 }
        if let since = issueDates.min() {
            let result: ([RepositoryIssue], TimeInterval) = try await pages(
                path: "issues", query: [
                    URLQueryItem(name: "filter", value: "all"),
                    URLQueryItem(name: "state", value: "all"),
                    URLQueryItem(name: "owned", value: "true"),
                    URLQueryItem(name: "pulls", value: "false"),
                    URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since.addingTimeInterval(-120))),
                ], token: token
            )
            issues = result.0
            interval = max(interval, result.1)
        }
        if settings.notifyIssueComments, let commentsSince {
            var visitedIssues = Set<Int>()
            for issue in issues where !issue.isPullRequest && issue.comments > 0 {
                guard issue.repository.fullName.split(separator: "/").first?.lowercased() == account.login.lowercased(),
                      issue.number > 0, visitedIssues.insert(issue.id).inserted else { continue }
                let path = try repositoryPath(issue.repository.fullName) + "/issues/\(issue.number)/comments"
                let result: ([RepositoryIssueComment], TimeInterval) = try await pages(
                    path: path, query: [
                        URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: commentsSince.addingTimeInterval(-120))),
                    ], token: token
                )
                comments += result.0.map { IssueCommentActivity(issue: issue, comment: $0) }
                interval = max(interval, result.1)
            }
        }
        return RepositoryActivitySnapshot(
            account: account, repositories: repositories, issues: issues, comments: comments,
            checkedAt: checkedAt, pollInterval: interval
        )
    }

    private func repositoryPath(_ repository: String) throws -> String {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw GitHubError.invalidRepository }
        return "repos/" + repository
    }

    private func pages<Item: Decodable>(
        path: String, query: [URLQueryItem], token: String
    ) async throws -> ([Item], TimeInterval) {
        var next: URL? = baseURL.appendingPathComponent(path)
            .appending(queryItems: query + [URLQueryItem(name: "per_page", value: "100")])
        var visited = Set<URL>()
        var items: [Item] = []
        var interval: TimeInterval = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while let url = next {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { throw GitHubError.invalidResponse }
            let (data, response) = try await send(request(url: url, token: token))
            items += try decoder.decode([Item].self, from: data)
            if let value = response.value(forHTTPHeaderField: "X-Poll-Interval"),
               let seconds = Double(value), seconds.isFinite, seconds > 0 { interval = max(interval, seconds) }
            next = try nextPage(response.value(forHTTPHeaderField: "Link"), path: "/" + path)
        }
        return (items, interval)
    }

    private func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitHub-Notify-macOS", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(result.1.statusCode) else {
            let response = result.1
            var delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if delay == nil, response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
                delay = max(1, reset - Date().timeIntervalSince1970)
            }
            throw GitHubError.http(status: response.statusCode, retryAfter: delay)
        }
        return result
    }

    private func nextPage(_ link: String?, path: String = "/notifications") throws -> URL? {
        guard let link else { return nil }
        for part in link.components(separatedBy: ",") {
            let sections = part.components(separatedBy: ";")
            guard sections.dropFirst().contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
            }) else { continue }
            let target = sections[0].trimmingCharacters(in: .whitespaces)
            guard target.hasPrefix("<"), target.hasSuffix(">"),
                  let url = URL(string: String(target.dropFirst().dropLast())),
                  url.scheme == "https", url.host == baseURL.host, url.port == nil,
                  url.user == nil, url.password == nil, url.path == path else {
                throw GitHubError.invalidResponse
            }
            return url
        }
        return nil
    }
}
