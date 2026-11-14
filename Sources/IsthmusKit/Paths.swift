import Foundation

/// Filesystem layout for everything Isthmus owns.
///
///     ~/Library/Application Support/Isthmus/
///       Engines/<version>/          unpacked engine (Wine + bundled libs)
///       Bottles/<id>/               one Windows environment per bottle
///         bottle.json               settings
///         prefix/                   WINEPREFIX
///         logs/                     per-launch logs
///       D3DMetal/<version>/         user-imported Apple Game Porting Toolkit redist
///       Runtime/<key>/              hardlinked engine overlays per graphics backend
///       Cache/                      downloads
///
/// Set `ISTHMUS_HOME` to relocate the whole tree (used by tests and CI).
public struct IsthmusPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var `default`: IsthmusPaths {
        if let override = ProcessInfo.processInfo.environment["ISTHMUS_HOME"], !override.isEmpty {
            return IsthmusPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return IsthmusPaths(root: support.appendingPathComponent("Isthmus", isDirectory: true))
    }

    public var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var d3dmetal: URL { root.appendingPathComponent("D3DMetal", isDirectory: true) }
    public var runtime: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    public func ensure() throws {
        for dir in [root, engines, bottles, d3dmetal, runtime, cache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum IsthmusError: LocalizedError, Equatable {
    case engineNotFound(String)
    case noEngineInstalled
    case bottleNotFound(String)
    case bottleExists(String)
    case invalidName(String)
    case invalidArchive(String)
    case checksumMismatch(expected: String, actual: String)
    case processFailed(command: String, status: Int32, output: String)
    case d3dmetalNotFound(String)
    case download(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotFound(let v): return "Engine \(v) is not installed."
        case .noEngineInstalled: return "No engine is installed. Download one from the Engines page."
        case .bottleNotFound(let n): return "No bottle named \"\(n)\"."
        case .bottleExists(let n): return "A bottle named \"\(n)\" already exists."
        case .invalidName(let n): return "\"\(n)\" isn't a valid name. Use letters, numbers, spaces, dashes or underscores."
        case .invalidArchive(let why): return "That file isn't a valid engine archive: \(why)"
        case .checksumMismatch(let e, let a): return "Download is corrupt (expected SHA-256 \(e), got \(a))."
        case .processFailed(let c, let s, let o): return "\(c) exited with status \(s).\n\(o.suffix(2000))"
        case .d3dmetalNotFound(let why): return "Couldn't find D3DMetal: \(why)"
        case .download(let why): return "Download failed: \(why)"
        case .unsupported(let why): return why
        }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension String {
    /// Filesystem-safe slug used for bottle directory names.
    /// ASCII-only: used for folder names, log names and bundle identifiers.
    var slug: String {
        let folded = folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        let mapped = folded.unicodeScalars.map { ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")) ? Character($0) : "-" }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
