# Architecture

```
Isthmus.app (SwiftUI)      isthmus CLI       Launchpad shortcuts (.app stubs → CLI)
        \                     |                     /
         +------------- IsthmusKit (Swift) --------+
         | bottles · launch planner · recipes · library scan · PE parser
         | runtime overlays · registry · components · doctor
         +--------------------|----------------------
                              v
                 Engine (x86_64, runs under Rosetta 2)
   Wine 11 (CodeWeavers tree) + msync · DXMT · DXVK-macOS · MoltenVK · vkd3d
   Wine Mono · Wine Gecko · GStreamer · GnuTLS · FreeType · SDL2
                              |
                 D3DMetal (optional, user-imported from Apple's GPTK)
```

## Engine

`engine/build.sh` builds the engine reproducibly from pinned inputs in
`engine/engine.env`:

- **Wine:** CodeWeavers publishes the LGPL source behind each CrossOver
  release. Their tree carries macOS work that isn't in upstream Wine yet:
  msync (Mach-semaphore sync), the winemac.drv hooks D3DMetal needs, and
  dozens of per-game "CW Hacks". We build it with
  `--enable-archs=i386,x86_64` (new WoW64), so 32-bit games run without
  32-bit macOS libraries.
- **Patches:** files in `engine/patches/*.patch` are applied in order on top
  of the CodeWeavers tree. `0001` makes Steam's web helper render in
  software; without it Steam's windows are black on the macOS driver.
- **Host dependencies:** these are x86_64 dylibs from conda-forge (osx-64),
  installed with micromamba into a private prefix. That avoids needing an
  Intel Homebrew in `/usr/local` (which needs sudo), and conda-forge's
  libraries are already `@rpath`-relocatable. The bundle step copies the
  dependency closure into `lib/` and strips build-machine rpaths.
- **Vulkan:** winevulkan links straight to `libMoltenVK` instead of the
  Khronos loader, because the loader hides portability drivers from apps that
  don't opt in.
- **Build-system traps found while bringing this up:**
  - The Xcode 27 SDK declares `pipe2`, but macOS 26 doesn't export it. Wine
    weak-links it and crashes calling NULL in `server_pipe`, so we force
    `ac_cv_func_pipe2=no`.
  - `--with-opengl` turns a Linux-only EGL check into a hard error on macOS,
    so we leave OpenGL detection on auto.
- **Translation layers:** DXMT and DXVK-macOS ship as prebuilt upstream
  "builtin" releases inside the engine, in `lib/dxmt` and `lib/dxvk`. They
  aren't installed over Wine's own DLLs.

## Graphics backends and runtime overlays

Wine loads builtin DLLs from the directory next to the real path of
`ntdll.so`, before anything in `WINEDLLPATH`. So the usual way to swap
translation layers is to copy DLLs into every prefix, which breaks on engine
updates.

Isthmus instead builds a **runtime overlay** per (engine, backend) pair in
`~/Library/Application Support/Isthmus/Runtime/`:

- Every file of the base engine is hardlinked, so an overlay costs almost
  no disk.
- Only the backend's DLLs and unix libraries are real copies.
- Each overlay works as a complete, independent engine. Switching a game's
  backend just means running a different `bin/wine`.
- Overlays are rebuilt whenever an engine or D3DMetal import changes.

Store clients are found from live process state, not from a saved record.
Steam restarts itself after every update, so a remembered pid goes stale.
`LauncherProcess.find` looks for the client in `ps`, uses `lsof` to keep
only processes with files open in this bottle's prefix, and reads the
runtime from the path its `ntdll.so` is mapped from.

Each overlay gets its **own copy of the two loader binaries** (`bin/wine` and
`lib/wine/x86_64-unix/wine`); everything else is hardlinked. CodeWeavers'
Dock-name hack (CW HACK 22144, enabled by setting `WINEDLLPATH`) re-execs
the loader through a link in `$TMPDIR/winetemp-<inode>-…/` named after the
game's `.exe`, so the Dock shows the game's name. That directory is keyed on
the loader's inode. With a shared inode, every backend silently reused
whichever runtime ran first. `tests/winprobes/d3d11_probe` reports which
implementation actually loaded (`impl=dxmt|dxvk|wined3d`), and the
integration suite interleaves backends to catch regressions of this.

Translation layers add modules that Wine itself doesn't ship (DXMT's
`winemetal.dll`, `nvngx.dll`). Wine only searches its builtin directory for a
module when the prefix's system32 has a stub, so `installStubs` copies the
builtin-marked PE files into `system32`/`syswow64` on first use.

`BackendResolver` picks a backend when a game is set to Automatic. It reads
the game's import table (and, failing that, scans for DLL-name strings,
because many engines `LoadLibrary` their renderer):

| DirectX | D3DMetal imported | Backend |
|---|---|---|
| 11 and 12 (most Unreal/Unity games) | yes | D3DMetal |
| 11 and 12 | no | DXMT (the game falls back to its DX11 renderer) |
| 12 | yes | D3DMetal |
| 12 | no | vkd3d (wined3d build) |
| 10/11 | any | DXMT |
| 9 and older | any | wined3d (OpenGL) |
| unknown | yes / no | D3DMetal / DXMT |

## Settings layering

