import Foundation
import Metal

/// System readiness checks shown on first launch and by `isthmus doctor`.
public struct Doctor: Sendable {
    public struct Check: Sendable, Identifiable, Equatable {
        public enum Level: String, Sendable { case ok, warning, error }
        public var id: String
        public var title: String
        public var level: Level
        public var detail: String
        /// Optional one-click fix the UI can offer.
        public var fix: Fix?
    }

    public enum Fix: String, Sendable { case installRosetta, downloadEngine, importD3DMetal }

    public var paths: IsthmusPaths
    public init(paths: IsthmusPaths = .default) { self.paths = paths }

    public static var isAppleSilicon: Bool {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    public static var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    public func run() -> [Check] {
        var checks: [Check] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        checks.append(Self.isAppleSilicon
            ? Check(id: "cpu", title: "Apple silicon", level: .ok, detail: Self.cpuName())
            : Check(id: "cpu", title: "Apple silicon", level: .error, detail: "Isthmus supports Apple silicon Macs only."))

        checks.append(os.majorVersion >= 15
            ? Check(id: "macos", title: "macOS \(osString)", level: .ok, detail: "AVX advertising and Metal 3 features available.")
            : Check(id: "macos", title: "macOS \(osString)", level: .warning,
                    detail: "macOS 15 or newer is recommended. Games that require AVX won't start on older versions."))

        checks.append(Self.rosettaInstalled
            ? Check(id: "rosetta", title: "Rosetta 2", level: .ok, detail: "Installed.")
            : Check(id: "rosetta", title: "Rosetta 2", level: .error,
                    detail: "Windows games are x86 code and need Rosetta 2.", fix: .installRosetta))

        if let gpu = MTLCreateSystemDefaultDevice() {
            let mem = gpu.recommendedMaxWorkingSetSize / 1_073_741_824
            checks.append(Check(id: "gpu", title: gpu.name, level: .ok,
                                detail: "\(mem) GB usable by the GPU\(gpu.supportsRaytracing ? ", hardware ray tracing" : "")."))
        } else {
            checks.append(Check(id: "gpu", title: "GPU", level: .error, detail: "No Metal device found."))
        }

        let ram = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        checks.append(ram >= 16
            ? Check(id: "ram", title: "\(ram) GB memory", level: .ok, detail: "Enough for most modern games.")
            : Check(id: "ram", title: "\(ram) GB memory", level: .warning,
                    detail: "Memory is shared with the GPU. Recent AAA games want 16 GB or more."))

        if let location = Self.appLocationProblem(Bundle.main.bundlePath) {
            checks.append(Check(id: "location", title: "App location", level: .warning, detail: location))
        }

        let engines = EngineManager(paths: paths).installed()
        checks.append(engines.isEmpty
            ? Check(id: "engine", title: "Engine", level: .error, detail: "No engine installed.", fix: .downloadEngine)
            : Check(id: "engine", title: "Engine \(engines[0].version)", level: .ok,
                    detail: "Wine \(engines[0].manifest.wine), DXMT \(engines[0].manifest.components["dxmt"] ?? "?")."))

        if let d = D3DMetalStore(paths: paths).current {
            checks.append(Check(id: "d3dmetal", title: "D3DMetal \(d.version)", level: .ok, detail: "DirectX 12 games use Apple's translator."))
        } else {
            checks.append(Check(id: "d3dmetal", title: "D3DMetal", level: .warning,
                                detail: "Optional. Import Apple's Game Porting Toolkit for the best DirectX 12 support.", fix: .importD3DMetal))
        }

        if let free = try? paths.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            let gb = free / 1_000_000_000
            checks.append(gb >= 50
                ? Check(id: "disk", title: "\(gb) GB free", level: .ok, detail: "")
                : Check(id: "disk", title: "\(gb) GB free", level: .warning, detail: "Modern games need 50–150 GB each."))
        }
        return checks
    }

    /// Launchpad shortcuts and file associations remember where the app is;
    /// running from the disk image or a quarantine-translocated copy breaks them.
    public static func appLocationProblem(_ path: String) -> String? {
        guard path.hasSuffix(".app") else { return nil }   // CLI / tests
        if path.contains("/AppTranslocation/") {
            return "macOS is running Isthmus from a temporary location. Move it to Applications, then open it again."
        }
        if path.hasPrefix("/Volumes/") {
            return "Isthmus is running from the disk image. Drag it to Applications so shortcuts keep working after you eject."
        }
        return nil
    }

    static func cpuName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Opens Apple's Rosetta installer prompt.
    public static func installRosetta() throws {
        try Shell.run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
    }
}
