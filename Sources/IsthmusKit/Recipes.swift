import Foundation

/// A community-maintained fix for one game or launcher. Recipes live in
/// `Sources/IsthmusKit/Resources/recipes/*.json` and are applied
/// automatically when a launch matches.
public struct Recipe: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var match: Match
    public var status: Status
    public var settings: Settings
    public var notes: String?
    /// Links supporting the recipe (bug reports, forum threads).
    public var sources: [String]?

    public struct Match: Codable, Sendable, Equatable {
        /// Lowercase executable file names, e.g. `eldenring.exe`.
        public var exe: [String]?
        public var steamAppID: [Int]?
        public var epicAppName: [String]?
        public var gogID: [String]?
    }

    public enum Status: String, Codable, Sendable {
        /// Works with the recipe's settings.
        case works
        /// Starts but has known problems (see notes).
        case issues
        /// Cannot work (kernel anti-cheat, unsupported DRM). Isthmus warns before launching.
        case blocked
    }

    public struct Settings: Codable, Sendable, Equatable {
        public var graphics: GraphicsBackend?
        public var msync: Bool?
        public var advertiseAVX: Bool?
        public var rayTracing: Bool?
        public var metalFXUpscaling: Bool?
        public var arguments: [String]?
        public var environment: [String: String]?
        public var dllOverrides: [String: String]?
        /// Component ids (see components.json) to install before first launch.
        public var components: [String]?
        public init() {}
    }

    public func matches(exeName: String?, steamAppID: Int?, epicAppName: String?, gogID: String?) -> Bool {
        if let exeName, let list = match.exe, list.contains(exeName.lowercased()) { return true }
        if let steamAppID, let list = match.steamAppID, list.contains(steamAppID) { return true }
        if let epicAppName, let list = match.epicAppName, list.contains(where: { $0.caseInsensitiveCompare(epicAppName) == .orderedSame }) { return true }
        if let gogID, let list = match.gogID, list.contains(gogID) { return true }
        return false
    }
}

public struct RecipeBook: Sendable {
    public let recipes: [Recipe]

    public init(recipes: [Recipe]) { self.recipes = recipes }

    /// Bundled recipes plus any user recipes in `<root>/Recipes/*.json`
    /// (user files win on id collisions, so people can test fixes locally).
    public static func load(paths: IsthmusPaths = .default) -> RecipeBook {
        var byID: [String: Recipe] = [:]
        if let dir = ResourceBundle.url(forResource: "recipes") {
            for r in loadDirectory(dir) { byID[r.id] = r }
        }
        for r in loadDirectory(paths.root.appendingPathComponent("Recipes")) { byID[r.id] = r }
        return RecipeBook(recipes: byID.values.sorted { $0.name < $1.name })
    }

    static func loadDirectory(_ dir: URL) -> [Recipe] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.flatMap { file -> [Recipe] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            if let many = try? JSON.decoder.decode([Recipe].self, from: data) { return many }
            if let one = try? JSON.decoder.decode(Recipe.self, from: data) { return [one] }
            return []
        }
    }

    public func recipe(exeName: String? = nil, steamAppID: Int? = nil, epicAppName: String? = nil, gogID: String? = nil) -> Recipe? {
        // Store ids are more specific than executable names; prefer them.
        if steamAppID != nil || epicAppName != nil || gogID != nil,
           let r = recipes.first(where: { $0.matches(exeName: nil, steamAppID: steamAppID, epicAppName: epicAppName, gogID: gogID) }) {
            return r
        }
        return recipes.first { $0.matches(exeName: exeName, steamAppID: nil, epicAppName: nil, gogID: nil) }
    }
}

/// Finds resources whether running from SwiftPM (`Bundle.module`) or from
/// the assembled app, where the resource bundle sits in Contents/Resources
/// (SwiftPM's generated accessor looks next to the .app, which breaks signing).
public enum ResourceBundle {
    static let bundleName = "Isthmus_IsthmusKit.bundle"

    public static var bundle: Bundle? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/\(bundleName)"),
        ]
        for case let url? in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }

    public static func url(forResource name: String) -> URL? {
        guard let base = bundle?.resourceURL else { return nil }
        let url = base.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
