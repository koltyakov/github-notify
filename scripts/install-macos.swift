import AppKit
import Foundation

// Copy into a sibling staging directory first, so failed builds or copies leave the
// installed app untouched. Only stop a running app at the destination being updated.
@MainActor
func install(source: URL, directory: URL) throws {
    let manager = FileManager.default
    let destination = directory.appendingPathComponent("GitHub Notify.app", isDirectory: true)
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
        throw installError("The source app and installation destination must be different.")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let staging = directory.appendingPathComponent(".github-notify-install-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var preserveStaging = false
    defer { if !preserveStaging { try? manager.removeItem(at: staging) } }
    let replacement = staging.appendingPathComponent("GitHub Notify.app", isDirectory: true)
    let backup = staging.appendingPathComponent("Previous.app", isDirectory: true)
    try manager.copyItem(at: source, to: replacement)

    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.koltyakov.github-notify")
        .filter { $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
    for app in runningApps {
        guard app.terminate() else {
            throw installError("Quit the installed GitHub Notify app, then run make install again.")
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while runningApps.contains(where: { !$0.isTerminated }), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard runningApps.allSatisfy(\.isTerminated) else {
        throw installError("GitHub Notify did not quit. Quit it manually, then run make install again.")
    }

    let updating = manager.fileExists(atPath: destination.path)
    if updating { try manager.moveItem(at: destination, to: backup) }
    do {
        try manager.moveItem(at: replacement, to: destination)
    } catch {
        if updating {
            do { try manager.moveItem(at: backup, to: destination) }
            catch {
                // Keep the backup if restoring it fails; never delete the user's installed app.
                preserveStaging = true
                throw installError("Installation failed and the previous app could not be restored. Recover it from \(backup.path).")
            }
        }
        throw error
    }
    print("\(updating ? "Updated" : "Installed") \(destination.path)")
    if !runningApps.isEmpty {
        guard NSWorkspace.shared.open(destination) else {
            throw installError("The app was updated but could not restart. Open \(destination.path) manually.")
        }
        print("Restarted GitHub Notify")
    }
}

func installError(_ message: String) -> NSError {
    NSError(domain: "GitHubNotify.Install", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

MainActor.assumeIsolated {
    do {
        guard CommandLine.arguments.count == 3 else {
            throw installError("Usage: swift scripts/install-macos.swift <source.app> <installation directory>")
        }
        try install(
            source: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL,
            directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        )
    } catch {
        FileHandle.standardError.write(Data("Install failed: \(error.localizedDescription)\nFor a per-user install, use make install INSTALL_DIR=\"$HOME/Applications\".\n".utf8))
        exit(1)
    }
}
