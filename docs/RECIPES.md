# Writing recipes

A recipe tells Isthmus how to run one game or launcher. Isthmus applies a
matching recipe automatically, and the user can turn it off per game.

```json
{
  "id": "cyberpunk-2077",
  "name": "Cyberpunk 2077",
  "match": { "steamAppID": [1091500], "gogID": ["1423049311"], "exe": ["cyberpunk2077.exe"] },
  "status": "works",
  "settings": {
    "graphics": "d3dmetal",
    "advertiseAVX": true,
    "arguments": ["--launcher-skip"],
    "environment": { "NAME": "value" },
    "dllOverrides": { "xinput1_3": "n,b" },
    "components": ["vcrun2022"]
  },
  "notes": "Shown in the app. Say what you tested and on which Mac.",
  "sources": ["https://link-to-evidence"]
}
```

## Fields

- **`match`:** any of these can match, and store IDs win over executable
  names.
  - Steam app IDs come from the store URL.
  - Epic app names come from the `.item` manifest's `AppName`.
  - GOG IDs come from `goggame-<id>.info`.
  - `exe` entries must be lowercase file names.
- **`status`:**
  - `works`: runs well with these settings.
  - `issues`: starts, with known problems listed in `notes`.
  - `blocked`: can't work, usually because of kernel anti-cheat. Isthmus
    refuses to launch blocked games and shows `notes` instead.
- **`settings.graphics`:** one of `auto`, `d3dmetal`, `dxmt`, `dxvk`,
  `wined3d`.
- **`settings.components`:** IDs from `components.json`. Isthmus installs
  missing ones before the first launch.

## Rules

- Recipes must not bypass, disable or hide from anti-cheat or DRM. If a game
  only runs that way, mark it `blocked`.
- Say how you verified it: Isthmus version, engine version, Mac model,
  macOS version. Recipes that haven't been verified must say so in `notes`.
- `swift test` validates every bundled recipe (unique IDs, lowercase exe
  names, known components, notes required for non-`works` statuses).

## Testing locally

Put the file in `~/Library/Application Support/Isthmus/Recipes/`. A local
recipe with the same `id` as a bundled one replaces it. Then relaunch the
game. The first lines of the launch log (Game Settings → Show Latest Log)
show which recipe and backend were used.
