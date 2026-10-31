// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitHubNotify",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "github-notify", targets: ["GitHubNotify"])],
    targets: [
        .target(name: "GitHubNotifyCore"),
        .executableTarget(name: "GitHubNotify", dependencies: ["GitHubNotifyCore"]),
        .testTarget(name: "GitHubNotifyCoreTests", dependencies: ["GitHubNotifyCore"]),
        .testTarget(name: "GitHubNotifyTests", dependencies: ["GitHubNotify"]),
    ]
)
