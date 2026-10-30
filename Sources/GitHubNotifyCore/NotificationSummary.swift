import Foundation

public struct GitHubNotification: Decodable, Equatable, Sendable {
    public struct Repository: Decodable, Equatable, Sendable {
        public let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    public struct Subject: Decodable, Equatable, Sendable {
        public let title: String
        public let type: String
        public let url: URL?
    }

    public let id: String
    public let repository: Repository
    public let subject: Subject?

    public init(id: String, repository: Repository, subject: Subject? = nil) {
        self.id = id
        self.repository = repository
        self.subject = subject
    }

    public var title: String {
        let text = subject?.title.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return text.isEmpty ? "Notification" : text
    }

    public var browserURL: URL? {
        let parts = repository.fullName.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        let repositoryURL = URL(string: "https://github.com")!.appendingPathComponent(repository.fullName)
        guard let url = subject?.url, url.scheme == "https", url.host == "api.github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
            return repositoryURL
        }
        let path = url.path.split(separator: "/")
        guard path.count == 5, path[0] == "repos",
              path[1].lowercased() == parts[0].lowercased(), path[2].lowercased() == parts[1].lowercased() else {
            return repositoryURL
        }
        let identifier = String(path[4])
        switch path[3] {
        case "issues", "pulls", "discussions":
            guard identifier.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(identifier), number > 0 else {
                return repositoryURL
            }
            let route = path[3] == "pulls" ? "pull" : String(path[3])
            return repositoryURL.appendingPathComponent("\(route)/\(identifier)")
        case "commits":
            guard (7...64).contains(identifier.count), identifier.allSatisfy(\.isHexDigit) else { return repositoryURL }
            return repositoryURL.appendingPathComponent("commit/\(identifier)")
        case "releases": return repositoryURL.appendingPathComponent("releases")
        case "check-suites": return repositoryURL.appendingPathComponent("actions")
        default: return repositoryURL
        }
    }
}

public struct NotificationSummary: Sendable {
    public let repositories: [String: Int]
    public let visibleRepositories: [String: Int]
    public let visibleNotifications: [GitHubNotification]
    public let favoriteCount: Int
    public var count: Int { visibleRepositories.values.reduce(0, +) }

    public init(notifications: [GitHubNotification], settings: Settings, accountLogin: String? = nil) {
        let patterns = settings.favoriteRepos.filter { !$0.isEmpty }
            .compactMap { try? Settings.favoriteExpression(for: $0) }
        var repositories: [String: Int] = [:]
        for notification in notifications {
            repositories[notification.repository.fullName, default: 0] += 1
        }
        let favorites = repositories.filter { name, _ in
            let range = NSRange(name.startIndex..., in: name)
            return patterns.contains { $0.firstMatch(in: name, range: range) != nil }
        }
        self.repositories = repositories
        let visibleRepositories: [String: Int]
        switch settings.filtersMode {
        case .all: visibleRepositories = repositories
        case .favorite: visibleRepositories = favorites
        case .owned:
            visibleRepositories = repositories.filter { name, _ in
                guard let accountLogin, !accountLogin.isEmpty else { return false }
                let parts = name.split(separator: "/", omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[1].isEmpty && parts[0].lowercased() == accountLogin.lowercased()
            }
        }
        self.visibleRepositories = visibleRepositories
        visibleNotifications = notifications.filter { visibleRepositories[$0.repository.fullName] != nil }
        favoriteCount = favorites.filter { visibleRepositories[$0.key] != nil }.values.reduce(0, +)
        self.settings = settings
    }

    private let settings: Settings

    public var title: String {
        guard count > 0 else { return "0" }
        let favorites = settings.filtersMode == .favorite ? 0 : favoriteCount
        var title = String(count)
        if favorites > 0 {
            title = favorites == count ? "[\(favorites)]" : "[\(favorites)]/\(count)"
        }
        if (visibleRepositories.count > 1 && count != visibleRepositories.count) || favorites > 0 {
            title += "/\(visibleRepositories.count)"
        }
        return title
    }

    public var tooltip: String {
        guard count > 0 else { return "No unread notifications" }
        return visibleRepositories.keys.sorted()
            .map { "\($0) (\(visibleRepositories[$0]!))" }.joined(separator: "\n")
    }
}
