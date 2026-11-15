import Foundation

/// What to run and how. Built by `LaunchPlanner`, executed by `WineRunner`.
public struct LaunchPlan: Sendable, Equatable {
    public var engineRoot: URL
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var backend: GraphicsBackend
    public var recipe: Recipe?
    /// Components the recipe wants that aren't installed yet.
    public var missingComponents: [String]
    /// Store client this launch goes through ("steam", "epic"), if any.
    /// Games started by a running client inherit the client's runtime.
    public var launcherID: String? = nil
}

/// Identifies what's being launched so recipes can match.
public struct LaunchTarget: Sendable, Equatable {
    /// Program to run: Unix path, Windows path, or a builtin like `winecfg`.
    public var program: String
    public var arguments: [String]
    public var steamAppID: Int?
    public var epicAppName: String?
    public var gogID: String?
    /// Executable to inspect for DirectX level / recipe match when `program`
    /// is a launcher (e.g. steam.exe launching a game).
    public var inspect: URL?
    /// One-off backend for this launch (CLI `--graphics`, "Run with…" menu).
    public var graphicsOverride: GraphicsBackend?

    public init(program: String, arguments: [String] = [], steamAppID: Int? = nil,
                epicAppName: String? = nil, gogID: String? = nil, inspect: URL? = nil,
                graphicsOverride: GraphicsBackend? = nil) {
        self.program = program; self.arguments = arguments; self.steamAppID = steamAppID
        self.epicAppName = epicAppName; self.gogID = gogID; self.inspect = inspect
        self.graphicsOverride = graphicsOverride
    }

    /// Key for per-program settings. Store games are keyed by store id
    /// because they all launch through the same client executable.
    public func settingsKey(in bottle: Bottle) -> String {
        if let steamAppID { return "steam:\(steamAppID)" }
        if let epicAppName { return "epic:\(epicAppName.lowercased())" }
        if program.contains("://") { return program }
        let isWindowsPath = program.count > 2 && program.dropFirst().hasPrefix(":")
        guard program.hasPrefix("/") || isWindowsPath || program.contains("\\") else { return program.lowercased() }
        return Bottle.programKey(bottle.windowsPath(forUnixPath: bottle.unixPath(forWindowsPath: program)))
    }
}

/// The settings that actually apply to one launch, after layering
/// bottle defaults ← recipe ← per-program overrides.
public struct EffectiveSettings: Sendable, Equatable {
    public var graphics: GraphicsBackend
    public var msync: Bool
    public var advertiseAVX: Bool
    public var metalHUD: Bool
    public var rayTracing: Bool
    public var metalFXUpscaling: Bool
    public var largeAddressAware: Bool
    public var logging: BottleSettings.LogLevel
    public var arguments: [String]
    public var environment: [String: String]
    public var dllOverrides: [String: String]

    public static func merge(bottle b: BottleSettings, recipe: Recipe.Settings?, program p: ProgramSettings) -> EffectiveSettings {
        let r = recipe ?? Recipe.Settings()
        return EffectiveSettings(
            graphics: p.graphics ?? r.graphics ?? b.graphics,
            msync: p.msync ?? r.msync ?? b.msync,
            advertiseAVX: p.advertiseAVX ?? r.advertiseAVX ?? b.advertiseAVX,
            metalHUD: p.metalHUD ?? b.metalHUD,
            rayTracing: p.rayTracing ?? r.rayTracing ?? b.rayTracing,
            metalFXUpscaling: p.metalFXUpscaling ?? r.metalFXUpscaling ?? b.metalFXUpscaling,
            largeAddressAware: b.largeAddressAware,
            logging: b.logging,
            arguments: (r.arguments ?? []) + (p.arguments ?? []),
            environment: b.environment.merging(r.environment ?? [:]) { $1 }.merging(p.environment ?? [:]) { $1 },
            dllOverrides: b.dllOverrides.merging(r.dllOverrides ?? [:]) { $1 }.merging(p.dllOverrides ?? [:]) { $1 }
        )
    }
}

