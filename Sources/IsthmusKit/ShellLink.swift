import Foundation

/// Minimal reader for Windows `.lnk` files (MS-SHLLINK): target path,
/// arguments and working directory. Installers drop these in the Start Menu,
/// which is how games installed from discs or standalone installers show up
/// in the library.
public struct ShellLink: Sendable, Equatable {
    public var target: String
    public var arguments: String?
    public var workingDirectory: String?
    public var name: String?

    public init(data: Data) throws {
        guard data.count >= 0x4C, data.u32(0) == 0x4C, data.u32(4) == 0x0002_1401 else { throw Error.notShellLink }
        let flags = data.u32(0x14)
        let hasIDList = flags & 0x1 != 0, hasLinkInfo = flags & 0x2 != 0
        let hasName = flags & 0x4 != 0, hasRelPath = flags & 0x8 != 0, hasWorkDir = flags & 0x10 != 0
        let hasArgs = flags & 0x20 != 0, unicode = flags & 0x80 != 0
        var pos = 0x4C
        if hasIDList { pos += 2 + Int(data.u16(pos)) }

        var localPath: String?
        if hasLinkInfo, pos + 28 <= data.count {
            let size = Int(data.u32(pos)), headerSize = Int(data.u32(pos + 4)), liFlags = data.u32(pos + 8)
            if liFlags & 0x1 != 0 {   // VolumeIDAndLocalBasePath
                var base: String?
                if headerSize >= 0x24, pos + 0x20 <= data.count, data.u32(pos + 0x1C) != 0 {
                    base = Self.utf16z(data, at: pos + Int(data.u32(pos + 0x1C)), limit: pos + size)
                }
                if base == nil { base = Self.ansiz(data, at: pos + Int(data.u32(pos + 16)), limit: pos + size) }
                let suffix = Self.ansiz(data, at: pos + Int(data.u32(pos + 24)), limit: pos + size) ?? ""
                if let base, !base.isEmpty {
                    localPath = suffix.isEmpty ? base : (base.hasSuffix("\\") ? base + suffix : base + "\\" + suffix)
                }
            }
            pos += max(size, 4)
        }

        func stringData() -> String? {
            guard pos + 2 <= data.count else { return nil }
            let n = Int(data.u16(pos)); pos += 2
            let bytes = unicode ? n * 2 : n
            guard n > 0, n < 4096, pos + bytes <= data.count else { pos += bytes; return nil }
            let slice = data.subdata(in: data.startIndex + pos ..< data.startIndex + pos + bytes)
            pos += bytes
            let str = unicode ? String(data: slice, encoding: .utf16LittleEndian) : String(data: slice, encoding: .windowsCP1252)
            // Some writers (Wine included) count a trailing NUL.
            return str?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        }
        let name = hasName ? stringData() : nil
        let rel = hasRelPath ? stringData() : nil
        let work = hasWorkDir ? stringData() : nil
        let args = hasArgs ? stringData() : nil

        guard let t = localPath ?? rel, !t.isEmpty else { throw Error.noTarget }
        target = t
        arguments = args?.isEmpty == false ? args : nil
        workingDirectory = work?.isEmpty == false ? work : nil
        self.name = name
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public enum Error: Swift.Error { case notShellLink, noTarget }

    static func ansiz(_ d: Data, at o: Int, limit: Int) -> String? {
        guard o > 0, o < min(d.count, limit) else { return nil }
        var e = o
        while e < min(d.count, limit), d[d.startIndex + e] != 0 { e += 1 }
        return String(data: d.subdata(in: d.startIndex + o ..< d.startIndex + e), encoding: .windowsCP1252)
    }

    static func utf16z(_ d: Data, at o: Int, limit: Int) -> String? {
        guard o > 0, o + 1 < min(d.count, limit) else { return nil }
        var e = o
        while e + 1 < min(d.count, limit), d.u16(e) != 0 { e += 2 }
        return String(data: d.subdata(in: d.startIndex + o ..< d.startIndex + e), encoding: .utf16LittleEndian)
    }
}

/// Programs installed by their own installers, found via Start Menu shortcuts.
public enum StartMenuLibrary {
    /// Shortcuts that aren't games.
    static let skipWords = ["uninstall", "readme", "manual", "website", "support", "help", "license", "release notes",
                            "configuration", "settings", "config", "setup", "update", "register", "documentation", "eula",
                            "visit", "homepage", "faq", "redistributable", "wine "]
    /// Executables already represented by a launcher or by Wine itself.
    static let skipTargets = ["steam.exe", "epicgameslauncher.exe", "galaxyclient.exe", "battle.net launcher.exe",
                              "battle.net.exe", "eadesktop.exe", "ubisoftconnect.exe", "upc.exe", "winecfg.exe",
                              "notepad.exe", "iexplore.exe", "wordpad.exe", "msiexec.exe", "regedit.exe", "explorer.exe"]

    public static func scan(_ bottle: Bottle, excluding known: Set<String> = []) -> [Game] {
        let fm = FileManager.default
        var roots = [bottle.unixPath(forWindowsPath: "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs")]
        if let users = try? fm.contentsOfDirectory(at: bottle.driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil) {
            roots += users.map { $0.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs") }
        }
        var seen = known
        var games: [Game] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let lnk as URL in walker where lnk.pathExtension.lowercased() == "lnk" {
                let title = lnk.deletingPathExtension().lastPathComponent
                if skipWords.contains(where: { title.lowercased().contains($0) }) { continue }
                guard let link = try? ShellLink(url: lnk) else { continue }
                let exe = bottle.unixPath(forWindowsPath: link.target)
                let leaf = exe.lastPathComponent.lowercased()
                guard exe.pathExtension.lowercased() == "exe", !skipTargets.contains(leaf),
                      !skipWords.contains(where: { leaf.contains($0) }),
                      fm.fileExists(atPath: exe.path) else { continue }
                let key = exe.standardizedFileURL.path.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                games.append(Game(bottleID: bottle.id, source: .installed, storeID: bottle.windowsPath(forUnixPath: exe),
                                  name: title, installDirectory: exe.deletingLastPathComponent(), executable: exe, artwork: nil,
                                  arguments: link.arguments.map(ArgumentSplitter.split) ?? []))
            }
        }
        return games
    }
}

/// Splits a command line the way Windows' CommandLineToArgvW and shells do
/// for the common cases: whitespace separates, double quotes group, `\"` escapes.
public enum ArgumentSplitter {
    public static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inQuotes = false, hasToken = false
        var it = Array(s), i = 0
        while i < it.count {
            let c = it[i]
            if c == "\\", i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 2; hasToken = true; continue }
            if c == "\"" { inQuotes.toggle(); hasToken = true }
            else if c.isWhitespace && !inQuotes {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
            } else { cur.append(c); hasToken = true }
            i += 1
        }
        if hasToken { out.append(cur) }
        it.removeAll()
        return out
    }
}
