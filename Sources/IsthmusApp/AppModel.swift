import SwiftUI
import IsthmusKit

/// A long-running job shown in the toolbar activity popover.
@Observable @MainActor
final class Activity: Identifiable {
    let id = UUID()
    let title: String
    var detail: String = ""
    var progress: Double?
    var finished = false
    var failed = false
    init(title: String) { self.title = title }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A program the user opened from Finder, waiting for a bottle choice.
struct PendingOpen: Identifiable {
    let id = UUID()
    var url: URL
}

@Observable @MainActor
final class AppModel {
    let paths = IsthmusPaths.default
    private(set) var engines: [Engine] = []
    private(set) var bottles: [Bottle] = []
    private(set) var games: [Game] = []
    private(set) var d3dmetal: D3DMetalInstall?
    private(set) var checks: [Doctor.Check] = []
    private(set) var remoteEngine: RemoteEngine?
    private(set) var running: [RunningProgram] = []
    private(set) var recipes = RecipeBook(recipes: [])
    var activities: [Activity] = []
    var alert: AppAlert?
    var pendingOpen: PendingOpen?
    var scanning = false

    var needsOnboarding: Bool { engines.isEmpty || bottles.isEmpty || !Doctor.rosettaInstalled }
    var busy: Bool { activities.contains { !$0.finished } }

    init() {
        try? paths.ensure()
        reload()
        Task { await checkForEngineUpdate() }
    }

    // MARK: Loading

    func reload() {
        engines = EngineManager(paths: paths).installed()
        bottles = BottleStore(paths: paths).list()
        d3dmetal = D3DMetalStore(paths: paths).current
        recipes = RecipeBook.load(paths: paths)
        checks = Doctor(paths: paths).run()
        refreshGames()
    }

    func refreshGames() {
        let bottles = self.bottles
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = bottles.flatMap { GameLibrary.scan($0) }
            await MainActor.run { self.games = found; self.scanning = false }
        }
    }

    func bottle(_ id: String) -> Bottle? { bottles.first { $0.id == id } }

    func recipe(for game: Game) -> Recipe? {
        recipes.recipe(exeName: game.executable?.lastPathComponent,
                       steamAppID: game.source == .steam ? Int(game.storeID) : nil,
                       epicAppName: game.source == .epic ? game.storeID : nil,
                       gogID: game.source == .gog ? game.storeID : nil)
    }

    func isRunning(bottleID: String) -> Bool { running.contains { $0.bottleID == bottleID && $0.isRunning } }

    var defaultBottleID: String? {
        get { UserDefaults.standard.string(forKey: "defaultBottle").flatMap { id in bottles.contains { $0.id == id } ? id : nil } ?? bottles.first?.id }
        set { UserDefaults.standard.set(newValue, forKey: "defaultBottle") }
    }

    // MARK: Activities

    /// Runs `work` off the main actor with a visible activity. Errors become an alert.
    func perform(_ title: String, _ work: @escaping @Sendable (_ report: @escaping @Sendable (String?, Double?) -> Void) async throws -> Void) {
        let activity = Activity(title: title)
        activities.insert(activity, at: 0)
        let report: @Sendable (String?, Double?) -> Void = { detail, progress in
            Task { @MainActor in
                if let detail { activity.detail = detail }
                activity.progress = progress
            }
        }
        Task.detached(priority: .userInitiated) {
            do {
                try await work(report)
                await MainActor.run { activity.finished = true; activity.detail = "Done"; activity.progress = nil; self.reload() }
            } catch {
                await MainActor.run {
                    activity.finished = true; activity.failed = true; activity.detail = error.localizedDescription
                    self.alert = AppAlert(title: "\(title) failed", message: error.localizedDescription)
                    self.reload()
                }
            }
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run { self.activities.removeAll { $0.id == activity.id && $0.finished && !$0.failed } }
        }
    }

    // MARK: Engines

