import Foundation
import GitHubNotifyCore
import os

@MainActor
final class RepositoryActivityMonitor {
    private let client = GitHubClient()
    private let store: RepositoryActivityStore
    private let notifications = NativeNotifications()
    private let logger = Logger(subsystem: "com.koltyakov.github-notify", category: "RepositoryActivity")
    private var task: Task<Void, Never>?
    private(set) var state: RepositoryActivityState?
    var onChange: ((RepositoryActivityState?) -> Void)?

    init(store: RepositoryActivityStore = RepositoryActivityStore()) {
        self.store = store
        notifications.onOpen = { [weak self] id in
            guard let self else { return }
            do { try self.dismiss([id]) }
            catch { self.logger.error("Activity dismissal failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func restore() throws {
        state = try store.load()
        onChange?(state)
    }

    @discardableResult
    func receive(_ snapshot: RepositoryActivitySnapshot, settings: Settings) throws -> [RepositoryToast] {
        var updated = state ?? RepositoryActivityState(accountID: snapshot.account.id)
        if updated.accountID != snapshot.account.id { updated = RepositoryActivityState(accountID: snapshot.account.id) }
        let alerts = updated.alerts(for: snapshot, settings: settings)
        // Commit unread events and checkpoints together, before submitting banners.
        try store.save(updated)
        state = updated
        onChange?(state)
        return alerts
    }

    func dismiss(_ ids: Set<String>) throws {
        guard !ids.isEmpty, var updated = state else { return }
        updated.dismiss(ids)
        try store.save(updated)
        state = updated
        onChange?(state)
    }

    func stop() { task?.cancel() }

    func start(token: String, settings: Settings) {
        stop()
        do {
            try restore()
            if var updated = state {
                updated.configure(settings)
                try store.save(updated)
                state = updated
            }
        } catch {
            logger.error("Repository activity could not load: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard settings.hasRepositoryAlerts, !token.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Denied banner permission must not prevent the local unread feed.
                var bannersAllowed = false
                do {
                    try await self.notifications.authorize()
                    bannersAllowed = true
                }
                catch { self.logger.error("Repository banners unavailable: \(error.localizedDescription, privacy: .public)") }
                try Task.checkCancellation()
                var account: GitHubAccount?
                while !Task.isCancelled {
                    var delay = max(60, settings.pollInterval)
                    do {
                        if account == nil { account = try await self.client.account(token: token) }
                        try Task.checkCancellation()
                        guard let account else { return }
                        let baseline = self.state?.accountID == account.id ? self.state : nil
                        let snapshot = try await self.client.repositoryActivity(
                            token: token, account: account,
                            issuesSince: baseline?.issuesCheckedAt,
                            commentsSince: baseline?.commentsCheckedAt,
                            pullRequestsSince: baseline?.pullRequestsCheckedAt,
                            pullRequestCommentsSince: baseline?.pullRequestCommentsCheckedAt,
                            workflowFailuresSince: baseline?.workflowFailuresCheckedAt,
                            settings: settings
                        )
                        try Task.checkCancellation()
                        for error in snapshot.workflowFailureErrors {
                            self.logger.error("CI alert check failed: \(error, privacy: .public)")
                        }
                        for error in snapshot.stargazerErrors {
                            self.logger.error("Stargazer check failed: \(error, privacy: .public)")
                        }
                        let alerts = try self.receive(snapshot, settings: settings)
                        for alert in alerts where bannersAllowed {
                            try Task.checkCancellation()
                            do { try await self.notifications.show(alert) }
                            catch { self.logger.error("Repository banner failed: \(error.localizedDescription, privacy: .public)") }
                        }
                        delay = max(delay, snapshot.pollInterval)
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        self.logger.error("Repository alert check failed: \(error.localizedDescription, privacy: .public)")
                        if let error = error as? GitHubError {
                            if error.isUnauthorized { return }
                            delay = max(delay, error.retryAfter ?? 60)
                        }
                    }
                    try await Task.sleep(for: .seconds(min(max(delay, 60), 86400)))
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Repository alerts could not start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
