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

/// Remembers which runtime a bottle's store launcher (Steam, Epic) was started
/// from. Games started *through* a launcher inherit the launcher's runtime, so
/// a backend change means the launcher must restart.
public struct LauncherRuntimeRecord: Codable, Sendable, Equatable {
    public var root: String
    public var launcher: String
    public var started: Date
    /// Host pid of the client process (Wine keeps the pid across its exec chain).
    public var pid: Int32?

    static func url(_ bottle: Bottle) -> URL { bottle.cache.appendingPathComponent("launcher-runtime.json") }

    /// The record, if that client is demonstrably still running.
    public static func read(_ bottle: Bottle) -> LauncherRuntimeRecord? {
        guard WineServer.isRunning(bottle),
              let r = try? JSON.read(LauncherRuntimeRecord.self, from: url(bottle)) else { return nil }
        if let pid = r.pid {
            guard kill(pid, 0) == 0, processName(pid)?.lowercased().contains(r.launcher == "steam" ? "steam" : "epic") == true else { return nil }
        } else if r.launcher == "epic" {
            guard (try? Shell.run("/usr/bin/pgrep", ["-f", "EpicGamesLauncher.exe"], allowFailure: true))?.status == 0 else { return nil }
        }
        return r
    }

    static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            // Windows processes rename argv[0]; fall back to ps.
            return (try? Shell.run("/bin/ps", ["-o", "command=", "-p", "\(pid)"], allowFailure: true))?.output
        }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let cmd = (try? Shell.run("/bin/ps", ["-o", "command=", "-p", "\(pid)"], allowFailure: true))?.output ?? ""
        return path + " " + cmd
    }

    public static func write(_ record: LauncherRuntimeRecord, for bottle: Bottle) {
        try? JSON.write(record, to: url(bottle))
    }
}
