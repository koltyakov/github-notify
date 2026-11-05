import AppKit
import GitHubNotifyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=notifications,repo&description=GitHub%20Notify%20App")!
    private let store = SettingsStore()
    private let tokenStore = TokenStore()
    private let client: GitHubClient
    private let openURL: @MainActor (URL) -> Void
    private let activityMonitor: RepositoryActivityMonitor
    private var settings = Settings()
    private var token = ""
    private var account: GitHubAccount?
    private(set) var statusItem: NSStatusItem!
    private var controlsMenu: NSMenu!
    private var markItem: NSMenuItem!
    private var refreshItem: NSMenuItem!
    private var tokenItem: NSMenuItem!
    private var allItem: NSMenuItem!
    private var favoritesItem: NSMenuItem!
    private var ownedItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController?
    private var pollingTask: Task<Void, Never>?
    private(set) var markingTask: Task<Void, Never>?
    private(set) var notificationReadTasks: [String: Task<Void, Never>] = [:]
    // Keep opened threads hidden until a poll started after their write completed.
    private var openedNotifications: [String: Date] = [:]
    private var snapshot: NotificationSnapshot?
    private var summary: NotificationSummary?
    private var instanceLock: InstanceLock?
    private var marking = false
    private var startupError: (any Error)?
    private var statusImages: [String: NSImage] = [:]
    // Load bundle resources directly instead of macOS's cached application icon.
    private let applicationIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
    private let aboutIcon = Bundle.main.url(forResource: "AppLogo", withExtension: "png")
        .flatMap { ApplicationIcon.aboutImage(from: $0) }

    init(
        client: GitHubClient = GitHubClient(),
        activityMonitor: RepositoryActivityMonitor = RepositoryActivityMonitor(),
        settings: Settings = Settings(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.client = client
        self.activityMonitor = activityMonitor
        self.settings = settings
        self.openURL = openURL
        super.init()
        activityMonitor.onChange = { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            self.render()
        }
    }

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
        if let applicationIcon { NSApp.applicationIconImage = applicationIcon }
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
        for task in notificationReadTasks.values { task.cancel() }
        activityMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Notification clicks can also send a reopen event. Only the Settings menu
        // action should open preferences; suppress AppKit's default window reopening too.
        return false
    }

    func buildMenu() {
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
        ownedItem = item("My repositories", action: #selector(filterOwned))
        filters.addItem(allItem)
        filters.addItem(favoritesItem)
        filters.addItem(ownedItem)
        let filter = NSMenuItem(title: "Filter mode", action: nil, keyEquivalent: "")
        filter.submenu = filters
        menu.addItem(filter)
        tokenItem = item("Get token", action: #selector(getToken))
        tokenItem.isHidden = !token.isEmpty
        menu.addItem(tokenItem)
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("About GitHub Notify", action: #selector(about)))
        menu.addItem(item("Quit GitHub Notify", action: #selector(quit), key: "q"))
        controlsMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateFilterChecks()
        setStatus(title: "", tooltip: "Loading notifications…", symbol: "bell")
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let showControls = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        let menu = showControls ? controlsMenu! : notificationsMenu()
        // Use native status-item placement, not a context menu aligned under the pointer.
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard statusItem.menu === menu else { return }
        // Restore custom click routing after native menu tracking finishes.
        statusItem.menu = nil
        menu.delegate = nil
    }

    func notificationsMenu() -> NSMenu {
        let notifications = summary?.visibleNotifications ?? []
        let emptyMessage: String
        if token.isEmpty { emptyMessage = "Add a GitHub token in Settings" }
        else if settings.filtersMode == .owned, account == nil { emptyMessage = "Loading your repositories…" }
        else if snapshot == nil { emptyMessage = "No notifications loaded" }
        else { emptyMessage = "No unread notifications" }
        return NotificationDropdown.make(
            notifications: notifications, activity: summary?.visibleActivity ?? [], emptyMessage: emptyMessage,
            target: self, action: #selector(openNotification(_:))
        )
    }

    @objc private func openNotification(_ sender: NSMenuItem) {
        if let event = sender.representedObject as? RepositoryToast {
            do { try activityMonitor.dismiss([event.id]) }
            catch { statusItem.button?.toolTip = "Could not dismiss activity: \(error.localizedDescription)" }
            if event.url.scheme == "https", event.url.host == "github.com",
               event.url.user == nil, event.url.password == nil, event.url.port == nil {
                openURL(event.url)
            }
            return
        }
        guard let notification = sender.representedObject as? GitHubNotification,
              let url = notification.browserURL else { return }
        if openedNotifications[notification.id] == nil, snapshot != nil {
            openedNotifications[notification.id] = .distantFuture
            render()
            let token = token
            notificationReadTasks[notification.id] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.markRead(notificationID: notification.id, token: token)
                    try Task.checkCancellation()
                    self.openedNotifications[notification.id] = Date()
                    self.notificationReadTasks[notification.id] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.openedNotifications[notification.id] = nil
                    self.notificationReadTasks[notification.id] = nil
                    self.render()
                    self.statusItem.button?.toolTip = "Could not mark notification as read: \(error.localizedDescription)"
                }
            }
        }
        openURL(url)
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
            render()
            refreshItem.isEnabled = false
            tokenItem.isHidden = false
            if summary?.count == 0 {
                setStatus(title: "No token", tooltip: "Enter a GitHub token in Settings.", symbol: "bell.slash")
            }
            return
        }
        refreshItem.isEnabled = true
        tokenItem.isHidden = !token.isEmpty
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var delay = self.settings.pollInterval
                do {
                    if self.settings.filtersMode == .owned, self.account == nil {
                        let account = try await self.client.account(token: self.token)
                        try Task.checkCancellation()
                        self.account = account
                    }
                    let snapshot = try await self.client.notifications(token: self.token)
                    try Task.checkCancellation()
                    self.receive(snapshot)
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
        activityMonitor.start(token: token, settings: settings)
    }

    func receive(_ snapshot: NotificationSnapshot) {
        openedNotifications = openedNotifications.filter { snapshot.checkedAt < $0.value }
        self.snapshot = snapshot
        render()
    }

    private func render() {
        let notifications = (snapshot?.notifications ?? []).filter { openedNotifications[$0.id] == nil }
        let summary = NotificationSummary(
            notifications: notifications, activity: activityMonitor.state?.unreadEvents ?? [],
            settings: settings, accountLogin: account?.login ?? activityMonitor.state?.accountLogin
        )
        self.summary = summary
        markItem.isEnabled = summary.count > 0 && !marking
        tokenItem.isHidden = !token.isEmpty
        let symbol = summary.count == 0 ? "bell" : summary.favoriteCount > 0 ? "bell.badge.fill" : "bell.fill"
        setStatus(title: summary.count == 0 ? "" : summary.title, tooltip: summary.tooltip, symbol: symbol)
    }

    private func showError(_ error: any Error) {
        snapshot = nil
        render()
        if let error = error as? GitHubError, error.isUnauthorized { tokenItem.isHidden = false }
        if let summary, summary.count > 0 {
            statusItem.button?.toolTip = "\(summary.tooltip)\nCould not load GitHub notifications: \(error.localizedDescription)"
            return
        }
        setStatus(title: "Error", tooltip: error.localizedDescription, symbol: "exclamationmark.triangle")
    }

    private func updateFilterChecks() {
        allItem.state = settings.filtersMode == .all ? .on : .off
        favoritesItem.state = settings.filtersMode == .favorite ? .on : .off
        ownedItem.state = settings.filtersMode == .owned ? .on : .off
    }

    private func setFilter(_ mode: FilterMode) {
        var updated = settings
        updated.filtersMode = mode
        do {
            try store.save(updated)
            settings = updated
            updateFilterChecks()
            render()
            if mode == .owned, account == nil {
                if activityMonitor.state?.accountLogin == nil {
                    setStatus(title: "", tooltip: "Loading your repositories…", symbol: "bell")
                }
                restartPolling()
            }
        } catch { showError(error) }
    }

    @objc private func filterAll() { setFilter(.all) }
    @objc private func filterFavorites() { setFilter(.favorite) }
    @objc private func filterOwned() { setFilter(.owned) }
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

    @objc func markRead() {
        guard !marking, let summary, summary.count > 0 else { return }
        // Capture only displayed local IDs. Events arriving during the remote write stay unread.
        do { try activityMonitor.dismiss(Set(summary.visibleActivity.map(\.id))) }
        catch {
            statusItem.button?.toolTip = "Could not dismiss activity: \(error.localizedDescription)"
            return
        }
        render()
        let repositories = Set(summary.visibleNotifications.map { $0.repository.fullName }).sorted()
        guard !repositories.isEmpty, let snapshot else { return }
        pollingTask?.cancel()
        marking = true
        markItem.isEnabled = false
        refreshItem.isEnabled = false
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
            self.account = nil
            self.startupError = nil
            self.snapshot = nil
            self.summary = nil
            self.markItem.isEnabled = false
            self.markingTask?.cancel()
            for task in self.notificationReadTasks.values { task.cancel() }
            self.notificationReadTasks.removeAll()
            self.openedNotifications.removeAll()
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
        let repositoryURL = URL(string: "https://github.com/koltyakov/github-notify")!
        let credits = NSMutableAttributedString(string: "GitHub notifications in your menu bar.\n")
        credits.append(NSAttributedString(string: repositoryURL.absoluteString, attributes: [
            .link: repositoryURL,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "GitHub Notify",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "GitHubNotifyVersion") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: credits,
        ]
        if let aboutIcon { options[.applicationIcon] = aboutIcon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
