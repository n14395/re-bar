# MenuOverflow

![Platform](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Interface](https://img.shields.io/badge/UI-SwiftUI-purple)

A macOS utility for people whose menu bar is full. Tighten the spacing between
items, recolor the whole bar with a live themed overlay, and put the items in
the order you want.

<!-- TODO: add a screenshot/banner here, e.g. docs/screenshot.png -->

## Features

### Spacing

Tighten the gap between menu bar items — sliders and presets from the system
default (16 pt) down to Packed (0 pt). Works by writing the ByHost global
defaults `NSStatusItemSpacing` / `NSStatusItemSelectionPadding`; no private
API and no special permission required.

macOS reads these values once per app, at launch, so changes apply to each app
the next time it starts. The **Log Out…** button applies the new spacing
everywhere at once.

### Color

A live *themed mirror* of the menu bar: the real bar is captured, its glyphs
are extracted by a self-matting recolor pipeline, and a click-through overlay
draws the same layout in your colors. Clicks pass straight through to the real
bar underneath.

- Solid colors and 2- or 3-stop gradients, with separate light/dark themes
  ("Match system appearance").
- Built-in presets plus custom saved presets — save, rename, update, delete;
  saving under an existing name replaces it.
- **Colored icons** modes: *Original* keeps genuinely-colored icons intact
  (the low-power battery stays yellow), *Muted* softens them to half contrast,
  *Themed* repaints everything uniformly.
- Optional fade-to-black around the notch (shown on notched displays only).
- Per-desktop wallpaper tinting, faint-icon boosting, and optional visibility
  in screenshots and screen sharing.
- Efficient by design: renders at up to 20 Hz but skips all work while the bar
  is unchanged, dropping to a low-power cadence when idle.

The mirror needs **Screen Recording** permission; the captured pixels never
leave your Mac. While the mirror runs, macOS shows its standard
screen-recording indicator — an inherent cost of any app that reads the
screen.

### Arrange

Reorder third-party menu bar items and movable system modules — drag rows or
use the chevron buttons, then apply. Works by rewriting the system's item
position store and restarting the menu bar agent (the bar disappears for a few
seconds, then returns in the new order).

- Items of installed-but-not-running apps are listed too (grayed, with a
  launch button) — toggleable via **Show inactive apps**.
- **Show inactive system items** reveals movable-but-hidden system items
  (Siri, camera indicator, …).
- **Clean Up…** removes provably-stale entries from the position store. The
  full store is backed up to `~/Library/Application Support/MenuOverflow/`
  before every write.

### Extras

- Runs quietly in the background; optional menu bar icon; start at login.
- Settings export/import as versioned JSON.

## Installation

Download the `.dmg` from the [Releases](../../releases) page, open it, and
drag **MenuOverflow** to Applications.

> **Note on first launch:** releases are signed with a development
> certificate but not notarized, so Gatekeeper will block the first open.
> Right-click the app → **Open** → **Open** (or approve it under
> System Settings → Privacy & Security).

### Permissions

| Permission | Used for | Required? |
|---|---|---|
| Screen Recording | The Color tab's themed mirror | Only for recoloring |
| Automation (System Events) | The Spacing tab's **Log Out…** button | Only for logout |

Spacing and Arrange work without any special permissions.

## Building from source

Requires Xcode (the SwiftUI macros need the full toolchain, not just the
Command Line Tools).

```sh
Scripts/build-app.sh              # builds build/MenuOverflow.app + a versioned .dmg
Scripts/build-app.sh --install    # …and copies the app to ~/Applications
Scripts/build-app.sh --no-dmg     # skip the .dmg for faster iteration
```

Point `DEVELOPER_DIR` at your Xcode if it isn't the default, e.g.
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

The script builds with Swift Package Manager, assembles the app bundle, and
signs it with your Apple Development identity when one exists (a stable
signing identity keeps macOS permission grants across rebuilds; it falls back
to ad-hoc signing otherwise).

### Working in Xcode

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked in:

```sh
brew install xcodegen   # once
xcodegen generate       # creates MenuOverflow.xcodeproj
```

## Compatibility

Minimum macOS 15; developed and tested against current macOS 27 betas. The
Color and Arrange backends track private WindowServer / menu-bar-agent
behavior, which Apple changes between OS releases — expect these features to
be version-sensitive by nature.
