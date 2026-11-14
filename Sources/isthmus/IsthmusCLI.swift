import ArgumentParser
import Foundation
import IsthmusKit

@main
struct IsthmusCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isthmus",
        abstract: "Run Windows games on Apple silicon Macs.",
        version: Isthmus.version,
        subcommands: [Doctor.self, EngineCmd.self, BottleCmd.self, Run.self, Play.self, Games.self,
                      Install.self, Kill.self, D3DMetalCmd.self, Recipes.self, Shortcut.self, SelfTestCmd.self]
    )
}

// MARK: Helpers

struct Common: ParsableArguments {
    @Option(name: .long, help: "Override the data directory (default: ~/Library/Application Support/Isthmus).")
    var home: String?

    var paths: IsthmusPaths {
        home.map { IsthmusPaths(root: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? .default
    }
}

func printTable(_ rows: [[String]]) {
    guard let first = rows.first else { return }
    let widths = (0..<first.count).map { c in rows.map { $0[c].count }.max() ?? 0 }
    for r in rows {
        print(r.enumerated().map { i, s in i == r.count - 1 ? s : s.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
}

func progressPrinter(_ label: String) -> @Sendable (Double) -> Void {
    { p in
        let pct = Int(p * 100)
        FileHandle.standardError.write(Data("\r\(label) \(pct)%".utf8))
        if pct >= 100 { FileHandle.standardError.write(Data("\n".utf8)) }
    }
}

let stepPrinter: @Sendable (String) -> Void = { msg in FileHandle.standardError.write(Data("==> \(msg)\n".utf8)) }

// MARK: doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check whether this Mac is ready to run games.")
    @OptionGroup var common: Common

    func run() throws {
        var failed = false
        for d in BottleStore(paths: common.paths).damaged() {
            print("! Bottle folder \(d.lastPathComponent) has a missing or unreadable bottle.json")
        }
        for c in IsthmusKit.Doctor(paths: common.paths).run() {
            let mark = switch c.level { case .ok: "✓"; case .warning: "!"; case .error: "✗" }
            if c.level == .error { failed = true }
            print("\(mark) \(c.title)\(c.detail.isEmpty ? "" : " — \(c.detail)")")
        }
        if failed { throw ExitCode(1) }
    }
}

// MARK: engine

struct EngineCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "engine", abstract: "Manage Wine engines.",
                                                    subcommands: [List.self, InstallEngine.self, Remove.self, Available.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed engines.")
        @OptionGroup var common: Common
        func run() throws {
            let engines = EngineManager(paths: common.paths).installed()
            if engines.isEmpty { print("No engines installed. Run `isthmus engine install`."); return }
            printTable([["VERSION", "WINE", "DXMT", "MOLTENVK"]] + engines.map {
                [$0.version, $0.manifest.wine, $0.manifest.components["dxmt"] ?? "-", $0.manifest.components["moltenvk"] ?? "-"]
            })
        }
    }

    struct Available: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List engines published on GitHub.")
        @OptionGroup var common: Common
        func run() async throws {
            let remote = try await EngineManager(paths: common.paths).availableRemote()
            if remote.isEmpty { print("No engine releases published yet."); return }
            for r in remote { print(r.version) }
        }
    }

    struct InstallEngine: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Install an engine from a file, or the latest release.")
        @OptionGroup var common: Common
        @Argument(help: "Path to an isthmus-engine-*.tar.xz. Omit to download the latest release.") var archive: String?
        @Option(help: "Expected SHA-256 of the archive.") var sha256: String?

        func run() async throws {
            let mgr = EngineManager(paths: common.paths)
            let engine: Engine
            if let archive {
                stepPrinter("Installing \(archive)")
                engine = try mgr.install(archive: URL(fileURLWithPath: (archive as NSString).expandingTildeInPath), expectedSHA256: sha256)
            } else {
                guard let latest = try await mgr.latestRemote() else { throw ValidationError("No engine releases published yet.") }
                engine = try await mgr.download(latest, progress: progressPrinter("Downloading engine \(latest.version)"))
            }
            print("Installed engine \(engine.version) (Wine \(engine.manifest.wine)).")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an engine.")
        @OptionGroup var common: Common
        @Argument var version: String
        func run() throws { try EngineManager(paths: common.paths).remove(version); print("Removed \(version).") }
    }
}

// MARK: bottle

struct BottleCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bottle", abstract: "Manage bottles (Windows environments).",
                                                    subcommands: [List.self, Create.self, Delete.self, Show.self, SetCmd.self, PathCmd.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bottles.")
        @OptionGroup var common: Common
        func run() throws {
            let bottles = BottleStore(paths: common.paths).list()
            if bottles.isEmpty { print("No bottles. Create one with `isthmus bottle create <name>`."); return }
            printTable([["ID", "NAME", "WINDOWS", "GRAPHICS", "ENGINE"]] + bottles.map {
                [$0.id, $0.name, $0.config.settings.windowsVersion.rawValue, $0.config.settings.graphics.rawValue, $0.config.engineVersion ?? "latest"]
            })
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and initialize a bottle.")
        @OptionGroup var common: Common
        @Argument var name: String
        @Option(help: "Engine version (default: newest installed).") var engine: String?
        @Option(help: "Windows version: \(WindowsVersion.allCases.map(\.rawValue).joined(separator: ", ")).") var windows: String = "win10"

        func run() throws {
            guard let wv = WindowsVersion(rawValue: windows) else { throw ValidationError("Unknown Windows version \(windows).") }
            _ = try EngineManager(paths: common.paths).engine(engine)
            var s = BottleSettings(); s.windowsVersion = wv
            let b = try BottleStore(paths: common.paths).create(name: name, engineVersion: engine, settings: s)
            do {
                _ = try BottleSetup(paths: common.paths).initialize(b, progress: stepPrinter)
            } catch {
                try? FileManager.default.removeItem(at: b.url)
                throw error
            }
            print("Created bottle \"\(b.name)\" (\(b.id)).")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a bottle to the Trash.")
        @OptionGroup var common: Common
        @Argument var bottle: String
        func run() throws {
            let store = BottleStore(paths: common.paths)
            let b = try store.bottle(bottle)
            try? WineRunner.killAll(bottle: b, paths: common.paths)
            try store.delete(b)
            print("Moved \"\(b.name)\" to the Trash.")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a bottle's configuration as JSON.")
        @OptionGroup var common: Common
        @Argument var bottle: String
        func run() throws {
            let b = try BottleStore(paths: common.paths).bottle(bottle)
            print(String(decoding: try Data(contentsOf: b.configURL), as: UTF8.self))
        }
    }

    struct PathCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "path", abstract: "Print a bottle's C: drive path.")
        @OptionGroup var common: Common
        @Argument var bottle: String
        func run() throws { print(try BottleStore(paths: common.paths).bottle(bottle).driveC.path) }
    }

    struct SetCmd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change a bottle setting.",
            discussion: """
            Keys: windows, graphics, msync, avx, hud, retina, raytracing, metalfx, option-alt, command-ctrl, logging, env.NAME, dll.NAME
            Examples:
              isthmus bottle set games graphics dxmt
              isthmus bottle set games avx off
              isthmus bottle set games env.DXVK_HUD fps
              isthmus bottle set games dll.xinput1_3 native
            """)
        @OptionGroup var common: Common
        @Argument var bottle: String
        @Argument var key: String
        @Argument var value: String

        func run() throws {
            let store = BottleStore(paths: common.paths)
            let id = try store.bottle(bottle).id
            var b = try store.update(id) { try BottleSettingKey.apply(key: key, value: value, to: &$0.settings) }
            if b.isInitialized { try BottleSetup(paths: common.paths).applySettings(&b) }
            print("\(key) = \(value)")
        }
    }
}