    func checkForEngineUpdate() async {
        let mgr = EngineManager(paths: paths)
        guard let latest = try? await mgr.latestRemote() else { return }
        if !engines.contains(where: { $0.version == latest.version }) { remoteEngine = latest } else { remoteEngine = nil }
    }

    func downloadEngine() {
        let paths = self.paths
        perform("Downloading engine") { report in
            let mgr = EngineManager(paths: paths)
            guard let latest = try await mgr.latestRemote() else {
                throw IsthmusError.download("No engine releases are published yet.")
            }
            report("Version \(latest.version)", 0)
            try await mgr.download(latest) { p in report(p < 1 ? "Downloading \(latest.version)… \(Int(p * 100))%" : "Installing…", p) }
        }
        remoteEngine = nil
    }

    func importEngine(_ url: URL) {
        let paths = self.paths
        perform("Installing engine") { report in
            report(url.lastPathComponent, nil)
            try EngineManager(paths: paths).install(archive: url)
        }
    }

    func removeEngine(_ e: Engine) {
        do { try EngineManager(paths: paths).remove(e.version); reload() }
        catch { alert = AppAlert(title: "Couldn't remove engine", message: error.localizedDescription) }
    }

    func importD3DMetal(_ url: URL) {
        let paths = self.paths
        perform("Importing D3DMetal") { report in
            report("Reading \(url.lastPathComponent)…", nil)
            let d = try D3DMetalStore(paths: paths).importToolkit(from: url)
            report("D3DMetal \(d.version)", nil)
        }
    }

    func installRosetta() {
        perform("Installing Rosetta 2") { report in
            report("Asking macOS to install Rosetta…", nil)
            try Doctor.installRosetta()
        }
    }

    // MARK: Bottles

    func createBottle(name: String, windows: WindowsVersion, installSteam: Bool) {
        let paths = self.paths
        perform("Creating \(name)") { report in
            var s = BottleSettings(); s.windowsVersion = windows
            let created = try BottleStore(paths: paths).create(name: name, settings: s)
            do {
                let b = try BottleSetup(paths: paths).initialize(created) { msg in report(msg, nil) }
                await MainActor.run { if self.defaultBottleID == nil { self.defaultBottleID = b.id } }
                if installSteam {
                    _ = try await BottleSetup(paths: paths).install(launcher: "steam", into: b) { msg in report(msg, nil) }
                }
            } catch {
                try? FileManager.default.removeItem(at: created.url)
                throw error
            }
        }
    }

    func save(_ bottle: Bottle) {
        do {
            try bottle.save()
            if let i = bottles.firstIndex(where: { $0.id == bottle.id }) { bottles[i] = bottle }
        } catch {
            alert = AppAlert(title: "Couldn't save settings", message: error.localizedDescription)
        }
    }

    func rename(_ bottle: Bottle, to name: String) {
        do { _ = try BottleStore(paths: paths).rename(bottle, to: name); reload() }
        catch { alert = AppAlert(title: "Couldn't rename", message: error.localizedDescription) }
    }

    func delete(_ bottle: Bottle) {
        try? WineRunner.killAll(bottle: bottle, paths: paths)
        do { try BottleStore(paths: paths).delete(bottle); reload() }
        catch { alert = AppAlert(title: "Couldn't delete bottle", message: error.localizedDescription) }
    }

    func installLauncher(_ launcher: LauncherInfo, in bottle: Bottle) {
        let paths = self.paths
        perform("Installing \(launcher.name)") { report in
            let exe = try await BottleSetup(paths: paths).install(launcher: launcher.id, into: bottle) { msg in report(msg, nil) }
            if exe == nil { throw IsthmusError.unsupported("\(launcher.name)'s installer finished, but the launcher wasn't found. Try running the installer again.") }
        }
    }

    func installComponent(_ c: ComponentInfo, in bottle: Bottle) {
        let paths = self.paths
        perform("Installing \(c.name)") { report in
            var b = bottle
            try await BottleSetup(paths: paths).install(component: c.id, into: &b) { msg in report(msg, nil) }
        }
    }

