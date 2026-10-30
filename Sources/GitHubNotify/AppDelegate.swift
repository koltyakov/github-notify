import AppKit
import GitHubNotifyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=notifications&description=GitHub%20Notify%20App")!
    private let store = SettingsStore()
    private let tokenStore = TokenStore()
    private let client = GitHubClient()
    private let activityMonitor = RepositoryActivityMonitor()
    private var settings = Settings()
    private var token = ""
    private var statusItem: NSStatusItem!
    private var markItem: NSMenuItem!
    private var refreshItem: NSMenuItem!
    private var tokenItem: NSMenuItem!
    private var allItem: NSMenuItem!
    private var favoritesItem: NSMenuItem!
    private var activityItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController?
    private var pollingTask: Task<Void, Never>?
    private var markingTask: Task<Void, Never>?
    private var snapshot: NotificationSnapshot?
    private var summary: NotificationSummary?
    private var instanceLock: InstanceLock?
    private var marking = false
    private var startupError: (any Error)?
    private var statusImages: [String: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            guard let lock = try InstanceLock() else {
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        do { settings = try store.load() } catch { startupError = error }
        do { token = try tokenStore.load() } catch { startupError = error }
        buildMenu()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil
        )
        if let startupError { showError(startupError) }
        else {
            restartPolling()
            restartActivityMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
        markingTask?.cancel()
        activityMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Notifications", action: #selector(openNotifications)))
        markItem = item("Mark as read", action: #selector(markRead))
        markItem.isEnabled = false
        menu.addItem(markItem)
        refreshItem = item("Check now", action: #selector(refresh))
        menu.addItem(refreshItem)
        let filters = NSMenu()
        filters.autoenablesItems = false
        allItem = item("All notifications", action: #selector(filterAll))
        favoritesItem = item("Favorite repos", action: #selector(filterFavorites))
        filters.addItem(allItem)
        filters.addItem(favoritesItem)
        let filter = NSMenuItem(title: "Filter mode", action: nil, keyEquivalent: "")
        filter.submenu = filters
        menu.addItem(filter)
        tokenItem = item("Get token", action: #selector(getToken))
        tokenItem.isHidden = !token.isEmpty
        menu.addItem(tokenItem)
        activityItem = item("Repository alerts are starting…", action: #selector(openSettings))
        menu.addItem(activityItem)
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("About GitHub Notify", action: #selector(about)))
        menu.addItem(item("Quit GitHub Notify", action: #selector(quit), key: "q"))
        statusItem.menu = menu
        updateFilterChecks()
        setStatus(title: "", tooltip: "Loading notifications…", symbol: "bell")
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func setStatus(title: String, tooltip: String, symbol: String) {
        guard let button = statusItem.button else { return }
        let displayTitle = title.isEmpty ? "" : " \(title)"
        if button.title != displayTitle { button.title = displayTitle }
        button.toolTip = tooltip
        if button.image?.accessibilityDescription != symbol {
            let image: NSImage?
            if let cached = statusImages[symbol] {
                image = cached
            } else {
                let artwork: String
                switch symbol {
                case "bell.fill": artwork = "notice"
                case "bell.badge.fill": artwork = "warn"
                case "bell.slash", "exclamationmark.triangle": artwork = "error"
                default: artwork = "base"
                }
                if let url = Bundle.main.url(forResource: "status-\(artwork)", withExtension: "png"),
                   let original = NSImage(contentsOf: url) {
                    original.size = NSSize(width: 18, height: 18)
                    original.accessibilityDescription = symbol
                    image = original
                } else {
                    image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                    image?.isTemplate = true
                }
                statusImages[symbol] = image
            }
            button.image = image
        }
        button.setAccessibilityLabel("GitHub Notify, \(title). \(tooltip)")
    }

    private func restartPolling() {
        pollingTask?.cancel()
        guard !marking else { return }
        guard !token.isEmpty else {
            snapshot = nil
            summary = nil
            markItem.isEnabled = false
            refreshItem.isEnabled = false
            tokenItem.isHidden = false
            setStatus(title: "No token", tooltip: "Enter a GitHub token in Settings.", symbol: "bell.slash")
            return
        }
        refreshItem.isEnabled = true
        tokenItem.isHidden = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var delay = self.settings.pollInterval
                do {
                    let snapshot = try await self.client.notifications(token: self.token)
                    try Task.checkCancellation()
                    self.snapshot = snapshot
                    self.render(snapshot)
                    delay = max(delay, snapshot.pollInterval)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.showError(error)
                    if let error = error as? GitHubError {
                        if error.isUnauthorized { return }
                        delay = max(delay, error.retryAfter ?? 60)
                    } else { delay = max(delay, 60) }
                }
                do {
                    // Bound untrusted server delays and avoid integer overflow in sleep.
                    try await Task.sleep(for: .seconds(min(max(delay, 10), 86400)))
                } catch { return }
            }
        }
    }

    private func restartActivityMonitoring() {
        activityMonitor.start(token: token, settings: settings) { [weak self] message in
            self?.activityItem.title = message
            self?.activityItem.toolTip = message
        }
    }

    private func render(_ snapshot: NotificationSnapshot) {
        let summary = NotificationSummary(notifications: snapshot.notifications, settings: settings)
        self.summary = summary
        markItem.isEnabled = summary.count > 0 && !marking
        tokenItem.isHidden = true
        let symbol = summary.count == 0 ? "bell" : summary.favoriteCount > 0 ? "bell.badge.fill" : "bell.fill"
        setStatus(title: summary.title, tooltip: summary.tooltip, symbol: symbol)
    }

    private func showError(_ error: any Error) {
        snapshot = nil
        summary = nil
        markItem.isEnabled = false
        if let error = error as? GitHubError, error.isUnauthorized { tokenItem.isHidden = false }
        setStatus(title: "Error", tooltip: error.localizedDescription, symbol: "exclamationmark.triangle")
    }

    private func updateFilterChecks() {
        allItem.state = settings.filtersMode == .all ? .on : .off
        favoritesItem.state = settings.filtersMode == .favorite ? .on : .off
    }

    private func setFilter(_ mode: FilterMode) {
        var updated = settings
        updated.filtersMode = mode
        do {
            try store.save(updated)
            settings = updated
            updateFilterChecks()
            if let snapshot { render(snapshot) }
        } catch { showError(error) }
    }

    @objc private func filterAll() { setFilter(.all) }
    @objc private func filterFavorites() { setFilter(.favorite) }
    @objc private func refresh() {
        restartPolling()
        restartActivityMonitoring()
    }
    @objc private func wake() {
        restartPolling()
        restartActivityMonitoring()
    }
    @objc private func openNotifications() {
        NSWorkspace.shared.open(URL(string: "https://github.com/notifications?query=is%3Aunread")!)
    }
    @objc private func getToken() { NSWorkspace.shared.open(Self.tokenURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func markRead() {
        guard !marking, let snapshot, let summary, summary.count > 0 else { return }
        pollingTask?.cancel()
        marking = true
        markItem.isEnabled = false
        refreshItem.isEnabled = false
        let repositories = summary.visibleRepositories.keys.sorted()
        let token = token
        markingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for repository in repositories {
                    try Task.checkCancellation()
                    try await self.client.markRead(repository: repository, through: snapshot.checkedAt, token: token)
                }
                try Task.checkCancellation()
                self.marking = false
                self.restartPolling()
            } catch {
                guard !Task.isCancelled else { return }
                self.marking = false
                self.refreshItem.isEnabled = true
                self.showError(error)
                // Do not retry writes automatically after a partial failure.
            }
        }
    }

    @objc private func openSettings() {
        if let window = settingsWindow, window.window?.isVisible == true {
            window.present()
            return
        }
        let window = SettingsWindowController(settings: settings, token: token) { [weak self] updated, token in
            guard let self else { return }
            let previousLogin = LaunchAtLogin.isEnabled
            var tokenChanged = false
            do {
                try LaunchAtLogin.configure(updated.autoStart)
                if token != self.token {
                    try self.tokenStore.save(token)
                    tokenChanged = true
                }
                try self.store.save(updated)
            } catch {
                var rollbackErrors: [String] = []
                if tokenChanged {
                    do { try self.tokenStore.save(self.token) }
                    catch { rollbackErrors.append(error.localizedDescription) }
                }
                do { try LaunchAtLogin.configure(previousLogin) }
                catch { rollbackErrors.append(error.localizedDescription) }
                if !rollbackErrors.isEmpty {
                    throw NSError(domain: "GitHubNotify.Settings", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: error.localizedDescription + " Some changes could not be undone: " + rollbackErrors.joined(separator: "; "),
                    ])
                }
                throw error
            }
            self.settings = updated
            self.token = token
            self.startupError = nil
            self.snapshot = nil
            self.summary = nil
            self.markItem.isEnabled = false
            self.markingTask?.cancel()
            self.marking = false
            self.updateFilterChecks()
            self.restartPolling()
            self.restartActivityMonitoring()
        }
        settingsWindow = window
        window.present()
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "GitHub Notify",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "GitHubNotifyVersion") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: NSAttributedString(string: "GitHub notifications in your menu bar.\nhttps://github.com/koltyakov/github-notify"),
        ])
    }
}
