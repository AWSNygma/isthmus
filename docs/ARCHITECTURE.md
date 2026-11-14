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

Translation layers add modules that Wine itself doesn't ship (DXMT's
`winemetal.dll`, `nvngx.dll`). Wine only searches its builtin directory for a
module when the prefix's system32 has a stub, so `installStubs` copies the
builtin-marked PE files into `system32`/`syswow64` on first use.

`BackendResolver` picks a backend when a game is set to Automatic. It reads
the game's import table (and, failing that, scans for DLL-name strings,
because many engines `LoadLibrary` their renderer):

| DirectX | D3DMetal imported | Backend |
|---|---|---|
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

## Library

`GameLibrary.scan` reads each store's own metadata:

- **Steam:** `libraryfolders.vdf` + `appmanifest_*.acf` (Valve KeyValues
  parser in `VDF`), with cover art from `appcache/librarycache`.
- **Epic:** `ProgramData/Epic/EpicGamesLauncher/Data/Manifests/*.item`.
- **GOG:** `goggame-*.info` in install folders.
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
- `tests/integration/run.sh` installs an engine into a throwaway
  `ISTHMUS_HOME` and runs every probe through the real CLI launch path.