public struct LaunchPlanner: Sendable {
    public var paths: IsthmusPaths
    public var recipes: RecipeBook

    public init(paths: IsthmusPaths = .default, recipes: RecipeBook? = nil) {
        self.paths = paths
        self.recipes = recipes ?? RecipeBook.load(paths: paths)
    }

    public func plan(bottle: Bottle, target: LaunchTarget) throws -> LaunchPlan {
        let engine = try EngineManager(paths: paths).engine(bottle.config.engineVersion)
        let d3dmetal = D3DMetalStore(paths: paths).current

        guard Doctor.rosettaInstalled || ProcessInfo.processInfo.environment["ISTHMUS_SKIP_ROSETTA_CHECK"] != nil else {
            throw IsthmusError.unsupported("Rosetta 2 isn't installed. Windows games need it; install it from the Engines & Graphics page or run `softwareupdate --install-rosetta`.")
        }
        // What are we really running?
        let resolved = resolveProgram(target.program, bottle: bottle)
        try Self.validate(target.program, resolved: resolved, bottle: bottle)
        let inspectURL = target.inspect ?? resolved.inspect
        let exeName = inspectURL?.lastPathComponent ?? resolved.inspect?.lastPathComponent
        let program = bottle.config.programs[target.settingsKey(in: bottle)] ?? ProgramSettings()
        let recipe = program.ignoreRecipe == true ? nil :
            recipes.recipe(exeName: exeName, steamAppID: target.steamAppID, epicAppName: target.epicAppName, gogID: target.gogID)
        var effective = EffectiveSettings.merge(bottle: bottle.config.settings, recipe: recipe?.settings, program: program)
        if let forced = target.graphicsOverride { effective.graphics = forced }

        let dx: DirectXLevel = inspectURL.flatMap { try? PEFile(url: $0).directXLevel } ?? .unknown
        let backend = BackendResolver.resolve(effective.graphics, directX: dx, d3dmetalAvailable: d3dmetal != nil)
        let root = try RuntimeOverlay.prepare(engine: engine, backend: backend, d3dmetal: d3dmetal,
                                              nvext: effective.metalFXUpscaling, paths: paths)
        try RuntimeOverlay.installStubs(engine: engine, backend: backend, d3dmetal: d3dmetal, into: bottle)

        let env = Self.environment(engineRoot: root, bottle: bottle, settings: effective, backend: backend)
        let missing = (recipe?.settings.components ?? []).filter { !bottle.config.components.contains($0) }
        return LaunchPlan(engineRoot: root,
                          executable: root.appendingPathComponent("bin/wine"),
                          arguments: resolved.wineArguments + target.arguments + effective.arguments,
                          environment: env,
                          workingDirectory: resolved.workingDirectory,
                          backend: backend, recipe: recipe, missingComponents: missing,
                          launcherID: Self.launcherID(for: target))
    }

    /// File types Wine can start.
    public static let runnableExtensions: Set<String> = ["exe", "msi", "bat", "cmd", "lnk", "url", "com"]

