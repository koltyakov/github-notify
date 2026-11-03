import Foundation

public struct GitHubAccount: Codable, Sendable {
    public let id: Int
    public let login: String

    public func owns(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return !login.isEmpty && parts.count == 2 && !parts[1].isEmpty && parts[0].lowercased() == login.lowercased()
    }
}

public struct OwnedRepository: Decodable, Sendable {
    public let id: Int
    public let fullName: String
    public let stargazersCount: Int
    public let forksCount: Int?

    public init(id: Int, fullName: String, stargazersCount: Int, forksCount: Int? = nil) {
        self.id = id
        self.fullName = fullName
        self.stargazersCount = stargazersCount
        self.forksCount = forksCount
    }

    enum CodingKeys: String, CodingKey {
        case id, fullName = "full_name", stargazersCount = "stargazers_count", forksCount = "forks_count"
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
    public enum Kind: String, Sendable { case thread, review }

    public let issue: RepositoryIssue
    public let comment: RepositoryIssueComment
    public let kind: Kind

    public init(issue: RepositoryIssue, comment: RepositoryIssueComment, kind: Kind = .thread) {
        self.issue = issue
        self.comment = comment
        self.kind = kind
    }
}

public struct RepositoryWorkflowRun: Decodable, Sendable {
    public let id: Int
    public let name: String?
    public let headBranch: String?
    public let runNumber: Int
    public let runAttempt: Int
    public let status: String
    public let conclusion: String?
    public let updatedAt: Date
    public let repository: GitHubNotification.Repository

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, repository
        case headBranch = "head_branch", runNumber = "run_number", runAttempt = "run_attempt", updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        headBranch = try values.decodeIfPresent(String.self, forKey: .headBranch)
        runNumber = try values.decode(Int.self, forKey: .runNumber)
        runAttempt = try values.decodeIfPresent(Int.self, forKey: .runAttempt) ?? 1
        status = try values.decode(String.self, forKey: .status)
        conclusion = try values.decodeIfPresent(String.self, forKey: .conclusion)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        repository = try values.decode(GitHubNotification.Repository.self, forKey: .repository)
    }
}

public struct RepositoryActivitySnapshot: Sendable {
    public let account: GitHubAccount
    public let repositories: [OwnedRepository]
    public let issues: [RepositoryIssue]
    public let comments: [IssueCommentActivity]
    public let workflowRuns: [RepositoryWorkflowRun]
    // A nonempty list means CI is incomplete and its saved checkpoint must not advance.
    public let workflowFailureErrors: [String]
    // Only complete stargazer lists are included, keyed by stable repository ID.
    public let stargazers: [String: [GitHubAccount]]
    public let stargazerErrors: [String]
    public let checkedAt: Date
    public let pollInterval: TimeInterval

