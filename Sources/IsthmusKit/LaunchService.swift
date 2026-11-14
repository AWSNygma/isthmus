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

    /// Start the planned program.
    public func start(_ plan: LaunchPlan, bottle: Bottle, title: String,
                      onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProgram {
        try WineRunner.launch(plan, bottle: bottle, title: title, onExit: onExit)
    }

    static func backendName(_ root: String) -> String {
        for b in GraphicsBackend.allCases where b != .auto && b != .wined3d && root.contains("-\(b.rawValue)-") { return b.displayName }
        if root.contains("/Runtime/") { return "another" }
        return GraphicsBackend.wined3d.displayName
    }

    /// A game launched through an already-running Steam/Epic inherits the
    /// client's runtime (its DLL directory), not ours. If they differ, quit
    /// the client so it restarts with the right one.
    func restartLauncherIfNeeded(plan: LaunchPlan, bottle: Bottle, progress: (@Sendable (String) -> Void)?) throws {
        guard let id = plan.launcherID, let running = LauncherProcess.find(id, in: bottle),
              URL(fileURLWithPath: running.root).standardizedFileURL != plan.engineRoot.standardizedFileURL else { return }
        let name = Catalog.launcher(id)?.name ?? id
        progress?("Restarting \(name) to switch to \(plan.backend.displayName)…")
        if id == "steam" {
            var shutdown = plan
            shutdown.executable = URL(fileURLWithPath: running.root).appendingPathComponent("bin/wine")
            shutdown.arguments = [bottle.unixPath(forWindowsPath: SteamLibrary.steamExe).path, "-shutdown"]
            _ = try? WineRunner.run(shutdown, timeout: 30)
        }
        // Wait for the client itself to exit; other programs in the bottle
        // may keep running. Never force-kill.
        let deadline = Date().addingTimeInterval(id == "steam" ? 60 : 3)
        while Date() < deadline, kill(running.pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.5) }
        guard kill(running.pid, 0) != 0 else {
            throw IsthmusError.unsupported("""
                \(name) is running with \(Self.backendName(running.root)) graphics, but this game is set to \(plan.backend.displayName). \
                Quit \(name), then try again.
                """)
        }
        Thread.sleep(forTimeInterval: 1)   // let its helper processes wind down
    }
}
