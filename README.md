# Isthmus

Isthmus is a free, open-source app for running Windows games on Apple silicon
Macs. It's built on Wine (from CodeWeavers' open-source CrossOver source
release), plus DXMT, DXVK, MoltenVK and vkd3d. It can also use Apple's
D3DMetal if you import it.

- **One-click stores.** Install Steam, Epic, GOG Galaxy, Battle.net, EA app or
  Ubisoft Connect into a bottle.
- **A real library.** Installed Steam, Epic and GOG games show up with cover
  art. Double-click to play, or add any game to Launchpad as a Mac app.
- **Automatic graphics.** Isthmus reads each game's executable and picks a
  backend: D3DMetal for DirectX 12 (when imported), DXMT for DirectX 10/11,
  and Wine's own renderer for DirectX 9. You can override this per game.
- **Built-in fixes.** A community recipe database applies known-good settings
  per game and warns you before launching games whose anti-cheat can't run.
- **Fast defaults.** MSync, AVX advertising through Rosetta, shader caches
  per bottle, and Retina mode with the DPI adjusted to match.
- **Scriptable.** Everything the app does is also available through the
  `isthmus` command-line tool.

## Requirements

- An Apple silicon Mac (M1 or newer)
- macOS 14 or newer (15+ recommended: games that need AVX require it)
- Rosetta 2 (Isthmus offers to install it)
- About 1.5 GB for the engine, plus space for games

## Install

1. Download `Isthmus-<version>.dmg` from
   [Releases](https://github.com/AWSNygma/isthmus/releases) and drag Isthmus
   to Applications.
2. Open it. The first-run screen installs Rosetta 2 if needed, downloads the
   engine (about 280 MB) and creates your first bottle with Steam.

Until releases are notarized, macOS blocks the first launch. Open Isthmus
once, then go to **System Settings → Privacy & Security** and click **Open
Anyway** next to the Isthmus message.

### Optional: D3DMetal for DirectX 12

Apple's license doesn't allow redistributing D3DMetal, so Isthmus can't ship
it. To get it yourself:

1. Download the **Game Porting Toolkit** from
   <https://developer.apple.com/games/game-porting-toolkit/> (a free Apple
   account works).
2. In Isthmus, open **Engines & Graphics** and choose **Import Toolkit…**, or
   run `isthmus d3dmetal import ~/Downloads/Game_Porting_Toolkit_*.dmg`.

Without D3DMetal, DirectX 12 games fall back to vkd3d, which runs fewer of
them.

## What won't work

- **Kernel-level anti-cheat:** Riot Vanguard (VALORANT), Ricochet (Call of
  Duty), and the anti-cheat setups that publishers block on compatibility
  layers (Fortnite, Destiny 2, Apex Legends, GTA Online). The library marks
  these games, and Isthmus refuses to launch them rather than risk your
  account. Isthmus does not try to bypass anti-cheat, and never will.
- **Games that need AVX-512 or Windows kernel drivers.**
- Some launchers' embedded web views are slow on first start.

## Command line

```sh
ln -s /Applications/Isthmus.app/Contents/Helpers/isthmus /usr/local/bin/isthmus

isthmus doctor                         # check this Mac
isthmus engine install                 # download the latest engine
isthmus bottle create Games
isthmus install steam -b Games
isthmus games                          # list installed games
isthmus play -b Games --game "Hades"   # launch by name
isthmus run -b Games ~/Downloads/setup.exe
isthmus run -b Games --graphics dxvk path/to/game.exe
isthmus bottle set Games hud on        # Metal performance HUD
isthmus shortcut -b Games --game "Hades"   # add to Launchpad
```

## Building from source

```sh
brew install mingw-w64 bison gettext pkgconf ccache micromamba xz
engine/build.sh all                    # ~25 min on M-series Max, produces .work/out/isthmus-engine-*.tar.xz
swift test                             # unit tests
make -C tests/winprobes                # Windows test programs
tests/integration/run.sh .work/out/isthmus-engine-*.tar.xz
scripts/bundle-app.sh                  # dist/Isthmus.app, .dmg, .zip
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit
together.

## Contributing game fixes

Recipes are small JSON files in
[`Sources/IsthmusKit/Resources/recipes`](Sources/IsthmusKit/Resources/recipes).
To try one locally before opening a pull request, drop it in
`~/Library/Application Support/Isthmus/Recipes/`.
[docs/RECIPES.md](docs/RECIPES.md) describes the format.

## License

Isthmus is GPL-3.0-or-later. The engine bundles LGPL, zlib, Apache and MIT
components; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Isthmus isn't affiliated with CodeWeavers, Apple, Valve or Microsoft.
CrossOver is a trademark of CodeWeavers, Inc. We use only CodeWeavers'
published LGPL source code, never code or assets from the CrossOver app.
