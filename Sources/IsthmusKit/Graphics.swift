import Foundation

/// A D3DMetal redistributable imported from Apple's Game Porting Toolkit.
/// Isthmus never ships D3DMetal; the user downloads the toolkit from
/// developer.apple.com and imports it, which keeps us inside Apple's license.
public struct D3DMetalInstall: Sendable, Equatable {
    public let url: URL
    public let version: String
    /// Mirrors the toolkit's `redist/lib` tree (`external/`, `wine/`).
    public var lib: URL { url.appendingPathComponent("lib", isDirectory: true) }
    public var framework: URL { lib.appendingPathComponent("external/D3DMetal.framework") }
}

public struct D3DMetalStore: Sendable {
    public let paths: IsthmusPaths
    public init(paths: IsthmusPaths = .default) { self.paths = paths }

    public func installed() -> [D3DMetalInstall] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.d3dmetal, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            let fw = dir.appendingPathComponent("lib/external/D3DMetal.framework")
            guard fm.fileExists(atPath: fw.path) else { return nil }
            return D3DMetalInstall(url: dir, version: dir.lastPathComponent)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    public var current: D3DMetalInstall? { installed().first }

    /// Import from the Game Porting Toolkit `.dmg` (outer or inner image), a
    /// mounted volume, or any folder containing `redist/lib/external/D3DMetal.framework`.
    @discardableResult
    public func importToolkit(from source: URL) throws -> D3DMetalInstall {
        try paths.ensure()
        // CrossOver's copy of D3DMetal is licensed to CodeWeavers for use in
        // CrossOver; it must come from Apple's toolkit download instead.
        let resolved = source.resolvingSymlinksInPath().path.lowercased()
        if resolved.contains("crossover.app") || resolved.contains("/crossover/") {
            throw IsthmusError.d3dmetalNotFound("that's CrossOver's copy, which is licensed for CrossOver only. Download the Game Porting Toolkit from developer.apple.com and import that instead.")
        }
        if source.pathExtension.lowercased() == "dmg" {
            return try withMountedImage(source) { mount in try importToolkit(from: mount) }
        }
        if let redistLib = Self.findRedistLib(in: source, depth: 5) {
            return try copyRedist(redistLib)
        }
        // Outer toolkit image contains the "Evaluation environment" image.
        if let nested = Self.findFiles(in: source, depth: 3, where: { $0.pathExtension.lowercased() == "dmg" }).first {
            return try importToolkit(from: nested)
        }
        throw IsthmusError.d3dmetalNotFound("no redist/lib/external/D3DMetal.framework in \(source.lastPathComponent)")
    }

    public func remove(_ install: D3DMetalInstall) throws {
        try FileManager.default.removeItem(at: install.url)
        RuntimeOverlay.purgeAll(paths: paths)
    }

    private func copyRedist(_ redistLib: URL) throws -> D3DMetalInstall {
        let fw = redistLib.appendingPathComponent("external/D3DMetal.framework")
        let version = Self.frameworkVersion(fw) ?? "unknown"
        let dest = paths.d3dmetal.appendingPathComponent(version, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/ditto", [redistLib.path, dest.appendingPathComponent("lib").path])
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        RuntimeOverlay.purgeAll(paths: paths)
        return D3DMetalInstall(url: dest, version: version)
    }

    static func frameworkVersion(_ fw: URL) -> String? {
        for plist in ["Versions/A/Resources/Info.plist", "Resources/Info.plist", "Info.plist"] {
            let url = fw.appendingPathComponent(plist)
            if let dict = NSDictionary(contentsOf: url),
               let v = (dict["CFBundleShortVersionString"] ?? dict["CFBundleVersion"]) as? String {
                return v
            }
        }
        return nil
    }

    static func findRedistLib(in root: URL, depth: Int) -> URL? {
        let direct = root.appendingPathComponent("redist/lib")
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("external/D3DMetal.framework").path) { return direct }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("external/D3DMetal.framework").path) { return root }
        return findFiles(in: root, depth: depth, where: { $0.lastPathComponent == "D3DMetal.framework" })
            .first.map { $0.deletingLastPathComponent().deletingLastPathComponent() }
    }

    static func findFiles(in root: URL, depth: Int, where match: (URL) -> Bool) -> [URL] {
        guard depth >= 0, let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var found: [URL] = []
        for item in items {
            if match(item) { found.append(item); continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true, item.pathExtension != "framework" {
                found += findFiles(in: item, depth: depth - 1, where: match)
            }
        }
        return found
    }

    private func withMountedImage<T>(_ dmg: URL, _ body: (URL) throws -> T) throws -> T {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("isthmus-gptk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        // Images with a license agreement prompt on stdin; accept it (the user
        // already agreed when downloading from Apple).
        try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path, dmg.path],
                      input: "Y\n")
        defer {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], allowFailure: true)
            try? FileManager.default.removeItem(at: mount)
        }
        return try body(mount)
    }
}

