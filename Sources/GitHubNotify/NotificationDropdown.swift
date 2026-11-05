import AppKit
import GitHubNotifyCore

@MainActor
enum NotificationDropdown {
    static func make(
        notifications: [GitHubNotification], activity: [RepositoryToast] = [],
        emptyMessage: String, target: AnyObject, action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.minimumWidth = 320
        guard !notifications.isEmpty || !activity.isEmpty else {
            let empty = NSMenuItem(title: emptyMessage, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        let entries = notifications.map { notification in
            Entry(
                repository: notification.repository.fullName, title: notification.title,
                tooltip: notification.title, symbol: symbol(for: notification.subject?.type),
                object: notification, enabled: notification.browserURL != nil
            )
        } + activity.map { event in
            Entry(
                repository: event.repository,
                title: "\(event.title): \(event.body)".split(whereSeparator: \.isWhitespace).joined(separator: " "),
                tooltip: "\(event.title)\n\(event.body)", symbol: activitySymbol(for: event.id),
                object: event, enabled: true
            )
        }
        let groups = Dictionary(grouping: entries, by: \.repository)
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
            for entry in entries {
                let item = NSMenuItem(title: shortened(entry.title), action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = entry.object
                item.isEnabled = entry.enabled
                item.toolTip = "\(repository)\n\(entry.tooltip)"
                item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.symbol)
                menu.addItem(item)
            }
        }
        return menu
    }

    private struct Entry {
        let repository: String
        let title: String
        let tooltip: String
        let symbol: String
        let object: Any
        let enabled: Bool
    }

    private static func symbol(for type: String?) -> String {
        switch type {
        case "Issue": "ladybug"
        case "PullRequest": "square.and.arrow.down"
        case "Comment", "IssueComment", "PullRequestReviewComment", "Discussion": "text.bubble"
        case "Star": "star"
        case "Unstar": "star.slash"
        case "Follow": "person"
        case "Unfollow": "person.slash"
        case "Release": "tag"
        case "Commit": "point.topleft.down.curvedto.point.bottomright.up"
        default: "bell"
        }
    }

    private static func activitySymbol(for id: String) -> String {
        if id.hasPrefix("workflow-failure-") { return "exclamationmark.triangle" }
        if id.hasPrefix("stars-removed-") { return "star.slash" }
        if id.hasPrefix("stars-") { return "star" }
        if id.hasPrefix("forks-") { return "arrow.triangle.branch" }
        if id.hasPrefix("issue-") { return "ladybug" }
        if id.hasPrefix("pull-request-") { return "square.and.arrow.down" }
        return "text.bubble"
    }

    private static func shortened(_ title: String) -> String {
        title.count > 48 ? String(title.prefix(47)) + "…" : title
    }
}
