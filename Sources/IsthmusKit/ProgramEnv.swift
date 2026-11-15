import Foundation

/// Writes `<bottle>/cache/program-env/<exe>.env` files: the FPS counter
/// settings for each game, applied by the engine's loader inside the game's
/// own process. That is the only way per-game settings reach games started
/// by Steam (or any launcher), which inherit the launcher's environment.
///
/// The loader only honours `MTL_HUD_*` keys (engine patch 0002).
public enum ProgramEnv {
    public static func directory(_ bottle: Bottle) -> URL { bottle.cache.appendingPathComponent("program-env", isDirectory: true) }

    /// File name the loader looks for: the executable's file name, lowercased.
    public static func fileName(forExecutable exe: String) -> String? {
        let leaf = exe.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? exe
        guard !leaf.isEmpty, leaf.count <= 255 else { return nil }
        return leaf.lowercased() + ".env"
    }

    static func contents(_ env: [String: String]) -> String {
        env.keys.sorted().filter { $0.hasPrefix("MTL_HUD_") }.map { "\($0)=\(env[$0]!)" }.joined(separator: "\n") + "\n"
    }

    /// Bring the directory in line with the bottle's settings: one file per
    /// game whose effective counter differs from the bottle default, plus
    /// one for every known game when the bottle default is on (so games
    /// launched by a client started with it off still get it).
    public static func sync(_ bottle: Bottle, games: [Game], recipes: RecipeBook) {
        let fm = FileManager.default
        let dir = directory(bottle)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var wanted: [String: String] = [:]
        let s = bottle.config.settings
        for g in games {
            guard let exe = g.executable, let name = fileName(forExecutable: exe.path) else { continue }
            let target = g.target(in: bottle)
            let program = bottle.config.programs[target.settingsKey(in: bottle)] ?? ProgramSettings()
            let overlay = program.overlay ?? s.overlay
            wanted[name] = contents(hudEnvironment(overlay, position: s.overlayPosition, showRange: s.overlayShowRange))
        }
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in existing where f.hasSuffix(".env") && wanted[f] == nil { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
        for (name, text) in wanted {
            let url = dir.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// One-off override for a single launch ("Play with FPS Counter"). The
    /// file is replaced by the next `sync`.
    public static func writeOverride(_ bottle: Bottle, executable: URL, overlay: PerformanceOverlay) {
        guard let name = fileName(forExecutable: executable.path) else { return }
        let s = bottle.config.settings
        try? FileManager.default.createDirectory(at: directory(bottle), withIntermediateDirectories: true)
        try? contents(hudEnvironment(overlay, position: s.overlayPosition, showRange: s.overlayShowRange))
            .write(to: directory(bottle).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
