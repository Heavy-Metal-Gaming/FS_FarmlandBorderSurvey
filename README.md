# Farmland Border Survey

Displays faint glowing border lines around your owned and contracted farmlands in the 3D world of **Farming Simulator 25**.

## Features

- **Two render modes**: Persistent 3D mesh geometry or debug-line overlay
- **Customizable appearance**: Choose border color, height above terrain, and render mode
- **Display scope**: Show borders for owned farmlands only, owned + contracted, or all farmlands
- **Contract awareness**: Optionally highlights borders of farmlands where you have active contracts, using a distinct color
- **Colorblind mode**: Automatically switches to colorblind-safe default colors when FS25's colorblind setting is enabled
- **Multiplayer compatible**: Settings are synced across all connected clients
- **Fully translatable**: Ships with English and German; drop in a `l10n/l10n_XX.xml` file for any other language (see template)
- **Lightweight**: Borders are scanned once per farmland and cached; mesh mode has near-zero per-frame cost

## Controls

| Action | Default Binding | Description |
|--------|----------------|-------------|
| Toggle borders | `RAlt + L` | Show / hide border lines |

Binding can be changed in-game via **Settings → Controls**.

## Installation

### From GitHub Releases (recommended)

1. Go to the [Releases](../../releases) page.
2. Download `FS25_FarmlandBorderSurvey.zip` from the latest release (or a pre-release for alpha/beta builds).
3. Place the zip (do **not** extract it) into your FS25 mods directory:
   - **Windows**: `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
   - **macOS**: `~/Library/Application Support/FarmingSimulator2025/mods/`
4. Enable the mod in the in-game mod manager.

### From GIANTS ModHub

Official stable releases are also published to the [GIANTS ModHub](https://www.farming-simulator.com/mods.php). Search for **Farmland Border Survey** and install directly from the in-game ModHub browser.

### From Source (development)

1. Clone this repository.
2. Run `./build.sh build` (Linux/macOS) or `.\build.ps1 build` (Windows) to produce the zip in `dist/`.
3. Copy the zip into your mods directory as above.

## Building from Source

```bash
# Linux / macOS
./build.sh build                        # builds for latest FS version detected
./build.sh build --fs_ver 25            # builds FS25_FarmlandBorderSurvey.zip
./build.sh build --fs_ver 28            # builds FS28_FarmlandBorderSurvey.zip

# Windows (PowerShell)
.\build.ps1 build                       # builds for latest FS version detected
.\build.ps1 build --fs_ver 25           # builds FS25_FarmlandBorderSurvey.zip
.\build.ps1 build --fs_ver 28           # builds FS28_FarmlandBorderSurvey.zip
```

Note: `build` always produces a single zip. To build multiple versions, run it once per version or use `release` which builds all specified versions.

### Creating a Release

```bash
# Linux / macOS
./build.sh release 1.0.0.0                     # stable, latest FS version
./build.sh release 1.0.0.0 --fs_ver 25         # stable, FS25 only
./build.sh release 1.0.0.0 --fs_ver 25,28      # stable, both FS25 and FS28
./build.sh release 1.0.0.0-alpha.1 --fs_ver 25  # alpha pre-release, FS25 only
./build.sh release 1.0.0.0-beta.1 --fs_ver 25   # beta pre-release, FS25 only

