import XCTest
import AppKit
@testable import IsthmusKit

final class PEFileTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    func testImportsAndMachine() throws {
        let pe = try PEFile(url: fixture("fixture-d3d11.exe"))
        XCTAssertEqual(pe.machine, .x86_64)
        XCTAssertTrue(pe.imports.map { $0.lowercased() }.contains("d3d11.dll"))
        XCTAssertEqual(pe.directXLevel, .d3d11)
    }

    func testIconExtraction() throws {
        let pe = try PEFile(url: fixture("fixture-d3d11.exe"))
        let ico = try XCTUnwrap(pe.iconData())
        XCTAssertEqual(ico.u16(2), 1, "ICO type")
        XCTAssertEqual(ico.u16(4), 1, "one image")
        let image = try XCTUnwrap(NSImage(data: ico))
        XCTAssertEqual(image.size.width, 32)
    }

    func testThirtyTwoBitWithoutIcon() throws {
        let pe = try PEFile(url: fixture("fixture-noicon32.exe"))
        XCTAssertEqual(pe.machine, .i386)
        XCTAssertNil(pe.iconData())
        XCTAssertEqual(pe.directXLevel, .unknown)
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEFile(data: Data("hello world, definitely not a PE file at all......................".utf8)))
        XCTAssertThrowsError(try PEFile(data: Data()))
    }

    func testStringMentionUTF16() throws {
        var d = Data(repeating: 0, count: 64)
        d.append(contentsOf: Array("D3D12.dll".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        d.append(Data(repeating: 0, count: 64))
        var pe = try PEFile(url: fixture("fixture-noicon32.exe"))
        XCTAssertFalse(pe.mentions("d3d12.dll"))
        // Splice the UTF-16 string onto a real PE.
        var raw = try Data(contentsOf: fixture("fixture-noicon32.exe"))
        raw.append(d)
        pe = try PEFile(data: raw)
        XCTAssertTrue(pe.mentions("d3d12.dll"))
        XCTAssertEqual(pe.directXLevel, .d3d12)
    }
}

final class BackendResolverTests: XCTestCase {
    func testAutoChoices() {
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .d3d12, d3dmetalAvailable: true), .d3dmetal)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .d3d12, d3dmetalAvailable: false), .wined3d)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .d3d11, d3dmetalAvailable: true), .dxmt)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .d3d10, d3dmetalAvailable: false), .dxmt)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .d3d9, d3dmetalAvailable: true), .wined3d)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .unknown, d3dmetalAvailable: true), .d3dmetal)
        XCTAssertEqual(BackendResolver.resolve(.auto, directX: .unknown, d3dmetalAvailable: false), .dxmt)
    }

    func testExplicitD3DMetalFallsBackWhenMissing() {
        XCTAssertEqual(BackendResolver.resolve(.d3dmetal, directX: .d3d12, d3dmetalAvailable: false), .wined3d)
        XCTAssertEqual(BackendResolver.resolve(.d3dmetal, directX: .d3d11, d3dmetalAvailable: false), .dxmt)
        XCTAssertEqual(BackendResolver.resolve(.dxvk, directX: .d3d12, d3dmetalAvailable: true), .dxvk)
    }

    func testDirectXFromImports() {
        XCTAssertEqual(DirectXLevel(imports: ["KERNEL32.dll", "D3D12.dll", "dxgi.dll"]), .d3d12)
        XCTAssertEqual(DirectXLevel(imports: ["dxgi.dll"]), .d3d11)
        XCTAssertEqual(DirectXLevel(imports: ["d3d9.dll"]), .d3d9)
        XCTAssertEqual(DirectXLevel(imports: ["d3d8.dll"]), .d3d9)
        XCTAssertEqual(DirectXLevel(imports: ["user32.dll"]), .unknown)
    }
}

final class SettingsMergeTests: XCTestCase {
    func testLayering() {
        var bottle = BottleSettings()
        bottle.graphics = .dxvk
        bottle.environment = ["A": "bottle", "B": "bottle"]
        bottle.dllOverrides = ["xinput1_3": "b"]
        var recipe = Recipe.Settings()
        recipe.graphics = .d3dmetal
        recipe.advertiseAVX = false
        recipe.arguments = ["--skip-launcher"]
        recipe.environment = ["B": "recipe"]
        var program = ProgramSettings()
        program.graphics = .dxmt
        program.arguments = ["-windowed"]
        program.environment = ["C": "program"]
        program.dllOverrides = ["xinput1_3": "n"]

        let e = EffectiveSettings.merge(bottle: bottle, recipe: recipe, program: program)
        XCTAssertEqual(e.graphics, .dxmt, "program beats recipe beats bottle")
        XCTAssertFalse(e.advertiseAVX, "recipe beats bottle")
        XCTAssertEqual(e.arguments, ["--skip-launcher", "-windowed"])
        XCTAssertEqual(e.environment, ["A": "bottle", "B": "recipe", "C": "program"])
        XCTAssertEqual(e.dllOverrides["xinput1_3"], "n")
    }

