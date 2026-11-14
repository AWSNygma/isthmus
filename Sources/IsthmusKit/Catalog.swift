import Foundation

/// A Windows game store/launcher Isthmus can install in one click.
public struct LauncherInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var installerURL: URL
    /// Installer file name to save as (the extension decides msiexec vs. exe).
    public var fileName: String
    public var silentArguments: [String]
    /// Path of the launcher executable after install, Windows style.
    public var executable: String
    public var arguments: [String]?
    public var notes: String?
}

/// A redistributable runtime (Visual C++, .NET, …) downloaded from the vendor at install time.
public struct ComponentInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var installers: [Installer]

    public struct Installer: Codable, Sendable, Equatable {
        public var url: URL
        public var fileName: String
        public var arguments: [String]
    }
}

public enum Catalog {
    public static func launchers() -> [LauncherInfo] { load([LauncherInfo].self, "launchers.json") }
    public static func components() -> [ComponentInfo] { load([ComponentInfo].self, "components.json") }

    public static func launcher(_ id: String) -> LauncherInfo? { launchers().first { $0.id == id } }
    public static func component(_ id: String) -> ComponentInfo? { components().first { $0.id == id } }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T where T: ExpressibleByArrayLiteral {
        guard let url = ResourceBundle.url(forResource: name), let v = try? JSON.read(T.self, from: url) else { return [] }
        return v
    }
}
