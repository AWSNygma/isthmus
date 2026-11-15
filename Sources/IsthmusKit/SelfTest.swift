import Foundation

/// Runs the bundled Windows probe programs (tests/winprobes) through the
/// normal launch path, so users can check every graphics backend on their
/// own Mac, for example right after importing D3DMetal.
public struct SelfTest: Sendable {
    public struct Result: Sendable, Identifiable, Equatable {
        public enum Outcome: String, Sendable { case pass, fail, skip }
        public var id: String { name }
        public var name: String
        public var outcome: Outcome
        public var detail: String
        public var required: Bool
    }

    struct Case { var name: String; var exe: String; var args: [String]; var graphics: GraphicsBackend?; var expect: String?; var required: Bool }

    public var paths: IsthmusPaths
    public var probes: URL

    public init(paths: IsthmusPaths = .default, probes: URL? = nil) {
        self.paths = paths
        self.probes = probes ?? Self.defaultProbes ?? URL(fileURLWithPath: "tests/winprobes/build")
    }

    /// Inside the app bundle (Contents/Resources/probes) or next to the CLI.
    public static var defaultProbes: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("probes"),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/probes"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("d3d11_probe.exe").path) }
    }

    func cases(d3dmetal: Bool) -> [Case] {
        var c: [Case] = []
        for g in [GraphicsBackend.dxmt, .dxvk, .wined3d] {
            c.append(Case(name: "DirectX 11 (64-bit) via \(g.displayName)", exe: "d3d11_probe.exe", args: [], graphics: g, expect: "impl=\(g.rawValue)", required: true))
            c.append(Case(name: "DirectX 11 (32-bit) via \(g.displayName)", exe: "d3d11_probe32.exe", args: [], graphics: g, expect: "impl=\(g.rawValue)", required: true))
        }
        c.append(Case(name: "DirectX 12 via vkd3d", exe: "d3d12_probe.exe", args: [], graphics: .wined3d, expect: nil, required: true))
        if d3dmetal {
            c.append(Case(name: "DirectX 12 via D3DMetal", exe: "d3d12_probe.exe", args: [], graphics: .d3dmetal, expect: nil, required: true))
            c.append(Case(name: "DirectX 11 via D3DMetal", exe: "d3d11_probe.exe", args: [], graphics: .d3dmetal, expect: "impl=d3dmetal", required: true))
        }
        c.append(Case(name: "DirectX 9", exe: "d3d9_probe.exe", args: [], graphics: nil, expect: nil, required: true))
        c.append(Case(name: "DirectX 9 (32-bit)", exe: "d3d9_probe32.exe", args: [], graphics: nil, expect: nil, required: true))
        c.append(Case(name: "Vulkan", exe: "vulkan_probe.exe", args: [], graphics: nil, expect: nil, required: true))
        c.append(Case(name: "AVX visible to games", exe: "system_probes.exe", args: ["cpu"], graphics: nil, expect: nil, required: true))
        c.append(Case(name: "HTTPS networking", exe: "system_probes.exe", args: ["net"], graphics: nil, expect: nil, required: false))
        c.append(Case(name: "Game controllers (XInput)", exe: "system_probes.exe", args: ["xinput"], graphics: nil, expect: nil, required: true))
        c.append(Case(name: "Audio output", exe: "system_probes.exe", args: ["audio"], graphics: nil, expect: nil, required: false))
        c.append(Case(name: "Video/audio decoding", exe: "system_probes.exe", args: ["media"], graphics: nil, expect: nil, required: true))
        return c
    }

    public func run(bottle: Bottle, progress: (@Sendable (Result) -> Void)? = nil) async throws -> [Result] {
        guard FileManager.default.fileExists(atPath: probes.appendingPathComponent("d3d11_probe.exe").path) else {
            throw IsthmusError.unsupported("Self-test programs not found at \(probes.path).")
        }
        let service = LaunchService(paths: paths, recipes: RecipeBook(recipes: []))
        var results: [Result] = []
        for c in cases(d3dmetal: D3DMetalStore(paths: paths).current != nil) {
            var r: Result
            do {
                let target = LaunchTarget(program: probes.appendingPathComponent(c.exe).path, arguments: c.args, graphicsOverride: c.graphics)
                var plan = try await service.prepare(bottle: bottle, target: target)
                plan.environment["WINEDEBUG"] = "-all"
                let out = try WineRunner.run(plan, timeout: 120).output
                r = Self.parse(out, name: c.name, required: c.required, expect: c.expect)
            } catch {
                r = Result(name: c.name, outcome: .fail, detail: error.localizedDescription, required: c.required)
            }
            results.append(r)
            progress?(r)
        }
        return results
    }

    static func parse(_ output: String, name: String, required: Bool, expect: String?) -> Result {
        let output = output.replacingOccurrences(of: "\r", with: "")
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("PASS ") || $0.hasPrefix("FAIL ") || $0.hasPrefix("SKIP ") }) else {
            return Result(name: name, outcome: .fail, detail: "no result (crashed or timed out)", required: required)
        }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let detail = parts.count > 2 ? parts[2] : ""
        switch parts[0] {
        case "PASS":
            if let expect, !detail.contains(expect) {
                return Result(name: name, outcome: .fail, detail: "wrong implementation loaded: \(detail)", required: required)
            }
            return Result(name: name, outcome: .pass, detail: detail, required: required)
        case "SKIP": return Result(name: name, outcome: .skip, detail: detail, required: required)
        default: return Result(name: name, outcome: .fail, detail: detail, required: required)
        }
    }
}
