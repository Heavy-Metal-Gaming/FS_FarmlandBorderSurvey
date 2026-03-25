# FS25 Property Borders Mod — Implementation Plan

## Overview

**Mod Name:** FS25_PropertyBorders  
**Engine:** GIANTS Engine 10 / Farming Simulator 25  
**Type:** Script-only mod (no custom vehicles or placeables)  
**Multiplayer:** Supported (settings synced via network events)  
**descVersion:** 90

This mod renders faint glowing lines along the borders of the player's owned farmlands in the 3D game world. Borders are extracted by scanning the farmland density bitmap pixel-by-pixel, detecting edge transitions between different farmland IDs, chaining them into polylines, and simplifying with Douglas-Peucker. Two rendering modes are provided: a procedural mesh mode using `createPlaneShapeFrom2DContour` (new FS25 API) and a debug-line mode using `drawDebugLine`. A settings dialog allows the player to choose color, height, and render mode. Toggled via **RAlt+L**.

---

## Key Technical Findings from Analysis

### Farmland System
- Farmland boundaries are defined by a **raster bitmap** (`infoLayer_farmlands.grle`) — each pixel's integer value is a farmland ID.
- No polygon/vertex boundary data exists in the game; we must **extract borders ourselves** by scanning adjacent pixels.
- `getBitVectorMapPoint(map, x, y, 0, numBits)` reads individual pixels — O(1) per read.
- `FarmlandManager` provides `getLocalMap()`, `localMapWidth`, `localMapHeight`, `numberOfBits`, and per-farmland bounding boxes.
- Coordinate conversion: `worldX = (bitmapX - mapWidth/2) * (terrainSize / mapWidth)`

### Rendering APIs
- **`drawDebugLine(x0,y0,z0, r0,g0,b0, x1,y1,z1, r1,g1,b1, solid?)`** — engine-level C binding, available in production builds, immediate-mode (must call every frame), thin colored line.
- **`createPlaneShapeFrom2DContour(name, {x1,z1, x2,z2, ...}, createRigidBody?)`** — NEW in FS25, creates a flat triangulated mesh from a 2D polygon. Used by the RiceField system. Persistent (no per-frame cost). Can apply materials.
- `getTerrainHeightAtWorldPos(terrainId, x, y, z)` — terrain height lookup.

### Mod Lifecycle
- `addModEventListener(obj)` registers a Lua table to receive `loadMap`, `deleteMap`, `update`, `draw`, `keyEvent`, `mouseEvent` callbacks.
- `g_currentMission:addDrawable(self)` / `addUpdateable(self)` registers for per-frame callbacks.
- `g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, callback, target)` listens for ownership changes.

### GUI System
- Built-in `ColorPickerDialog` with custom color support is available.
- Custom dialogs created via `g_gui:loadGui(xmlFile, name, controller)`, shown via `g_gui:showDialog(name)`.
- ~40 GUI element types available (MultiTextOptionElement, SliderElement, ButtonElement, etc.).

### i18n (Internationalization)
- **String translation**: External l10n files (`l10n/l10n_en.xml`, `l10n/l10n_de.xml`, etc.) referenced via `<l10n filenamePrefix="l10n/l10n" />`.
- **Number formatting**: FS25 provides `g_i18n:formatNumber(value, precision)` which respects locale decimal/thousands separators (e.g., `0.3` in English → `0,3` in German). All player-facing numbers are pre-formatted with this before insertion into translated strings (via `%s`, not `%0.1f`).
- **Translation workflow**: A blank `l10n/l10n_template.xml` with full instructions is included. Translators copy, rename to `l10n/l10n_XX.xml`, fill in values, and the game auto-detects it.
- **Supported language codes**: br, cs, ct, cz, da, de, ea, en, es, fc, fi, fr, hu, id, it, jp, kr, nl, no, pl, pt, ro, ru, sv, tr, uk, vi.

---

## File Structure

