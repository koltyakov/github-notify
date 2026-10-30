import Foundation

public enum FilterMode: String, Codable, Sendable {
    case all, favorite
}

public struct Settings: Codable, Equatable, Sendable {
    public var updateFrequency: String = "30s"
    public var favoriteRepos: [String] = []
    public var filtersMode: FilterMode = .all
    public var autoStart = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case updateFrequency, favoriteRepos, filtersMode, autoStart
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        updateFrequency = try values.decodeIfPresent(String.self, forKey: .updateFrequency) ?? "30s"
        favoriteRepos = try values.decodeIfPresent([String].self, forKey: .favoriteRepos) ?? []
        let mode = try values.decodeIfPresent(String.self, forKey: .filtersMode)
        filtersMode = mode.flatMap(FilterMode.init(rawValue:)) ?? .all
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    // Accept the duration strings used by the Go app, including compound values like 1m30s.
    public var pollInterval: TimeInterval {
        let expression = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|s|m|h)"#)
        let range = NSRange(updateFrequency.startIndex..., in: updateFrequency)
        let matches = expression.matches(in: updateFrequency, range: range)
        guard !matches.isEmpty,
              matches.map(\.range.length).reduce(0, +) == range.length else { return 30 }
        var seconds: Double = 0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: updateFrequency),
                  let unitRange = Range(match.range(at: 2), in: updateFrequency),
                  let number = Double(updateFrequency[numberRange]) else { return 30 }
            let multiplier: Double
            switch updateFrequency[unitRange] {
            case "ms": multiplier = 0.001
            case "m": multiplier = 60
            case "h": multiplier = 3600
            default: multiplier = 1
            }
            seconds += number * multiplier
        }
        guard seconds.isFinite, seconds > 0 else { return 30 }
        return min(max(seconds, 10), 86400)
    }

    public func validate() throws {
        for pattern in favoriteRepos where !pattern.isEmpty {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw SettingsError.invalidPattern(pattern) }
        }
    }

    public static func parseFavorites(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public enum SettingsError: LocalizedError {
    case invalidPattern(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let pattern): return "Invalid favorite repository expression: \(pattern)"
        }
    }
}

public struct SettingsStore {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("github-notify", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: Settings) throws {
        try settings.validate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