/// Which DirectX generation an executable uses, from its PE imports.
public enum DirectXLevel: Int, Sendable, Comparable, Codable {
    /// `d3d11and12`: links both. Unreal/Unity games try 12 and fall back to
    /// 11; Chromium/Electron-based games link 12 for WebGPU but render with 11.
    case unknown = 0, d3d9 = 9, d3d10 = 10, d3d11 = 11, d3d11and12 = 13, d3d12 = 12
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(imports: [String]) {
        let set = Set(imports.map { $0.lowercased() })
        let has12 = set.contains("d3d12.dll") || set.contains("d3d12core.dll")
        let has11 = set.contains("d3d11.dll")
        if has12 && has11 { self = .d3d11and12 }
        else if has12 { self = .d3d12 }
        else if set.contains("d3d11.dll") || set.contains("dxgi.dll") { self = .d3d11 }
        else if set.contains("d3d10.dll") || set.contains("d3d10_1.dll") || set.contains("d3d10core.dll") { self = .d3d10 }
        else if set.contains(where: { $0.hasPrefix("d3d9") || $0.hasPrefix("d3d8") }) { self = .d3d9 }
        else { self = .unknown }
    }
}

public enum BackendResolver {
    /// Concrete backend for a launch. Never returns `.auto`.
    public static func resolve(_ requested: GraphicsBackend, directX: DirectXLevel, d3dmetalAvailable: Bool) -> GraphicsBackend {
        switch requested {
        case .d3dmetal: return d3dmetalAvailable ? .d3dmetal : (directX == .d3d12 ? .wined3d : .dxmt)
        case .dxmt, .dxvk, .wined3d: return requested
        case .auto:
            switch directX {
            case .d3d12: return d3dmetalAvailable ? .d3dmetal : .wined3d
            // Games linking both (most Unreal/Unity titles) try DX12 first and
            // fall back to DX11. Without D3DMetal, DXMT handles the DX11 path:
            // One More Lawn (Unreal) ran 43 minutes this way in testing.
            case .d3d11and12: return d3dmetalAvailable ? .d3dmetal : .dxmt
            case .d3d11, .d3d10: return .dxmt
            case .d3d9: return .wined3d
            case .unknown: return d3dmetalAvailable ? .d3dmetal : .dxmt
            }
        }
    }
}

/// Builds per-backend engine trees by hardlinking the base engine and
/// replacing the Direct3D DLLs. Wine resolves its DLL directory from the
/// real path of ntdll.so, so each overlay behaves as an independent engine.
public enum RuntimeOverlay {
    public struct Key: Hashable, Sendable {
        public var engineVersion: String
        public var backend: GraphicsBackend
        public var d3dmetalVersion: String?
        public var nvext: Bool

        /// Bump when the overlay layout changes so old overlays are rebuilt.
        static let format = 3

        var directoryName: String {
            var s = "\(engineVersion)-\(backend.rawValue)-f\(Self.format)"
            if backend == .d3dmetal, let v = d3dmetalVersion { s += "-gptk\(v)" }
            if nvext { s += "-nvext" }
            return s
        }
    }

    /// Returns a directory laid out like an engine (bin/, lib/, share/).
    public static func prepare(engine: Engine, backend: GraphicsBackend, d3dmetal: D3DMetalInstall?,
                               nvext: Bool, paths: IsthmusPaths) throws -> URL {
        precondition(backend != .auto, "resolve the backend first")
        if backend == .wined3d { return engine.url }

        let key = Key(engineVersion: engine.version, backend: backend,
                      d3dmetalVersion: backend == .d3dmetal ? d3dmetal?.version : nil,
                      nvext: backend == .dxmt && nvext)
        let dest = paths.runtime.appendingPathComponent(key.directoryName, isDirectory: true)
        let marker = dest.appendingPathComponent(".complete")
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path) { return dest }

