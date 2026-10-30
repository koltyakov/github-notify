import AppKit
import GitHubNotifyCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tokenField = NSSecureTextField()
    private let frequency = NSPopUpButton()
    private let favorites = NSTextField(wrappingLabelWithString: "")
    private let autoStart = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let notifyStars = NSButton(checkboxWithTitle: "New repository stars", target: nil, action: nil)
    private let notifyIssues = NSButton(checkboxWithTitle: "New repository issues", target: nil, action: nil)
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
        favorites.isBezeled = true
        favorites.drawsBackground = true
        favorites.maximumNumberOfLines = 4
        favorites.preferredMaxLayoutWidth = 462
        favorites.stringValue = settings.favoriteRepos.joined(separator: ", ")
        favorites.setAccessibilityLabel("Favorite repositories")
        autoStart.state = LaunchAtLogin.isEnabled ? .on : .off
        notifyStars.state = settings.notifyStars ? .on : .off
        notifyIssues.state = settings.notifyIssues ? .on : .off

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
            hint("Use a classic personal access token with the notifications scope. The token is stored in your macOS Keychain."),
            label("Update frequency"), frequency,
            hint("GitHub's minimum polling interval takes precedence to avoid rate limits."),
            label("Favorite repositories"), favorites,
            hint("Separate repository names or regular expressions with commas or newlines. Example: ^owner/repo$ or ^owner/"),
            label("Desktop notifications"), notifyStars, notifyIssues,
            hint("Silent banners for repositories owned by your GitHub account, independent of the menu filter. Stars report net increases between checks. Private repositories require the repo token scope."),
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
            favorites.widthAnchor.constraint(equalTo: stack.widthAnchor),
            favorites.heightAnchor.constraint(equalToConstant: 62),
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
        updated.favoriteRepos = Settings.parseFavorites(favorites.stringValue)
        if frequency.indexOfSelectedItem < intervals.count {
            updated.updateFrequency = intervals[frequency.indexOfSelectedItem]
        }
        updated.autoStart = autoStart.state == .on
        updated.notifyStars = notifyStars.state == .on
        updated.notifyIssues = notifyIssues.state == .on
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