enum BottleSettingKey {
    static func bool(_ v: String) throws -> Bool {
        switch v.lowercased() {
        case "1", "on", "yes", "true", "y": return true
        case "0", "off", "no", "false", "n": return false
        default: throw ValidationError("Expected on/off, got \(v).")
        }
    }

    static func apply(key: String, value: String, to s: inout BottleSettings) throws {
        if key.hasPrefix("env.") {
            let name = String(key.dropFirst(4))
            if value.isEmpty || value == "-" { s.environment.removeValue(forKey: name) } else { s.environment[name] = value }
            return
        }
        if key.hasPrefix("dll.") {
            let name = String(key.dropFirst(4)).lowercased()
            let mode: String? = switch value.lowercased() {
            case "native", "n": "n"
            case "builtin", "b": "b"
            case "native,builtin", "n,b": "n,b"
            case "builtin,native", "b,n": "b,n"
            case "disabled", "off", "d": ""
            case "-", "default": nil
            default: throw ValidationError("DLL mode must be native, builtin, native,builtin, builtin,native, disabled or default.")
            }
            if let mode { s.dllOverrides[name] = mode } else { s.dllOverrides.removeValue(forKey: name) }
            return
        }
        switch key {
        case "windows":
            guard let v = WindowsVersion(rawValue: value) else { throw ValidationError("Unknown Windows version \(value).") }
            s.windowsVersion = v
        case "graphics":
            guard let v = GraphicsBackend(rawValue: value) else {
                throw ValidationError("Graphics must be one of \(GraphicsBackend.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            s.graphics = v
        case "msync": s.msync = try bool(value)
        case "avx": s.advertiseAVX = try bool(value)
        case "hud": s.metalHUD = try bool(value)
        case "retina": s.retinaMode = try bool(value)
        case "raytracing": s.rayTracing = try bool(value)
        case "metalfx": s.metalFXUpscaling = try bool(value)
        case "option-alt": s.leftOptionIsAlt = try bool(value); s.rightOptionIsAlt = s.leftOptionIsAlt
        case "command-ctrl": s.commandIsCtrl = try bool(value)
        case "logging":
            guard let v = BottleSettings.LogLevel(rawValue: value) else { throw ValidationError("Logging must be quiet, normal or verbose.") }
            s.logging = v
        default:
            throw ValidationError("Unknown setting \(key). See `isthmus bottle set --help`.")
        }
    }
}

// MARK: run / play

struct LaunchOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Bottle id or name.") var bottle: String
    @Option(help: "Force a graphics backend for this launch.") var graphics: String?
    @Flag(help: "Return immediately instead of waiting for the program to exit.") var detach = false
    @Flag(help: "Wait for the program, keep the display awake, and exit 0 once it started (used by Launchpad shortcuts).") var hold = false
    @Flag(help: "Print Wine output to the terminal instead of the log file.") var verbose = false
}

func launch(target: LaunchTarget, title: String, options: LaunchOptions, paths: IsthmusPaths) async throws {
    let b = try BottleStore(paths: paths).bottle(options.bottle)
    var target = target
    if let g = options.graphics {
        guard let backend = GraphicsBackend(rawValue: g) else { throw ValidationError("Unknown graphics backend \(g).") }
        target.graphicsOverride = backend
    }
    let service = LaunchService(paths: paths)
    let plan = try await service.prepare(bottle: b, target: target, progress: stepPrinter)
    stepPrinter("Launching \(title) with \(plan.backend.displayName)\(plan.recipe.map { " (recipe: \($0.id))" } ?? "")")

    if options.verbose {
        let r = try WineRunner.run(plan)
        print(r.output)
        throw ExitCode(r.status)
    }
    let running = try service.start(plan, bottle: b, title: title)
    // A store client (Steam, Epic) stays open long after the game; don't keep
    // the display awake for it.
    if options.hold && plan.launcherID != nil { return }
    if options.detach { print("Started (pid \(running.pid)). Log: \(running.logURL.path)"); return }
    // Keep the display awake while the game runs (controllers don't count as user activity).
    let awake = PowerAssertion(reason: "Playing \(title)")
    let status = running.waitUntilExit()
    awake.release()
    if options.hold { return }   // the game ran; its own exit code isn't a launch failure
    if status != 0 { FileHandle.standardError.write(Data("Exited with status \(status). Log: \(running.logURL.path)\n".utf8)) }
    throw ExitCode(status)
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a Windows program in a bottle.",
        discussion: "PROGRAM can be a Mac path, a Windows path (C:\\...), or a builtin like winecfg, regedit, taskmgr, explorer, cmd.")
    @OptionGroup var common: Common
    @OptionGroup var options: LaunchOptions
    @Argument var program: String
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() async throws {
        let expanded = program.hasPrefix("~") ? (program as NSString).expandingTildeInPath : program
        let path = expanded.hasPrefix("/") || expanded.contains("\\") || expanded.contains(":") ? expanded
            : (FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded).path : expanded)
        try await launch(target: LaunchTarget(program: path, arguments: arguments),
                         title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                         options: options, paths: common.paths)
    }
}

struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch a game from the library (see `isthmus games`).")
    @OptionGroup var common: Common
    @OptionGroup var options: LaunchOptions
    @Option(help: "Game id from `isthmus games`, or a name.") var game: String

    func run() async throws {
        let b = try BottleStore(paths: common.paths).bottle(options.bottle)
        let games = GameLibrary.scan(b)
        guard let g = games.first(where: { $0.id == game }) ?? games.first(where: { $0.name.localizedCaseInsensitiveContains(game) }) else {
            throw ValidationError("No game matching \"\(game)\" in \(b.name).")
        }
        try await launch(target: g.target(in: b), title: g.name, options: options, paths: common.paths)
    }
}

struct Games: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List installed games across bottles.")
    @OptionGroup var common: Common
    @Option(name: .shortAndLong) var bottle: String?

    func run() throws {
        let store = BottleStore(paths: common.paths)
        let bottles = try bottle.map { [try store.bottle($0)] } ?? store.list()
        let book = RecipeBook.load(paths: common.paths)
        var rows = [["BOTTLE", "SOURCE", "NAME", "STATUS", "ID"]]
        for b in bottles {
            for g in GameLibrary.scan(b) {
                let r = book.recipe(exeName: g.executable?.lastPathComponent, steamAppID: g.source == .steam ? Int(g.storeID) : nil,
                                    epicAppName: g.source == .epic ? g.storeID : nil, gogID: g.source == .gog ? g.storeID : nil)
                rows.append([b.id, g.source.rawValue, g.name, r?.status.rawValue ?? "-", g.id])
            }
        }
        if rows.count == 1 { print("No games found. Install a store with `isthmus install steam -b <bottle>`."); return }
        printTable(rows)
    }
}