    public init(
        account: GitHubAccount, repositories: [OwnedRepository], issues: [RepositoryIssue],
        comments: [IssueCommentActivity] = [], workflowRuns: [RepositoryWorkflowRun] = [],
        workflowFailureErrors: [String] = [],
        stargazers: [String: [GitHubAccount]] = [:], stargazerErrors: [String] = [],
        checkedAt: Date, pollInterval: TimeInterval
    ) {
        self.account = account
        self.repositories = repositories
        self.issues = issues
        self.comments = comments
        self.workflowRuns = workflowRuns
        self.workflowFailureErrors = workflowFailureErrors
        self.stargazers = stargazers
        self.stargazerErrors = stargazerErrors
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
    public private(set) var stargazers: [String: [GitHubAccount]]?
    private var forkCounts: [String: Int]?
    public private(set) var issuesCheckedAt: Date?
    private var issuesStartedAt: Date?
    private var seenIssues: [String: Date] = [:]
    private var commentState: ActivityState?
    private var pullRequestState: ActivityState?
    private var pullRequestCommentState: ActivityState?
    private var workflowFailureState: ActivityState?
    public var commentsCheckedAt: Date? { commentState?.checkedAt }
    public var pullRequestsCheckedAt: Date? { pullRequestState?.checkedAt }
    public var pullRequestCommentsCheckedAt: Date? { pullRequestCommentState?.checkedAt }
    public var workflowFailuresCheckedAt: Date? { workflowFailureState?.checkedAt }

    // New category baselines are optional so older activity files still decode.
    private struct ActivityState: Codable, Sendable {
        let startedAt: Date
        var checkedAt: Date
        var seen: [String: Date] = [:]

        func accepts(_ id: String, createdAt: Date) -> Bool {
            createdAt >= startedAt && createdAt >= checkedAt.addingTimeInterval(-120) && seen[id] == nil
        }

        mutating func finish(at date: Date) {
            seen = seen.filter { $0.value >= date.addingTimeInterval(-120) }
            checkedAt = date
        }
    }

    public init(accountID: Int) { self.accountID = accountID }

    public mutating func configure(_ settings: Settings) {
        if !settings.notifyStars { stargazers = nil }
        if !settings.notifyForks { forkCounts = nil }
        if !settings.notifyPullRequests { pullRequestState = nil }
        if !settings.notifyPullRequestComments { pullRequestCommentState = nil }
        if !settings.notifyWorkflowFailures { workflowFailureState = nil }
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
            var updated: [String: [GitHubAccount]] = [:]
            var visited = Set<String>()
            for repository in snapshot.repositories where snapshot.account.owns(repository.fullName) {
                let key = String(repository.id)
                guard visited.insert(key).inserted else { continue }
                guard let current = snapshot.stargazers[key] else {
                    // A failed or incomplete fetch must never look like everyone unstarred.
                    updated[key] = stargazers?[key]
                    continue
                }
                var seen = Set<Int>()
                let users = current.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
                updated[key] = users
                guard let previous = stargazers?[key],
                       let url = Self.repositoryURL(repository.fullName)?.appendingPathComponent("stargazers") else { continue }
                let previousIDs = Set(previous.map(\.id))
                let currentIDs = Set(users.map(\.id))
                let added = users.filter { !previousIDs.contains($0.id) }
                let removed = previous.filter { !currentIDs.contains($0.id) }
                for (kind, changed) in [("added", added), ("removed", removed)] where !changed.isEmpty {
                    let names = changed.map { "@\($0.login)" }.sorted().joined(separator: ", ")
                    let title = kind == "added"
                        ? (changed.count == 1 ? "New star" : "\(changed.count) new stars")
                        : (changed.count == 1 ? "Star removed" : "\(changed.count) stars removed")
                    alerts.append(RepositoryToast(
                        id: "stars-\(kind)-\(key)-\(snapshot.checkedAt.timeIntervalSince1970)", repository: repository.fullName,
                        title: title, body: "\(names)\n\(users.count) total stars", url: url
                    ))
                }
            }
            stargazers = updated
        } else { stargazers = nil }

        if settings.notifyForks {
            var updated: [String: Int] = [:]
            for repository in snapshot.repositories where snapshot.account.owns(repository.fullName) {
                let key = String(repository.id)
                guard updated[key] == nil, let count = repository.forksCount else { continue }
                updated[key] = count
                guard let previous = forkCounts?[key], count > previous,
                      let url = Self.repositoryURL(repository.fullName)?.appendingPathComponent("forks") else { continue }
                let increase = count - previous
                alerts.append(RepositoryToast(
                    id: "forks-\(key)-\(snapshot.checkedAt.timeIntervalSince1970)", repository: repository.fullName,
                    title: increase == 1 ? "New fork" : "\(increase) new forks", body: "\(count) total forks", url: url
                ))
            }
            forkCounts = updated
        } else { forkCounts = nil }

        if settings.notifyIssues {
            if let startedAt = issuesStartedAt {
                for issue in snapshot.issues.sorted(by: { $0.id < $1.id }) {
                    let name = issue.repository.fullName
                    guard !issue.isPullRequest, issue.createdAt >= startedAt,
                          issue.createdAt >= (issuesCheckedAt ?? startedAt).addingTimeInterval(-120),
                          snapshot.account.owns(name),
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

        if settings.notifyPullRequests {
            if var state = pullRequestState {
                for issue in snapshot.issues.sorted(by: { $0.id < $1.id }) where issue.isPullRequest {
                    let key = String(issue.id)
                    let name = issue.repository.fullName
                    guard snapshot.account.owns(name), issue.number > 0, state.accepts(key, createdAt: issue.createdAt),
                          let url = Self.repositoryURL(name)?.appendingPathComponent("pull/\(issue.number)") else { continue }
                    state.seen[key] = issue.createdAt
                    alerts.append(RepositoryToast(
                        id: "pull-request-\(issue.id)", repository: name, title: "New pull request #\(issue.number)",
                        body: issue.user.map { "\($0.login): \(issue.title)" } ?? issue.title, url: url
                    ))
                }
                state.finish(at: snapshot.checkedAt)
                pullRequestState = state
            } else { pullRequestState = ActivityState(startedAt: snapshot.checkedAt, checkedAt: snapshot.checkedAt) }
        } else { pullRequestState = nil }

        if settings.notifyIssueComments {
            alerts += Self.commentAlerts(for: snapshot, state: &commentState, pullRequest: false)
        } else { commentState = nil }
        if settings.notifyPullRequestComments {
            alerts += Self.commentAlerts(for: snapshot, state: &pullRequestCommentState, pullRequest: true)
        } else { pullRequestCommentState = nil }
        if settings.notifyWorkflowFailures {
            if var state = workflowFailureState {
                for run in snapshot.workflowRuns.sorted(by: { $0.id < $1.id }) {
                    let name = run.repository.fullName
                    let key = "\(run.id)-\(run.runAttempt)"
                    guard run.status == "completed", run.conclusion == "failure",
                          run.id > 0, run.runAttempt > 0, snapshot.account.owns(name),
                          state.accepts(key, createdAt: run.updatedAt),
                          let url = Self.repositoryURL(name)?.appendingPathComponent("actions/runs/\(run.id)/attempts/\(run.runAttempt)") else { continue }
                    state.seen[key] = run.updatedAt
                    let branch = run.headBranch.map { " on \($0)" } ?? ""
                    alerts.append(RepositoryToast(
                        id: "workflow-failure-\(key)", repository: name, title: "CI pipeline failed",
                        body: "\(run.name ?? "Workflow")\(branch), run #\(run.runNumber)", url: url
                    ))
                }
                // Partial CI results may alert, but must not move past events still waiting to be fetched.
                if snapshot.workflowFailureErrors.isEmpty { state.finish(at: snapshot.checkedAt) }
                workflowFailureState = state
            } else { workflowFailureState = ActivityState(startedAt: snapshot.checkedAt, checkedAt: snapshot.checkedAt) }
        } else { workflowFailureState = nil }
        return alerts
    }

    private static func commentAlerts(
        for snapshot: RepositoryActivitySnapshot, state baseline: inout ActivityState?, pullRequest: Bool
    ) -> [RepositoryToast] {
        guard var state = baseline else {
            baseline = ActivityState(startedAt: snapshot.checkedAt, checkedAt: snapshot.checkedAt)
            return []
        }
        var alerts: [RepositoryToast] = []
        for activity in snapshot.comments.sorted(by: { $0.comment.id < $1.comment.id }) {
            let issue = activity.issue
            let comment = activity.comment
            let name = issue.repository.fullName
            let key = activity.kind == .review ? "review-\(comment.id)" : String(comment.id)
            guard issue.isPullRequest == pullRequest, pullRequest || activity.kind == .thread,
                  issue.number > 0, comment.id > 0, snapshot.account.owns(name),
                  comment.user?.id != snapshot.account.id,
                  state.accepts(key, createdAt: comment.createdAt),
                  let issueURL = repositoryURL(name)?.appendingPathComponent("\(pullRequest ? "pull" : "issues")/\(issue.number)"),
                  var components = URLComponents(url: issueURL, resolvingAgainstBaseURL: false) else { continue }
            components.fragment = activity.kind == .review ? "discussion_r\(comment.id)" : "issuecomment-\(comment.id)"
            guard let url = components.url else { continue }
            state.seen[key] = comment.createdAt
            let text = (comment.body ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let preview = text.isEmpty ? "Comment added" : String(text.prefix(240))
            alerts.append(RepositoryToast(
                id: "\(pullRequest ? "pull-comment" : "comment")-\(key)", repository: name,
                title: pullRequest ? "New comment on pull request #\(issue.number)" : "New comment on #\(issue.number)",
                body: comment.user.map { "\($0.login): \(preview)" } ?? preview, url: url
            ))
        }
        state.finish(at: snapshot.checkedAt)
        baseline = state
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
