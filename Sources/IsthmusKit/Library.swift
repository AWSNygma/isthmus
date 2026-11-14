import Foundation

/// A game found in a bottle (installed via a store, or pinned by the user).
public struct Game: Sendable, Identifiable, Hashable {
    public enum Source: String, Sendable, Codable { case steam, epic, gog, pinned }

    public var id: String { "\(bottleID):\(source.rawValue):\(storeID)" }
    public var bottleID: String
    public var source: Source
    public var storeID: String
    public var name: String
    public var installDirectory: URL?
    /// Executable to inspect for icon/DirectX level, when known.
    public var executable: URL?
    /// Cover art (Steam library cache), when available.
    public var artwork: URL?

    /// What to hand the launch planner.
    public func target(in bottle: Bottle) -> LaunchTarget {
        switch source {
        case .steam:
            let steam = bottle.unixPath(forWindowsPath: SteamLibrary.steamExe)
            return LaunchTarget(program: steam.path, arguments: ["-silent", "-applaunch", storeID],
                                steamAppID: Int(storeID), inspect: executable)
        case .epic:
            return LaunchTarget(program: "com.epicgames.launcher://apps/\(storeID)?action=launch&silent=true",
                                epicAppName: storeID, inspect: executable)
        case .gog, .pinned:
            return LaunchTarget(program: executable?.path ?? storeID, gogID: source == .gog ? storeID : nil, inspect: executable)
        }
    }
}

public enum GameLibrary {
    public static func scan(_ bottle: Bottle) -> [Game] {
        var games = SteamLibrary.scan(bottle) + EpicLibrary.scan(bottle) + GOGLibrary.scan(bottle)
        for p in bottle.config.pinned {
            let exe = bottle.unixPath(forWindowsPath: p.path)
            games.append(Game(bottleID: bottle.id, source: .pinned, storeID: p.id.uuidString, name: p.name,
                              installDirectory: exe.deletingLastPathComponent(), executable: exe, artwork: nil))
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Best guess at a game's main executable: the largest .exe near the top
    /// of the install folder, skipping installers, crash reporters and redists.
    static func guessExecutable(in dir: URL, preferring hint: String? = nil) -> URL? {
        let skip = ["unins", "setup", "install", "crash", "report", "redist", "vcredist", "dxsetup", "dotnet", "launcherhelper", "ue4prereq", "easyanticheat", "be_service", "cefsharp", "helper", "update"]
        let fm = FileManager.default
        var best: (URL, Int)?
        func visit(_ d: URL, depth: Int) {
            guard depth <= 3, let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
            for item in items {
                let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true {
                    let n = item.lastPathComponent.lowercased()
                    if !["_commonredist", "redist", "directx", "support", "__installer", "engine"].contains(n) { visit(item, depth: depth + 1) }
                } else if item.pathExtension.lowercased() == "exe" {
                    let n = item.lastPathComponent.lowercased()
                    if let hint, n == hint.lowercased() { best = (item, Int.max); return }
                    if skip.contains(where: { n.contains($0) }) { continue }
                    let size = (v?.fileSize ?? 0) - depth * 1_000_000   // prefer shallow
                    if best == nil || size > best!.1 { best = (item, size) }
                }
            }
        }
        visit(dir, depth: 0)
        return best?.0
    }
}

/// Valve KeyValues (VDF/ACF) text format: `"key" "value"` and `"key" { ... }`.
public enum VDF {
    public indirect enum Node: Sendable, Equatable {
        case value(String)
        case object([(String, Node)])

        public static func == (a: Node, b: Node) -> Bool {
            switch (a, b) {
            case let (.value(x), .value(y)): return x == y
            case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }

        public subscript(key: String) -> Node? {
            guard case .object(let kv) = self else { return nil }
            return kv.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }
        public var string: String? { if case .value(let s) = self { return s }; return nil }
        public var children: [(String, Node)] { if case .object(let kv) = self { return kv }; return [] }
    }

    public static func parse(_ text: String) -> Node {
        var tokens: [String?] = []   // nil = "{" / "}" markers encoded below
        var markers: [Int: Character] = [:]
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var s = ""; i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\", text.index(after: i) < text.endIndex {
                        i = text.index(after: i)
                        switch text[i] { case "n": s.append("\n"); case "t": s.append("\t"); default: s.append(text[i]) }
                    } else { s.append(text[i]) }
                    i = text.index(after: i)
                }
                tokens.append(s)
            } else if c == "{" || c == "}" {
                markers[tokens.count] = c; tokens.append(nil)
            } else if c == "/", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            } else if !c.isWhitespace {
                var s = ""
                while i < text.endIndex, !text[i].isWhitespace, text[i] != "{", text[i] != "}", text[i] != "\"" { s.append(text[i]); i = text.index(after: i) }
                tokens.append(s); continue
            }
            if i < text.endIndex { i = text.index(after: i) }
        }
        var pos = 0
        func object() -> [(String, Node)] {
            var kv: [(String, Node)] = []
            while pos < tokens.count {
                if markers[pos] == "}" { pos += 1; return kv }
                guard let key = tokens[pos] else { pos += 1; continue }
                pos += 1
                guard pos < tokens.count else { break }
                if markers[pos] == "{" { pos += 1; kv.append((key, .object(object()))) }
                else if let v = tokens[pos] { pos += 1; kv.append((key, .value(v))) }
            }
            return kv
        }
        return .object(object())
    }
}