    static func validate(_ program: String, resolved: ResolvedProgram, bottle: Bottle) throws {
        guard resolved.isPath else { return }
        let unix = bottle.unixPath(forWindowsPath: program)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: unix.path, isDirectory: &isDir) else {
            throw IsthmusError.unsupported("\(unix.lastPathComponent) wasn't found at \(unix.deletingLastPathComponent().path). It may have been moved, deleted, or be on a disconnected drive.")
        }
        if isDir.boolValue || !runnableExtensions.contains(unix.pathExtension.lowercased()) {
            if unix.pathExtension.lowercased() == "app" {
                throw IsthmusError.unsupported("\(unix.lastPathComponent) is a Mac app. Open it directly from Finder.")
            }
            throw IsthmusError.unsupported("\(unix.lastPathComponent) isn't a Windows program. Isthmus can run .exe, .msi, .bat and .lnk files.")
        }
    }

    static func launcherID(for target: LaunchTarget) -> String? {
        if target.steamAppID != nil { return "steam" }
        if target.epicAppName != nil && target.program.contains("://") { return "epic" }
        let name = (target.program as NSString).lastPathComponent.lowercased()
        let leaf = name.split(separator: "\\").last.map(String.init) ?? name
        if leaf == "steam.exe" { return "steam" }
        if leaf == "epicgameslauncher.exe" { return "epic" }
        return nil
    }

    struct ResolvedProgram {
        var wineArguments: [String]
        var workingDirectory: URL?
        var inspect: URL?
        var key: String
        var isPath = true
    }

    func resolveProgram(_ program: String, bottle: Bottle) -> ResolvedProgram {
        let isWindowsPath = program.count > 2 && program.dropFirst().hasPrefix(":")
        let isPath = program.hasPrefix("/") || isWindowsPath || program.contains("\\")
        guard isPath else {
            // Builtin program (winecfg, regedit, explorer, cmd, taskmgr, …) or URL.
            if program.contains("://") { return ResolvedProgram(wineArguments: ["start", "", program], workingDirectory: nil, inspect: nil, key: program, isPath: false) }
            return ResolvedProgram(wineArguments: [program], workingDirectory: nil, inspect: nil, key: program, isPath: false)
        }
        let unix = bottle.unixPath(forWindowsPath: program)
        let key = Bottle.programKey(bottle.windowsPath(forUnixPath: unix))
        let dir = unix.deletingLastPathComponent()
        switch unix.pathExtension.lowercased() {
        case "msi":
            return ResolvedProgram(wineArguments: ["msiexec", "/i", unix.path], workingDirectory: dir, inspect: nil, key: key)
        case "bat", "cmd":
            return ResolvedProgram(wineArguments: ["cmd", "/c", unix.path], workingDirectory: dir, inspect: nil, key: key)
        case "lnk", "url":
            return ResolvedProgram(wineArguments: ["start", "/unix", unix.path], workingDirectory: dir, inspect: nil, key: key)
        default:
            return ResolvedProgram(wineArguments: [unix.path], workingDirectory: dir, inspect: unix, key: key)
        }
    }

    /// Pure function: everything Wine and the translation layers read from the environment.
    public static func environment(engineRoot root: URL, bottle: Bottle, settings s: EffectiveSettings,
                                   backend: GraphicsBackend, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL"] {
            if let v = base[key] { env[key] = v }
        }
        // Apps started from Finder get no LANG; Wine would fall back to the C
        // locale (English UI, broken non-ASCII paths). Derive it from macOS.
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = posixLocale() }
        let lib = root.appendingPathComponent("lib").path
        // With WINEDLLPATH set, the CrossOver loader re-execs through a link
        // named after the .exe, so the Dock shows the game's name, not "wine".
        env["WINEDLLPATH"] = lib + "/wine"
        env["PATH"] = "\(root.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = bottle.prefix.path
        env["WINEDEBUG"] = switch s.logging {
        case .quiet: "-all"
        case .normal: "-all,err+all"
        case .verbose: "fixme-all,warn+all,err+all,+loaddll,+seh"
        }
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [lib, lib + "/external", "/usr/lib"].joined(separator: ":")
        env["VK_DRIVER_FILES"] = root.appendingPathComponent("share/vulkan/icd.d/MoltenVK_icd.json").path
        env["VK_ICD_FILENAMES"] = env["VK_DRIVER_FILES"]
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = lib + "/gstreamer-1.0"
        env["GST_PLUGIN_PATH_1_0"] = lib + "/gstreamer-1.0"
        env["GST_REGISTRY_1_0"] = bottle.cache.appendingPathComponent("gstreamer-registry.bin").path
        env["GST_REGISTRY_FORK"] = "no"
        // MoltenVK: survive transient device loss and use Metal fences for speed.
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        env["MVK_ALLOW_METAL_FENCES"] = "1"

        if s.msync { env["WINEMSYNC"] = "1" }
        if s.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if s.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if s.largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = "1" }

        var overrides = ["winemenubuilder.exe": "d"]   // no desktop/file-association spam
        switch backend {
        case .d3dmetal:
            if s.rayTracing { env["D3DM_SUPPORT_DXR"] = "1" }
            overrides["d3d11"] = "b"; overrides["d3d12"] = "b"; overrides["dxgi"] = "b"
        case .dxmt:
            overrides["d3d11"] = "b"; overrides["dxgi"] = "b"; overrides["d3d10core"] = "b"
            env["DXMT_SHADER_CACHE_PATH"] = bottle.cache.appendingPathComponent("dxmt").path
            if s.logging == .verbose { env["DXMT_LOG_LEVEL"] = "info" }
            if s.metalFXUpscaling { overrides["nvapi64"] = "b"; overrides["nvngx"] = "b"; env["DXMT_ENABLE_NVEXT"] = "1" }
        case .dxvk:
            overrides["d3d11"] = "b"; overrides["d3d10core"] = "b"
            env["DXVK_ASYNC"] = "1"
            env["DXVK_STATE_CACHE_PATH"] = bottle.cache.path
            if s.metalHUD { env["DXVK_HUD"] = "fps,devinfo" }
        case .wined3d, .auto:
            // wined3d's Vulkan renderer on MoltenVK rejects some SM4 shaders;
            // the GL renderer passes our D3D9/10/11 probes.
            env["WINE_D3D_CONFIG"] = "renderer=gl"
        }
        for (k, v) in s.dllOverrides { overrides[k.lowercased()] = v }
        env["WINEDLLOVERRIDES"] = overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" }.joined(separator: ";")

        for (k, v) in s.environment { env[k] = v }
        return env
    }
}

