import AppKit
import GitHubNotifyCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tokenField = NSSecureTextField()
    private let frequency = NSPopUpButton()
    private let favorites = NSTextView()
    private let autoStart = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let notifyStars = NSButton(checkboxWithTitle: "Stars and unstars", target: nil, action: nil)
    private let notifyForks = NSButton(checkboxWithTitle: "Forks", target: nil, action: nil)
    private let notifyIssues = NSButton(checkboxWithTitle: "Issues", target: nil, action: nil)
    private let notifyPullRequests = NSButton(checkboxWithTitle: "Pull requests", target: nil, action: nil)
    private let notifyIssueComments = NSButton(checkboxWithTitle: "Issue comments", target: nil, action: nil)
    private let notifyPullRequestComments = NSButton(checkboxWithTitle: "Pull request comments", target: nil, action: nil)
    private let onSave: (Settings, String) throws -> Void
    private var settings: Settings
    private let intervals = ["10s", "30s", "120s"]

    init(settings: Settings, token: String, onSave: @escaping (Settings, String) throws -> Void) {
        self.settings = settings
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 550),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "GitHub Notify Settings"
        window.isReleasedWhenClosed = false
        window.center()

        tokenField.stringValue = token
        tokenField.placeholderString = "GitHub personal access token"
        tokenField.setAccessibilityLabel("GitHub personal access token")
        frequency.addItems(withTitles: ["High, every 10 seconds", "Medium, every 30 seconds", "Low, every 2 minutes"])
        if let index = intervals.firstIndex(of: settings.updateFrequency) {
            frequency.selectItem(at: index)
        } else {
            frequency.addItem(withTitle: "Custom, \(settings.updateFrequency)")
            frequency.selectItem(at: intervals.count)
        }
        frequency.setAccessibilityLabel("Update frequency")
        favorites.isEditable = true
        favorites.isSelectable = true
        favorites.isRichText = false
        favorites.isAutomaticQuoteSubstitutionEnabled = false
        favorites.isAutomaticDashSubstitutionEnabled = false
        favorites.isAutomaticTextReplacementEnabled = false
        favorites.font = .systemFont(ofSize: NSFont.systemFontSize)
        favorites.textContainerInset = NSSize(width: 4, height: 4)
        favorites.isVerticallyResizable = true
        favorites.isHorizontallyResizable = false
        favorites.autoresizingMask = [.width]
        favorites.textContainer?.widthTracksTextView = true
        favorites.string = settings.favoriteRepos.joined(separator: "\n")
        favorites.setAccessibilityLabel("Favorite repositories")
        let favoritesScroll = NSScrollView()
        favoritesScroll.borderType = .bezelBorder
        favoritesScroll.hasVerticalScroller = true
        favoritesScroll.documentView = favorites
        autoStart.state = LaunchAtLogin.isEnabled ? .on : .off
        notifyStars.state = settings.notifyStars ? .on : .off
        notifyIssues.state = settings.notifyIssues ? .on : .off
        notifyIssueComments.state = settings.notifyIssueComments ? .on : .off
        notifyForks.state = settings.notifyForks ? .on : .off
        notifyPullRequests.state = settings.notifyPullRequests ? .on : .off
        notifyPullRequestComments.state = settings.notifyPullRequestComments ? .on : .off

        let alertOptions = NSGridView(views: [
            [notifyStars, notifyForks], [notifyIssues, notifyPullRequests],
            [notifyIssueComments, notifyPullRequestComments],
        ])
        alertOptions.columnSpacing = 16
        alertOptions.rowSpacing = 6

        let notificationSettings = NSButton(title: "Open notification settings", target: self, action: #selector(openNotificationSettings))
        notificationSettings.bezelStyle = .rounded

        let createToken = NSButton(title: "Create token on GitHub", target: self, action: #selector(openTokenPage))
        createToken.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [createToken, NSView(), cancel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            label("GitHub token"), tokenField,
            hint("Use a classic personal access token with notifications and repo scopes. repo includes private-repository access. The token is stored in your macOS Keychain."),
            label("Update frequency"), frequency,
            hint("GitHub's minimum polling interval takes precedence to avoid rate limits."),
            label("Favorite repositories"), favoritesScroll,
            hint("Separate repository names, wildcard patterns, or regular expressions with commas or newlines. Examples: koltyakov/* or ssnitko/varro-*"),
            label("Desktop notifications"), alertOptions,
            hint("Silent banners for your repositories. Use Filter mode > My repositories to also limit the menu count. Stars and forks report net changes between checks. Private repositories require the repo token scope."),
            notificationSettings,
            autoStart, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            tokenField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            favoritesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            favoritesScroll.heightAnchor.constraint(equalToConstant: 62),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 510, height: stack.fittingSize.height + 48))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 462
        return field
    }

    @objc private func openTokenPage() { NSWorkspace.shared.open(AppDelegate.tokenURL) }
    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    @objc private func cancelSettings() { close() }

    @objc private func saveSettings() {
        var updated = settings
        updated.favoriteRepos = Settings.parseFavorites(favorites.string)
        if frequency.indexOfSelectedItem < intervals.count {
            updated.updateFrequency = intervals[frequency.indexOfSelectedItem]
        }
        updated.autoStart = autoStart.state == .on
        updated.notifyStars = notifyStars.state == .on
        updated.notifyIssues = notifyIssues.state == .on
        updated.notifyIssueComments = notifyIssueComments.state == .on
        updated.notifyForks = notifyForks.state == .on
        updated.notifyPullRequests = notifyPullRequests.state == .on
        updated.notifyPullRequestComments = notifyPullRequestComments.state == .on
        do {
            try updated.validate()
            try onSave(updated, tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            close()
            if LaunchAtLogin.needsApproval {
                let alert = NSAlert()
                alert.messageText = "Approve launch at login"
                alert.informativeText = "Allow GitHub Notify under Login Items in System Settings."
                alert.addButton(withTitle: "Open Login Items")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
