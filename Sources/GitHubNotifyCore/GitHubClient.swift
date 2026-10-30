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
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !repository.contains("?"), !repository.contains("#"), !repository.contains("%") else {
            throw GitHubError.invalidRepository
        }
        let url = baseURL.appendingPathComponent("repos").appendingPathComponent(repository)
            .appendingPathComponent("notifications")
        var request = request(url: url, token: token)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let timestamp = ISO8601DateFormatter().string(from: date)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["last_read_at": timestamp])
        _ = try await send(request)
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

    private func nextPage(_ link: String?) throws -> URL? {
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
                  url.user == nil, url.password == nil, url.path == "/notifications" else {
                throw GitHubError.invalidResponse
            }
            return url
        }
        return nil
    }
}