    func testBottleSettingsDecodeIsTolerant() throws {
        let json = #"{"graphics":"dxmt","msync":false}"#
        let s = try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.graphics, .dxmt)
        XCTAssertFalse(s.msync)
        XCTAssertTrue(s.advertiseAVX, "missing keys take defaults")
        XCTAssertEqual(s.windowsVersion, .win10)
    }
}

final class EnvironmentTests: XCTestCase {
    func bottle() -> Bottle {
        Bottle(url: URL(fileURLWithPath: "/tmp/isthmus-test/Bottles/b"), config: BottleConfig(id: "b", name: "B"))
    }

    func env(_ backend: GraphicsBackend, _ mutate: (inout EffectiveSettings) -> Void = { _ in }) -> [String: String] {
        var s = EffectiveSettings.merge(bottle: BottleSettings(), recipe: nil, program: ProgramSettings())
        mutate(&s)
        return LaunchPlanner.environment(engineRoot: URL(fileURLWithPath: "/E"), bottle: bottle(), settings: s,
                                         backend: backend, base: ["HOME": "/Users/x", "SECRET_TOKEN": "nope"])
    }

    func testBasics() {
        let e = env(.dxmt)
        XCTAssertEqual(e["WINEPREFIX"], "/tmp/isthmus-test/Bottles/b/prefix")
        XCTAssertEqual(e["HOME"], "/Users/x")
        XCTAssertNil(e["SECRET_TOKEN"], "don't leak arbitrary parent environment into games")
        XCTAssertEqual(e["WINEMSYNC"], "1")
        XCTAssertEqual(e["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertTrue(e["DYLD_FALLBACK_LIBRARY_PATH"]!.hasPrefix("/E/lib:"))
        XCTAssertEqual(e["VK_DRIVER_FILES"], "/E/share/vulkan/icd.d/MoltenVK_icd.json")
        XCTAssertTrue(e["WINEDLLOVERRIDES"]!.contains("winemenubuilder.exe=d"))
        XCTAssertTrue(e["WINEDLLOVERRIDES"]!.contains("dxgi=b"))
        XCTAssertNotNil(e["DXMT_SHADER_CACHE_PATH"])
        XCTAssertNil(e["DXMT_ENABLE_NVEXT"])
    }

    func testToggles() {
        let e = env(.dxmt) { $0.msync = false; $0.advertiseAVX = false; $0.metalHUD = true; $0.metalFXUpscaling = true }
        XCTAssertNil(e["WINEMSYNC"])
        XCTAssertNil(e["ROSETTA_ADVERTISE_AVX"])
        XCTAssertEqual(e["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(e["DXMT_ENABLE_NVEXT"], "1")
        XCTAssertTrue(e["WINEDLLOVERRIDES"]!.contains("nvngx=b"))
    }

    func testBackendSpecific() {
        XCTAssertEqual(env(.dxvk)["DXVK_ASYNC"], "1")
        XCTAssertEqual(env(.wined3d)["WINE_D3D_CONFIG"], "renderer=gl")
        XCTAssertEqual(env(.d3dmetal) { $0.rayTracing = true }["D3DM_SUPPORT_DXR"], "1")
        XCTAssertNil(env(.dxmt) { $0.rayTracing = true }["D3DM_SUPPORT_DXR"])
    }

    func testUserOverridesWin() {
        let e = env(.dxmt) { $0.environment = ["WINEDEBUG": "+relay"]; $0.dllOverrides = ["DXGI": "n"] }
        XCTAssertEqual(e["WINEDEBUG"], "+relay")
        XCTAssertTrue(e["WINEDLLOVERRIDES"]!.contains("dxgi=n"))
        XCTAssertFalse(e["WINEDLLOVERRIDES"]!.contains("dxgi=b"))
    }
}

final class BottleTests: XCTestCase {
    var paths: IsthmusPaths!

    override func setUpWithError() throws {
        paths = IsthmusPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("isthmus-tests-\(UUID().uuidString)"))
        try paths.ensure()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: paths.root) }

    func testCreateListRenameDelete() throws {
        let store = BottleStore(paths: paths)
        let b = try store.create(name: "  My Games  ")
        XCTAssertEqual(b.id, "my-games")
        XCTAssertEqual(b.name, "My Games")
        XCTAssertThrowsError(try store.create(name: "my games"))
        XCTAssertThrowsError(try store.create(name: "   "))
        XCTAssertThrowsError(try store.create(name: "!!!"))
        XCTAssertEqual(store.list().map(\.id), ["my-games"])
        XCTAssertEqual(try store.bottle("MY GAMES").id, "my-games")
        let renamed = try store.rename(b, to: "Steam")
        XCTAssertEqual(try store.bottle("my-games").name, "Steam")
        try store.delete(renamed)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testPathMapping() throws {
        let b = try BottleStore(paths: paths).create(name: "Map")
        try FileManager.default.createDirectory(at: b.driveC, withIntermediateDirectories: true)
        let dos = b.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: dos, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("d:").path, withDestinationPath: "/Volumes/Games")

        let steam = b.unixPath(forWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe")
        XCTAssertEqual(steam.standardizedFileURL.path, b.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe").standardizedFileURL.path)
        XCTAssertEqual(b.unixPath(forWindowsPath: "D:\\SteamLibrary").path, "/Volumes/Games/SteamLibrary")
        XCTAssertEqual(b.unixPath(forWindowsPath: "/Users/x/game.exe").path, "/Users/x/game.exe")
        XCTAssertEqual(b.windowsPath(forUnixPath: b.driveC.appendingPathComponent("Games/a.exe")), "C:\\Games\\a.exe")
        XCTAssertEqual(b.windowsPath(forUnixPath: URL(fileURLWithPath: "/Users/x/a.exe")), "Z:\\Users\\x\\a.exe")
        XCTAssertEqual(Bottle.programKey("C:/Games/A.EXE"), "c:\\games\\a.exe")
    }
}

final class RegFileTests: XCTestCase {
    func testFormatting() {
        var r = RegFile()
        r.set("HKEY_CURRENT_USER\\Software\\Test", "Name", .string("C:\\path \"q\""))
        r.set("HKEY_CURRENT_USER\\Software\\Test", "Count", .dword(192))
        r.set("HKEY_CURRENT_USER\\Software\\Other", "Gone", .delete)
        XCTAssertEqual(r.text, """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Test]
        "Name"="C:\\\\path \\"q\\""
        "Count"=dword:000000c0

        [HKEY_CURRENT_USER\\Software\\Other]
        "Gone"=-

        """)
    }

    func testSettingsHashChangesOnlyForRegistryFields() {
        var a = BottleSettings(), b = BottleSettings()
        b.metalHUD = true                       // env-only setting
        XCTAssertEqual(BottleSetup.registryHash(a), BottleSetup.registryHash(b))
        a.retinaMode = true                     // registry setting
        XCTAssertNotEqual(BottleSetup.registryHash(a), BottleSetup.registryHash(b))
        b.retinaMode = true; b.windowsVersion = .win7
        XCTAssertNotEqual(BottleSetup.registryHash(a), BottleSetup.registryHash(b))
    }
}

final class VDFTests: XCTestCase {
    func testAppManifest() {
        let text = """
        "AppState"
        {
            "appid"     "1091500"
            "name"      "Cyberpunk 2077"
            "StateFlags"    "4"
            "installdir"    "Cyberpunk 2077"
            "UserConfig" { "language" "english" }
        }
        """
        let root = VDF.parse(text)
        XCTAssertEqual(root["AppState"]?["appid"]?.string, "1091500")
        XCTAssertEqual(root["appstate"]?["NAME"]?.string, "Cyberpunk 2077")
        XCTAssertEqual(root["AppState"]?["UserConfig"]?["language"]?.string, "english")
    }

    func testLibraryFoldersWithEscapesAndComments() {
        let text = """
        // comment
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { "228980" "1" } }
            "1" { "path" "D:\\\\SteamLibrary" }
        }
        """
        let lf = VDF.parse(text)["libraryfolders"]
        XCTAssertEqual(lf?.children.count, 2)
        XCTAssertEqual(lf?["1"]?["path"]?.string, "D:\\SteamLibrary")
        XCTAssertEqual(lf?["0"]?["apps"]?["228980"]?.string, "1")
    }
}

final class RecipeTests: XCTestCase {
    func testBundledRecipesLoadAndValidate() {
        let book = RecipeBook.load(paths: IsthmusPaths(root: URL(fileURLWithPath: "/nonexistent")))
        XCTAssertGreaterThan(book.recipes.count, 5)
        XCTAssertEqual(Set(book.recipes.map(\.id)).count, book.recipes.count, "recipe ids are unique")
        for r in book.recipes {
            XCTAssertFalse(r.name.isEmpty)
            let m = r.match
            XCTAssertTrue(m.exe != nil || m.steamAppID != nil || m.epicAppName != nil || m.gogID != nil, "\(r.id) matches nothing")
            XCTAssertEqual(m.exe ?? [], (m.exe ?? []).map { $0.lowercased() }, "\(r.id): exe names must be lowercase")
            for c in r.settings.components ?? [] { XCTAssertNotNil(Catalog.component(c), "\(r.id) references unknown component \(c)") }
            if r.status != .works { XCTAssertNotNil(r.notes, "\(r.id) needs notes explaining its status") }
        }
    }

    func testMatchingPrefersStoreIDs() {
        let book = RecipeBook.load(paths: IsthmusPaths(root: URL(fileURLWithPath: "/nonexistent")))
        XCTAssertEqual(book.recipe(steamAppID: 1091500)?.id, "cyberpunk-2077")
        XCTAssertEqual(book.recipe(exeName: "Cyberpunk2077.exe")?.id, "cyberpunk-2077")
        XCTAssertEqual(book.recipe(exeName: "VALORANT.exe")?.status, .blocked)
        XCTAssertEqual(book.recipe(epicAppName: "fortnite")?.status, .blocked)
        XCTAssertNil(book.recipe(exeName: "notepad.exe"))
    }

    func testUserRecipesOverrideBundled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isthmus-recipes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Recipes"), withIntermediateDirectories: true)
        let json = #"{"id":"cyberpunk-2077","name":"Local CP","match":{"steamAppID":[1091500]},"status":"issues","settings":{"graphics":"dxvk"},"notes":"x"}"#
        try json.write(to: root.appendingPathComponent("Recipes/local.json"), atomically: true, encoding: .utf8)
        let book = RecipeBook.load(paths: IsthmusPaths(root: root))
        XCTAssertEqual(book.recipe(steamAppID: 1091500)?.name, "Local CP")
        XCTAssertEqual(book.recipe(steamAppID: 1091500)?.settings.graphics, .dxvk)
    }
}

final class CatalogTests: XCTestCase {
    func testCatalogs() {
        let launchers = Catalog.launchers()
        XCTAssertNotNil(launchers.first { $0.id == "steam" })
        for l in launchers {
            XCTAssertEqual(l.installerURL.scheme, "https")
            XCTAssertTrue(l.executable.hasPrefix("C:\\"), "\(l.id) executable should be a Windows path")
        }
        let comps = Catalog.components()
        XCTAssertNotNil(comps.first { $0.id == "vcrun2022" })
        for c in comps { XCTAssertFalse(c.installers.isEmpty); c.installers.forEach { XCTAssertEqual($0.url.scheme, "https") } }
    }
}

final class OverlayTests: XCTestCase {
    func testOverlayReplacesWithoutTouchingBase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("isthmus-overlay-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = IsthmusPaths(root: root)
        try paths.ensure()
        let e = paths.engines.appendingPathComponent("1.0")
        for d in ["bin", "lib/wine/x86_64-windows", "lib/wine/x86_64-unix", "lib/dxmt/x86_64-windows", "lib/dxmt/x86_64-unix"] {
            try fm.createDirectory(at: e.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data("base-d3d11".utf8).write(to: e.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        try Data("base-kernel".utf8).write(to: e.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll"))
        try Data("dxmt-d3d11".utf8).write(to: e.appendingPathComponent("lib/dxmt/x86_64-windows/d3d11.dll"))
        try Data("nv".utf8).write(to: e.appendingPathComponent("lib/dxmt/x86_64-windows/nvngx.dll"))
        try Data("so".utf8).write(to: e.appendingPathComponent("lib/dxmt/x86_64-unix/winemetal.so"))
        try Data("#!".utf8).write(to: e.appendingPathComponent("bin/wine"))
        try fm.createSymbolicLink(atPath: e.appendingPathComponent("lib/libfoo.dylib").path, withDestinationPath: "libfoo.1.dylib")
        let manifest = EngineManifest(name: "t", version: "1.0", wine: "11.0", source: "t", arch: "x86_64", components: [:], built: nil)
        try JSON.write(manifest, to: e.appendingPathComponent("engine.json"))
        let engine = try Engine(url: e)

        let dir = try RuntimeOverlay.prepare(engine: engine, backend: .dxmt, d3dmetal: nil, nvext: false, paths: paths)
        let read = { (p: String) in String(decoding: try Data(contentsOf: dir.appendingPathComponent(p)), as: UTF8.self) }
        XCTAssertEqual(try read("lib/wine/x86_64-windows/d3d11.dll"), "dxmt-d3d11")
        XCTAssertEqual(try read("lib/wine/x86_64-windows/kernel32.dll"), "base-kernel")
        XCTAssertEqual(try read("lib/wine/x86_64-unix/winemetal.so"), "so")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("lib/wine/x86_64-windows/nvngx.dll").path), "nvext off")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("lib/libfoo.dylib").path), "libfoo.1.dylib")
        XCTAssertEqual(String(decoding: try Data(contentsOf: e.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), as: UTF8.self),
                       "base-d3d11", "base engine untouched")
        // Hardlinked, not copied.
        let a = try fm.attributesOfItem(atPath: dir.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll").path)
        XCTAssertEqual((a[.referenceCount] as? Int) ?? 0, 2)
        // Cached on second call; wined3d uses the base engine directly.
        XCTAssertEqual(try RuntimeOverlay.prepare(engine: engine, backend: .dxmt, d3dmetal: nil, nvext: false, paths: paths), dir)
        XCTAssertEqual(try RuntimeOverlay.prepare(engine: engine, backend: .wined3d, d3dmetal: nil, nvext: false, paths: paths), engine.url)
        let nv = try RuntimeOverlay.prepare(engine: engine, backend: .dxmt, d3dmetal: nil, nvext: true, paths: paths)
        XCTAssertTrue(fm.fileExists(atPath: nv.appendingPathComponent("lib/wine/x86_64-windows/nvngx.dll").path))
    }
}

final class LibraryTests: XCTestCase {
    func testSteamAndGOGScan() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("isthmus-lib-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = IsthmusPaths(root: root)
        try paths.ensure()
        let b = try BottleStore(paths: paths).create(name: "Lib")
        let apps = b.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        try fm.createDirectory(at: apps.appendingPathComponent("common/Game One/bin"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: apps.appendingPathComponent("common/Game One/bin/gameone.exe"))
        try Data(count: 10).write(to: apps.appendingPathComponent("common/Game One/unins000.exe"))
        try #""AppState" { "appid" "42" "name" "Game One" "StateFlags" "4" "installdir" "Game One" }"#
            .write(to: apps.appendingPathComponent("appmanifest_42.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4" "installdir" "x" }"#
            .write(to: apps.appendingPathComponent("appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "7" "name" "Downloading" "StateFlags" "1026" "installdir" "y" }"#
            .write(to: apps.appendingPathComponent("appmanifest_7.acf"), atomically: true, encoding: .utf8)

        let gog = b.driveC.appendingPathComponent("GOG Games/Old Game")
        try fm.createDirectory(at: gog, withIntermediateDirectories: true)
        try #"{"gameId":"1207","name":"Old Game","playTasks":[{"isPrimary":true,"path":"old.exe"}]}"#
            .write(to: gog.appendingPathComponent("goggame-1207.info"), atomically: true, encoding: .utf8)

        var bottle = b
        bottle.config.pinned = [PinnedProgram(name: "Tool", path: "C:\\tool.exe")]
        let games = GameLibrary.scan(bottle)
        XCTAssertEqual(games.map(\.name), ["Game One", "Old Game", "Tool"])
        let steam = try XCTUnwrap(games.first { $0.source == .steam })
        XCTAssertEqual(steam.executable?.lastPathComponent, "gameone.exe")
        let t = steam.target(in: bottle)
        XCTAssertEqual(t.arguments, ["-silent", "-applaunch", "42"])
        XCTAssertEqual(t.steamAppID, 42)
        XCTAssertEqual(games.first { $0.source == .gog }?.executable?.lastPathComponent, "old.exe")
    }
}
