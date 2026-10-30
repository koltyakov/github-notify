import Foundation
import GitHubNotifyCore

@MainActor
final class RepositoryActivityMonitor {
    private let client = GitHubClient()
    private let store = RepositoryActivityStore()
    private let notifications = NativeNotifications()
    private var task: Task<Void, Never>?

    func stop() { task?.cancel() }

    func start(token: String, settings: Settings, status: @escaping @MainActor (String) -> Void) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var state = try self.store.load()
                state?.configure(settings)
                if let state { try self.store.save(state) }
                guard settings.notifyStars || settings.notifyIssues || settings.notifyIssueComments else {
                    status("Repository alerts are off")
                    return
                }
                guard !token.isEmpty else {
                    status("Repository alerts need a GitHub token")
                    return
                }
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
                            commentsSince: state?.commentsCheckedAt, settings: settings
                        )
                        try Task.checkCancellation()
                        guard var updated = state else { return }
                        let alerts = updated.alerts(for: snapshot, settings: settings)
                        // Save before delivery so refresh/relaunch cannot replay already submitted banners.
                        try self.store.save(updated)
                        state = updated
                        for alert in alerts {
                            try Task.checkCancellation()
                            try await self.notifications.show(alert)
                        }
                        status("Repository alerts are on")
                        delay = max(delay, snapshot.pollInterval)
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        status("Repository alerts: \(error.localizedDescription)")
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
                status("Repository alerts: \(error.localizedDescription)")
            }
        }
    }
}
