# AVSysMaster

**iPad TCP audio/video control surface — SwiftUI, iOS 17, landscape-only.**

Build custom control panels for professional AV gear (matrix switchers, DSPs, displays, power systems, etc.) that communicate over TCP. All configuration is defined in a single JSON model and can be imported/exported at any time.

---

## Features

### Control Page

- **Grid-based layout** — controls snap to a configurable column grid; multiple breakpoints allow different layouts for different screen widths.
- **Six control types**: Button, Icon Toggle, Toggle Switch, Label, Slider, and Matrix Switcher.
- **Themes** — 17 built-in UI themes with iOS-style color palettes covering dark, glass, and light variants.
- **Logo & background** — custom image positioning and sizing, persisted in the model.
- **Haptic feedback** on every interaction (light / medium / rigid / error).
- **Operation Log** — all commands sent with device target, payload, and success/failure result.

### Control Types

| Type | Description |
|---|---|
| **Button** | Sends one or more TCP commands in sequence. Shows a `×N` badge when configured with extra commands. |
| **Icon Toggle** | Full-screen icon that alternates between ON/OFF commands. **Long-press 3 s** to activate — a circular countdown ring confirms intent. |
| **Toggle Switch** | Switch-style row control. **Long-press 3 s** to activate — shows countdown and "Hold N s to turn on/off" hint. |
| **Label** | Static text element; no binding required. Configurable font, size, weight, color, and alignment. |
| **Slider** | Continuous value control mapped to a TCP command. |
| **Matrix** | AV matrix switcher. Drag input chips onto output chips to send a routing command. Routed source name appears inside the output chip after switching. |

### Matrix Switcher (detail)

- **Visual layout**: Displays (outputs) on top, Video Sources (inputs) on bottom.
- **Drag-to-route**: pick up an input chip → floating ghost chip follows the finger with target preview → release on output chip to send command.
- **Per-channel names & IDs**: each input/output has an editable label and a command ID (up to 12 alphanumeric characters).
- **Command template**: `{input}` / `{output}` placeholders substituted at send time. Live preview shows the generated command.
- **Fully configurable**: chip width/height, chip spacing, title font size, title-to-chip gap, section spacing (between Displays and Sources).
- **Routing state**: successful route is remembered in session; output chip shows the connected source name.

### Multi-Command Buttons

Any Button can run multiple TCP commands in sequence:

- Add extra commands in the **Multi-Command Sequence** section of the editor.
- Set an optional **interval** (0–5000 ms) between commands.
- Button stays `busy` until the last command completes or fails.

### Safety-Guarded Switches

Icon Toggle and Toggle Switch require a **3-second long press** to fire:

- Animated circular progress ring fills over 3 s.
- Toggle shows a countdown hint ("Hold 3s to turn on").
- Releasing early cancels and resets the ring with no command sent.

### Import / Export

- **Save to Files** — saves a dated JSON file (`avsysmaster-YYYYMMDD-HHmmss.json`) to any Files location.
- **Share** — sends the config via AirDrop, Mail, or any share target.
- **Import** — presents a confirmation dialog before overwriting; validates the imported model and reports all errors; persists to disk automatically on success.

---

## Architecture

```
AVSysMasterApp              @main App entry point
├── Stores/
│   ├── UnifiedModelStore   draft/runtime/validation/persist/import/export
│   ├── RuntimeControlStore per-control visual state, haptics, behavior
│   └── OperationLogStore   append-only command log (max 200 entries)
├── Models/
│   └── UnifiedControlModel Codable model graph (devices, commands, controls, layouts, styles)
├── Networking/
│   └── TcpTransport        NWConnection TCP client; text/hex payloads; configurable line endings and timeouts
├── Views/
│   ├── RootShellView       root container
│   ├── ControlPageView     runtime grid + all tile views + matrix tile
│   ├── SettingsView        5-tab settings sheet
│   ├── EditorPageView      canvas editor + ControlPropertySheet
│   ├── DeviceCommandEditorView  device & command management
│   ├── UIStyleSettingsView theme picker (17 themes)
│   ├── ModelEditorView     schema/JSON inspector, publish/rollback
│   └── OperationLogView    log viewer
├── Documents/
│   └── UnifiedModelDocument  FileDocument for Files import/export
└── Localization/
    ├── en.lproj/Localizable.strings
    └── zh-Hans.lproj/Localizable.strings
```

### Draft → Runtime workflow

```
Edit (draft)  →  Validate  →  Publish (runtime)
                                  ↓
                           Persist to disk   (unified-model.json)
                           Snapshot (≤ 5)
                                  ↓
                             Rollback ←
```

---

## Data Model

`UnifiedControlModel` is fully `Codable` (ISO 8601 dates, pretty-printed JSON):