```
FS25_PropertyBorders/
├── modDesc.xml                     — Mod descriptor (descVersion=90)
├── icon.dds                        — Mod icon (placeholder needed)
├── PLAN.md                         — This file
├── i3d/
│   └── glowMaterial.i3d            — Material source for mesh-mode border strips
├── l10n/
│   ├── l10n_en.xml                 — English localization
│   └── l10n_de.xml                 — German localization
├── gui/
│   └── PropertyBordersSettingsDialog.xml — Settings dialog layout
└── scripts/
    ├── PropertyBorders.lua         — Main entry point (registered via addModEventListener)
    ├── BorderScanner.lua           — Density map scanning & edge extraction
    ├── BorderRendererMesh.lua      — Procedural mesh renderer (createPlaneShapeFrom2DContour)
    ├── BorderRendererDebug.lua     — Debug line fallback renderer (drawDebugLine)
    ├── PropertyBordersSettingsDialog.lua — Settings dialog controller
    └── events/
        ├── PropertyBordersSettingsEvent.lua     — MP settings sync event
        └── PropertyBordersSettingsInitialEvent.lua — MP initial state sync
```

---

## Implementation Steps

### Step 1: modDesc.xml
- `descVersion="90"` (FS25 SDK standard)
- `<extraSourceFiles>` loading `scripts/PropertyBorders.lua`
- `<actions>` defining `PROPERTY_BORDERS_TOGGLE` and `PROPERTY_BORDERS_SETTINGS`
- `<inputBinding>` binding RAlt+L (toggle) and RAlt+K (settings)
- `<l10n filenamePrefix="l10n/l10n" />` for i18n
- Title and description in both English and German

### Step 2: BorderScanner.lua — Density Map Edge Extraction
1. For a given farmlandId, iterate the density map within the farmland's bounding box
2. For each pixel matching the farmlandId, check 4 neighbors
3. Where a neighbor differs → record a border edge segment `{bx1,bz1, bx2,bz2}` (grid-edge coords)
4. Chain edge segments into continuous polylines via endpoint matching
5. Apply Douglas-Peucker simplification (tolerance ~0.5m) to reduce vertex count
6. Convert bitmap coordinates to world XZ; query terrain height for Y

### Step 3: BorderRendererMesh.lua — Procedural Mesh Rendering
For each border polyline segment:
1. Compute perpendicular offset to form a thin quad strip (~5cm wide)
2. Call `createPlaneShapeFrom2DContour("border_N", {4 vertices}, false)` for each segment
3. Position at local terrain height + configured offset via `setTranslation`
4. Apply glow material from loaded i3d reference via `setMaterial`
5. Group all shapes under a per-farmland `createTransformGroup` linked to a root node
6. Toggle visibility with `setVisibility(rootNode, bool)` — zero GPU cost when hidden

### Step 4: BorderRendererDebug.lua — Debug Line Fallback
- In `draw()` callback, iterate cached border segments
- Call `drawDebugLine(x1,y1,z1, r,g,b, x2,y2,z2, r,g,b, false)` per segment
- `solid=false` renders on top of everything (good for border visibility)

### Step 5: Settings Dialog
- Extend `MessageDialog` pattern
- Uses `ColorPickerDialog.show(...)` for color selection (built-in FS25 dialog)
- Render mode: cycle via `MultiTextOptionElement` (Mesh / Debug Lines)
- Height: cycle via `MultiTextOptionElement` (0.1m to 2.0m in 0.1 steps)
- OK/Cancel buttons

### Step 6: Multiplayer Sync
- `PropertyBordersSettingsEvent`: syncs color, height, renderMode, visibility
- `PropertyBordersSettingsInitialEvent`: sent to connecting clients with current state
- Uses FS25 `Event` subclass pattern with `readStream` / `writeStream` / `run`

### Step 7: Save/Load
- Settings persisted to `<savegameDir>/propertyBorders.xml`
- Loaded in `loadMap()`, saved on settings change and map unload

### Step 8: Farmland Ownership Listener
- Subscribe to `MessageType.FARMLAND_OWNER_CHANGED`
- On buy: scan new farmland, build border meshes
- On sell: remove border meshes and cached data

### Step 9: Contract-Based Border Display
- The display scope setting now has three options: **Owned Only**, **Owned + Contracted**, **All Farmlands**.
- When set to "Owned + Contracted", borders are shown for:
  - Farmlands owned by the player's farm
  - Farmlands associated with fields that have active contracts accepted by the player's farm
- **Contract detection** uses `g_missionManager.missions` (the active mission list):
  - Each `AbstractMission` has: `farmId` (the farm that accepted it), `field` (the FieldDefinition), and `status` (e.g., `AbstractMission.STATUS_RUNNING`)
  - `field.farmland.id` gives the farmlandId for the contracted field
  - Filter: `mission.farmId == playerFarmId and mission.status == AbstractMission.STATUS_RUNNING`
