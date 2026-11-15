import Foundation
import Darwin

/// Detects whether a prefix's wineserver is alive without starting one.
///
/// wineserver listens on `/tmp/.wine-<uid>/server-<dev>-<inode>/socket`, where
/// dev/inode identify the prefix directory (server/request.c). A successful
/// `connect()` means a server is running; a leftover socket file refuses.
public enum WineServer {
    public static func socketPath(prefix: URL) -> String? {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return nil }
        let dev = String(UInt64(bitPattern: Int64(st.st_dev)), radix: 16)
        let ino = String(UInt64(st.st_ino), radix: 16)
        return "/tmp/.wine-\(getuid())/server-\(dev)-\(ino)/socket"
    }

    public static func isRunning(prefix: URL) -> Bool {
        guard let path = socketPath(prefix: prefix), FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
        return ok
    }

    public static func isRunning(_ bottle: Bottle) -> Bool { isRunning(prefix: bottle.prefix) }
}

/// Finds a running store client (Steam, Epic) in a bottle and the runtime
/// it loaded, from live process state rather than records: Steam restarts
/// itself after updates, so any remembered pid goes stale.
public enum LauncherProcess {
    public struct Found: Sendable, Equatable { public var pid: Int32; public var root: String }

    /// Lowercased executable leaf per launcher id.
    static let executables = ["steam": "steam.exe", "epic": "epicgameslauncher.exe"]

    public static func find(_ launcher: String, in bottle: Bottle, paths: IsthmusPaths = .default) -> Found? {
        guard WineServer.isRunning(bottle), let exe = executables[launcher],
              let ps = try? Shell.run("/bin/ps", ["-axo", "pid=,command="], allowFailure: true) else { return nil }
        let loaders = loaderInodes(paths: paths)
        for pid in candidates(psOutput: ps.output, exe: exe) {
            guard let lsof = try? Shell.run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"], allowFailure: true),
                  let root = runtimeRoot(lsofOutput: lsof.output, prefix: bottle.prefix.path, loaders: loaders) else { continue }
            return Found(pid: pid, root: root)
        }
        return nil
    }

    /// inode of each runtime's `lib/wine/x86_64-unix/wine` → runtime root.
    /// Overlays hardlink everything else (so file paths of e.g. ntdll.so are
    /// ambiguous: the kernel reports whichever link was used last), but each
    /// gets its own loader copy.
    static func loaderInodes(paths: IsthmusPaths) -> [UInt64: String] {
        let fm = FileManager.default
        var map: [UInt64: String] = [:]
        for base in [paths.engines, paths.runtime] {
            for dir in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where !dir.lastPathComponent.hasPrefix(".") {
                var st = stat()
                if stat(dir.appendingPathComponent("lib/wine/x86_64-unix/wine").path, &st) == 0 { map[UInt64(st.st_ino)] = dir.path }
            }
        }
        return map
    }

    /// Wine processes show their Windows command line; the client's own
    /// process is the one whose program (not an argument) is `exe`.
    static func candidates(psOutput: String, exe: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = Int32(t[..<space]) else { return nil }
            let cmd = t[t.index(after: space)...].trimmingCharacters(in: .whitespaces).lowercased()
            // Processes Wine starts itself show a Windows path (C:\…\steam.exe);
            // the one Isthmus starts shows the Unix path it was given
            // (/Users/…/steam.exe). The program ends at the first ".exe"
            // followed by a space or the end.
            let isWindows = cmd.count > 3 && cmd.dropFirst().hasPrefix(":\\")
            guard isWindows || cmd.hasPrefix("/"),
                  let end = cmd.range(of: #"\.exe(?=\s|$)"#, options: .regularExpression) else { return nil }
            let program = cmd[..<end.upperBound]
            return program.hasSuffix((isWindows ? "\\" : "/") + exe) ? pid : nil
        }
    }

    /// Folder whose processes belong to each client.
    static let clientFolders = ["steam": ["\\steam\\", "\\common files\\steam\\"], "epic": ["\\epic games\\launcher\\"]]

    /// Windows processes in the bottle, as (pid, lowercased command line).
    static func windowsProcesses(in bottle: Bottle) -> [(Int32, String)] {
        guard WineServer.isRunning(bottle), let ps = try? Shell.run("/bin/ps", ["-axo", "pid=,command="], allowFailure: true) else { return [] }
        return ps.output.split(separator: "\n").compactMap { line -> (Int32, String)? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
            let cmd = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces).lowercased()
            // Windows-path command lines, or the Unix path Isthmus started a program with.
            let isWindows = cmd.count > 3 && cmd.dropFirst().hasPrefix(":\\")
            guard isWindows || (cmd.hasPrefix("/") && cmd.contains("/drive_c/")) else { return nil }
            guard let lsof = try? Shell.run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"], allowFailure: true),
                  lsof.output.contains("n" + bottle.prefix.path + "/") else { return nil }
            return (pid, cmd)
        }
    }

    /// Names of user programs running in the bottle other than the client
    /// and Wine's own background services.
    public static func otherPrograms(in bottle: Bottle, excluding launcher: String) -> [String] {
        let folders = clientFolders[launcher] ?? []
        return windowsProcesses(in: bottle).compactMap { _, cmd in
            if cmd.contains("\\windows\\system32\\") || cmd.contains("\\windows\\syswow64\\") { return nil }
            if folders.contains(where: { cmd.replacingOccurrences(of: "/", with: "\\").contains($0) }) { return nil }
            let leaf = cmd.components(separatedBy: ".exe").first?.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
            return leaf.map { String($0) + ".exe" }
        }
    }

    /// SIGTERM, then SIGKILL, the client's own processes (not the bottle's).
    public static func terminate(_ launcher: String, in bottle: Bottle) {
        let folders = clientFolders[launcher] ?? []
        let pids = windowsProcesses(in: bottle).filter { _, cmd in
            folders.contains { cmd.replacingOccurrences(of: "/", with: "\\").contains($0) }
        }.map(\.0)
        pids.forEach { kill($0, SIGTERM) }
        Thread.sleep(forTimeInterval: 3)
        pids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    /// The process belongs to `prefix` if it has files open inside it. Its
    /// runtime comes from the loader it runs: either Wine's re-exec link
    /// `…/winetemp-<loader inode>-…/<name>` or the loader path itself.
    static func runtimeRoot(lsofOutput: String, prefix: String, loaders: [UInt64: String]) -> String? {
        let names = lsofOutput.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        guard names.contains(where: { $0.hasPrefix(prefix + "/") }) else { return nil }
        for n in names {
            if let r = n.range(of: #"/winetemp-([0-9]+)-"#, options: .regularExpression) {
                let digits = n[r].dropFirst("/winetemp-".count).dropLast()
                if let ino = UInt64(digits), let root = loaders[ino] { return root }
            }
        }
        let suffix = "/lib/wine/x86_64-unix/wine"
        return names.first { $0.hasSuffix(suffix) && loaders.values.contains(String($0.dropLast(suffix.count))) }
            .map { String($0.dropLast(suffix.count)) }
    }
}