```
bottle defaults  ←  recipe (bundled or ~/…/Isthmus/Recipes)  ←  per-game overrides  ←  one-off "Play With…"
```

`EffectiveSettings.merge` is a pure function and is unit-tested.
`LaunchPlanner.environment` is also pure: it turns effective settings into
environment variables (`WINEMSYNC`, `ROSETTA_ADVERTISE_AVX`,
`MTL_HUD_ENABLED`, `D3DM_SUPPORT_DXR`, `DXMT_ENABLE_NVEXT`, DXVK/DXMT cache
paths, `WINEDLLOVERRIDES`…). It passes through only a small allowlist of the
parent environment.

Some settings live in the Wine registry instead: Retina mode, DPI, keyboard
modifier mapping and the Windows version. These are written with a single
`regedit /S` import. Isthmus stores a hash of what it last applied, so a
launch only touches the registry when something changed.

## Launching

Everything goes through `LaunchService` (app, CLI, Launchpad shortcuts):

1. Re-read `bottle.json` from disk, and finish an interrupted bottle setup.
2. Apply registry-backed settings if they changed. This never waits for the
   bottle to go idle: `wineserver -w` would block forever while Steam is
   open.
3. Plan the launch. Preflight checks: Rosetta installed, the file exists, it
   is a Windows program (not a `.app` or a folder).
4. Refuse games whose recipe status is `blocked`.
5. Install missing runtimes the recipe asks for.
6. **Store-client runtime check.** A game started through a running Steam
   inherits Steam's DLL directory, not the one chosen for the game. Isthmus
   finds the running client and the runtime it loaded (see below). When a
   game needs a different one, it asks Steam to quit (`steam.exe -shutdown`)
   and waits for that process to exit. It never force-kills, because other games in the bottle would die
   with it. If Steam doesn't quit, the user gets an explanation instead.

Running state comes from the bottle's wineserver socket
(`/tmp/.wine-<uid>/server-<dev>-<inode>/socket`, connect-tested), so it's
right regardless of what started the programs.

Concurrent writers (the app, the CLI, shortcuts) change `bottle.json` with
`BottleStore.update`, a read-modify-write under `flock`, so nobody saves over
another's changes from a stale copy.

Other launch details:

- Logs are capped at 64 MB per launch.
- `LANG` is derived from macOS settings when the process has none, which is
  always the case when launched from Finder.
- A display-sleep assertion is held while a game runs, because controller
  input doesn't count as user activity.

## FPS counter

The counter is Apple's Metal Performance HUD. All backends end in Metal, so
`MTL_HUD_ENABLED`/`MTL_HUD_ELEMENTS`/`MTL_HUD_ALIGNMENT` work everywhere.

The hard part is games started by Steam: they inherit Steam's environment,
not the launch Isthmus planned. Engine patch 0002 adds a hook to the Wine
loader (`loader/main.c`), which runs in every Wine process before ntdll and
before any Metal device exists. It reads `$ISTHMUS_PROGRAM_ENV/<exe>.env`
for the executable being started and applies `MTL_HUD_*` lines only.
`ProgramEnv.sync` writes one file per library game before each launch. Its
value is the game's effective counter setting, and off is written as
`MTL_HUD_ENABLED=0`, so a per-game "off" beats a HUD-enabled launcher.

## Library

`GameLibrary.scan` reads each store's own metadata:

- **Steam:** `libraryfolders.vdf` + `appmanifest_*.acf` (Valve KeyValues
  parser in `VDF`), with cover art from `appcache/librarycache`.
- **Epic:** `ProgramData/Epic/EpicGamesLauncher/Data/Manifests/*.item`.
- **GOG:** `goggame-*.info` in install folders.
- **Installed:** Start Menu shortcuts (`.lnk`, parsed by `ShellLink`).
  Installers create these, so games installed from discs or standalone
  installers appear automatically. Uninstallers, readmes and store clients
  are filtered out.
- **Pinned:** executables the user added.

Steam games launch through `steam.exe -silent -applaunch <appid>`, so Steam's
DRM, cloud saves and overlay keep working.

## Tests

- `swift test` runs the unit tests: PE parsing (against committed mingw-built
  fixtures), backend resolution, settings layering, environment building,
  overlays (hardlink and replacement semantics), VDF parsing, library
  scanning, registry file formatting, and recipe and catalog validation.
- `tests/winprobes` holds Windows programs cross-compiled with mingw. They
  exercise real GPU work on each backend (D3D11 shader draw and read-back,
  D3D12 clear/copy/fence, D3D9, Vulkan), plus AVX visibility, HTTPS via
  WinHTTP, XInput, CoreAudio and Media Foundation decoding through
  GStreamer.
- `isthmus selftest` (and **Engines & Graphics → Self-Test** in the app)
  runs the same probes on the user's own Mac. The probes ship inside the
  app.
- The unit tests also cover edge cases:
  - Fuzzed PE and `.lnk` input
  - Concurrent overlay builds and concurrent bottle updates
  - Engine removal guards
  - Wineserver socket detection
  - Legacy `libraryfolders.vdf`
  - Unicode bottle names
  - Launch validation
  - Log capping
  - Locale fallback
- `tests/integration/run.sh` installs an engine into a throwaway
  `ISTHMUS_HOME` and runs every probe through the real CLI launch path.