| Entity | Key fields |
|---|---|
| `DeviceItem` | name, host, port, transport (`tcp`), text encoding (`utf8` / `gb18030`) |
| `CommandItem` | name, payload (text or hex), line ending, timeout ms |
| `ControlItem` | type, title, behavior, binding (deviceID + commandID), placement, customFields |
| `LayoutItem` | breakpoint (px), columns, spacing |
| `StyleItem` | theme, logo/background paths & geometry, font, glow/shadow settings |

`customFields` is an open `[String: String]` dictionary on every `ControlItem` used for type-specific configuration (icon names, matrix dimensions, chip sizes, multi-command IDs, etc.).

---

## Themes

| Name | Style |
|---|---|
| Dark | iOS dark mode navy |
| Light | iOS light mode |
| Glass | Frosted glass with blur |
| Midnight | Deep black |
| Ocean | Deep teal |
| Warm Gray | Neutral warm gray |
| Sky Blue | Light blue |
| Mint Fresh | Soft mint |
| Rose | Dusty pink |
| Lavender | Soft purple |
| Sand | Warm sand |
| Peach | Warm peach |
| Lemon | Soft yellow |
| Sage | Muted green |
| Coral | Warm coral |
| Ice | Cool light blue |
| Pure White | Clean white |

---

## Build

Requires **XcodeGen**. If not installed:

```bash
brew install xcodegen
```

Generate the project and open:

```bash
cd /path/to/AVSysMaster
xcodegen generate
open AVSysMaster.xcodeproj
```

Build target: **iPad**, iOS 17.0+, landscape only.

---

## Usage

1. **Open Settings** — four-finger long press (~1 s) on the control page.
2. **Devices tab** — add a device (name, IP, port, encoding).
3. **Devices tab** — add commands for that device (name, payload, line ending).
4. **Editor tab** — add controls to the grid; tap a control to open its property sheet and bind a device + command.
5. **Style tab** — choose a theme.
6. **Publish** (Model Editor tab) — validate and push the draft to runtime.
7. **Done** — return to the control page and use your controls.

### Configuring a Matrix

1. Add a Matrix control in the Editor.
2. In its property sheet → set input/output count and channel names/IDs.
3. Set the command template, e.g. `av tx{input} rx{output}`.
4. On the control page, drag an input chip onto an output chip to route.

### Importing / Exporting

- **Export**: Settings toolbar → **Export Config** → choose **Save to Files** or **Share**.
- **Import**: Settings toolbar → **Import Config** → pick a `.json` file → confirm replacement.

---

## Notes

- **iPad landscape only** — portrait orientation is not supported.
- **Local Network permission** — required for TCP communication. Grant access in iOS Settings if prompted.
- All configuration is stored at `Application Support/AVSysMaster/unified-model.json`.
- The model supports up to 5 in-memory rollback snapshots per session.

---

## Changelog

| Date | Change |
|---|---|
| 2026-03-25 | Import/export overhaul: security-scoped URL, confirmation dialog, validation error details, auto-persist, dated filenames, Share sheet |
| 2026-03-25 | Multi-command button: sequence of commands with configurable interval |
| 2026-03-25 | Toggle/Icon require 3-second long-press with animated countdown ring |
| 2026-03-25 | Matrix: display name below output chip; routed source name inside chip after switching |
| 2026-03-25 | Matrix: drag ghost chip follows finger with target preview; source chip fades while dragging |
| 2026-03-25 | Matrix: per-channel name/ID as individual editable rows; 12-char alphanumeric IDs; command preview |
| 2026-03-25 | Matrix: configurable chip spacing, title-chip gap, section spacing (Displays ↔ Sources) |
| 2026-03-25 | Matrix: adjustable chip height up to 300 pt |
| 2026-03-25 | Added 11 new light themes (Peach, Lemon, Sage, Coral, Ice, Pure White, …) |
| 2026-03-25 | iOS-style color system applied to all themes (system blue/green/indigo accents) |
| 2026-03-25 | Matrix chip inner padding; title-to-chip spacing increased |
| 2026-03-25 | UI Style theme switcher — 17 themes total |
| 2026-03-25 | Elements list in editor side panel |
| 2026-03-25 | Matrix drag-to-route control with `sendRaw`; command template with `{input}`/`{output}` |
| 2026-03-25 | Operation Log tab |
| 2026-03-25 | Control page polish: busy/error/haptics; icon toggle; toggle switch UI |
| 2026-03-25 | Icon Toggle control with ON/OFF commands |
| 2026-03-25 | Logo positioning in editor and runtime |
| 2026-03-25 | Full-screen editor canvas with floating inspector |
| 2026-03-25 | Label control type (static text, no binding) |
| 2026-03-25 | Editor-to-runtime 1:1 layout matching |
