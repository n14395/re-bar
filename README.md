# MenuOverflow

A small macOS menu-bar utility for people whose menu bar is full. Three tabs:

## Spacing

Tightens the gap between menu bar items by writing the ByHost global defaults
`NSStatusItemSpacing` / `NSStatusItemSelectionPadding` (sliders + presets from
Default 16 pt down to Packed 0 pt). macOS reads these once per app process, at
status-item creation, so changes apply per app at its next launch. To apply the
new spacing everywhere at once, use **Log Out…** and log back in.

## Color

A live *themed mirror* of the menu bar: the real bar is captured, its glyphs
extracted with a self-matting recolor pipeline, and a click-through overlay
draws the same layout in your colors (solid, 2- or 3-stop gradients). Clicks
pass straight through to the real bar.

- Light/dark appearance slots ("Match system appearance") with a Light|Dark
  editing chip.
- Built-in and custom saved presets (save/rename/update/delete; saving under
  an existing name replaces it).
- Colored icons: Original (keep true colors — low-power battery stays yellow),
  Muted (half-contrast theme paint), or Themed (uniform repaint).
- Fade to black around the notch (notched displays only).
- Per-desktop wallpaper icon tinting, faint-icon boost, optional visibility in
  screenshots/screen sharing.
- The engine renders at up to 20 Hz but skips work entirely while the bar is
  unchanged (damage-gated).

Needs **Screen Recording** permission (the bar's pixels never leave the Mac).
On current macOS 27 betas, any region capture shows the system's
screen-recording indicator while the mirror runs — see
`THEMED-MENUBAR-DESIGN.md` for the architecture and constraints.

## Arrange

Reorders third-party menu bar items (and movable system modules) by rewriting
MenuBarAgent's `TrailingItemPreferredPositions` store and restarting the agent.
Includes: drag or chevron reordering, items of installed-but-not-running apps
(grayed, launchable), inactive system items toggle, and a Clean Up pass that
removes provably-stale store keys (full store backup to
`~/Library/Application Support/MenuOverflow/` before every write).

## Extras

- Runs in the background with an optional menu bar icon; start at login.
- Settings export/import (versioned JSON).

## Building

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/build-app.sh --install
```

Builds with SPM, wraps `build/MenuOverflow.app`, signs with your Apple
Development identity when one exists (keeps TCC permission grants stable
across rebuilds; falls back to ad-hoc), and `--install` copies to
`~/Applications`. Targets current macOS 27 betas — the capture and arrange
backends track private WindowServer/MenuBarAgent behavior and are
version-sensitive by nature.
