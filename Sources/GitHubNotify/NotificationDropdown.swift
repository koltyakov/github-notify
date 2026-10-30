import AppKit
import GitHubNotifyCore

@MainActor
enum NotificationDropdown {
    static func make(
        notifications: [GitHubNotification], emptyMessage: String, target: AnyObject, action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 320
        guard !notifications.isEmpty else {
            let empty = NSMenuItem(title: emptyMessage, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        let groups = Dictionary(grouping: notifications, by: { $0.repository.fullName })
        for repository in groups.keys.sorted() {
            guard let entries = groups[repository] else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: shortened("\(repository) (\(entries.count))"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            heading.toolTip = repository
            heading.attributedTitle = NSAttributedString(string: heading.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(heading)
            for notification in entries {
                let item = NSMenuItem(title: shortened(notification.title), action: action, keyEquivalent: "")
                let url = notification.browserURL
                item.target = target
                item.representedObject = url
                item.isEnabled = url != nil
                item.indentationLevel = 1
                item.toolTip = "\(repository)\n\(notification.title)"
                let symbol: String
                switch notification.subject?.type {
                case "Issue": symbol = "circle.dotted"
                case "PullRequest": symbol = "arrow.triangle.branch"
                case "Discussion": symbol = "bubble.left.and.bubble.right"
                case "Release": symbol = "tag"
                case "Commit": symbol = "point.topleft.down.curvedto.point.bottomright.up"
                default: symbol = "bell"
                }
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: notification.subject?.type ?? "Notification")
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func shortened(_ title: String) -> String {
        title.count > 80 ? String(title.prefix(79)) + "…" : title
    }
}
