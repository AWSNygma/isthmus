# Changelog

## 0.2.2

Fixes Steam failing to open after importing D3DMetal.

- **Opening Steam while it's already running never restarts it.** The request
  goes to the running Steam, which brings its window back. Before, if Steam
  had been started before D3DMetal was imported, clicking Open Steam made
  Isthmus restart it to switch backends. With a long-running Steam that
  restart could hang with nothing on screen, and Stop All was the only way
  out.
- **The Steam client is pinned to DXMT.** Its own window renders in software,
  so importing D3DMetal no longer changes which runtime Steam starts with.
  Games still get their own backend; a game that needs a different one
  restarts Steam first, as before.
- **Restart and Quit for store clients.** Right-click Steam in the Library
  (or use Restart on the bottle page, or `isthmus kill <bottle> --store
  steam`). This asks Steam to quit, and if it doesn't respond, stops only
  Steam's own processes. Other games in the bottle keep running. Use this
  instead of Stop All for a stuck or invisible Steam.
- **Automatic restarts no longer stall.** If Steam ignores the quit request
  and nothing else is running in the bottle, Isthmus stops Steam's processes
  after 20 seconds. If something else is running, it explains instead.
- **Steam's runtime is detected correctly.** All runtimes share most files
  through hardlinks, so the path of a loaded library could name the wrong
  runtime. Detection now uses the loader's inode, which is unique per runtime.
  It also finds a Steam that Isthmus started (Unix path), not only one Steam
  restarted itself (Windows path).
- **Stop All waits for the bottle to shut down,** so a launch right afterwards
  starts cleanly instead of joining the dying session (that's what killed the
  first relaunch attempt).
- **Logs say "killed by signal 9"** instead of "exited with status 9" when a
  program was stopped.
- **Self-test checks DirectX 11 on D3DMetal** and identifies it correctly
  (it was labeled as DXVK).

## 0.2.1

- **Library:** installed stores (Steam, Epic, …) appear in a Stores row with
  an Open button. The empty state no longer offers to install a store that's
  already installed.
- **Library:** refreshes on its own when a store installs or removes a game.
- **Library:** Steam games show portrait cover art. Newer Steam clients store
  each image in its own folder, and Isthmus was picking a wide banner that
  overflowed the grid. Cards now have a fixed shape.
- **Backends:** games that link both DirectX 11 and 12 (most Unreal and Unity
  titles) now pick DXMT by default when D3DMetal isn't imported, instead of
  Wine's built-in renderer.
- **Steam backend switching:** a running Steam is now found from live process
  state. Steam restarts itself after updates, so the pid Isthmus had saved
  went stale and the restart silently didn't happen.
- **CLI:** new `isthmus inspect <exe>` shows imports, detected DirectX
  version and icon; `-b <bottle>` also reports running store clients.
- **Recipes:** first verified entry: One More Lawn.
- **Docs:** added `docs/STATUS.md`.

## 0.2.0

Reliability release:

- Launching no longer hangs while Steam is open.
- Each graphics backend gets its own loader; before, a shared loader file let
  the first backend's runtime be reused for every backend.
- Steam restarts when a game needs a different backend.
- Bottle changes are saved read-modify-write under a lock, so the app and CLI
  no longer overwrite each other.
- The PE and `.lnk` parsers are hardened with fuzz tests.
- Clear launch errors: missing Rosetta, missing files, non-Windows files.
- Unicode bottle names; locale derived from macOS; the Dock shows the game's
  name.
- Logs are capped at 64 MB.
- Engine download falls back to a manifest in the repo when GitHub's API rate
  limit is hit.
- New: Start Menu game discovery, `isthmus selftest` and the Self-Test page,
  and Launchpad shortcuts that keep the display awake and show an alert on
  failure.

## 0.1.0

First release:

- Engine from CodeWeavers' CrossOver 26.3.0 sources with DXMT, DXVK, MoltenVK
  and vkd3d, plus a Steam web-helper patch.
- SwiftUI app and `isthmus` CLI.
- Bottles, store installers, library, recipes, D3DMetal import, Launchpad
  shortcuts.
- Unit tests, Windows probes, integration runner.
