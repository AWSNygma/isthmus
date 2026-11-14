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
    /// Bottles that would run on `version` right now.
    public func bottles(using version: String) -> [Bottle] {
        let newest = installed().first?.version
        return BottleStore(paths: paths).list().filter { ($0.config.engineVersion ?? newest) == version }
    }

    /// Refuse to touch an engine whose files running Wine processes have mapped.
    func ensureNotInUse(_ version: String, action: String) throws {
        let busy = bottles(using: version).filter { WineServer.isRunning($0) }
        if !busy.isEmpty {
            throw IsthmusError.unsupported("Can't \(action) engine \(version) while programs are running in \(busy.map { "\"\($0.name)\"" }.joined(separator: ", ")). Quit them first.")
        }
    }

    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// An xz engine archive unpacks to roughly 4.5× its size.
    func ensureSpace(forArchiveBytes bytes: Int64) throws {
        let need = bytes * 5 + (512 << 20)
        if let free = Self.freeSpace(at: paths.root), free < need {
            throw IsthmusError.unsupported("Not enough disk space: the engine needs about \(need >> 30 + 1) GB free, and \(free >> 30) GB is available.")
        }
    }

    @discardableResult
    public func install(archive: URL, expectedSHA256: String? = nil) throws -> Engine {
        try paths.ensure()
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try ensureSpace(forArchiveBytes: size)
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
        if fm.fileExists(atPath: dest.path) {
            try ensureNotInUse(candidate.version, action: "replace")
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: top[0], to: dest)
        // Downloaded archives carry the quarantine flag; Wine's loader and
        // dylibs must not be quarantined or Gatekeeper prompts per-file.
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        RuntimeOverlay.purge(paths: paths, engineVersion: candidate.version)
        return try Engine(url: dest)
    }

    public func remove(_ version: String) throws {
        let e = try engine(version)
        let pinned = BottleStore(paths: paths).list().filter { $0.config.engineVersion == version }
        if !pinned.isEmpty {
            throw IsthmusError.unsupported("Engine \(version) is selected by \(pinned.map { "\"\($0.name)\"" }.joined(separator: ", ")). Switch those bottles to another engine first.")
        }
        if installed().count == 1, !BottleStore(paths: paths).list().isEmpty {
            throw IsthmusError.unsupported("Engine \(version) is the only engine, and your bottles need one. Install another engine first.")
        }
        try ensureNotInUse(version, action: "remove")
        try FileManager.default.removeItem(at: e.url)
        RuntimeOverlay.purge(paths: paths, engineVersion: version)
    }

    // MARK: Remote

    public func latestRemote(session: URLSession = .shared) async throws -> RemoteEngine? {
        try await availableRemote(session: session).first
    }

    /// Static manifest in the repo, used when the GitHub API is unreachable
    /// or rate-limited (60 requests/hour per IP without a token).
    public struct LatestManifest: Codable, Sendable { public var version: String; public var url: URL; public var sha256: String }

    public func availableRemote(session: URLSession = .shared) async throws -> [RemoteEngine] {
        do {
            let list = try await releasesFromAPI(session: session)
            if !list.isEmpty { return list }
        } catch {
            if let fallback = try? await latestFromManifest(session: session) { return [fallback] }
            throw error
        }
        return (try? await latestFromManifest(session: session)).map { [$0] } ?? []
    }

    func latestFromManifest(session: URLSession) async throws -> RemoteEngine {
        let url = URL(string: "https://raw.githubusercontent.com/\(repository)/main/engine/latest.json")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IsthmusError.download("engine manifest unavailable") }
        let m = try JSONDecoder().decode(LatestManifest.self, from: data)
        return RemoteEngine(version: m.version, archiveURL: m.url, sha256: m.sha256, notes: nil)
    }

    func releasesFromAPI(session: URLSession) async throws -> [RemoteEngine] {
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
        try ensureSpace(forArchiveBytes: 300 << 20)
        let archive = paths.cache.appendingPathComponent(remote.archiveURL.lastPathComponent)
        try await Downloader.fetch(remote.archiveURL, to: archive, session: session, progress: progress)
        var expected: String? = (remote.sha256?.isEmpty == false) ? remote.sha256 : nil
        if expected == nil, remote.sha256 != nil {
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
    public static let version = "0.2.0"
}
