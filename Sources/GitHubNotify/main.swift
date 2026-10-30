import AppKit

let application = NSApplication.shared
let delegate: any NSApplicationDelegate = CommandLine.arguments.contains("--test-notification")
    ? NotificationTestDelegate() : AppDelegate()
application.delegate = delegate
application.run()
