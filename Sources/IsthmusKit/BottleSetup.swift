import Foundation
import CryptoKit

/// Builds REGEDIT4 files. Wine's `regedit /S` imports them atomically,
/// which is much faster than one `reg add` process per value.
public struct RegFile: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case dword(UInt32)
        case delete
    }

    private var keys: [(String, [(String, Value)])] = []

    public init() {}

    public mutating func set(_ key: String, _ name: String, _ value: Value) {
        if let i = keys.firstIndex(where: { $0.0 == key }) { keys[i].1.append((name, value)) }
        else { keys.append((key, [(name, value)])) }
    }

    public static func == (a: RegFile, b: RegFile) -> Bool { a.text == b.text }

    public var text: String {
        var out = "REGEDIT4\n"
        for (key, values) in keys {
            out += "\n[\(key)]\n"
            for (name, value) in values {
                let n = "\"\(escape(name))\""
                switch value {
                case .string(let s): out += "\(n)=\"\(escape(s))\"\n"
                case .dword(let d): out += "\(n)=dword:\(String(format: "%08x", d))\n"
                case .delete: out += "\(n)=-\n"
                }
            }
        }
        return out
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Registry state derived from bottle settings.
    public static func forSettings(_ s: BottleSettings) -> RegFile {
        var r = RegFile()
        let mac = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver"
        r.set(mac, "RetinaMode", .string(s.retinaMode ? "y" : "n"))
        r.set(mac, "LeftOptionIsAlt", .string(s.leftOptionIsAlt ? "y" : "n"))
        r.set(mac, "RightOptionIsAlt", .string(s.rightOptionIsAlt ? "y" : "n"))
        r.set(mac, "LeftCommandIsCtrl", .string(s.commandIsCtrl ? "y" : "n"))
        r.set(mac, "RightCommandIsCtrl", .string(s.commandIsCtrl ? "y" : "n"))
        // Retina doubles the pixel count; double DPI so UI text stays readable.
        r.set("HKEY_CURRENT_USER\\Control Panel\\Desktop", "LogPixels", .dword(s.retinaMode ? 192 : 96))
        // Don't let a crashing game pop a modal debugger dialog.
        r.set("HKEY_CURRENT_USER\\Software\\Wine\\WineDbg", "ShowCrashDialog", .dword(0))
        return r
    }
}

public struct BottleSetup: Sendable {
    public var paths: IsthmusPaths
    public init(paths: IsthmusPaths = .default) { self.paths = paths }

    /// Plan for Wine's own tools (wineboot, regedit, installers): base engine,
    /// quiet logging, no graphics overlay.
    public func utilityPlan(bottle: Bottle, arguments: [String], workingDirectory: URL? = nil) throws -> LaunchPlan {
        let engine = try EngineManager(paths: paths).engine(bottle.config.engineVersion)
        var s = EffectiveSettings.merge(bottle: bottle.config.settings, recipe: nil, program: ProgramSettings())
        s.logging = .quiet
        var env = LaunchPlanner.environment(engineRoot: engine.url, bottle: bottle, settings: s, backend: .wined3d)
        // Installers that crash shouldn't open an interactive debugger window.
        env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"] ?? "") + ";winedbg.exe=d"
        return LaunchPlan(engineRoot: engine.url, executable: engine.wineLoader, arguments: arguments,
                          environment: env, workingDirectory: workingDirectory, backend: .wined3d,
                          recipe: nil, missingComponents: [])
    }

    /// Create the Wine prefix and apply settings. Safe to call again.
    public func initialize(_ bottle: Bottle, progress: (@Sendable (String) -> Void)? = nil) throws -> Bottle {
        progress?("Creating Windows environment…")
        let boot = try WineRunner.run(try utilityPlan(bottle: bottle, arguments: ["wineboot", "--init"]), timeout: 600)
        try WineRunner.waitIdle(bottle: bottle, paths: paths)
        guard bottle.isInitialized else {
            throw IsthmusError.processFailed(command: "wineboot --init", status: boot.status, output: boot.output)
        }
        progress?("Applying settings…")
        var b = bottle
        try applySettings(&b, force: true)
        return b
    }

