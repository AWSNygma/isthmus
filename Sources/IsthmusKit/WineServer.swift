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

    public static func find(_ launcher: String, in bottle: Bottle) -> Found? {
        guard WineServer.isRunning(bottle), let exe = executables[launcher],
              let ps = try? Shell.run("/bin/ps", ["-axo", "pid=,command="], allowFailure: true) else { return nil }
        for pid in candidates(psOutput: ps.output, exe: exe) {
            guard let lsof = try? Shell.run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"], allowFailure: true),
                  let root = runtimeRoot(lsofOutput: lsof.output, prefix: bottle.prefix.path) else { continue }
            return Found(pid: pid, root: root)
        }
        return nil
    }

    /// Wine processes show their Windows command line; the client's own
    /// process is the one whose program (not an argument) is `exe`.
    static func candidates(psOutput: String, exe: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = Int32(t[..<space]) else { return nil }
            let cmd = t[t.index(after: space)...].trimmingCharacters(in: .whitespaces).lowercased()
            // The program ends at the first ".exe" followed by a space or the end.
            guard cmd.count > 3, cmd.dropFirst().hasPrefix(":\\"),
                  let end = cmd.range(of: #"\.exe(?=\s|$)"#, options: .regularExpression) else { return nil }
            let program = cmd[..<end.upperBound]
            return program.hasSuffix("\\" + exe) ? pid : nil
        }
    }

    /// The process belongs to `prefix` if it has files open inside it; its
    /// runtime is wherever its ntdll.so is mapped from.
    static func runtimeRoot(lsofOutput: String, prefix: String) -> String? {
        let names = lsofOutput.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        guard names.contains(where: { $0.hasPrefix(prefix + "/") }) else { return nil }
        let suffix = "/lib/wine/x86_64-unix/ntdll.so"
        return names.first { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
    }
}
