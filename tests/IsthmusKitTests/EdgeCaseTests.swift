import XCTest
import Darwin
@testable import IsthmusKit

/// Fresh ISTHMUS_HOME per test.
class TempHomeTestCase: XCTestCase {
    var paths: IsthmusPaths!
    override func setUpWithError() throws {
        paths = IsthmusPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("isthmus-edge-\(UUID().uuidString)"))
        try paths.ensure()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: paths.root) }

    /// A structurally valid fake engine (no real Wine inside).
    @discardableResult
    func fakeEngine(_ version: String) throws -> Engine {
        let fm = FileManager.default
        let e = paths.engines.appendingPathComponent(version)
        for d in ["bin", "lib/wine/x86_64-unix", "lib/wine/x86_64-windows", "lib/dxmt/x86_64-windows"] {
            try fm.createDirectory(at: e.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for f in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/d3d11.dll", "lib/dxmt/x86_64-windows/d3d11.dll"] {
            try Data(f.utf8).write(to: e.appendingPathComponent(f))
        }
        try JSON.write(EngineManifest(name: "t", version: version, wine: "11.0", source: "t", arch: "x86_64", components: [:], built: nil),
                       to: e.appendingPathComponent("engine.json"))
        return try Engine(url: e)
    }
}

final class ArgumentSplitterTests: XCTestCase {
    func testSplitting() {
        XCTAssertEqual(ArgumentSplitter.split(""), [])
        XCTAssertEqual(ArgumentSplitter.split("  -windowed   -dx11 "), ["-windowed", "-dx11"])
        XCTAssertEqual(ArgumentSplitter.split(#"-path "C:\Program Files\Game" -x"#), ["-path", #"C:\Program Files\Game"#, "-x"])
        XCTAssertEqual(ArgumentSplitter.split(#"--name=\"quoted\""#), [#"--name="quoted""#])
        XCTAssertEqual(ArgumentSplitter.split(#""""#), [""], "empty quoted argument is kept")
        XCTAssertEqual(ArgumentSplitter.split(#"a"b c"d"#), ["ab cd"])
    }
}

final class ShellLinkTests: TempHomeTestCase {
    func fixture(_ n: String) throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: nil)) }

    func testWineCreatedShortcut() throws {
        let l = try ShellLink(url: fixture("steam-wine.lnk"))
        XCTAssertEqual(l.target, #"C:\Program Files (x86)\Steam\steam.exe"#)
        XCTAssertNil(l.arguments)
        XCTAssertEqual(l.workingDirectory, #"C:\Program Files (x86)\Steam"#)
    }

    func testShortcutWithArguments() throws {
        let l = try ShellLink(url: fixture("hero-args.lnk"))
        XCTAssertEqual(l.target, #"C:\Games\Hero Quest\hero.exe"#)
        XCTAssertEqual(l.arguments, #"-windowed -profile "Main Save""#)
        XCTAssertEqual(l.workingDirectory, #"C:\Games\Hero Quest"#)
        XCTAssertEqual(ArgumentSplitter.split(l.arguments!), ["-windowed", "-profile", "Main Save"])
    }

    func testStartMenuFindsInstalledGame() throws {
        let b = try BottleStore(paths: paths).create(name: "Hero")
        let fm = FileManager.default
        let menu = b.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs/Hero Quest")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try fm.copyItem(at: fixture("hero-args.lnk"), to: menu.appendingPathComponent("Hero Quest.lnk"))
        XCTAssertTrue(StartMenuLibrary.scan(b).isEmpty, "target missing → not listed")
        let dir = b.driveC.appendingPathComponent("Games/Hero Quest")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: dir.appendingPathComponent("hero.exe"))
        let found = StartMenuLibrary.scan(b)
        XCTAssertEqual(found.map(\.name), ["Hero Quest"])
        XCTAssertEqual(found.first?.target(in: b).arguments, ["-windowed", "-profile", "Main Save"])
        // A desktop duplicate or second shortcut to the same exe isn't listed twice.
        try fm.copyItem(at: fixture("hero-args.lnk"), to: menu.appendingPathComponent("Hero Quest (2).lnk"))
        XCTAssertEqual(StartMenuLibrary.scan(b).count, 1)
        // Pinned already → excluded by the library merge.
        var pinned = b
        pinned.config.pinned = [PinnedProgram(name: "Hero", path: #"C:\Games\Hero Quest\hero.exe"#)]
        XCTAssertEqual(GameLibrary.scan(pinned).filter { $0.source == .installed }.count, 0)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ShellLink(data: Data("not a shortcut".utf8)))
        XCTAssertThrowsError(try ShellLink(data: Data(repeating: 0, count: 200)))
    }

    func testFuzzNeverCrashes() throws {
        let base = try Data(contentsOf: fixture("steam-wine.lnk"))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var d = base
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            if Bool.random(using: &rng) { d = d.prefix(Int.random(in: 0..<d.count, using: &rng)) }
            _ = try? ShellLink(data: d)
        }
    }

    func testStartMenuScan() throws {
        let b = try BottleStore(paths: paths).create(name: "SM")
        let fm = FileManager.default
        let menu = b.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs/Old Game")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        // Reuse the Steam shortcut but make its target a "game" by placing steam.exe… which is skipped.
        try fm.copyItem(at: fixture("steam-wine.lnk"), to: menu.appendingPathComponent("Steam.lnk"))
        try fm.createDirectory(at: b.driveC.appendingPathComponent("Program Files (x86)/Steam"), withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: b.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe"))
        XCTAssertTrue(StartMenuLibrary.scan(b).isEmpty, "store clients aren't games")
        try fm.copyItem(at: fixture("steam-wine.lnk"), to: menu.appendingPathComponent("Uninstall Old Game.lnk"))
        XCTAssertTrue(StartMenuLibrary.scan(b).isEmpty, "uninstallers are skipped")
    }
}

final class FuzzPETests: XCTestCase {
    func testMutatedExecutablesNeverCrash() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/fixture-d3d11.exe", withExtension: nil))
        let base = try Data(contentsOf: url)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<2500 {
            var d = base
            // Concentrate mutations on headers and the resource/import tables.
            for _ in 0..<Int.random(in: 1...16, using: &rng) {
                let hot = i % 2 == 0 ? Int.random(in: 0..<min(1024, d.count), using: &rng) : Int.random(in: 0..<d.count, using: &rng)
                d[hot] = UInt8.random(in: 0...255, using: &rng)
            }
            // Large values in RVA/size fields provoke overflow paths.
            if i % 7 == 0, d.count > 0x200 {
                let o = Int.random(in: 0x80..<0x200, using: &rng)
                d.replaceSubrange(o..<o + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
            }
            if i % 11 == 0 { d = d.prefix(Int.random(in: 0..<d.count, using: &rng)) }
            if let pe = try? PEFile(data: d) {
                _ = pe.imports
                _ = pe.iconData()
                _ = pe.directXLevel
            }
        }
    }
}

final class VDFLegacyTests: TempHomeTestCase {
    func testOldAndNewLibraryFolders() throws {
        let b = try BottleStore(paths: paths).create(name: "VDF")
        let apps = b.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try #"""
        "LibraryFolders"
        {
            "TimeNextStatsReport"  "1600000000"
            "ContentStatsID"       "-123"
            "1"                    "Z:\\Volumes\\Games\\SteamLibrary"
        }
        """#.write(to: apps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        let folders = SteamLibrary.libraryFolders(b).map(\.path)
        XCTAssertEqual(folders.count, 2, "only numeric keys are libraries: \(folders)")
        XCTAssertTrue(folders.last!.hasSuffix("Volumes/Games/SteamLibrary"))
    }
}

final class BottleEdgeTests: TempHomeTestCase {
    func testNames() throws {
        let store = BottleStore(paths: paths)
        let jp = try store.create(name: "ゲーム")
        XCTAssertTrue(jp.id.hasPrefix("bottle-"))
        XCTAssertEqual(try store.bottle("ゲーム").id, jp.id)
        XCTAssertThrowsError(try store.create(name: "ゲーム"), "duplicate display name")
        XCTAssertThrowsError(try store.create(name: "a/b"))
        XCTAssertThrowsError(try store.create(name: "C:"))
        XCTAssertThrowsError(try store.create(name: String(repeating: "x", count: 65)))
        // Different names, same slug → distinct ids.
        let a = try store.create(name: "My Games")
        let b = try store.create(name: "My-Games")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(b.id, "my-games-2")
    }

    func testUpdatePreservesConcurrentChanges() throws {
        let store = BottleStore(paths: paths)
        let b = try store.create(name: "Shared")
        // "CLI" installs a component while the "app" holds a stale copy.
        try store.update(b.id) { $0.components.append("vcrun2022") }
        try store.update(b.id) { $0.settings.metalHUD = true }   // app edits settings
        let disk = try store.bottle(b.id)
        XCTAssertEqual(disk.config.components, ["vcrun2022"])
        XCTAssertTrue(disk.config.settings.metalHUD)
    }

    func testConcurrentUpdatesSerialize() throws {
        let store = BottleStore(paths: paths)
        let b = try store.create(name: "Race")
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            _ = try? store.update(b.id) { $0.components.append("c\(i)") }
        }
        XCTAssertEqual(Set(try store.bottle(b.id).config.components).count, 40)
    }

    func testDamagedBottleIsReported() throws {
        let store = BottleStore(paths: paths)
        let b = try store.create(name: "Broken")
        try Data("{ not json".utf8).write(to: b.configURL)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(store.damaged().map(\.lastPathComponent), [b.id])
    }
}

final class WineServerTests: TempHomeTestCase {
    func testDetectsListeningSocket() throws {
        let prefix = paths.root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        XCTAssertFalse(WineServer.isRunning(prefix: prefix))
        let path = try XCTUnwrap(WineServer.socketPath(prefix: prefix))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        // A stale socket file (no listener) must read as "not running".
        FileManager.default.createFile(atPath: path, contents: nil)
        XCTAssertFalse(WineServer.isRunning(prefix: prefix))
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let b = Array(path.utf8); raw.copyBytes(from: b); raw[b.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        XCTAssertTrue(WineServer.isRunning(prefix: prefix))
    }

    func testLauncherNotFoundWhenBottleNotRunning() throws {
        let b = try BottleStore(paths: paths).create(name: "LR")
        XCTAssertNil(LauncherProcess.find("steam", in: b))
    }

    func testLauncherProcessParsing() {
        // Real `ps -axo pid=,command=` lines from a bottle running Steam.
        let ps = #"""
        14809 C:\Program Files (x86)\Steam\steam.exe 
        14820 C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -nocrashdialog -steampath=C:\Program Files (x86)\Steam\steam.exe
          301 /usr/sbin/cfprefsd agent
        15001 C:\windows\system32\explorer.exe /desktop
        16000 C:\Games\Mods\steam.exe.bak.exe
        40818 /Users/x/Library/Application Support/Isthmus/Bottles/games/prefix/drive_c/Program Files (x86)/Steam/steam.exe
        40822 /Users/x/Library/Application Support/Isthmus/Runtime/26.3.0-i1-dxmt-f3/lib/wine/../../bin/wineserver
        """#
        // Wine-started processes show a Windows path; the one Isthmus starts shows the Unix path.
        XCTAssertEqual(LauncherProcess.candidates(psOutput: ps, exe: "steam.exe"), [14809, 40818])
        let prefix = "/Users/x/Library/Application Support/Isthmus/Bottles/games/prefix"
        let dxmt = "/Users/x/Library/Application Support/Isthmus/Runtime/26.3.0-i1-dxmt-f3"
        let d3dm = "/Users/x/Library/Application Support/Isthmus/Runtime/26.3.0-i1-d3dmetal-f3-gptk4.0b3"
        let loaders: [UInt64: String] = [20420894: dxmt, 20500000: d3dm]
        // ntdll.so is hardlinked across runtimes, so lsof may name the wrong
        // one; the winetemp-<loader inode> re-exec link is authoritative.
        let lsof = """
        p14809
        fcwd
        n\(prefix)/drive_c/Program Files (x86)/Steam
        ftxt
        n/private/var/folders/m4/x/T/winetemp-20420894-14760-1794616967-0/wine
        ftxt
        n\(d3dm)/lib/wine/x86_64-unix/ntdll.so
        """
        XCTAssertEqual(LauncherProcess.runtimeRoot(lsofOutput: lsof, prefix: prefix, loaders: loaders), dxmt)
        XCTAssertNil(LauncherProcess.runtimeRoot(lsofOutput: lsof, prefix: "/Users/x/other/prefix", loaders: loaders), "Steam in another bottle")
        let direct = "p1\nn\(prefix)/drive_c/x\nn\(d3dm)/lib/wine/x86_64-unix/wine\n"
        XCTAssertEqual(LauncherProcess.runtimeRoot(lsofOutput: direct, prefix: prefix, loaders: loaders), d3dm, "no re-exec link: loader path")
        XCTAssertEqual(LaunchService.backendName("/r/Runtime/26.3.0-i1-dxmt-f3"), GraphicsBackend.dxmt.displayName)
        XCTAssertEqual(LaunchService.backendName("/r/Engines/26.3.0-i1"), GraphicsBackend.wined3d.displayName)
    }
}

final class EngineGuardTests: TempHomeTestCase {
    func testRemoveGuards() throws {
        try fakeEngine("1.0")
        try fakeEngine("2.0")
        let store = BottleStore(paths: paths)
        _ = try store.create(name: "Pinned", engineVersion: "1.0")
        let mgr = EngineManager(paths: paths)
        XCTAssertThrowsError(try mgr.remove("1.0"), "a bottle selects it")
        try mgr.remove("2.0")
        try store.update("pinned") { $0.engineVersion = nil }
        XCTAssertThrowsError(try mgr.remove("1.0"), "last engine while bottles exist")
    }

    func testInvalidArchiveLeavesNoStaging() throws {
        let bogus = paths.root.appendingPathComponent("bogus.tar.xz")
        let dir = paths.root.appendingPathComponent("pkg/thing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("readme"))
        try Shell.run("/usr/bin/tar", ["-cJf", bogus.path, "-C", paths.root.appendingPathComponent("pkg").path, "thing"])
        XCTAssertThrowsError(try EngineManager(paths: paths).install(archive: bogus))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.engines.path).filter { $0.hasPrefix(".staging") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertThrowsError(try EngineManager(paths: paths).install(archive: bogus, expectedSHA256: "00"), "checksum checked first")
    }

    func testConcurrentOverlayBuilds() throws {
        let e = try fakeEngine("3.0")
        let results = NSMutableArray()
        let errors = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                let u = try RuntimeOverlay.prepare(engine: e, backend: .dxmt, d3dmetal: nil, nvext: false, paths: paths)
                results.add(u.path)
            } catch { errors.add(error) }
        }
        XCTAssertEqual(errors.count, 0, "\(errors)")
        XCTAssertEqual(Set(results.compactMap { $0 as? String }).count, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.runtime.path).filter { $0.hasPrefix(".build") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}

final class LaunchEdgeTests: TempHomeTestCase {
    func testValidation() throws {
        let b = try BottleStore(paths: paths).create(name: "V")
        try FileManager.default.createDirectory(at: b.driveC, withIntermediateDirectories: true)
        let planner = LaunchPlanner(paths: paths, recipes: RecipeBook(recipes: []))
        func check(_ program: String) throws { try LaunchPlanner.validate(program, resolved: planner.resolveProgram(program, bottle: b), bottle: b) }

        XCTAssertThrowsError(try check("C:\\missing\\game.exe")) { XCTAssertTrue("\($0.localizedDescription)".contains("wasn't found")) }
        let txt = b.driveC.appendingPathComponent("notes.txt"); try Data().write(to: txt)
        XCTAssertThrowsError(try check(txt.path)) { XCTAssertTrue("\($0.localizedDescription)".contains("isn't a Windows program")) }
        let app = b.driveC.appendingPathComponent("Thing.app"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertThrowsError(try check(app.path)) { XCTAssertTrue("\($0.localizedDescription)".contains("Mac app")) }
        let exe = b.driveC.appendingPathComponent("Game.EXE"); try Data().write(to: exe)
        XCTAssertNoThrow(try check(exe.path), "extension check is case-insensitive")
        XCTAssertNoThrow(try check("winecfg"), "builtins skip file checks")
    }

    func testLauncherIDs() {
        XCTAssertEqual(LaunchPlanner.launcherID(for: LaunchTarget(program: "/x/steam.exe", steamAppID: 10)), "steam")
        XCTAssertEqual(LaunchPlanner.launcherID(for: LaunchTarget(program: #"C:\Program Files (x86)\Steam\Steam.exe"#)), "steam")
        XCTAssertEqual(LaunchPlanner.launcherID(for: LaunchTarget(program: "com.epicgames.launcher://apps/x", epicAppName: "x")), "epic")
        XCTAssertNil(LaunchPlanner.launcherID(for: LaunchTarget(program: "/x/game.exe", epicAppName: "x")), "direct Epic exe launch")
        XCTAssertNil(LaunchPlanner.launcherID(for: LaunchTarget(program: "/x/game.exe")))
    }

    func testEpicFallsBackToExecutableWithoutLauncher() throws {
        let b = try BottleStore(paths: paths).create(name: "E")
        let exe = URL(fileURLWithPath: "/tmp/game/game.exe")
        let g = Game(bottleID: b.id, source: .epic, storeID: "Sugar", name: "Sugar", installDirectory: nil, executable: exe, artwork: nil)
        XCTAssertEqual(g.target(in: b).program, exe.path)
        let l = b.unixPath(forWindowsPath: EpicLibrary.launcherExe)
        try FileManager.default.createDirectory(at: l.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: l)
        XCTAssertTrue(g.target(in: b).program.hasPrefix("com.epicgames.launcher://"))
    }

    func testEnvironmentLocaleAndDllPath() {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), config: BottleConfig(id: "b", name: "B"))
        let s = EffectiveSettings.merge(bottle: BottleSettings(), recipe: nil, program: ProgramSettings())
        let finder = LaunchPlanner.environment(engineRoot: URL(fileURLWithPath: "/E"), bottle: b, settings: s, backend: .dxmt, base: ["HOME": "/h"])
        XCTAssertTrue(finder["LANG"]!.hasSuffix(".UTF-8"), "LANG derived when launched from Finder")
        XCTAssertEqual(finder["WINEDLLPATH"], "/E/lib/wine")
        let shell = LaunchPlanner.environment(engineRoot: URL(fileURLWithPath: "/E"), bottle: b, settings: s, backend: .dxmt, base: ["LANG": "de_DE.UTF-8"])
        XCTAssertEqual(shell["LANG"], "de_DE.UTF-8")
        XCTAssertEqual(posixLocale(Locale(identifier: "fr_CA")), "fr_CA.UTF-8")
        XCTAssertEqual(posixLocale(Locale(identifier: "ja")), "ja_JP.UTF-8")
    }

    func testCappedLog() throws {
        let url = paths.root.appendingPathComponent("cap.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let w = CappedLogWriter(handle: try FileHandle(forWritingTo: url), limit: 1000)
        for _ in 0..<50 { w.write(Data(repeating: 0x41, count: 100)) }
        w.write(Data("END".utf8), force: true)
        w.close()
        w.write(Data("after close".utf8))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("log truncated"))
        XCTAssertTrue(text.hasSuffix("END"))
        XCTAssertLessThan(text.utf8.count, 1200)
    }
}

final class SelfTestParseTests: XCTestCase {
    func testParsing() {
        let ok = SelfTest.parse("msync: up\r\nPASS d3d11 impl=dxmt feature level b000\r\n", name: "x", required: true, expect: "impl=dxmt")
        XCTAssertEqual(ok.outcome, .pass)
        XCTAssertFalse(ok.detail.contains("\r"))
        XCTAssertEqual(SelfTest.parse("PASS d3d11 impl=wined3d", name: "x", required: true, expect: "impl=dxmt").outcome, .fail,
                       "passing on the wrong backend is a failure")
        XCTAssertEqual(SelfTest.parse("SKIP d3d12 no dll", name: "x", required: true, expect: nil).outcome, .skip)
        XCTAssertEqual(SelfTest.parse("wine: crashed", name: "x", required: true, expect: nil).outcome, .fail)
    }

    func testAppLocation() {
        XCTAssertNotNil(Doctor.appLocationProblem("/private/var/folders/x/AppTranslocation/ABC/d/Isthmus.app"))
        XCTAssertNotNil(Doctor.appLocationProblem("/Volumes/Isthmus 0.2.0/Isthmus.app"))
        XCTAssertNil(Doctor.appLocationProblem("/Applications/Isthmus.app"))
        XCTAssertNil(Doctor.appLocationProblem("/usr/local/bin/isthmus"))
    }
}

final class LibraryRefreshTests: TempHomeTestCase {
    func testStoresAndFingerprint() throws {
        let b = try BottleStore(paths: paths).create(name: "Lib")
        XCTAssertTrue(GameLibrary.stores(b).isEmpty)
        let steam = b.unixPath(forWindowsPath: SteamLibrary.steamExe)
        let apps = steam.deletingLastPathComponent().appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let before = GameLibrary.fingerprint(b)
        try Data([0x4D, 0x5A]).write(to: steam)
        XCTAssertEqual(GameLibrary.stores(b).map(\.launcherID), ["steam"])
        let afterStore = GameLibrary.fingerprint(b)
        XCTAssertNotEqual(before, afterStore, "installing a store changes the fingerprint")

        Thread.sleep(forTimeInterval: 1.1)   // directory mtimes have 1 s resolution on some volumes
        try #""AppState" { "appid" "9" "name" "New" "StateFlags" "4" "installdir" "n" }"#
            .write(to: apps.appendingPathComponent("appmanifest_9.acf"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(afterStore, GameLibrary.fingerprint(b), "a game install changes the fingerprint")
        XCTAssertEqual(GameLibrary.scan(b).map(\.name), ["New"])
    }
}

final class SteamArtworkTests: TempHomeTestCase {
    func testPrefersPortraitAcrossHashFolders() throws {
        let root = paths.root.appendingPathComponent("Steam")
        let app = root.appendingPathComponent("appcache/librarycache/5378110")
        let fm = FileManager.default
        // Layout copied from a real Steam client: one image per hash folder.
        for (dir, file) in [("5f96", "logo.png"), ("13e6", "library_header.jpg"), ("421a", "library_capsule.jpg"), ("05a7", "library_hero.jpg")] {
            try fm.createDirectory(at: app.appendingPathComponent(dir), withIntermediateDirectories: true)
            try Data([1]).write(to: app.appendingPathComponent("\(dir)/\(file)"))
        }
        XCTAssertEqual(SteamLibrary.artwork(appID: "5378110", steamRoot: root)?.lastPathComponent, "library_capsule.jpg")
        try fm.removeItem(at: app.appendingPathComponent("421a"))
        XCTAssertEqual(SteamLibrary.artwork(appID: "5378110", steamRoot: root)?.lastPathComponent, "library_header.jpg",
                       "wide header is the fallback")
        XCTAssertNil(SteamLibrary.artwork(appID: "1", steamRoot: root))
        // Old flat layout.
        try Data([1]).write(to: root.appendingPathComponent("appcache/librarycache/7_library_600x900.jpg"))
        XCTAssertEqual(SteamLibrary.artwork(appID: "7", steamRoot: root)?.lastPathComponent, "7_library_600x900.jpg")
    }
}

final class LauncherRestartRuleTests: XCTestCase {
    func testOpeningClientNeverRestarts() {
        XCTAssertTrue(LaunchService.opensClientOnly(LaunchTarget(program: #"C:\Program Files (x86)\Steam\steam.exe"#)))
        XCTAssertFalse(LaunchService.opensClientOnly(LaunchTarget(program: "/x/steam.exe", steamAppID: 480)), "a game via Steam")
        XCTAssertFalse(LaunchService.opensClientOnly(LaunchTarget(program: "com.epicgames.launcher://apps/x", epicAppName: "x")))
    }

    func testBackendFromRuntimeRoot() {
        XCTAssertEqual(LaunchService.backend(ofRoot: "/a/Runtime/26.3.0-i1-dxmt-f3"), .dxmt)
        XCTAssertEqual(LaunchService.backend(ofRoot: "/a/Runtime/26.3.0-i1-d3dmetal-f3-gptk4.0b3"), .d3dmetal)
        XCTAssertEqual(LaunchService.backend(ofRoot: "/a/Runtime/26.3.0-i1-dxvk-f3"), .dxvk)
        XCTAssertEqual(LaunchService.backend(ofRoot: "/a/Engines/26.3.0-i1"), .wined3d)
    }

    func testSteamClientPinned() {
        let r = RecipeBook.load(paths: IsthmusPaths(root: URL(fileURLWithPath: "/nonexistent"))).recipe(exeName: "steam.exe")
        XCTAssertEqual(r?.settings.graphics, .dxmt, "importing D3DMetal must not change the Steam client's runtime")
    }
}

final class OverlayTests2: XCTestCase {
    func env(_ mutate: (inout EffectiveSettings) -> Void) -> [String: String] {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), config: BottleConfig(id: "b", name: "B"))
        var s = EffectiveSettings.merge(bottle: BottleSettings(), recipe: nil, program: ProgramSettings())
        mutate(&s)
        return LaunchPlanner.environment(engineRoot: URL(fileURLWithPath: "/E"), bottle: b, settings: s, backend: .dxmt, base: [:])
    }

    func testOverlayEnvironment() {
        XCTAssertEqual(env { _ in }["MTL_HUD_ENABLED"], "0", "off is explicit so a HUD-enabled Steam doesn't leak it into games")
        let fps = env { $0.overlay = .fps; $0.overlayPosition = .bottomRight }
        XCTAssertEqual(fps["MTL_HUD_ENABLED"], "1"); XCTAssertEqual(fps["MTL_HUD_ELEMENTS"], "FPS")
        XCTAssertEqual(fps["MTL_HUD_ALIGNMENT"], "bottomright"); XCTAssertEqual(fps["MTL_HUD_SHOW_METRICS_RANGE"], "0", "explicit so an inherited value cannot leak in")
        let full = env { $0.overlay = .full; $0.overlayShowRange = true }
        XCTAssertTrue(full["MTL_HUD_ELEMENTS"]!.contains("shaders")); XCTAssertEqual(full["MTL_HUD_SHOW_METRICS_RANGE"], "1")
        XCTAssertNil(full["MTL_HUD_SCALE"])
        XCTAssertNil(env { $0.overlay = .detailed }["DXVK_HUD"], "one overlay, not two")
    }

    func testLayering() {
        var b = BottleSettings(); b.overlay = .fps
        var p = ProgramSettings(); p.overlay = .off
        XCTAssertEqual(EffectiveSettings.merge(bottle: b, recipe: nil, program: p).overlay, .off, "per-game override wins")
        XCTAssertEqual(EffectiveSettings.merge(bottle: b, recipe: nil, program: ProgramSettings()).overlay, .fps)
    }

    func testMigrationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(BottleSettings.self, from: Data(#"{"metalHUD":true}"#.utf8))
        XCTAssertEqual(old.overlay, .detailed, "pre-0.3 HUD-on bottles keep a full HUD")
        XCTAssertEqual(try JSONDecoder().decode(BottleSettings.self, from: Data("{}".utf8)).overlay, .off)
        var s = BottleSettings(); s.overlay = .compact; s.overlayPosition = .topCenter; s.overlayShowRange = true; s.msync = false
        let back = try JSONDecoder().decode(BottleSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class ProgramEnvTests: TempHomeTestCase {
    func testSyncWritesPerGameFiles() throws {
        var b = try BottleStore(paths: paths).create(name: "PE")
        b.config.settings.overlay = .fps
        let exe = b.driveC.appendingPathComponent("Games/Hero/HERO.EXE")
        let game = Game(bottleID: b.id, source: .pinned, storeID: "x", name: "Hero", installDirectory: exe.deletingLastPathComponent(), executable: exe, artwork: nil)
        ProgramEnv.sync(b, games: [game], recipes: RecipeBook(recipes: []))
        let file = ProgramEnv.directory(b).appendingPathComponent("hero.exe.env")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("MTL_HUD_ENABLED=1\n")); XCTAssertTrue(text.contains("MTL_HUD_ELEMENTS=FPS\n"))
        XCTAssertFalse(text.contains("WINE"), "loader only honours MTL_HUD_*")

        // Per-game off overrides an on bottle default.
        b.config.programs[game.target(in: b).settingsKey(in: b)] = { var p = ProgramSettings(); p.overlay = .off; return p }()
        ProgramEnv.sync(b, games: [game], recipes: RecipeBook(recipes: []))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "MTL_HUD_ENABLED=0\n")

        // Games that disappear lose their files.
        ProgramEnv.sync(b, games: [], recipes: RecipeBook(recipes: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFileNames() {
        XCTAssertEqual(ProgramEnv.fileName(forExecutable: #"C:\Program Files\Game\Game.EXE"#), "game.exe.env")
        XCTAssertEqual(ProgramEnv.fileName(forExecutable: "/x/y/OneMoreLawn.exe"), "onemorelawn.exe.env")
        XCTAssertNil(ProgramEnv.fileName(forExecutable: ""))
    }

    func testEnvironmentPointsLoaderAtDirectory() throws {
        let b = try BottleStore(paths: paths).create(name: "PE2")
        let s = EffectiveSettings.merge(bottle: BottleSettings(), recipe: nil, program: ProgramSettings())
        let env = LaunchPlanner.environment(engineRoot: URL(fileURLWithPath: "/E"), bottle: b, settings: s, backend: .dxmt, base: [:])
        XCTAssertEqual(env["ISTHMUS_PROGRAM_ENV"], ProgramEnv.directory(b).path)
    }
}
