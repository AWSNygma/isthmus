import Foundation

public enum WindowsVersion: String, Codable, Sendable, CaseIterable, Identifiable {
    case win11, win10, win81, win7, winxp
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        case .winxp: "Windows XP"
        }
    }
}

/// Which translation layer handles Direct3D.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Pick per game: D3DMetal when imported, otherwise DXMT for D3D10/11
    /// and Wine's vkd3d for D3D12.
    case auto
    /// Apple's D3DMetal (Game Porting Toolkit). D3D11 + D3D12. User-imported.
    case d3dmetal
    /// DXMT: open-source D3D10/11 → Metal.
    case dxmt
    /// DXVK (macOS fork): D3D10/11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// Wine's own wined3d (D3D1–11 → OpenGL/Vulkan) and vkd3d (D3D12 → Vulkan).
    case wined3d

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .d3dmetal: "D3DMetal (DirectX 11/12)"
        case .dxmt: "DXMT (DirectX 10/11)"
        case .dxvk: "DXVK (DirectX 10/11 via Vulkan)"
        case .wined3d: "Wine built-in (DirectX 9, OpenGL, DX12 via vkd3d)"
        }
    }
}

/// Bottle-wide defaults. Every field can be overridden per program.
public struct BottleSettings: Codable, Sendable, Equatable {
    public var windowsVersion: WindowsVersion = .win10
    public var graphics: GraphicsBackend = .auto
    /// Mach-semaphore based sync (CrossOver's msync). Large CPU win in most games.
    public var msync: Bool = true
    /// Tell Rosetta 2 to advertise AVX/AVX2 (macOS 15+). Many recent games require it.
    public var advertiseAVX: Bool = true
    /// Metal performance HUD overlay.
    public var metalHUD: Bool = false
    /// Render at native Retina resolution instead of scaled points.
    public var retinaMode: Bool = false
    /// D3DMetal ray tracing (M3 and newer).
    public var rayTracing: Bool = false
    /// DLSS → MetalFX through DXMT's nvngx shim (DXMT only).
    public var metalFXUpscaling: Bool = false
    /// Map ⌥ Option keys to Alt and ⌘ Command to Ctrl for games.
    public var leftOptionIsAlt: Bool = true
    public var rightOptionIsAlt: Bool = true
    public var commandIsCtrl: Bool = false
    /// Large-address-aware for 32-bit games (4 GB instead of 2 GB).
    public var largeAddressAware: Bool = true
    public var environment: [String: String] = [:]
    public var dllOverrides: [String: String] = [:]
    public var logging: LogLevel = .normal

    public init() {}

    public enum LogLevel: String, Codable, Sendable, CaseIterable {
        case quiet, normal, verbose
    }

    enum CodingKeys: String, CodingKey {
        case windowsVersion, graphics, msync, advertiseAVX, metalHUD, retinaMode, rayTracing, metalFXUpscaling
        case leftOptionIsAlt, rightOptionIsAlt, commandIsCtrl, largeAddressAware, environment, dllOverrides, logging
    }

    // Tolerant decoding so older bottle.json files keep working as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BottleSettings.defaults
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? d.windowsVersion
        graphics = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics) ?? d.graphics
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? d.msync
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? d.advertiseAVX
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? d.retinaMode
        rayTracing = try c.decodeIfPresent(Bool.self, forKey: .rayTracing) ?? d.rayTracing
        metalFXUpscaling = try c.decodeIfPresent(Bool.self, forKey: .metalFXUpscaling) ?? d.metalFXUpscaling
        leftOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .leftOptionIsAlt) ?? d.leftOptionIsAlt
        rightOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .rightOptionIsAlt) ?? d.rightOptionIsAlt
        commandIsCtrl = try c.decodeIfPresent(Bool.self, forKey: .commandIsCtrl) ?? d.commandIsCtrl
        largeAddressAware = try c.decodeIfPresent(Bool.self, forKey: .largeAddressAware) ?? d.largeAddressAware
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
        logging = try c.decodeIfPresent(LogLevel.self, forKey: .logging) ?? d.logging
    }

    static let defaults = BottleSettings()
}

/// Per-program overrides. `nil` means "inherit from bottle / recipe".
public struct ProgramSettings: Codable, Sendable, Equatable {
    public var graphics: GraphicsBackend?
    public var msync: Bool?
    public var advertiseAVX: Bool?
    public var metalHUD: Bool?
    public var rayTracing: Bool?
    public var metalFXUpscaling: Bool?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var dllOverrides: [String: String]?
    /// Ignore the bundled recipe for this program.
    public var ignoreRecipe: Bool?
    public init() {}
}

/// A program the user added to the library by hand.
public struct PinnedProgram: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Path inside the bottle, Windows style (`C:\Games\Foo\foo.exe`) or Unix.
    public var path: String
    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }
}