public enum SteamLibrary {
    public static let steamExe = "C:\\Program Files (x86)\\Steam\\steam.exe"
    /// Tools and runtimes that appear as "apps" but aren't games.
    static let ignoredAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350", "1493710", "2180100", "961940", "1826330"]

    public static func steamRoot(_ bottle: Bottle) -> URL {
        bottle.unixPath(forWindowsPath: "C:\\Program Files (x86)\\Steam")
    }

    public static func libraryFolders(_ bottle: Bottle) -> [URL] {
        let root = steamRoot(bottle)
        var folders = [root]
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for (_, node) in VDF.parse(text)["libraryfolders"]?.children ?? [] {
                if let p = node["path"]?.string {
                    let u = bottle.unixPath(forWindowsPath: p)
                    if !folders.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { folders.append(u) }
                }
            }
        }
        return folders
    }

    public static func scan(_ bottle: Bottle) -> [Game] {
        let fm = FileManager.default
        let root = steamRoot(bottle)
        var games: [Game] = []
        for lib in libraryFolders(bottle) {
            let apps = lib.appendingPathComponent("steamapps")
            guard let files = try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.lastPathComponent.hasPrefix("appmanifest_") && f.pathExtension == "acf" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let state = VDF.parse(text)["AppState"]
                guard let appid = state?["appid"]?.string, let name = state?["name"]?.string,
                      !ignoredAppIDs.contains(appid), !name.lowercased().contains("redistributable") else { continue }
                // StateFlags 4 = fully installed.
                if let flags = state?["StateFlags"]?.string.flatMap(Int.init), flags & 4 == 0 { continue }
                let dir = state?["installdir"]?.string.map { apps.appendingPathComponent("common/\($0)") }
                games.append(Game(bottleID: bottle.id, source: .steam, storeID: appid, name: name,
                                  installDirectory: dir,
                                  executable: dir.flatMap { GameLibrary.guessExecutable(in: $0) },
                                  artwork: artwork(appID: appid, steamRoot: root)))
            }
        }
        return games
    }

    /// Steam caches library art per app; newer clients nest it under a hash dir.
    static func artwork(appID: String, steamRoot: URL) -> URL? {
        let fm = FileManager.default
        let cache = steamRoot.appendingPathComponent("appcache/librarycache")
        let names = ["library_600x900.jpg", "library_capsule.jpg", "header.jpg", "library_header.jpg"]
        for n in ["\(appID)_library_600x900.jpg", "\(appID)_header.jpg"] {
            let u = cache.appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) { return u }
        }
        let dir = cache.appendingPathComponent(appID)
        for n in names where fm.fileExists(atPath: dir.appendingPathComponent(n).path) { return dir.appendingPathComponent(n) }
        if let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for s in subs { for n in names where fm.fileExists(atPath: s.appendingPathComponent(n).path) { return s.appendingPathComponent(n) } }
        }
        return nil
    }
}

public enum EpicLibrary {
    struct Item: Decodable {
        var DisplayName: String?
        var AppName: String?
        var InstallLocation: String?
        var LaunchExecutable: String?
        var bIsIncompleteInstall: Bool?
        var MainGameAppName: String?
    }

    public static func scan(_ bottle: Bottle) -> [Game] {
        let dir = bottle.unixPath(forWindowsPath: "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "item" }.compactMap { f in
            guard let data = try? Data(contentsOf: f), let item = try? JSONDecoder().decode(Item.self, from: data),
                  let app = item.AppName, let name = item.DisplayName, item.bIsIncompleteInstall != true,
                  item.MainGameAppName == nil || item.MainGameAppName == app else { return nil }
            let dir = item.InstallLocation.map { bottle.unixPath(forWindowsPath: $0) }
            let exe = zip2(dir, item.LaunchExecutable).map { $0.appendingPathComponent($1.replacingOccurrences(of: "\\", with: "/")) }
            return Game(bottleID: bottle.id, source: .epic, storeID: app, name: name, installDirectory: dir, executable: exe, artwork: nil)
        }
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? { if let a, let b { return (a, b) }; return nil }
}

public enum GOGLibrary {
    struct Info: Decodable {
        struct Task: Decodable { var isPrimary: Bool?; var path: String?; var arguments: String?; var category: String? }
        var gameId: String?
        var name: String?
        var playTasks: [Task]?
    }

    public static func scan(_ bottle: Bottle) -> [Game] {
        let fm = FileManager.default
        var roots = ["C:\\GOG Games", "C:\\Program Files (x86)\\GOG Galaxy\\Games", "C:\\Program Files (x86)\\GOG Games"].map { bottle.unixPath(forWindowsPath: $0) }
        roots = roots.filter { fm.fileExists(atPath: $0.path) }
        var games: [Game] = []
        for root in roots {
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard let infoFile = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                        .first(where: { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }),
                      let data = try? Data(contentsOf: infoFile),
                      let info = try? JSONDecoder().decode(Info.self, from: data),
                      let id = info.gameId, let name = info.name else { continue }
                let task = info.playTasks?.first { $0.isPrimary == true } ?? info.playTasks?.first
                let exe = task?.path.map { dir.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/")) }
                games.append(Game(bottleID: bottle.id, source: .gog, storeID: id, name: name, installDirectory: dir, executable: exe, artwork: nil))
            }
        }
        return games
    }
}