    public static func registryHash(_ s: BottleSettings) -> String {
        let text = RegFile.forSettings(s).text + s.windowsVersion.rawValue
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Write registry-backed settings if they changed since last time.
    public func applySettings(_ bottle: inout Bottle, force: Bool = false) throws {
        let hash = Self.registryHash(bottle.config.settings)
        guard force || bottle.config.appliedRegistryHash != hash else { return }
        let reg = bottle.cache.appendingPathComponent("isthmus-settings.reg")
        try FileManager.default.createDirectory(at: bottle.cache, withIntermediateDirectories: true)
        try RegFile.forSettings(bottle.config.settings).text.write(to: reg, atomically: true, encoding: .utf8)
        try checked(WineRunner.run(try utilityPlan(bottle: bottle, arguments: ["regedit", "/S", reg.path]), timeout: 120), "regedit")
        try checked(WineRunner.run(try utilityPlan(bottle: bottle, arguments: ["winecfg", "/v", bottle.config.settings.windowsVersion.rawValue]), timeout: 120), "winecfg")
        try WineRunner.waitIdle(bottle: bottle, paths: paths)
        bottle.config.appliedRegistryHash = hash
        try bottle.save()
    }

    private func checked(_ r: Shell.Result, _ what: String) throws {
        if r.status != 0 { throw IsthmusError.processFailed(command: what, status: r.status, output: r.output) }
    }

    // MARK: Components & launchers

    /// Download and silently install a runtime component (Visual C++, .NET…).
    public func install(component id: String, into bottle: inout Bottle,
                        progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard let c = Catalog.component(id) else { throw IsthmusError.unsupported("Unknown component \(id).") }
        for inst in c.installers {
            let file = paths.cache.appendingPathComponent("components/\(c.id)/\(inst.fileName)")
            if !FileManager.default.fileExists(atPath: file.path) {
                progress?("Downloading \(c.name)…")
                try await Downloader.fetch(inst.url, to: file)
            }
            progress?("Installing \(c.name)…")
            let args = (file.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", file.path] : [file.path]) + inst.arguments
            let r = try WineRunner.run(try utilityPlan(bottle: bottle, arguments: args, workingDirectory: file.deletingLastPathComponent()), timeout: 1800)
            // VC++ returns 3010 (reboot required) and 1638 (newer already installed) on success.
            guard [0, 1638, 3010].contains(r.status) else {
                throw IsthmusError.processFailed(command: "\(c.name) installer", status: r.status, output: r.output)
            }
        }
        try WineRunner.waitIdle(bottle: bottle, paths: paths)
        if !bottle.config.components.contains(id) { bottle.config.components.append(id) }
        try bottle.save()
    }

    /// Download a store launcher's installer and run it. Returns the
    /// launcher's executable path if it exists afterwards.
    @discardableResult
    public func install(launcher id: String, into bottle: Bottle,
                        progress: (@Sendable (String) -> Void)? = nil) async throws -> URL? {
        guard let l = Catalog.launcher(id) else { throw IsthmusError.unsupported("Unknown launcher \(id).") }
        let file = paths.cache.appendingPathComponent("launchers/\(l.fileName)")
        progress?("Downloading \(l.name)…")
        try await Downloader.fetch(l.installerURL, to: file)
        progress?("Installing \(l.name)…")
        let args = (file.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", file.path] : [file.path]) + l.silentArguments
        _ = try WineRunner.run(try utilityPlan(bottle: bottle, arguments: args, workingDirectory: file.deletingLastPathComponent()), timeout: 3600)
        try WineRunner.waitIdle(bottle: bottle, paths: paths)
        let exe = bottle.unixPath(forWindowsPath: l.executable)
        return FileManager.default.fileExists(atPath: exe.path) ? exe : nil
    }

    public func isInstalled(launcher: LauncherInfo, in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: bottle.unixPath(forWindowsPath: launcher.executable).path)
    }
}