public struct BottleConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Engine version; nil means "newest installed".
    public var engineVersion: String?
    public var settings: BottleSettings
    public var programs: [String: ProgramSettings]
    public var pinned: [PinnedProgram]
    public var components: [String]
    public var created: Date
    /// Settings last written to the registry, so we only re-apply on change.
    public var appliedRegistryHash: String?

    public init(id: String, name: String, engineVersion: String? = nil, settings: BottleSettings = .init()) {
        self.id = id; self.name = name; self.engineVersion = engineVersion; self.settings = settings
        self.programs = [:]; self.pinned = []; self.components = []; self.created = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, engineVersion, settings, programs, pinned, components, created, appliedRegistryHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engineVersion = try c.decodeIfPresent(String.self, forKey: .engineVersion)
        settings = try c.decodeIfPresent(BottleSettings.self, forKey: .settings) ?? .init()
        programs = try c.decodeIfPresent([String: ProgramSettings].self, forKey: .programs) ?? [:]
        pinned = try c.decodeIfPresent([PinnedProgram].self, forKey: .pinned) ?? []
        components = try c.decodeIfPresent([String].self, forKey: .components) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        appliedRegistryHash = try c.decodeIfPresent(String.self, forKey: .appliedRegistryHash)
    }
}

public struct Bottle: Sendable, Equatable, Identifiable, Hashable {
    public let url: URL
    public var config: BottleConfig

    public var id: String { config.id }
    public var name: String { config.name }
    public var configURL: URL { url.appendingPathComponent("bottle.json") }
    public var prefix: URL { url.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    public var logs: URL { url.appendingPathComponent("logs", isDirectory: true) }
    public var cache: URL { url.appendingPathComponent("cache", isDirectory: true) }
    public var isInitialized: Bool { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) }

    public static func == (a: Bottle, b: Bottle) -> Bool { a.url == b.url && a.config == b.config }
    public func hash(into h: inout Hasher) { h.combine(url) }

    public func save() throws { try JSON.write(config, to: configURL) }

    public func settings(forProgram key: String) -> ProgramSettings {
        config.programs[Self.programKey(key)] ?? ProgramSettings()
    }

    /// Normalized key for per-program settings: lowercase Windows path.
    public static func programKey(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\").lowercased()
    }

    /// Convert a Windows path (`C:\foo\bar.exe`) into a Unix path using the
    /// prefix's `dosdevices` symlinks. Unix paths pass through unchanged.
    public func unixPath(forWindowsPath path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2, normalized[normalized.index(after: normalized.startIndex)] == ":" else {
            return driveC.appendingPathComponent(normalized)
        }
        let drive = normalized.prefix(2).lowercased()
        var rest = String(normalized.dropFirst(2))
        while rest.hasPrefix("/") { rest.removeFirst() }
        let device = prefix.appendingPathComponent("dosdevices/\(drive)")
        let base = (try? FileManager.default.destinationOfSymbolicLink(atPath: device.path)).map { dest -> URL in
            dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : prefix.appendingPathComponent("dosdevices").appendingPathComponent(dest)
        } ?? (drive == "c:" ? driveC : device)
        return (rest.isEmpty ? base : base.appendingPathComponent(rest)).standardizedFileURL
    }

    /// Inverse of `unixPath`: files inside drive_c become `C:\...`; anything
    /// else maps to Wine's `Z:` drive (the Mac root).
    public func windowsPath(forUnixPath url: URL) -> String {
        let p = url.standardizedFileURL.path
        let c = driveC.standardizedFileURL.path
        if p == c { return "C:\\" }
        if p.hasPrefix(c + "/") { return "C:\\" + p.dropFirst(c.count + 1).replacingOccurrences(of: "/", with: "\\") }
        return "Z:" + p.replacingOccurrences(of: "/", with: "\\")
    }
}

public struct BottleStore: Sendable {
    public let paths: IsthmusPaths
    public init(paths: IsthmusPaths = .default) { self.paths = paths }

    public func list() -> [Bottle] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> Bottle? in
            let cfg = dir.appendingPathComponent("bottle.json")
            guard let config = try? JSON.read(BottleConfig.self, from: cfg) else { return nil }
            return Bottle(url: dir, config: config)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look up by id or (case-insensitive) display name.
    public func bottle(_ idOrName: String) throws -> Bottle {
        let all = list()
        if let b = all.first(where: { $0.id == idOrName }) ?? all.first(where: { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }) {
            return b
        }
        throw IsthmusError.bottleNotFound(idOrName)
    }

    /// Creates the bottle directory and config. Call `BottleSetup.initialize`
    /// afterwards to build the Wine prefix (slow: 20–60 s).
    public func create(name: String, engineVersion: String? = nil, settings: BottleSettings = .init()) throws -> Bottle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.slug
        guard !trimmed.isEmpty, !id.isEmpty, trimmed.count <= 64 else { throw IsthmusError.invalidName(name) }
        try paths.ensure()
        let dir = paths.bottles.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw IsthmusError.bottleExists(trimmed) }
        let bottle = Bottle(url: dir, config: BottleConfig(id: id, name: trimmed, engineVersion: engineVersion, settings: settings))
        for d in [bottle.prefix, bottle.logs, bottle.cache] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try bottle.save()
        return bottle
    }

    public func delete(_ bottle: Bottle) throws {
        // Move to Trash rather than unlinking: bottles hold save games.
        try FileManager.default.trashItem(at: bottle.url, resultingItemURL: nil)
    }

    public func rename(_ bottle: Bottle, to name: String) throws -> Bottle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.slug.isEmpty else { throw IsthmusError.invalidName(name) }
        if list().contains(where: { $0.id != bottle.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw IsthmusError.bottleExists(trimmed)
        }
        var b = bottle
        b.config.name = trimmed
        try b.save()
        return b
    }
}