// MARK: install

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install a store launcher or runtime component into a bottle.",
        discussion: "Launchers: \(Catalog.launchers().map(\.id).joined(separator: ", "))\nComponents: \(Catalog.components().map(\.id).joined(separator: ", "))")
    @OptionGroup var common: Common
    @Option(name: .shortAndLong) var bottle: String
    @Argument var item: String

    func run() async throws {
        var b = try BottleStore(paths: common.paths).bottle(bottle)
        let setup = BottleSetup(paths: common.paths)
        if !b.isInitialized { b = try setup.initialize(b, progress: stepPrinter) }
        if Catalog.launcher(item) != nil {
            let exe = try await setup.install(launcher: item, into: b, progress: stepPrinter)
            print(exe.map { "Installed: \($0.path)" } ?? "Installer finished, but the launcher wasn't found where expected.")
        } else if Catalog.component(item) != nil {
            try await setup.install(component: item, into: &b, progress: stepPrinter)
            print("Installed \(item).")
        } else {
            throw ValidationError("Unknown item \(item).")
        }
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop every Windows program in a bottle.")
    @OptionGroup var common: Common
    @Argument var bottle: String
    func run() throws {
        try WineRunner.killAll(bottle: try BottleStore(paths: common.paths).bottle(bottle), paths: common.paths)
        print("Stopped.")
    }
}

