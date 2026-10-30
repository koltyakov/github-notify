import Foundation

public struct GitHubAccount: Decodable, Sendable {
    public let id: Int
    public let login: String
}

public struct OwnedRepository: Decodable, Sendable {
    public let id: Int
    public let fullName: String
    public let stargazersCount: Int

    enum CodingKeys: String, CodingKey {
        case id, fullName = "full_name", stargazersCount = "stargazers_count"
    }
}

public struct RepositoryIssue: Decodable, Sendable {
    public let id: Int
    public let number: Int
    public let title: String
    public let createdAt: Date
    public let repository: GitHubNotification.Repository
    public let user: GitHubAccount?
    public let isPullRequest: Bool
    public let comments: Int

    private enum CodingKeys: String, CodingKey {
        case id, number, title, repository, user, comments, createdAt = "created_at", pullRequest = "pull_request"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        number = try values.decode(Int.self, forKey: .number)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        repository = try values.decode(GitHubNotification.Repository.self, forKey: .repository)
        user = try values.decodeIfPresent(GitHubAccount.self, forKey: .user)
        isPullRequest = try values.contains(.pullRequest) && !values.decodeNil(forKey: .pullRequest)
        comments = try values.decodeIfPresent(Int.self, forKey: .comments) ?? 0
    }
}

public struct RepositoryIssueComment: Decodable, Sendable {
    public let id: Int
    public let body: String?
    public let createdAt: Date
    public let user: GitHubAccount?

    enum CodingKeys: String, CodingKey {
        case id, body, user, createdAt = "created_at"
    }
}

public struct IssueCommentActivity: Sendable {
    public let issue: RepositoryIssue
    public let comment: RepositoryIssueComment
}

public struct RepositoryActivitySnapshot: Sendable {
    public let account: GitHubAccount
    public let repositories: [OwnedRepository]
    public let issues: [RepositoryIssue]
    public let comments: [IssueCommentActivity]
    public let checkedAt: Date
    public let pollInterval: TimeInterval

    public init(
        account: GitHubAccount, repositories: [OwnedRepository], issues: [RepositoryIssue],
        comments: [IssueCommentActivity] = [], checkedAt: Date, pollInterval: TimeInterval
    ) {
        self.account = account
        self.repositories = repositories
        self.issues = issues
        self.comments = comments
        self.checkedAt = checkedAt
        self.pollInterval = pollInterval
    }
}

public struct RepositoryToast: Equatable, Sendable {
    public let id: String
    public let repository: String
    public let title: String
    public let body: String
    public let url: URL
}

// Keep baselines separate from unread notifications. Marking notifications as read,
// changing the menu filter, and restarting the app must not replay activity.
public struct RepositoryActivityState: Codable, Sendable {
    public let accountID: Int
    private var starCounts: [String: Int]?
    public private(set) var issuesCheckedAt: Date?
    private var issuesStartedAt: Date?
    private var seenIssues: [String: Date] = [:]
    private var commentState: CommentState?
    public var commentsCheckedAt: Date? { commentState?.checkedAt }

    // Optional so activity files from versions without comment alerts still decode.
    private struct CommentState: Codable, Sendable {
        let startedAt: Date
        var checkedAt: Date
        var seen: [String: Date] = [:]
    }

    public init(accountID: Int) { self.accountID = accountID }

    public mutating func configure(_ settings: Settings) {
        if !settings.notifyStars { starCounts = nil }
        if !settings.notifyIssues {
            issuesStartedAt = nil
            issuesCheckedAt = nil
            seenIssues = [:]
        }
        if !settings.notifyIssueComments { commentState = nil }
    }

