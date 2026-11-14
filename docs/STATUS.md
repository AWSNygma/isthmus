# Project status

*Last updated for Isthmus 0.2.1, engine 26.3.0-i1 (November 2026).*

Isthmus is an early, working release. The engine, the app, the CLI and the
test tooling are complete enough to install a store, install a game and play
it. Coverage of real games is still very thin: one game has been verified
end to end. This page separates what's been tested from what is only
designed to work.

## Releases

| Release | What it is |
|---|---|
| [v0.2.1](https://github.com/AWSNygma/isthmus/releases) | App: DMG and zip, Apple silicon, ad-hoc signed |
| [engine-26.3.0-i1](https://github.com/AWSNygma/isthmus/releases/tag/engine-26.3.0-i1) | Engine (280 MB), downloaded by the app on first run |

The engine:

- **Wine 11.0**, built from CodeWeavers' CrossOver 26.3.0 LGPL source
  release: new WoW64 (32- and 64-bit games), msync, the hooks D3DMetal needs.
- **DXMT** v0.80
- **DXVK-macOS** v1.10.3
- **MoltenVK** 1.4.2
- **vkd3d**, in the Wine tree
- **Wine Mono** 10.4.1 and **Wine Gecko** 2.47.4
- **GStreamer** 1.28
- One Isthmus patch: Steam's web helper renders in software. Without it,
  Steam windows are black.

## Verified

All of this was tested on an M5 Max (36 GB) running macOS 26.6.2.

| Area | Result |
|---|---|
| Engine build from scratch (`engine/build.sh all`) | ✅ about 25 minutes |
| First run: Rosetta check, engine download from GitHub, bottle creation | ✅ |
| Steam: install, self-update, sign-in window, game download | ✅ |
| **One More Lawn** (Unreal Engine, DX11+12) via Steam on DXMT | ✅ ran 43 minutes; frame rate not measured |
| Library: Steam games with cover art, installed stores, auto-refresh | ✅ |
| Library: games found through Start Menu shortcuts | ✅ with a Wine-created `.lnk` |
| Launchpad shortcut: launches through the CLI, exits cleanly | ✅ |
| Self-test, from the published DMG on a clean data folder | ✅ 15/15 required checks |
| Switching backend for a Steam game | ⚠️ partly: the restart was tested in 0.2.0 with a stand-in game; 0.2.1's live detection was checked read-only against a real running Steam, but the restart hasn't been re-run with it |
| Unit tests | ✅ 54 passing, including on a case-sensitive fresh clone |

The self-test covers:

- **DirectX 11**, 64- and 32-bit, on each of DXMT, DXVK and wined3d. It
  checks which implementation actually loaded, not just that drawing worked.
- **DirectX 12** via vkd3d, **DirectX 9** (64- and 32-bit), and **Vulkan**
  through MoltenVK.
- **System:** AVX visible to games through Rosetta, HTTPS via WinHTTP,
  XInput, CoreAudio, and Media Foundation decoding through GStreamer.

## Built but not yet verified

These are implemented and unit-tested, but haven't been exercised against
the real thing:

- **D3DMetal.** The importer handles Apple's Game Porting Toolkit `.dmg`
  (nested images, license prompts). Nobody has imported it yet, so the
  "DirectX 12 via D3DMetal" check is always skipped. Whether Apple's current
  D3DMetal works with CodeWeavers' 26.3 hooks is still an open question.
- **Store launchers other than Steam:** Epic, GOG Galaxy, Battle.net, EA app,
  Ubisoft Connect. Their installers' download URLs were checked to resolve,
  but installing and running them hasn't been tested.
- **Runtime components:** Visual C++ 2015–2022, .NET 8 Desktop, WebView2.
  The URLs resolve; the installs haven't been run.
- **Game controllers.** XInput loads and answers, but no physical controller
  has been tested.
- **Recipes.** Apart from One More Lawn, the game entries come from
  well-known facts about those games and are labeled "not yet verified on
  Isthmus". The anti-cheat blocks are based on public statements by the
  publishers.

## Known limitations

- **Kernel anti-cheat.** VALORANT, Call of Duty, Fortnite, Destiny 2, Apex
  Legends and GTA Online can't run. Isthmus refuses to launch them, and will
  never try to bypass anti-cheat.
- **Not notarized.** Users have to approve the app once in Privacy &
  Security. Signing and notarization are set up in `scripts/bundle-app.sh`
  and the release workflow; they need a Developer ID.
- **No macOS Game Mode.** Game Mode only engages for processes inside an
  app bundle. Wine runs games as bare executables. Fixing this needs an
  engine change (running the loader from inside a bundle).
- **Wine's built-in renderer reports a fake GPU** ("NVIDIA GeForce 8800
  GTX"). DXMT and DXVK report the real Apple GPU. Only DirectX 9 games and
  the fallback path use the built-in renderer.
- **Bottles live in `~/Library/Application Support/Isthmus`.** External
  drives work for Steam libraries, but not for whole bottles.
- **Steam games inherit Steam's graphics backend.** Switching backend for one
  game restarts Steam. If a game in the same bottle keeps Steam from
  quitting, Isthmus explains and doesn't force anything.
- **The app doesn't update itself.** It does check for new engines. App
  updates (Sparkle) are planned along with signing.

## Repository

| Path | Contents |
|---|---|
| `engine/` | Reproducible engine build, pinned versions, Wine patches, update manifest |
| `Sources/IsthmusKit/` | Core library: bottles, launching, overlays, recipes, library scan, PE and `.lnk` parsers |
| `Sources/isthmus/` | Command-line tool |
| `Sources/IsthmusApp/` | SwiftUI app |
| `tests/IsthmusKitTests/` | Unit tests, including fuzzing and concurrency tests |
| `tests/winprobes/` | Windows test programs (built with mingw), also bundled in the app for Self-Test |
| `tests/integration/` | End-to-end runner for a built engine |
| `.github/workflows/` | CI, engine build and release automation (see below) |
| `docs/` | Architecture, recipe format, this status page |

## CI

- **CI** (`ci.yml`) runs on every push to `main` and on pull requests, on
  GitHub's macOS 26 arm64 runners. It runs the unit tests, validates the
  recipe JSON, builds the Windows probes, and builds and uploads the app
  bundle. It has passed.
- **Release** (`release.yml`) builds and publishes the app when a `v*` tag is
  pushed. It signs and notarizes when the Developer ID secrets are set. It
  hasn't run yet: v0.1.0 through v0.2.1 were built locally with the same
  script.
- **Engine** (`engine.yml`) builds the engine from source when run manually
  or when an `engine-*` tag is pushed. It hasn't run yet; the published
  engine was built locally with the same script. Hosted runners are VMs
  with limited Metal support, so the GPU probes there are informational.

## Next

1. Test more real games (most valuable), and record results as recipes.
2. Import D3DMetal and run the self-test, to settle whether it works with
   the CodeWeavers 26.3 hooks.
3. Sign and notarize the app, and add Sparkle app updates.
4. Run the engine workflow once, and publish future engines from CI.
5. Investigate Game Mode via a bundled loader.
6. Test the other store launchers and the runtime components.
