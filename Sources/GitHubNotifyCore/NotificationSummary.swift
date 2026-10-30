import Foundation

public struct GitHubNotification: Decodable, Equatable, Sendable {
    public struct Repository: Decodable, Equatable, Sendable {
        public let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    public let id: String
    public let repository: Repository
}

public struct NotificationSummary: Sendable {
    public let repositories: [String: Int]
    public let visibleRepositories: [String: Int]
    public let favoriteCount: Int
    public var count: Int { visibleRepositories.values.reduce(0, +) }

    public init(notifications: [GitHubNotification], settings: Settings) {
        let patterns = settings.favoriteRepos.filter { !$0.isEmpty }
            .compactMap { try? NSRegularExpression(pattern: $0) }
        var repositories: [String: Int] = [:]
        for notification in notifications {
            repositories[notification.repository.fullName, default: 0] += 1
        }
        let favorites = repositories.filter { name, _ in
            let range = NSRange(name.startIndex..., in: name)
            return patterns.contains { $0.firstMatch(in: name, range: range) != nil }
        }
        self.repositories = repositories
        favoriteCount = favorites.values.reduce(0, +)
        visibleRepositories = settings.filtersMode == .favorite ? favorites : repositories
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