/// `en_US.UTF-8`-style locale from the user's macOS language settings.
public func posixLocale(_ locale: Locale = .current) -> String {
    let lang = locale.language.languageCode?.identifier ?? "en"
    // No region (e.g. just "ja"): use the language's most likely one ("ja-Jpan-JP" → JP).
    let likely = Locale.Language(identifier: lang).maximalIdentifier.split(separator: "-").last.map(String.init)
    let region = locale.region?.identifier ?? likely.flatMap { $0.count == 2 ? $0 : nil } ?? "US"
    return "\(lang)_\(region).UTF-8"
}

/// A running Wine process started by Isthmus.
public final class RunningProgram: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let bottleID: String
    public let title: String
    public let logURL: URL
    public let started = Date()
    let process: Process
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    init(bottleID: String, title: String, logURL: URL, process: Process) {
        self.bottleID = bottleID; self.title = title; self.logURL = logURL; self.process = process
    }

    public func terminate() { process.terminate() }

    public func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

public enum WineRunner {
    /// Largest log kept per launch; verbose Wine logging can produce GBs.
    public static let logLimit = 64 << 20

    /// Start a program and return immediately. Output goes to a per-launch log.
    public static func launch(_ plan: LaunchPlan, bottle: Bottle, title: String,
                              onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProgram {
        try FileManager.default.createDirectory(at: bottle.logs, withIntermediateDirectories: true)
        pruneLogs(in: bottle.logs, keep: 30)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = title.slug.isEmpty ? "program" : String(title.slug.prefix(60))
        let logURL = bottle.logs.appendingPathComponent("\(stamp)-\(safe).log")
        FileManager.default.createFile(atPath: logURL.path, contents: header(plan, title: title))
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        let writer = CappedLogWriter(handle: log, limit: logLimit)

        let pipe = Pipe()
        let p = Process()
        p.executableURL = plan.executable
        p.arguments = plan.arguments
        p.environment = plan.environment
        p.currentDirectoryURL = plan.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { writer.write(d) }
        }
        p.terminationHandler = { proc in
            // Drain what's left, then close.
            pipe.fileHandleForReading.readabilityHandler = nil
            writer.write(pipe.fileHandleForReading.readDataToEndOfFile())
            let how = proc.terminationReason == .uncaughtSignal
                ? "was killed by signal \(proc.terminationStatus)\(proc.terminationStatus == SIGKILL ? " (Stop All / wineserver -k, or macOS)" : "")"
                : "exited with status \(proc.terminationStatus)"
            writer.write(Data("\n# \(how) at \(Date())\n".utf8), force: true)
            writer.close()
            onExit?(proc.terminationStatus)
        }
        try p.run()
        return RunningProgram(bottleID: bottle.id, title: title, logURL: logURL, process: p)
    }

