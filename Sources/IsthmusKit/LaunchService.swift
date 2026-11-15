import Foundation

/// The one path every launch takes (app, CLI, Launchpad shortcuts): make
/// sure the bottle is usable, apply settings, honor recipes, install missing
/// runtimes, switch a running store client to the right graphics runtime,
/// then start the program.
public struct LaunchService: Sendable {
    public var paths: IsthmusPaths
    public var recipes: RecipeBook

    public init(paths: IsthmusPaths = .default, recipes: RecipeBook? = nil) {
        self.paths = paths
        self.recipes = recipes ?? RecipeBook.load(paths: paths)
    }

    public func prepare(bottle original: Bottle, target: LaunchTarget,
                        progress: (@Sendable (String) -> Void)? = nil) async throws -> LaunchPlan {
        var bottle = original.reloaded()
        let setup = BottleSetup(paths: paths)

        // A bottle whose creation was interrupted has no registry yet.
        if !bottle.isInitialized {
            progress?("Finishing setup of \(bottle.name)…")
            bottle = try setup.initialize(bottle, progress: progress)
        }
        try setup.applySettings(&bottle)

        // Per-game FPS counter files, for games a launcher starts.
        ProgramEnv.sync(bottle, games: GameLibrary.scan(bottle), recipes: recipes)
        if let o = target.overlayOverride, let exe = target.inspect ?? (target.program.hasPrefix("/") ? URL(fileURLWithPath: target.program) : nil) {
            ProgramEnv.writeOverride(bottle, executable: exe, overlay: o)
        }

        let planner = LaunchPlanner(paths: paths, recipes: recipes)
        var plan = try planner.plan(bottle: bottle, target: target)
        if let r = plan.recipe, r.status == .blocked {
            throw IsthmusError.unsupported("\(r.name) can't run on Isthmus. \(r.notes ?? "")")
        }
        if !plan.missingComponents.isEmpty {
            for c in plan.missingComponents {
                progress?("Installing \(Catalog.component(c)?.name ?? c)…")
                try await setup.install(component: c, into: &bottle)
            }
            plan = try planner.plan(bottle: bottle, target: target)
        }
        // Opening the store client itself while it's running: hand the
        // request to the running client (it brings its window back) using the
        // runtime it already has. Restarting it would close whatever the user
        // has open just to show a window.
        if plan.launcherID != nil, Self.opensClientOnly(target),
           let running = LauncherProcess.find(plan.launcherID!, in: bottle, paths: paths) {
            if let backend = Self.backend(ofRoot: running.root), backend != plan.backend {
                var t = target
                t.graphicsOverride = backend
                plan = try planner.plan(bottle: bottle, target: t)
            }
            return plan
        }
        try restartLauncherIfNeeded(plan: plan, bottle: bottle, progress: progress)
        return plan
    }

    /// Start the planned program.
    public func start(_ plan: LaunchPlan, bottle: Bottle, title: String,
                      progress: (@Sendable (String) -> Void)? = nil,
                      onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProgram {
        try WineRunner.launch(plan, bottle: bottle, title: title, onExit: onExit)
    }

    /// Quit a store client (Steam, Epic) without touching anything else in
    /// the bottle: ask politely, then stop only the client's own processes.
    /// This is the fix for a stuck or invisible Steam, instead of Stop All.
    /// `forceUnlessOthers`: only force-stop when nothing else is running in
    /// the bottle (used when Isthmus, not the user, decided to restart it).
    public func quitStore(_ id: String, in bottle: Bottle, forceUnlessOthers: Bool = false,
                          progress: (@Sendable (String) -> Void)? = nil) throws {
        guard let running = LauncherProcess.find(id, in: bottle, paths: paths) else { return }
        let name = Catalog.launcher(id)?.name ?? id
        if id == "steam" {
            progress?("Asking \(name) to quit…")
            // Same runtime and environment as the running client (msync in
            // particular must match the wineserver's, or the request is lost).
            let root = URL(fileURLWithPath: running.root)
            var settings = EffectiveSettings.merge(bottle: bottle.config.settings, recipe: nil, program: ProgramSettings())
            settings.logging = .quiet
            let env = LaunchPlanner.environment(engineRoot: root, bottle: bottle, settings: settings,
                                                backend: Self.backend(ofRoot: running.root) ?? .wined3d)
            _ = try? Shell.run(root.appendingPathComponent("bin/wine").path,
                               [bottle.unixPath(forWindowsPath: SteamLibrary.steamExe).path, "-shutdown"], environment: env, allowFailure: true)
            if Self.waitForExit(running.pid, timeout: 20) { return }
        }
        if forceUnlessOthers {
            let others = LauncherProcess.otherPrograms(in: bottle, excluding: id)
            if !others.isEmpty {
                throw IsthmusError.unsupported("""
                    \(name) didn't quit, and \(ListFormatter.localizedString(byJoining: others)) is also running in "\(bottle.name)". \
                    Quit \(others.count == 1 ? "it" : "them") first, or right-click \(name) in the Library and choose Quit.
                    """)
            }
        }
        progress?("\(name) isn't responding; stopping it…")
        LauncherProcess.terminate(id, in: bottle)
        guard Self.waitForExit(running.pid, timeout: 10) else {
            throw IsthmusError.unsupported("\(name) couldn't be stopped. Use Stop All on the bottle's page.")
        }
    }


    static func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return kill(pid, 0) != 0
    }

    static func backendName(_ root: String) -> String {
        backend(ofRoot: root)?.displayName ?? "another"
    }

    /// Backend of a runtime directory (Runtime/<engine>-<backend>-f<n>…, or a
    /// base engine for wined3d).
    static func backend(ofRoot root: String) -> GraphicsBackend? {
        if root.contains("/Runtime/") {
            return GraphicsBackend.allCases.first { $0 != .auto && $0 != .wined3d && root.contains("-\($0.rawValue)-") }
        }
        return .wined3d
    }

    /// The target is the client (steam.exe, EpicGamesLauncher.exe), not a game.
    static func opensClientOnly(_ target: LaunchTarget) -> Bool {
        target.steamAppID == nil && !target.program.contains("://")
    }

    /// A game launched through an already-running Steam/Epic inherits the
    /// client's runtime (its DLL directory), not ours. If they differ, quit
    /// the client so it restarts with the right one.
    func restartLauncherIfNeeded(plan: LaunchPlan, bottle: Bottle, progress: (@Sendable (String) -> Void)?) throws {
        guard let id = plan.launcherID, let running = LauncherProcess.find(id, in: bottle, paths: paths),
              URL(fileURLWithPath: running.root).standardizedFileURL != plan.engineRoot.standardizedFileURL else { return }
        let name = Catalog.launcher(id)?.name ?? id
        progress?("Restarting \(name) to switch to \(plan.backend.displayName)…")
        try quitStore(id, in: bottle, forceUnlessOthers: true, progress: progress)
        // Let its helper processes (web helper, overlay) wind down.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, LauncherProcess.find(id, in: bottle, paths: paths) != nil { Thread.sleep(forTimeInterval: 0.5) }
    }
}
