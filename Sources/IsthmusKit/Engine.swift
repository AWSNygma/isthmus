import Foundation
import CryptoKit

/// Contents of `engine.json` written by `engine/build.sh`.
public struct EngineManifest: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var wine: String
    public var source: String
    public var arch: String
    public var components: [String: String]
    public var built: String?
}

/// An engine unpacked on disk.
public struct Engine: Sendable, Equatable, Identifiable {
    public let url: URL
    public let manifest: EngineManifest

    public var id: String { manifest.version }
    public var version: String { manifest.version }

    public var bin: URL { url.appendingPathComponent("bin") }
    public var lib: URL { url.appendingPathComponent("lib") }
    public var wineLoader: URL { bin.appendingPathComponent("wine") }
    public var wineserver: URL { bin.appendingPathComponent("wineserver") }
    public var wineLib: URL { lib.appendingPathComponent("wine") }
    public var dxmt: URL { lib.appendingPathComponent("dxmt") }
    public var dxvk: URL { lib.appendingPathComponent("dxvk") }
    public var vulkanICD: URL { url.appendingPathComponent("share/vulkan/icd.d/MoltenVK_icd.json") }
    public var gstreamerPlugins: URL { lib.appendingPathComponent("gstreamer-1.0") }

    public init(url: URL) throws {
        self.url = url
        let manifestURL = url.appendingPathComponent("engine.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw IsthmusError.invalidArchive("missing engine.json in \(url.lastPathComponent)")
        }
        self.manifest = try JSON.read(EngineManifest.self, from: manifestURL)
    }

    /// Basic structural check so a half-extracted engine is never used.
    public func validate() throws {
        for path in [wineLoader, wineserver, wineLib.appendingPathComponent("x86_64-unix/ntdll.so")] {
            guard FileManager.default.isExecutableFile(atPath: path.path) || FileManager.default.fileExists(atPath: path.path) else {
                throw IsthmusError.invalidArchive("missing \(path.path.replacingOccurrences(of: url.path + "/", with: ""))")
            }
        }
    }
}

/// A downloadable engine published as a GitHub release.
public struct RemoteEngine: Sendable, Equatable {
    public var version: String
    public var archiveURL: URL
    public var sha256: String?
    public var notes: String?
}

public struct EngineManager: Sendable {
    public let paths: IsthmusPaths
    /// GitHub repository that publishes `engine-*` releases.
    public var repository: String

    public init(paths: IsthmusPaths = .default, repository: String = Isthmus.repository) {
        self.paths = paths
        self.repository = repository
    }

    public func installed() -> [Engine] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? Engine(url: $0) }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    public func engine(_ version: String?) throws -> Engine {
        let all = installed()
        if let version, !version.isEmpty {
            guard let e = all.first(where: { $0.version == version }) else { throw IsthmusError.engineNotFound(version) }
            return e
        }
        guard let newest = all.first else { throw IsthmusError.noEngineInstalled }
        return newest
    }

    /// Install from a local `.tar.xz` produced by `engine/build.sh`.
    @discardableResult
    public func install(archive: URL, expectedSHA256: String? = nil) throws -> Engine {
        try paths.ensure()
        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            let actual = try Self.sha256(of: archive)
            guard actual == expected else { throw IsthmusError.checksumMismatch(expected: expected, actual: actual) }
        }
        let fm = FileManager.default
        let staging = paths.engines.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])
        let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard top.count == 1 else { throw IsthmusError.invalidArchive("expected one top-level folder, found \(top.count)") }
        let candidate = try Engine(url: top[0])
        try candidate.validate()

        let dest = paths.engines.appendingPathComponent(candidate.version, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: top[0], to: dest)
        // Downloaded archives carry the quarantine flag; Wine's loader and
        // dylibs must not be quarantined or Gatekeeper prompts per-file.
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        RuntimeOverlay.purge(paths: paths, engineVersion: candidate.version)
        return try Engine(url: dest)
    }

    public func remove(_ version: String) throws {
        let e = try engine(version)
        try FileManager.default.removeItem(at: e.url)
        RuntimeOverlay.purge(paths: paths, engineVersion: version)
    }

    // MARK: Remote

    public func latestRemote(session: URLSession = .shared) async throws -> RemoteEngine? {
        try await availableRemote(session: session).first
    }

    public func availableRemote(session: URLSession = .shared) async throws -> [RemoteEngine] {
        let releases = try await GitHub.releases(repository: repository, session: session)
        return releases.compactMap { rel -> RemoteEngine? in
            guard rel.tagName.hasPrefix("engine-"), !rel.draft else { return nil }
            let version = String(rel.tagName.dropFirst("engine-".count))
            guard let archive = rel.assets.first(where: { $0.name.hasSuffix(".tar.xz") }) else { return nil }
            let shaAsset = rel.assets.first(where: { $0.name == archive.name + ".sha256" })
            return RemoteEngine(version: version, archiveURL: archive.browserDownloadURL,
                                sha256: shaAsset.map { _ in "" }, notes: rel.body)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// Download + verify + install. `progress` receives 0...1.
    @discardableResult
    public func download(_ remote: RemoteEngine, session: URLSession = .shared,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> Engine {
        try paths.ensure()
        let archive = paths.cache.appendingPathComponent(remote.archiveURL.lastPathComponent)
        try await Downloader.fetch(remote.archiveURL, to: archive, session: session, progress: progress)
        var expected: String?
        if remote.sha256 != nil {
            let shaURL = URL(string: remote.archiveURL.absoluteString + ".sha256")!
            let (data, _) = try await session.data(from: shaURL)
            expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)
        }
        let engine = try install(archive: archive, expectedSHA256: expected)
        try? FileManager.default.removeItem(at: archive)
        return engine
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum Isthmus {
    public static let repository = "AWSNygma/isthmus"
    public static let version = "0.1.0"
}