# Windows (PowerShell)
.\build.ps1 release 1.0.0.0                     # stable, latest FS version
.\build.ps1 release 1.0.0.0 --fs_ver 25         # stable, FS25 only
.\build.ps1 release 1.0.0.0 --fs_ver 25,28      # stable, both FS25 and FS28
.\build.ps1 release 1.0.0.0-alpha.1 --fs_ver 25  # alpha pre-release, FS25 only
.\build.ps1 release 1.0.0.0-beta.1 --fs_ver 25   # beta pre-release, FS25 only
```

This updates `fs_versions.json`, commits it, creates a `release/X.Y.Z.W` tag, and pushes — which triggers CI to build the artifact(s) and publish a GitHub Release.

If `--fs_ver` is omitted, the scripts auto-detect the highest-numbered `FS*_Src` directory.

## Repository Structure

```
FS_FarmlandBorderSurvey/               — Repo root
├── README.md                          — This file
├── PLAN.md                            — Technical design document (not in releases)
├── build.sh                           — Build / release script (bash)
├── build.ps1                          — Build / release script (PowerShell)
├── .github/
│   └── workflows/
│       └── release.yml                — CI: build + GitHub Release on release tags
├── dist/                              — Build output (git-ignored)
│   └── FS25_FarmlandBorderSurvey.zip
└── FS25_Src/                          — FS25 mod source
    ├── modDesc.xml
    ├── icon_FarmlandBorderSurvey.dds
    ├── i3d/
    │   └── glowMaterial.i3d
    ├── l10n/
    │   ├── l10n_en.xml
    │   ├── l10n_de.xml
    │   └── l10n_template.xml
    └── scripts/
        ├── PropertyBorders.lua
        ├── BorderScanner.lua
        ├── BorderRendererMesh.lua
        ├── BorderRendererDebug.lua
        ├── PropertyBordersSettingsDialog.lua
        └── events/
            ├── PropertyBordersSettingsEvent.lua
            └── PropertyBordersSettingsInitialEvent.lua
```

## How It Works

1. **Scanning** — `BorderScanner` reads the farmland density bitmap (`infoLayer_farmlands.grle`) pixel by pixel within each farmland's bounding box. Where adjacent pixels have different IDs, a border edge is recorded.
2. **Chaining** — Edge segments are connected into continuous polylines via endpoint matching.
3. **Simplification** — Douglas-Peucker reduces vertex count (~90% reduction) while preserving shape.
4. **Rendering** — Polylines are drawn as either thin 3D quad strips (`createPlaneShapeFrom2DContour`) or immediate-mode debug lines (`drawDebugLine`).

## Defaults

| Setting | Default | Colorblind Default |
|---------|---------|-------------------|
| Owned border color | Cyan `(0.2, 0.8, 1.0, 0.4)` | Bright Yellow `(1.0, 1.0, 0.0, 0.5)` |
| Contract border color | Orange `(1.0, 0.6, 0.1, 0.5)` | Bright Magenta `(1.0, 0.0, 1.0, 0.5)` |
| Height | 0.3 m above terrain | — |
| Render mode | Debug Lines | — |
| Display scope | Owned Only | — |

## Adding a Translation

1. Copy `FS25_Src/l10n/l10n_template.xml` → `FS25_Src/l10n/l10n_XX.xml` (see template header for language codes).
2. Fill in every `text=""` value. Preserve `%d` and `%s` placeholders exactly.
3. Number formatting (decimal/thousands separators) is handled automatically by the engine — no need to worry about locale-specific number formats.
4. Place the file in `FS25_Src/l10n/` and restart the game.

## Multiplayer

Settings (color, height, render mode, visibility) are synced from server to all clients via custom network events. When a client changes settings, the server rebroadcasts to other clients. Newly connecting clients receive the current state automatically.

## Known Limitations

- Mesh-mode border strips are flat and may not perfectly follow steep terrain. Increase the height offset on hilly maps.
- Border scanning on first load may take a few seconds if you own many farmlands.
- The glow material (`glowMaterial.i3d`) may need tuning in GIANTS Editor for different visual preferences.

## Requirements

- Farming Simulator 25 (PC)
- GIANTS Engine 10+

## Reporting Bugs

If you encounter a bug, please [open a Bug Report](../../issues/new?template=bug_report.yml). Include:

- Your mod version and FS version
- Whether you're in single-player or multiplayer
- Steps to reproduce the issue
- Any relevant lines from `log.txt` (found in your FS25 user directory)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting bug fixes, translations, and feature requests.

## License

All rights reserved. This mod is provided for personal use. See `LICENSE` file if present for details.

## Author

**Heavy Metal Gaming**