// MARK: d3dmetal

struct D3DMetalCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "d3dmetal",
        abstract: "Import Apple's D3DMetal from the Game Porting Toolkit.",
        discussion: "Download the Game Porting Toolkit from https://developer.apple.com/games/game-porting-toolkit/ (free Apple account), then pass the .dmg here.",
        subcommands: [Import.self, Status.self])

    struct Import: ParsableCommand {
        @OptionGroup var common: Common
        @Argument(help: "Toolkit .dmg, mounted volume, or folder.") var source: String
        func run() throws {
            let d = try D3DMetalStore(paths: common.paths).importToolkit(from: URL(fileURLWithPath: (source as NSString).expandingTildeInPath))
            print("Imported D3DMetal \(d.version).")
        }
    }

    struct Status: ParsableCommand {
        @OptionGroup var common: Common
        func run() throws {
            if let d = D3DMetalStore(paths: common.paths).current { print("D3DMetal \(d.version) at \(d.url.path)") }
            else { print("Not imported.") }
        }
    }
}

// MARK: recipes

struct Recipes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List known game fixes.")
    @OptionGroup var common: Common
    @Option(help: "Filter by name.") var search: String?

    func run() throws {
        let book = RecipeBook.load(paths: common.paths)
        let list = book.recipes.filter { search == nil || $0.name.localizedCaseInsensitiveContains(search!) }
        printTable([["ID", "STATUS", "GRAPHICS", "NAME"]] + list.map { [$0.id, $0.status.rawValue, $0.settings.graphics?.rawValue ?? "auto", $0.name] })
    }
}

// MARK: shortcut

struct Shortcut: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a Mac app shortcut for a game in ~/Applications/Isthmus Games.")
    @OptionGroup var common: Common
    @Option(name: .shortAndLong) var bottle: String
    @Option var game: String

    func run() throws {
        let b = try BottleStore(paths: common.paths).bottle(bottle)
        let games = GameLibrary.scan(b)
        guard let g = games.first(where: { $0.id == game }) ?? games.first(where: { $0.name.localizedCaseInsensitiveContains(game) }) else {
            throw ValidationError("No game matching \"\(game)\".")
        }
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = try ShortcutMaker(cli: cli).create(for: g, in: b)
        print("Created \(app.path)")
    }
}

// MARK: selftest

struct SelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest",
        abstract: "Run the built-in Windows test programs on every graphics backend.")
    @OptionGroup var common: Common
    @Option(name: .shortAndLong, help: "Bottle to test in (default: a temporary one).") var bottle: String?
    @Option(help: "Folder with the probe .exe files.") var probes: String?

    func run() async throws {
        let store = BottleStore(paths: common.paths)
        var temp: Bottle?
        let b: Bottle
        if let bottle { b = try store.bottle(bottle) } else {
            stepPrinter("Creating a temporary bottle…")
            let t = try store.create(name: "Self-Test \(UUID().uuidString.prefix(6))")
            temp = try BottleSetup(paths: common.paths).initialize(t, progress: stepPrinter)
            b = temp!
        }
        defer {
            if let temp {
                try? WineRunner.killAll(bottle: temp, paths: common.paths)
                try? FileManager.default.removeItem(at: temp.url)
            }
        }
        let test = SelfTest(paths: common.paths, probes: probes.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
        let results = try await test.run(bottle: b) { r in
            let mark = switch r.outcome { case .pass: "✓"; case .skip: "–"; case .fail: r.required ? "✗" : "!" }
            print("\(mark) \(r.name)  \(r.detail)")
        }
        let failed = results.filter { $0.outcome == .fail && $0.required }
        print(failed.isEmpty ? "All required checks passed." : "\(failed.count) required check(s) failed.")
        if !failed.isEmpty { throw ExitCode(1) }
    }
}