    /// Run to completion and capture output (wineboot, reg, installers).
    @discardableResult
    public static func run(_ plan: LaunchPlan, timeout: TimeInterval? = nil) throws -> Shell.Result {
        let p = Process()
        p.executableURL = plan.executable
        p.arguments = plan.arguments
        p.environment = plan.environment
        p.currentDirectoryURL = plan.workingDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Shell.Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `wineserver -k`: stop every process in the bottle.
    /// Returns once the wineserver is gone, so a launch right afterwards
    /// starts a fresh server instead of joining the dying one.
    public static func killAll(bottle: Bottle, paths: IsthmusPaths = .default) throws {
        let engine = try EngineManager(paths: paths).engine(bottle.config.engineVersion)
        try Shell.run(engine.wineserver.path, ["-k"], environment: ["WINEPREFIX": bottle.prefix.path], allowFailure: true)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, WineServer.isRunning(bottle) { Thread.sleep(forTimeInterval: 0.2) }
    }

    /// `wineserver -w`: wait until the bottle is idle (all processes exited),
    /// giving up after `timeout`. Returns true if it went idle.
    /// Never call this without a timeout while user programs may be running:
    /// an open Steam client would block it forever.
    @discardableResult
    public static func waitIdle(bottle: Bottle, paths: IsthmusPaths = .default, timeout: TimeInterval) throws -> Bool {
        guard WineServer.isRunning(bottle) else { return true }
        let engine = try EngineManager(paths: paths).engine(bottle.config.engineVersion)
        let p = Process()
        p.executableURL = engine.wineserver
        p.arguments = ["-w"]
        p.environment = ["WINEPREFIX": bottle.prefix.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return false }
        return true
    }

    static func header(_ plan: LaunchPlan, title: String) -> Data {
        var s = "# Isthmus \(Isthmus.version) — \(title)\n"
        s += "# started \(Date())\n# backend \(plan.backend.rawValue)\n"
        if let r = plan.recipe { s += "# recipe \(r.id) (\(r.status.rawValue))\n" }
        s += "# command \(([plan.executable.path] + plan.arguments).joined(separator: " "))\n"
        for k in plan.environment.keys.sorted() where k.hasPrefix("WINE") || k.hasPrefix("DXVK") || k.hasPrefix("MTL") || k.hasPrefix("ROSETTA") || k.hasPrefix("D3DM") || k.hasPrefix("DXMT") {
            s += "# env \(k)=\(plan.environment[k]!)\n"
        }
        return Data((s + "\n").utf8)
    }

    static func pruneLogs(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.filter { $0.pathExtension == "log" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(keep) { try? fm.removeItem(at: f) }
    }
}

/// Writes Wine output to the log until `limit` bytes, then notes the
/// truncation and discards the rest (the pipe must keep draining or the
/// game would block on a full pipe).
final class CappedLogWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private var written = 0
    private var truncated = false
    private var closed = false
    private let lock = NSLock()

    init(handle: FileHandle, limit: Int) { self.handle = handle; self.limit = limit }

    func write(_ data: Data, force: Bool = false) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if force || written + data.count <= limit {
            try? handle.write(contentsOf: data); written += data.count
        } else if !truncated {
            let room = max(0, limit - written)
            try? handle.write(contentsOf: data.prefix(room))
            try? handle.write(contentsOf: Data("\n# log truncated at \(limit >> 20) MB; set logging to Errors or Quiet for long sessions\n".utf8))
            written = limit; truncated = true
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