    public mutating func alerts(for snapshot: RepositoryActivitySnapshot, settings: Settings) -> [RepositoryToast] {
        guard accountID == snapshot.account.id else { return [] }
        var alerts: [RepositoryToast] = []
        if settings.notifyStars {
            var updated: [String: Int] = [:]
            for repository in snapshot.repositories {
                let key = String(repository.id)
                guard updated[key] == nil else { continue }
                updated[key] = repository.stargazersCount
                guard let previous = starCounts?[key], repository.stargazersCount > previous,
                      let url = Self.repositoryURL(repository.fullName)?.appendingPathComponent("stargazers") else { continue }
                let increase = repository.stargazersCount - previous
                alerts.append(RepositoryToast(
                    id: "stars-\(key)-\(snapshot.checkedAt.timeIntervalSince1970)", repository: repository.fullName,
                    title: increase == 1 ? "New star" : "\(increase) new stars",
                    body: "\(repository.stargazersCount) total stars", url: url
                ))
            }
            starCounts = updated
        } else { starCounts = nil }

        if settings.notifyIssues {
            if let startedAt = issuesStartedAt {
                for issue in snapshot.issues.sorted(by: { $0.id < $1.id }) {
                    let name = issue.repository.fullName
                    guard !issue.isPullRequest, issue.createdAt >= startedAt,
                          issue.createdAt >= (issuesCheckedAt ?? startedAt).addingTimeInterval(-120),
                          name.split(separator: "/").first?.lowercased() == snapshot.account.login.lowercased(),
                          seenIssues[String(issue.id)] == nil,
                          let url = Self.repositoryURL(name)?.appendingPathComponent("issues/\(issue.number)") else { continue }
                    seenIssues[String(issue.id)] = issue.createdAt
                    alerts.append(RepositoryToast(
                        id: "issue-\(issue.id)", repository: name, title: "New issue #\(issue.number)",
                        body: issue.user.map { "\($0.login): \(issue.title)" } ?? issue.title, url: url
                    ))
                }
            } else { issuesStartedAt = snapshot.checkedAt }
            // Overlap requests to tolerate timestamp precision and short indexing delays.
            let cutoff = snapshot.checkedAt.addingTimeInterval(-120)
            seenIssues = seenIssues.filter { $0.value >= cutoff }
            issuesCheckedAt = snapshot.checkedAt
        } else {
            issuesStartedAt = nil
            issuesCheckedAt = nil
            seenIssues = [:]
        }

        if settings.notifyIssueComments {
            if var state = commentState {
                for activity in snapshot.comments.sorted(by: { $0.comment.id < $1.comment.id }) {
                    let issue = activity.issue
                    let comment = activity.comment
                    let name = issue.repository.fullName
                    guard !issue.isPullRequest, issue.number > 0, comment.id > 0,
                          comment.createdAt >= state.startedAt,
                          comment.createdAt >= state.checkedAt.addingTimeInterval(-120),
                          name.split(separator: "/").first?.lowercased() == snapshot.account.login.lowercased(),
                          state.seen[String(comment.id)] == nil,
                          let issueURL = Self.repositoryURL(name)?.appendingPathComponent("issues/\(issue.number)"),
                          var components = URLComponents(url: issueURL, resolvingAgainstBaseURL: false) else { continue }
                    components.fragment = "issuecomment-\(comment.id)"
                    guard let url = components.url else { continue }
                    state.seen[String(comment.id)] = comment.createdAt
                    let text = (comment.body ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    let preview = text.isEmpty ? "Comment added" : String(text.prefix(240))
                    alerts.append(RepositoryToast(
                        id: "comment-\(comment.id)", repository: name, title: "New comment on #\(issue.number)",
                        body: comment.user.map { "\($0.login): \(preview)" } ?? preview, url: url
                    ))
                }
                state.seen = state.seen.filter { $0.value >= snapshot.checkedAt.addingTimeInterval(-120) }
                state.checkedAt = snapshot.checkedAt
                commentState = state
            } else {
                commentState = CommentState(startedAt: snapshot.checkedAt, checkedAt: snapshot.checkedAt)
            }
        } else { commentState = nil }
        return alerts
    }

    private static func repositoryURL(_ name: String) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return URL(string: "https://github.com")!.appendingPathComponent(name)
    }
}

public struct RepositoryActivityStore {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL.deletingLastPathComponent().appendingPathComponent("activity.json")) {
        self.url = url
    }

    public func load() throws -> RepositoryActivityState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RepositoryActivityState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: RepositoryActivityState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