        try paths.ensure()
        let tmp = paths.runtime.appendingPathComponent(".build-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try linkTree(from: engine.url, to: tmp)
        // The loader must NOT be a hardlink: Wine's Dock-name hack keys its
        // temp re-exec directory on the loader's inode, and a shared inode
        // would make every backend reuse whichever runtime ran first.
        for rel in ["bin/wine", "lib/wine/x86_64-unix/wine", "lib/wine/x86_64-unix/wine-preloader"] {
            let src = engine.url.appendingPathComponent(rel)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = tmp.appendingPathComponent(rel)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }

        let wine = tmp.appendingPathComponent("lib/wine")
        switch backend {
        case .dxmt:
            try overlay(from: engine.dxmt, into: wine, skip: nvext ? [] : ["nvapi64.dll", "nvngx.dll"])
        case .dxvk:
            try overlay(from: engine.dxvk, into: wine, skip: [])
        case .d3dmetal:
            guard let d3dmetal else { throw IsthmusError.d3dmetalNotFound("not imported") }
            try overlay(from: d3dmetal.lib, into: tmp.appendingPathComponent("lib"), skip: [])
        case .auto, .wined3d:
            break
        }
        fm.createFile(atPath: tmp.appendingPathComponent(".complete").path, contents: Data(key.directoryName.utf8))
        // Another launch may have finished the same overlay while we built ours.
        if fm.fileExists(atPath: marker.path) { return dest }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }   // stale, incomplete
        do {
            try fm.moveItem(at: tmp, to: dest)
        } catch where fm.fileExists(atPath: marker.path) {
            return dest
        }
        return dest
    }

    /// Recreate `src` under `dst` with hardlinks (falls back to copies across volumes).
    static func linkTree(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(atPath: src.path) else { return }
        while let rel = walker.nextObject() as? String {
            let item = src.appendingPathComponent(rel)
            let target = dst.appendingPathComponent(rel)
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: item.path))
            } else if type == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                do { try fm.linkItem(at: item, to: target) } catch { try fm.copyItem(at: item, to: target) }
            }
        }
    }

    /// Copy every file under `src` to the same relative path under `dst`,
    /// replacing what's there (unlink first so the base engine's inode is untouched).
    static func overlay(from src: URL, into dst: URL, skip: Set<String>) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path), let walker = fm.enumerator(atPath: src.path) else {
            throw IsthmusError.unsupported("missing translation layer at \(src.path)")
        }
        while let rel = walker.nextObject() as? String {
            let item = src.appendingPathComponent(rel)
            let target = dst.appendingPathComponent(rel)
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if item.pathExtension == "framework" {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: item, to: target)
                    walker.skipDescendants()
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                continue
            }
            if skip.contains(item.lastPathComponent.lowercased()) { continue }
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if type == .typeSymbolicLink {
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: item.path))
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    /// Wine only falls back to its builtin DLL directory for modules that
    /// have a stub in the prefix's system32/syswow64. Translation layers add
    /// modules Wine doesn't ship (DXMT's winemetal.dll, nvngx.dll …), so copy
    /// their builtin-marked PE files into the prefix when they're missing.
    public static func installStubs(engine: Engine, backend: GraphicsBackend, d3dmetal: D3DMetalInstall?, into bottle: Bottle) throws {
        let source: URL?
        switch backend {
        case .dxmt: source = engine.dxmt
        case .dxvk: source = engine.dxvk
        case .d3dmetal: source = d3dmetal?.lib.appendingPathComponent("wine")
        case .auto, .wined3d: source = nil
        }
        guard let source else { return }
        let fm = FileManager.default
        let windows = bottle.driveC.appendingPathComponent("windows")
        for (arch, dir) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let from = source.appendingPathComponent(arch)
            let to = windows.appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil),
                  fm.fileExists(atPath: to.path) else { continue }
            for f in files where ["dll", "exe"].contains(f.pathExtension.lowercased()) {
                let dest = to.appendingPathComponent(f.lastPathComponent.lowercased())
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: f, to: dest) }
            }
        }
    }

    public static func purge(paths: IsthmusPaths, engineVersion: String) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.runtime, includingPropertiesForKeys: nil) else { return }
        for d in dirs where d.lastPathComponent.hasPrefix(engineVersion + "-") { try? fm.removeItem(at: d) }
    }

    public static func purgeAll(paths: IsthmusPaths) {
        try? FileManager.default.removeItem(at: paths.runtime)
    }
}