    func pin(_ url: URL, in bottle: Bottle) {
        var b = bottle
        let path = b.windowsPath(forUnixPath: url)
        guard !b.config.pinned.contains(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return }
        b.config.pinned.append(PinnedProgram(name: url.deletingPathExtension().lastPathComponent, path: path))
        save(b)
        refreshGames()
    }

    func unpin(_ game: Game) {
        guard game.source == .pinned, var b = bottle(game.bottleID) else { return }
        b.config.pinned.removeAll { $0.id.uuidString == game.storeID }
        save(b)
        refreshGames()
    }

    func stopAll(_ bottle: Bottle) {
        let paths = self.paths
        Task.detached { try? WineRunner.killAll(bottle: bottle, paths: paths) }
    }

    // MARK: Launching

    func play(_ game: Game, graphics: GraphicsBackend? = nil) {
        guard let b = bottle(game.bottleID) else { return }
        var target = game.target(in: b)
        target.graphicsOverride = graphics
        launch(target, title: game.name, in: b)
    }

    func run(_ url: URL, in bottle: Bottle, arguments: [String] = []) {
        launch(LaunchTarget(program: url.path, arguments: arguments), title: url.deletingPathExtension().lastPathComponent, in: bottle)
    }

    func runTool(_ tool: String, in bottle: Bottle) {
        launch(LaunchTarget(program: tool), title: tool, in: bottle)
    }

    private func launch(_ target: LaunchTarget, title: String, in bottle: Bottle) {
        let paths = self.paths
        let recipes = self.recipes
        let activity = Activity(title: "Starting \(title)")
        activities.insert(activity, at: 0)
        Task.detached(priority: .userInitiated) {
            do {
                var b = bottle
                try BottleSetup(paths: paths).applySettings(&b)
                let planner = LaunchPlanner(paths: paths, recipes: recipes)
                var plan = try planner.plan(bottle: b, target: target)
                if let r = plan.recipe, r.status == .blocked {
                    throw IsthmusError.unsupported("\(r.name) can't run on Isthmus. \(r.notes ?? "")")
                }
                for c in plan.missingComponents {
                    let name = Catalog.component(c)?.name ?? c
                    await MainActor.run { activity.detail = "Installing \(name)…" }
                    try await BottleSetup(paths: paths).install(component: c, into: &b)
                }
                if !plan.missingComponents.isEmpty { plan = try planner.plan(bottle: b, target: target) }
                await MainActor.run { activity.detail = plan.backend.displayName }
                let program = try WineRunner.launch(plan, bottle: b, title: title) { status in
                    Task { @MainActor in
                        self.running.removeAll { !$0.isRunning }
                        // Non-zero within a few seconds usually means it never got going.
                        if status != 0, let p = self.lastLaunched[title], Date().timeIntervalSince(p.started) < 10 {
                            self.alert = AppAlert(title: "\(title) quit unexpectedly",
                                                  message: "Exit code \(status). The log has details:\n\(p.logURL.path)")
                        }
                    }
                }
                await MainActor.run {
                    self.running.append(program)
                    self.lastLaunched[title] = program
                    activity.finished = true
                    activity.detail = "Running"
                }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run { self.activities.removeAll { $0.id == activity.id } }
            } catch {
                await MainActor.run {
                    activity.finished = true; activity.failed = true; activity.detail = error.localizedDescription
                    self.alert = AppAlert(title: "Couldn't start \(title)", message: error.localizedDescription)
                }
            }
        }
    }

    private var lastLaunched: [String: RunningProgram] = [:]

    func createShortcut(_ game: Game) {
        guard let b = bottle(game.bottleID) else { return }
        do {
            let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/isthmus")
            let app = try ShortcutMaker(cli: cli).create(for: game, in: b)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            alert = AppAlert(title: "Couldn't create shortcut", message: error.localizedDescription)
        }
    }

    func latestLog(for bottle: Bottle) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: bottle.logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}