- **Contract borders use a distinct color** (default: orange `{1.0, 0.6, 0.1, 0.5}`) to differentiate from owned borders. This color is also adjustable in settings.
- **Refresh trigger**: Contract borders are refreshed:
  - When the player toggles borders on
  - When settings dialog is applied
  - Periodically (every 30 seconds via `update()`) since contracts can start/finish at any time
  - Alternatively, subscribe to mission-related message types if available

### Step 10: Colorblind Mode Support
- Detect via `g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE)`
- Subscribe to changes: `g_messageCenter:subscribe(MessageType.SETTING_CHANGED[GameSettings.SETTING.USE_COLORBLIND_MODE], self.onColorblindChanged, self)`
- **When colorblind mode is active**, default colors change to colorblind-safe alternatives:
  - Owned border default: **Bright Yellow** `{1.0, 1.0, 0.0, 0.5}` (instead of cyan)
  - Contract border default: **Bright Magenta** `{1.0, 0.0, 1.0, 0.5}` (instead of orange)
  - These defaults are luminance-distinct and safe for deuteranopia/protanopia
- If the user has manually chosen a custom color, colorblind mode does NOT override it (only affects defaults)
- A HUD notification appears when colorblind mode toggles ("Colorblind-safe colors active" / "Standard colors active")
- The settings dialog shows a read-only indicator of current colorblind mode state

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Default height | **0.3m** | Low enough not to obstruct, high enough to clear grass/crops |
| Default color (owned) | **Cyan (0.2, 0.8, 1.0, 0.4)** | Visible but not harsh; semi-transparent for "glow" effect |
| Default color (contract) | **Orange (1.0, 0.6, 0.1, 0.5)** | Distinct from owned; warm = "temporary" connotation |
| Colorblind default (owned) | **Bright Yellow (1.0, 1.0, 0.0, 0.5)** | High luminance contrast with terrain; safe for most CVD types |
| Colorblind default (contract) | **Bright Magenta (1.0, 0.0, 1.0, 0.5)** | Luminance-distinct from yellow; safe for deuteranopia/protanopia |
| Default render mode | **Debug Lines** | Works out of the box; mesh mode may require i3d material setup |
| Default display scope | **Owned Only** | Shows only the player's own farmlands by default |
| Simplification tolerance | **0.5m** | Reduces vertex count ~90% while preserving shape |
| Debug line solid mode | **false** (no depth test) | Always visible = better for property border awareness |
| Keybindings | **RAlt+L** toggle, **RAlt+K** settings | Non-conflicting with base game bindings |
| Contract refresh interval | **30 seconds** | Balances responsiveness with CPU impact |

---

## Performance Considerations

- **Border scanning** runs once per farmland at load time (or on buy). A 4096×4096 density map scan within a bounding box takes <1 second per farmland.
- **Mesh mode**: persistent GPU geometry, near-zero frame cost when visible, literally zero when hidden.
- **Debug line mode**: must redraw every frame, but FS25's engine handles thousands of debug lines efficiently.
- **Douglas-Peucker simplification** reduces a typical farmland from ~500-2000 edge segments to ~50-200 vertices.
- **Lazy scanning**: only owned farmlands are scanned, not the entire map.

---

## Notes for Contributors

### Adding Translations (i18n)
1. Copy `l10n/l10n_template.xml` and rename to `l10n/l10n_XX.xml` (see template for language codes)
2. Fill in all `text=""` values with your translations
3. Preserve `%d` and `%s` format specifiers exactly where they appear
4. Do NOT worry about number formatting (decimal/thousands separators) — the engine handles this via `g_i18n:formatNumber()` before numbers reach translated strings
5. Place the file in the `l10n/` folder; the game auto-detects it at startup

### Modifying the Glow Material
The `i3d/glowMaterial.i3d` file can be edited in GIANTS Editor 10+ to change the material properties (shader, blending, emissive color, etc.). The Lua code extracts the material from this file at load time.

### Known Limitations
- Mesh mode border strips are flat (not terrain-following on steep hills). Increase height offset on hilly maps.
- The i3d material file may need adjustment in GIANTS Editor for optimal visual results.
- Border scanning on first load may take a few seconds on maps with many owned farmlands.
