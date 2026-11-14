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
        try restartLauncherIfNeeded(plan: plan, bottle: bottle, progress: progress)
        return plan
    }

    /// Start the planned program, remembering which runtime a store client
    /// came from.
    public func start(_ plan: LaunchPlan, bottle: Bottle, title: String,
                      onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProgram {
        let running = try WineRunner.launch(plan, bottle: bottle, title: title, onExit: onExit)
        if let id = plan.launcherID {
            let existing = LauncherRuntimeRecord.read(bottle)
            // Only the process that actually starts the client defines its runtime.
            if existing == nil || existing?.launcher != id {
                // steam.exe stays alive as the client; Epic is started via `start`, which exits.
                LauncherRuntimeRecord.write(LauncherRuntimeRecord(root: plan.engineRoot.path, launcher: id, started: Date(),
                                                                  pid: id == "steam" ? running.pid : nil), for: bottle)
            }
        }
        return running
    }

    static func backendName(_ root: String) -> String {
        for b in GraphicsBackend.allCases where b != .auto && b != .wined3d && root.contains("-\(b.rawValue)-") { return b.displayName }
        return GraphicsBackend.wined3d.displayName
    }

    /// A game launched through an already-running Steam/Epic inherits the
    /// client's runtime (its DLL directory), not ours. If they differ, quit
    /// the client so it restarts with the right one.
    func restartLauncherIfNeeded(plan: LaunchPlan, bottle: Bottle, progress: (@Sendable (String) -> Void)?) throws {
        guard let id = plan.launcherID, let record = LauncherRuntimeRecord.read(bottle),
              record.launcher == id, record.root != plan.engineRoot.path else { return }
        let name = Catalog.launcher(id)?.name ?? id
        progress?("Restarting \(name) to switch to \(plan.backend.displayName)…")
        if id == "steam" {
            var shutdown = plan
            shutdown.executable = URL(fileURLWithPath: record.root).appendingPathComponent("bin/wine")
            shutdown.arguments = [bottle.unixPath(forWindowsPath: SteamLibrary.steamExe).path, "-shutdown"]
            _ = try? WineRunner.run(shutdown, timeout: 30)
        }
        // Wait for the client to exit. Never force-kill: other games in the
        // same bottle would die with it.
        guard try WineRunner.waitIdle(bottle: bottle, paths: paths, timeout: id == "steam" ? 60 : 3) else {
            throw IsthmusError.unsupported("""
                \(name) is running with \(Self.backendName(record.root)) graphics, but this game is set to \(plan.backend.displayName). \
                Quit \(name) and any other programs in "\(bottle.name)", then try again.
                """)
        }
        try? FileManager.default.removeItem(at: LauncherRuntimeRecord.url(bottle))
    }
}
