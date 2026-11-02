import Foundation
import GitHubNotifyCore
import os

@MainActor
final class RepositoryActivityMonitor {
    private let client = GitHubClient()
    private let store = RepositoryActivityStore()
    private let notifications = NativeNotifications()
    private let logger = Logger(subsystem: "com.koltyakov.github-notify", category: "RepositoryActivity")
    private var task: Task<Void, Never>?

    func stop() { task?.cancel() }

    func start(token: String, settings: Settings) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var state = try self.store.load()
                state?.configure(settings)
                if let state { try self.store.save(state) }
                guard settings.hasRepositoryAlerts, !token.isEmpty else { return }
                try await self.notifications.authorize()
                try Task.checkCancellation()
                var account: GitHubAccount?
                while !Task.isCancelled {
                    var delay = max(60, settings.pollInterval)
                    do {
                        if account == nil { account = try await self.client.account(token: token) }
                        try Task.checkCancellation()
                        guard let account else { return }
                        if state?.accountID != account.id { state = RepositoryActivityState(accountID: account.id) }
                        let snapshot = try await self.client.repositoryActivity(
                            token: token, account: account, issuesSince: state?.issuesCheckedAt,
                            commentsSince: state?.commentsCheckedAt,
                            pullRequestsSince: state?.pullRequestsCheckedAt,
                            pullRequestCommentsSince: state?.pullRequestCommentsCheckedAt,
                            workflowFailuresSince: state?.workflowFailuresCheckedAt, settings: settings
                        )
                        try Task.checkCancellation()
                        for error in snapshot.workflowFailureErrors {
                            self.logger.error("CI alert check failed: \(error, privacy: .public)")
                        }
                        guard var updated = state else { return }
                        let alerts = updated.alerts(for: snapshot, settings: settings)
                        // Save before delivery so refresh/relaunch cannot replay already submitted banners.
                        try self.store.save(updated)
                        state = updated
                        for alert in alerts {
                            try Task.checkCancellation()
                            try await self.notifications.show(alert)
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
