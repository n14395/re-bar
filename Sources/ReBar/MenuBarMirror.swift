import AppKit
import SwiftUI
import CoreGraphics
import QuartzCore

// MARK: - Route A capture (the indicator-free path)
// Bind the SDK-obsoleted C symbol directly; it still lives in CoreGraphics at
// runtime and, unlike ScreenCaptureKit / CGDisplayCreateImageForRect, targeting
// a single window raises no screen-recording indicator.
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImage(_ screenBounds: CGRect, _ listOption: UInt32,
                                      _ windowID: UInt32, _ imageOption: UInt32) -> Unmanaged<CGImage>?

private let kOnScreenOnly: UInt32 = 1      // kCGWindowListOptionOnScreenOnly
private let kBelowWindow: UInt32 = 4       // kCGWindowListOptionOnScreenBelowWindow
private let kIncludingWindow: UInt32 = 8   // kCGWindowListOptionIncludingWindow
private let kBestResolution: UInt32 = 8    // kCGWindowImageBestResolution

/// The onscreen `Menubar` strip window whose bounds match a given display.
private func captureStrip(_ wid: UInt32) -> CGImage? {
    _CGWindowListCreateImage(CGRect.null, kIncludingWindow, wid, kBestResolution)?.takeRetainedValue()
}

/// The onscreen Window Server "Menubar" window matching a given display. Since
/// macOS 27 beta 26A5406e this window carries only the bar's background material
/// (content moved out — see captureMenubar), but it remains the reliable probe
/// for "the bar is on screen here" and the authoritative source of the bar rect.
private func findMenubarWindow(displayBounds: CGRect) -> (wid: UInt32, rect: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    var best: (wid: UInt32, rect: CGRect)? = nil
    for w in list {
        guard (w[kCGWindowName as String] as? String) == "Menubar",
              (w[kCGWindowLayer as String] as? Int) == 24,
              let owner = w[kCGWindowOwnerName as String] as? String,
              owner == "Window Server" || owner == "WindowServer",
              let wid = w[kCGWindowNumber as String] as? UInt32,
              let bAny = w[kCGWindowBounds as String],
              let b = CGRect(dictionaryRepresentation: bAny as! CFDictionary) else { continue }
        // Match on the full top-left origin + width so vertically-stacked displays
        // of equal width (same x, different y) can't be confused for each other.
        if abs(b.origin.x - displayBounds.origin.x) < 4,
           abs(b.origin.y - displayBounds.origin.y) < 4,
           abs(b.width - displayBounds.width) < 4 {
            if best == nil || wid > best!.wid { best = (wid, b) }   // freshest first
        }
    }
    return best
}

/// Capture the given display's menu-bar strip. Returns the image (nil if the bar
/// couldn't be read right now) and `barExists` = whether a Menubar window is
/// present at all, so the caller can distinguish "can't read it right now" (hold)
/// from "bar is gone" (Mission Control — ok to hide).
///
/// macOS 27 beta 26A5406e re-architected the bar: the Window Server "Menubar"
/// window now holds only the background material. App menus render in per-app
/// windows and status items in MenuBarAgent windows, none of which are
/// individually capturable. So instead of capturing that one window we composite
/// everything on screen within the bar's rect *below our own overlay*
/// (kCGWindowListOptionOnScreenBelowWindow). That keeps the overlay itself — and
/// anything stacked above it, like open menus — out of the capture, so there is
/// no feedback loop even when the overlay is screenshot-visible. Window names
/// stay hidden without Screen Recording permission, so the probe (and therefore
/// the whole capture) still fails cleanly when access is missing.
private func captureMenubar(displayBounds: CGRect, belowWindow: UInt32 = 0) -> (image: CGImage?, barExists: Bool) {
    guard let bar = findMenubarWindow(displayBounds: displayBounds) else { return (nil, false) }
    return (captureBarComposite(rect: bar.rect, wid: bar.wid, belowWindow: belowWindow), true)
}

private func captureBarComposite(rect: CGRect, wid: UInt32, belowWindow: UInt32) -> CGImage? {
    let opt: UInt32 = belowWindow != 0 ? kBelowWindow : kOnScreenOnly
    if let img = _CGWindowListCreateImage(rect, opt, belowWindow, kBestResolution)?.takeRetainedValue() {
        return img
    }
    // Composite hiccup — fall back to the bar window alone. On pre-26A5406e
    // builds that window still carries the full bar content anyway.
    return captureStrip(wid)
}

/// Is this (previously-resolved) Menubar window still on screen? A one-window
/// info query — far cheaper than the full window-list walk in
/// findMenubarWindow, so the render loop can reuse a cached resolution.
private func menubarWindowOnscreen(_ wid: UInt32) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
          let w = list.first else { return false }
    return (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
}

// MARK: - Private Spaces API (soft-linked; no-ops if the symbols ever change)
// Pin the overlay onto every managed Space so it's already a member of the
// incoming Space at commit — eliminating the ~1-frame `.canJoinAllSpaces` join
// lag that otherwise flashes the real bar at the end of a Space switch. This is
// the technique SketchyBar/yabai use for a flash-free per-Space bar.

nonisolated(unsafe) private let gSkyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private func slsSym<T>(_ names: [String], as _: T.Type) -> T? {
    guard let h = gSkyLight else { return nil }
    for n in names { if let p = dlsym(h, n) { return unsafeBitCast(p, to: T.self) } }
    return nil
}
private typealias FnMainConn = @convention(c) () -> Int32
private typealias FnCopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias FnAddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void
private let slsMainConnectionID = slsSym(["SLSMainConnectionID", "CGSMainConnectionID"], as: FnMainConn.self)
private let slsCopyManagedDisplaySpaces = slsSym(["SLSCopyManagedDisplaySpaces"], as: FnCopySpaces.self)
private let slsAddWindowsToSpaces = slsSym(["CGSAddWindowsToSpaces", "SLSAddWindowsToSpaces"], as: FnAddWindows.self)

// MARK: - "Show menu bar background" detection (capture-based)
// The setting isn't a readable preference — it's private WindowServer state. But
// its effect is unmistakable in what we capture: with the background OFF the menu
// bar window has no fill, so its backdrop rows come back pure black (~1/255) while
// glyphs are still present, versus ~234/255 when the background is on. We detect
// that directly rather than reading a pref.
private func menuBarBackgroundOnNow() -> Bool {
    // Probe the Menubar window ALONE (not the composite): with the background on
    // it captures as the bright material strip; with it off there is nothing to
    // draw and the capture comes back black/empty. On pre-26A5406e builds the
    // window also carries glyphs, which the legacy black-backdrop test handles.
    guard let bar = findMenubarWindow(displayBounds: CGDisplayBounds(CGMainDisplayID())),
          let img = captureStrip(bar.wid) else { return true }
    let w = img.width, h = img.height
    guard h >= 24 else { return true }
    let band = max(4, Int((Double(h) * 0.22).rounded()))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { p in
        CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var backdropMax = 0.0, overallMax = 0.0
    px.withUnsafeBufferPointer { S in
        func scan(_ rows: Range<Int>, into acc: inout Double) {
            for y in rows { for x in 0..<w {
                let i = (y * w + x) * 4
                let l = 0.299 * Double(S[i]) + 0.587 * Double(S[i+1]) + 0.114 * Double(S[i+2])
                if l > acc { acc = l }
            } }
        }
        scan(0..<band, into: &backdropMax)        // clean backdrop bands (top + bottom)
        scan((h - band)..<h, into: &backdropMax)
        scan(0..<h, into: &overallMax)
    }
    // Legacy (window carries glyphs): pure-black backdrop with real content above
    // it => transparent bar. 26A5406e (material only, no glyphs): the whole window
    // capturing black/empty => transparent bar. Full-screen never lands here —
    // the Menubar window is gone from the onscreen list, caught by the guard.
    return !((backdropMax < 12 && overallMax > 20) || overallMax < 10)
}

/// TCC preflight is unreliable — it reports false negatives after the ad-hoc dev
/// build is re-signed and on newer macOS in general. So trust ground truth too:
/// if we can actually capture the bar, we have access (without Screen Recording,
/// window NAMES are hidden from CGWindowListCopyWindowInfo, so captureMenubar
/// can't even find a "Menubar" candidate — it fails cleanly, not spuriously).
private func screenCapturePermissionNow() -> Bool {
    CGPreflightScreenCaptureAccess()
        || captureMenubar(displayBounds: CGDisplayBounds(CGMainDisplayID())).image != nil
}

private func allManagedSpaceIDs(_ cid: Int32) -> [NSNumber] {
    guard let raw = slsCopyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    var ids: [NSNumber] = []
    for display in raw {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
        for s in spaces {
            if let id = s["ManagedSpaceID"] as? NSNumber { ids.append(id) }
            else if let id = s["id64"] as? NSNumber { ids.append(id) }
        }
    }
    return ids
}

/// Add `windowNumber` to every managed Space. Safe to call repeatedly.
private func pinWindowToAllSpaces(_ windowNumber: Int) {
    guard windowNumber > 0, let mainConn = slsMainConnectionID, let add = slsAddWindowsToSpaces else { return }
    let cid = mainConn()
    let spaces = allManagedSpaceIDs(cid)
    guard !spaces.isEmpty else { return }
    add(cid, [NSNumber(value: windowNumber)] as CFArray, spaces as CFArray)
}

// MARK: - Theme + extraction/recolor (clean-row self-matte)

struct MirrorTheme: Sendable, Equatable {
    var bg: SIMD3<Double>          // sRGB 0…1
    var bg2: SIMD3<Double>         // right gradient stop (== bg when gradient is off)
    var bgMid: SIMD3<Double>? = nil   // optional middle stop (3-color gradients)
    var gradient: Bool             // horizontal bg→(bgMid→)bg2 wash across each bar
    var fg: SIMD3<Double>
    var desktopTint: Bool          // paint glyphs with the desktop's own color
    var boostFaint: Bool           // lift dimmed/disabled icons (√alpha)
    var coloredIcons: ColoredIconMode
    var notchFade: Bool            // fade the background to black around the notch
    var showInScreenshots: Bool
}

/// How glyphs that carry their own color (the low-power battery, recording
/// dots, app logos) are painted.
enum ColoredIconMode: String, CaseIterable, Codable, Sendable {
    case original   // keep their recovered color at full strength
    case muted      // repaint in the theme's paint at half contrast
    case themed     // repaint in the theme's paint like everything else
}

/// A complete, persistable background+foreground look. Shared by the
/// light/dark appearance slots, custom presets, and settings export.
/// bgMid is optional so specs saved before 3-color support decode unchanged.
struct ThemeSpec: Codable, Equatable, Sendable {
    var bg: SIMD3<Double>
    var bgMid: SIMD3<Double>? = nil
    var bg2: SIMD3<Double>
    var gradient: Bool
    var fg: SIMD3<Double>
}

struct CustomPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var spec: ThemeSpec
}

enum AppearanceSlot: String, Codable, Sendable { case light, dark }

/// CGImage isn't Sendable under Swift 6; box it for the background→main hop.
private struct SendableImage: @unchecked Sendable { let image: CGImage }

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

@inline(__always) private func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1); return t * t * (3 - 2 * t)
}

/// Extract glyphs from the captured strip via a clean-row backdrop estimate and
/// repaint them in the theme. Returns the themed image and the fraction of
/// non-black source pixels (≈0 ⇒ bar hidden, e.g. fullscreen).
/// Normalize the captured strip into a plain RGBA buffer. Split out from
/// renderThemed so the engine can hash the bytes and skip the (much more
/// expensive) recolor passes when nothing on the bar has changed.
private func drawSource(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var src = [UInt8](repeating: 0, count: w * h * 4)
    src.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return src
}

/// FNV-1a over ~2k strided pixels — microseconds, and any real bar change
/// (clock tick, hover capsule, item add/remove) lands on sampled pixels.
private func sampleHash(_ src: [UInt8]) -> UInt64 {
    let pixels = src.count / 4
    let step = max(1, pixels / 2048)
    var h: UInt64 = 0xcbf29ce484222325
    src.withUnsafeBytes { raw in
        var i = 0
        while i < pixels {
            let v = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
            h = (h ^ UInt64(v)) &* 0x100000001b3
            i += step
        }
    }
    return h
}

private func renderThemed(src: [UInt8], w: Int, h: Int, theme: MirrorTheme,
                          notchBand: NotchBandPx? = nil) -> (CGImage, Double)? {
    guard w > 32, h >= 24, src.count == w * h * 4 else { return nil }

    // Clean backdrop bands, sized as a fraction of strip height so the same code
    // works on the Retina notched built-in (78px: glyphs at rows 21–54) and a
    // non-Retina external (30px: glyphs at rows 7–22). ~22% lands the bands on
    // genuine backdrop with margin at every strip height we've measured.
    let band = max(4, Int((Double(h) * 0.22).rounded()))
    let topN = band, botN = band
    var out = [UInt8](repeating: 0, count: w * h * 4)
    var nonBlack = 0

    // Gradient: resolve the per-column background once; nil means solid.
    // With a middle stop the wash is piecewise: bg→bgMid over the left half,
    // bgMid→bg2 over the right.
    let colBG: [SIMD3<Double>]? = theme.gradient
        ? (0..<w).map { x in
            let t = Double(x) / Double(max(1, w - 1))
            if let m = theme.bgMid {
                return t < 0.5 ? theme.bg + (t * 2) * (m - theme.bg)
                               : m + ((t - 0.5) * 2) * (theme.bg2 - m)
            }
            return theme.bg + t * (theme.bg2 - theme.bg)
        }
        : nil

    // Notch fade: a per-column multiplier that takes the background to pure
    // black inside the notch span and smoothsteps back to the theme over
    // `fadeWidth` on each side. Background only — glyphs never sit in the
    // notch, and glyphs beside it gain contrast on the darkened base.
    let fadeMul: [Double]? = notchBand.map { b in
        (0..<w).map { x in
            let d = max(b.minX - Double(x), Double(x) - b.maxX)   // ≤0 inside the notch
            return smoothstep(d / b.fadeWidth)
        }
    }

    src.withUnsafeBufferPointer { S in
    out.withUnsafeMutableBufferPointer { O in
        var bTop = [Double](repeating: 0, count: w * 3)
        var bBot = [Double](repeating: 0, count: w * 3)
        for x in 0..<w {
            var st = (0.0, 0.0, 0.0), sb = (0.0, 0.0, 0.0)
            for y in 0..<topN { let i = (y * w + x) * 4
                st.0 += Double(S[i]); st.1 += Double(S[i+1]); st.2 += Double(S[i+2]) }
            for y in (h - botN)..<h { let i = (y * w + x) * 4
                sb.0 += Double(S[i]); sb.1 += Double(S[i+1]); sb.2 += Double(S[i+2]) }
            bTop[x*3] = st.0/Double(topN); bTop[x*3+1] = st.1/Double(topN); bTop[x*3+2] = st.2/Double(topN)
            bBot[x*3] = sb.0/Double(botN); bBot[x*3+1] = sb.1/Double(botN); bBot[x*3+2] = sb.2/Double(botN)
        }

        // Pass 1 — per-pixel backdrop-relative diff + histogram for self-calibrating D.
        var hist = [Int](repeating: 0, count: 256)
        var diffBuf = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let i = (y * w + x) * 4
                let br = bTop[x*3]   + t * (bBot[x*3]   - bTop[x*3])
                let bg = bTop[x*3+1] + t * (bBot[x*3+1] - bTop[x*3+1])
                let bb = bTop[x*3+2] + t * (bBot[x*3+2] - bTop[x*3+2])
                let d = max(abs(Double(S[i]) - br), max(abs(Double(S[i+1]) - bg), abs(Double(S[i+2]) - bb)))
                diffBuf[y * w + x] = d
                hist[min(255, Int(d))] += 1
                if Double(S[i]) + Double(S[i+1]) + Double(S[i+2]) > 30 { nonBlack += 1 }
            }
        }
        let cut = Int(0.98 * Double(w * h))
        var acc = 0, p98 = 60
        for v in 0..<256 { acc += hist[v]; if acc >= cut { p98 = v; break } }
        let D = max(60.0, Double(p98)) / 255.0
        let t0 = 8.0 / 255.0

        // Pass 1.5 — per-column chroma evidence. Recover each strong glyph
        // pixel's own color (un-premultiply against the estimated backdrop) and
        // keep the column's maximum chroma. Colored fills — the low-power
        // battery, recording dots, app logos — read high; template glyphs are
        // gray (≈0). Tracking the COLUMN maximum lets low-chroma pixels inside
        // a colored fill (the dark "63" digits in the yellow battery pill, whose
        // columns also pass through yellow above and below) inherit keep-color
        // treatment — per-pixel chroma alone would repaint them as foreground,
        // which lands light-on-yellow and is unreadable.
        var colChroma = [Double](repeating: 0, count: w)
        for y in 0..<h where theme.coloredIcons == .original {
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let aRaw = smoothstep((diffBuf[y * w + x] / 255.0 - t0) / (D - t0))
                guard aRaw >= 0.5 else { continue }
                let i = (y * w + x) * 4
                let br = (bTop[x*3]   + t * (bBot[x*3]   - bTop[x*3]))   / 255.0
                let bg = (bTop[x*3+1] + t * (bBot[x*3+1] - bTop[x*3+1])) / 255.0
                let bb = (bTop[x*3+2] + t * (bBot[x*3+2] - bTop[x*3+2])) / 255.0
                let gr = min(1, max(0, (Double(S[i])   / 255.0 - (1 - aRaw) * br) / aRaw))
                let gg = min(1, max(0, (Double(S[i+1]) / 255.0 - (1 - aRaw) * bg) / aRaw))
                let gb = min(1, max(0, (Double(S[i+2]) / 255.0 - (1 - aRaw) * bb) / aRaw))
                let chroma = max(gr, max(gg, gb)) - min(gr, min(gg, gb))
                if chroma > colChroma[x] { colChroma[x] = chroma }
            }
        }

        // Pass 2 — soft matte + recolor (alpha-only paint ⇒ no halos).
        for y in 0..<h {
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let i = (y * w + x) * 4
                let br = (bTop[x*3]   + t * (bBot[x*3]   - bTop[x*3]))   / 255.0
                let bg = (bTop[x*3+1] + t * (bBot[x*3+1] - bTop[x*3+1])) / 255.0
                let bb = (bTop[x*3+2] + t * (bBot[x*3+2] - bTop[x*3+2])) / 255.0
                let aRaw = smoothstep((diffBuf[y * w + x] / 255.0 - t0) / (D - t0))
                // Dimmed/disabled items (HazeOver off, Caffeinated idle, …) draw at
                // low opacity → low matte alpha → washed toward the background. A
                // √-curve lifts the faint mid-range while keeping 0 and 1 fixed, so
                // empty backdrop stays empty and solid glyphs stay solid.
                var a = aRaw
                if theme.boostFaint { a = a.squareRoot() }

                // Backdrop is continuous across the notch (no glyphs land there);
                // paint theme bg like any empty column — the physical notch occludes it.
                var base = colBG?[x] ?? theme.bg
                if let f = fadeMul { base *= f[x] }
                // Monochrome glyphs get the theme foreground, or — with desktop
                // tint on — this column's wallpaper hue, pastelized toward white
                // on dark backgrounds (what macOS's translucent bar items look
                // like) but deepened toward black on light ones, where a pastel
                // would vanish into the background.
                var cr = theme.fg.x, cg = theme.fg.y, cb = theme.fg.z
                if theme.desktopTint {
                    if 0.2126*base.x + 0.7152*base.y + 0.0722*base.z > 0.55 {
                        cr = 0.35*br; cg = 0.35*bg; cb = 0.35*bb
                    } else {
                        cr = 0.5 + 0.5*br; cg = 0.5 + 0.5*bg; cb = 0.5 + 0.5*bb
                    }
                }
                // Chroma-preserve: strongly colored glyphs keep their OWN color
                // (recovered by un-premultiplying against the backdrop) instead
                // of the theme paint — the low-power battery stays yellow, the
                // recording dot red. `kPix` keys off this pixel's chroma, `kCol`
                // off the column's (so dark digits inside a colored fill stay
                // dark); the aRaw ramp suppresses noisy recovery at soft edges,
                // where division by a tiny alpha amplifies sensor-level noise.
                if theme.coloredIcons != .themed, aRaw > 0.12 {
                    let ar = max(aRaw, 0.25)
                    let gr = min(1, max(0, (Double(S[i])   / 255.0 - (1 - aRaw) * br) / ar))
                    let gg = min(1, max(0, (Double(S[i+1]) / 255.0 - (1 - aRaw) * bg) / ar))
                    let gb = min(1, max(0, (Double(S[i+2]) / 255.0 - (1 - aRaw) * bb) / ar))
                    let chroma = max(gr, max(gg, gb)) - min(gr, min(gg, gb))
                    let kPix = smoothstep((chroma - 0.18) / 0.17)
                    let edge = smoothstep((aRaw - 0.12) / 0.15)
                    if theme.coloredIcons == .original {
                        // Colored glyphs keep their own recovered color, at full
                        // strength. kCol extends the treatment to low-chroma
                        // pixels inside a colored fill (the battery digits).
                        let kCol = smoothstep((colChroma[x] - 0.25) / 0.20)
                        let k = max(kPix, kCol) * edge
                        if k > 0 {
                            cr += k * (gr - cr); cg += k * (gg - cg); cb += k * (gb - cb)
                        }
                    } else {
                        // Muted: colored glyphs still repaint in the theme's
                        // paint, but at HALF its contrast against the
                        // background — half as bright as the primary — so they
                        // read as secondary rather than blending in completely.
                        // Per-pixel chroma only: the achromatic digits inside
                        // the battery pill stay full-strength and legible
                        // against the dimmed fill.
                        let k = kPix * edge
                        if k > 0 {
                            let dr = base.x + 0.5 * (cr - base.x)
                            let dg = base.y + 0.5 * (cg - base.y)
                            let db = base.z + 0.5 * (cb - base.z)
                            cr += k * (dr - cr); cg += k * (dg - cg); cb += k * (db - cb)
                        }
                    }
                }
                let or_ = base.x + a*(cr - base.x)
                let og  = base.y + a*(cg - base.y)
                let ob  = base.z + a*(cb - base.z)
                O[i]   = UInt8(min(255, max(0, or_ * 255)))
                O[i+1] = UInt8(min(255, max(0, og  * 255)))
                O[i+2] = UInt8(min(255, max(0, ob  * 255)))
                O[i+3] = 255
            }
        }
    }}

    let outImg = out.withUnsafeMutableBytes { p -> CGImage? in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()
    }
    guard let outImg else { return nil }
    return (outImg, Double(nonBlack) / Double(w * h))
}

// MARK: - Display snapshot (captured on main, read on the render queue)

/// The notch's horizontal span in points from the display's LEFT edge.
struct NotchSpan: Sendable, Equatable {
    let minXPt: CGFloat
    let maxXPt: CGFloat
}

struct DisplaySnapshot: Sendable {
    let displayID: CGDirectDisplayID
    let cgBounds: CGRect       // CoreGraphics global (top-left origin)
    let appKitFrame: CGRect    // NSScreen.frame (bottom-left origin)
    let scale: CGFloat
    let notch: NotchSpan?      // nil on displays without a camera housing
}

/// The notch-fade band in image-pixel columns, ready for renderThemed.
struct NotchBandPx: Sendable, Equatable {
    let minX: Double
    let maxX: Double
    let fadeWidth: Double
}

struct MirrorStats: Sendable { var activeDisplays = 0 }

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Engine (background render loop + click-through overlay panels)

private final class MirrorEngine: @unchecked Sendable {
    private let q = DispatchQueue(label: "com.n14395.re-bar.mirror", qos: .userInteractive)
    private let lock = NSLock()

    // shared state (lock-guarded)
    private var theme = MirrorTheme(bg: .init(0.10, 0.11, 0.16), bg2: .init(0.10, 0.11, 0.16),
                                    gradient: false, fg: .init(0.95, 0.95, 0.97),
                                    desktopTint: false, boostFaint: false, coloredIcons: .original,
                                    notchFade: false, showInScreenshots: false)
    private var displays: [DisplaySnapshot] = []
    private var isActive = false
    private var stats = MirrorStats()
    // Bumped (under `lock`) whenever the theme, display set, or Space changes —
    // any of which must defeat the damage gate below and force a full render.
    private var renderGen = 0

    // Damage-gate state: render-queue-only (touched exclusively inside tick(),
    // which runs solely on `q`), so no locking needed.
    private struct RenderKey: Equatable {
        let theme: MirrorTheme
        let band: NotchBandPx?
        let w: Int
        let h: Int
    }
    private var lastHash: [CGDirectDisplayID: UInt64] = [:]
    private var lastKey: [CGDirectDisplayID: RenderKey] = [:]
    private var ticksSinceRender: [CGDirectDisplayID: Int] = [:]
    private var lastGen: [CGDirectDisplayID: Int] = [:]
    // Cached Menubar-window resolution per display: the full window-list walk is
    // the priciest part of an idle tick, so between periodic re-resolutions we
    // only ask "is that window still on screen?" (a one-window query).
    private var barCache: [CGDirectDisplayID: (wid: UInt32, rect: CGRect)] = [:]
    private var barCacheAge: [CGDirectDisplayID: Int] = [:]
    // Adaptive cadence: ~2 s of a byte-identical bar drops the timer to ~6.7 Hz;
    // any change (or capture trouble) snaps straight back to 20 Hz.
    private var quietTicks = 0
    private var slowMode = false

    // background-only
    private var timer: DispatchSourceTimer?
    // main-only
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var lastGoodTime: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var blackSince: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var frontBoostUntil: CFTimeInterval = 0
    // Panel window numbers, mirrored under `lock` so the capture thread can pass
    // its own overlay as the below-window exclusion bound without touching AppKit.
    private var overlayIDs: [CGDirectDisplayID: UInt32] = [:]

    private func overlayID(for did: CGDirectDisplayID) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return overlayIDs[did] ?? 0
    }

    private func setOverlayID(_ wid: UInt32?, for did: CGDirectDisplayID) {
        lock.lock(); overlayIDs[did] = wid; lock.unlock()
    }

    func setTheme(_ t: MirrorTheme) { lock.lock(); theme = t; renderGen += 1; lock.unlock() }
    func setDisplays(_ d: [DisplaySnapshot]) {
        lock.lock(); displays = d; renderGen += 1; lock.unlock()
        let keep = Set(d.map(\.displayID))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.prunePanels(keeping: keep) } }
    }
    func snapshotStats() -> MirrorStats { lock.lock(); defer { lock.unlock() }; return stats }

    func start() {
        lock.lock(); isActive = true; renderGen += 1; lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))   // ~20 Hz
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock(); isActive = false; lock.unlock()
        timer?.cancel(); timer = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { self.teardownPanels() } }
    }

    /// Called the moment the active Space changes: repaint with the new Space's
    /// content immediately and re-assert the overlay's front ordering for a beat.
    @MainActor func onSpaceChanged() {
        lock.lock(); renderGen += 1; lock.unlock()
        frontBoostUntil = CACurrentMediaTime() + 0.5
        for p in panels.values { pinWindowToAllSpaces(p.windowNumber) }   // catch newly-created Spaces
        q.async { [weak self] in self?.tick() }
    }

    private func tick() {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        let t = theme, ds = displays, gen = renderGen
        lock.unlock()
        guard !ds.isEmpty else { return }

        var active = 0
        var anyWork = false      // false ⇔ every display took the unchanged-skip path
        for d in ds {
            let did = d.displayID, frame = d.appKitFrame, scale = d.scale, show = t.showInScreenshots

            // Resolve the bar window — from cache when it's fresh and still on
            // screen (Space switches retire the old per-Space window, which the
            // liveness probe catches), with a periodic full re-resolve.
            var bar = barCache[did]
            if let c = bar, (barCacheAge[did] ?? .max) < 24, menubarWindowOnscreen(c.wid) {
                barCacheAge[did]! += 1
            } else {
                bar = findMenubarWindow(displayBounds: d.cgBounds)
                barCache[did] = bar
                barCacheAge[did] = 0
            }
            let barExists = bar != nil
            let cap = bar.flatMap {
                captureBarComposite(rect: $0.rect, wid: $0.wid, belowWindow: overlayID(for: did))
            }
            guard let img = cap, img.width > 32, img.height >= 24 else {
                lastHash[did] = nil        // whatever comes back next is a fresh start
                barCache[did] = nil        // and the window gets re-resolved too
                anyWork = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.applyFrame(did: did, image: nil, hardHidden: false, barExists: barExists,
                                        barPt: 0, frame: frame, scale: scale, show: show)
                    }
                }
                continue
            }

            // Damage gate: hash a sparse sample of the normalized bytes and skip
            // the recolor passes + main-thread push when the bar, theme, and
            // geometry are all unchanged. A periodic forced render backstops
            // anything a sparse sample could alias past.
            let w = img.width, h = img.height
            let band: NotchBandPx? = (t.notchFade && d.notch != nil)
                ? NotchBandPx(minX: Double(d.notch!.minXPt * d.scale),
                              maxX: Double(d.notch!.maxXPt * d.scale),
                              fadeWidth: 48.0 * Double(d.scale))
                : nil
            let src = drawSource(img)
            let hash = sampleHash(src)
            let key = RenderKey(theme: t, band: band, w: w, h: h)
            // `changed` = genuine invalidation (drives the cadence); the periodic
            // safety render is self-inflicted and must NOT reset the quiet streak,
            // or slow mode could never engage.
            let changed = gen != lastGen[did] || overlayID(for: did) == 0
                       || hash != lastHash[did] || key != lastKey[did]
            let periodic = (ticksSinceRender[did] ?? .max) >= 24
            if changed { anyWork = true }
            if !changed, !periodic {
                ticksSinceRender[did] = (ticksSinceRender[did] ?? 0) + 1
                active += 1
                DispatchQueue.main.async { MainActor.assumeIsolated { self.noteUnchanged(did: did) } }
                continue
            }
            lastGen[did] = gen; lastHash[did] = hash; lastKey[did] = key; ticksSinceRender[did] = 0

            var box: SendableImage? = nil
            var barPt: CGFloat = 0
            var hardHidden = false
            if let (out, nonBlack) = renderThemed(src: src, w: w, h: h, theme: t, notchBand: band),
               nonBlack > 0.002 {
                box = SendableImage(image: out)
                barPt = CGFloat(h) / d.scale
                active += 1
            } else {
                hardHidden = true          // captured, but the bar is all-black (e.g. full-screen)
                lastHash[did] = nil        // re-render the moment it recovers
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.applyFrame(did: did, image: box, hardHidden: hardHidden, barExists: barExists,
                                    barPt: barPt, frame: frame, scale: scale, show: show)
                }
            }
        }

        lock.lock()
        stats = MirrorStats(activeDisplays: active)
        lock.unlock()

        // Adaptive cadence. The forced periodic render (ticksSinceRender) still
        // happens in slow mode, just spaced further apart; a Space change comes
        // in via onSpaceChanged's direct tick and snaps the rate back.
        if anyWork {
            quietTicks = 0
            if slowMode {
                slowMode = false
                timer?.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            }
        } else {
            quietTicks += 1
            if !slowMode, quietTicks >= 40 {
                slowMode = true
                timer?.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150))
            }
        }
    }

    /// Damage-gate skip path: keep the visibility state machine fed without
    /// pushing a frame — lastGoodTime must not go stale during long static
    /// periods (the Mission-Control hold keys off it), and the Space-switch
    /// front boost must keep re-asserting the overlay's ordering.
    @MainActor private func noteUnchanged(did: CGDirectDisplayID) {
        let now = CACurrentMediaTime()
        lastGoodTime[did] = now
        blackSince[did] = nil
        if now < frontBoostUntil { panels[did]?.orderFrontRegardless() }
    }

    @MainActor private func applyFrame(did: CGDirectDisplayID, image: SendableImage?, hardHidden: Bool,
                                       barExists: Bool, barPt: CGFloat, frame: CGRect, scale: CGFloat, show: Bool) {
        lock.lock(); let active = isActive; lock.unlock()
        guard active else { panels[did]?.orderOut(nil); return }
        let now = CACurrentMediaTime()

        if let box = image {
            let panel = panels[did] ?? makePanel(did: did)
            let rect = NSRect(x: frame.minX, y: frame.maxY - barPt, width: frame.width, height: barPt)
            if panel.frame != rect {
                panel.setFrame(rect, display: false)
                panel.contentView?.frame = NSRect(origin: .zero, size: rect.size)
            }
            panel.contentView?.layer?.contentsScale = scale
            panel.sharingType = show ? .readOnly : .none
            panel.contentView?.layer?.contents = box.image
            // Re-assert front ordering right after a Space change so the overlay
            // sits above the newly-composited Space's real bar rather than under it.
            if !panel.isVisible || now < frontBoostUntil { panel.orderFrontRegardless() }
            lastGoodTime[did] = now
            blackSince[did] = nil
        } else if hardHidden {
            // A successful but all-black capture. Only *persistent* black means the bar
            // is genuinely gone (full-screen). A stray black frame while a freshly-
            // switched Space's bar is still compositing must NOT hide.
            if blackSince[did] == nil { blackSince[did] = now }
            if now - blackSince[did]! >= 0.3 { panels[did]?.orderOut(nil) }
        } else if barExists {
            // The Menubar window is present but momentarily uncapturable (the common
            // post-Space-switch hiccup). The bar IS on screen, so hiding would expose
            // the real untinted bar — hold the last colored frame indefinitely; capture
            // recovers within a few hundred ms.
            blackSince[did] = nil
        } else {
            // No Menubar window at all (Mission Control / bar genuinely absent): hold
            // briefly, then hide so we don't sit over the Mission Control UI.
            blackSince[did] = nil
            if lastGoodTime[did] == nil || now - lastGoodTime[did]! >= 0.8 { panels[did]?.orderOut(nil) }
        }
    }

    @MainActor private func makePanel(did: CGDirectDisplayID) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true            // clicks pass through to the real bar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))   // above the bar
        // NB: no `.stationary` — that flag pins the window to the desktop layer, so
        // during a Space slide the incoming Space's real menu bar composites ABOVE it
        // and flashes through. `.canJoinAllSpaces` alone keeps a normal above-the-bar
        // window present on every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        let v = FlippedView(frame: .zero)
        v.wantsLayer = true
        v.layer!.contentsGravity = .resize
        panel.contentView = v
        panels[did] = panel
        setOverlayID(UInt32(panel.windowNumber), for: did)
        pinWindowToAllSpaces(panel.windowNumber)   // eager per-Space membership (no join lag)
        return panel
    }

    @MainActor private func prunePanels(keeping: Set<CGDirectDisplayID>) {
        for (did, panel) in panels where !keeping.contains(did) {
            panel.orderOut(nil); panels[did] = nil; lastGoodTime[did] = nil; blackSince[did] = nil
            setOverlayID(nil, for: did)
        }
    }

    @MainActor private func teardownPanels() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        lastGoodTime.removeAll()
        blackSince.removeAll()
        lock.lock(); overlayIDs.removeAll(); lock.unlock()
    }
}

// MARK: - Background tint (permission-free path)

/// How the bar gets recolored. `.mirror` captures the bar and redraws all of
/// it — icons included — which needs Screen Recording and shows the system's
/// recording indicators. `.tint` lays a translucent wash of the theme color
/// over the bar: everything stays visible through it, uniformly tinted, and
/// nothing ever reads the screen — no permission, no indicator.
enum RecolorStyle: String, CaseIterable, Sendable {
    case mirror, tint
}

/// One click-through panel per display laid OVER the bar as a translucent
/// wash of the theme background — icons and menus stay legible through it,
/// uniformly tinted.
///
/// A behind-the-bar panel (the Ice/Thaw placement, one level below the bar so
/// only the backdrop picks up the color) was tried first and is measurably
/// dead on macOS 27 beta 26A5421a: the bar's material composites as an opaque
/// raster with its wallpaper blur baked in, and windows beneath it are
/// occlusion-culled outright — a panel at ANY lower level contributes nothing
/// (verified with saturated-color probes at levels 3–24; only level ≥ the
/// bar's own shows up at all). The wash above the bar is the one capture-free
/// recolor lever left on this build.
@MainActor
final class TintOverlay {
    /// Strong enough to read as the theme color, weak enough that glyph
    /// contrast survives underneath.
    private static let washAlpha = 0.45

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var theme: MirrorTheme?
    private(set) var running = false

    var activeDisplays: Int { running ? panels.count : 0 }

    func apply(_ theme: MirrorTheme) {
        self.theme = theme
        if running { layout() }
    }

    func start() {
        running = true
        layout()
    }

    func stop() {
        running = false
        for p in panels.values { p.orderOut(nil) }
        panels.removeAll()
    }

    /// Screens changed (resolution, arrangement, plug/unplug) — rebuild frames.
    func refreshFrames() {
        if running { layout() }
    }

    func onSpaceChanged() {
        guard running else { return }
        for p in panels.values {
            pinWindowToAllSpaces(p.windowNumber)   // catch newly-created Spaces
            p.orderFrontRegardless()
        }
    }

    private func layout() {
        guard let theme else { return }
        var kept: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let did = CGDirectDisplayID(num.uint32Value)
            // Bar height: what visibleFrame excludes at the top, with the
            // notch-adjacent safe area as a floor (it under-reports by 1 pt
            // here: aux 38 vs bar 39). A zero height (menu bar set to
            // auto-hide) gets no panel — a bare colored stripe would just
            // sit on the desktop.
            let h = max(screen.auxiliaryTopLeftArea?.height ?? 0,
                        screen.frame.maxY - screen.visibleFrame.maxY)
            guard h > 1, h < 80 else { continue }
            kept.insert(did)
            let panel = panels[did] ?? makePanel(did: did)
            panel.sharingType = theme.showInScreenshots ? .readOnly : .none
            panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.maxY - h,
                                  width: screen.frame.width, height: h), display: true)
            if let layer = panel.contentView?.layer as? CAGradientLayer {
                // A single-stop gradient layer renders nothing — duplicate the
                // color for the solid case.
                var stops = [theme.bg]
                if theme.gradient {
                    if let m = theme.bgMid { stops.append(m) }
                    stops.append(theme.bg2)
                } else {
                    stops.append(theme.bg)
                }
                layer.colors = stops.map {
                    CGColor(srgbRed: $0.x, green: $0.y, blue: $0.z, alpha: Self.washAlpha)
                }
            }
            panel.orderFrontRegardless()
        }
        for (did, panel) in panels where !kept.contains(did) {
            panel.orderOut(nil); panels[did] = nil
        }
    }

    private func makePanel(did: CGDirectDisplayID) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true            // clicks land on the real bar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        // Over the bar (same level as the mirror overlay — the two modes are
        // never active together). See the class note for why "one level below"
        // does not work on this OS.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        let v = NSView(frame: .zero)
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        v.layer = gradient           // layer-hosting: the layer tracks the view's bounds
        v.wantsLayer = true
        panel.contentView = v
        panels[did] = panel
        pinWindowToAllSpaces(panel.windowNumber)   // eager per-Space membership (no join lag)
        return panel
    }
}

// MARK: - Controller (SwiftUI-facing state)

// Persisted so a relaunch — in particular a silent login-item start — restores
// the theme and re-enables the mirror without the window ever opening.
private let kEnabled = "mirror.enabled"
private let kBG = "mirror.bg", kFG = "mirror.fg"
private let kBG2 = "mirror.bg2", kGradient = "mirror.gradient"
private let kBGMid = "mirror.bgMid", kThreeColor = "mirror.threeColor"
private let kTint = "mirror.desktopTint", kBoost = "mirror.boostFaint"
private let kShots = "mirror.showInScreenshots"
private let kColoredIcons = "mirror.coloredIcons"
private let kNotchFade = "mirror.notchFade"
private let kStyle = "mirror.style"
private let kKeepColors = "mirror.keepColors"   // legacy boolean this replaced
private let kFollow = "mirror.followAppearance"
private let kThemeLight = "mirror.themeLight", kThemeDark = "mirror.themeDark"
private let kCustomPresets = "mirror.customPresets"

private func savedColor(_ key: String, or fallback: Color) -> Color {
    guard let c = UserDefaults.standard.array(forKey: key) as? [Double], c.count == 3
    else { return fallback }
    return Color(red: c[0], green: c[1], blue: c[2])
}

private func loadCustomPresets() -> [CustomPreset] {
    guard let data = UserDefaults.standard.data(forKey: kCustomPresets),
          let list = try? JSONDecoder().decode([CustomPreset].self, from: data) else { return [] }
    return list
}

@MainActor @Observable
final class MenuBarMirrorController {
    var enabled = UserDefaults.standard.bool(forKey: kEnabled) {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: kEnabled)
            enabled ? start() : stop()
        }
    }
    /// Which recolor path runs while `enabled` — flipping it live swaps engines.
    var recolorStyle = RecolorStyle(rawValue: UserDefaults.standard.string(forKey: kStyle) ?? "") ?? .mirror {
        didSet {
            guard recolorStyle != oldValue else { return }
            UserDefaults.standard.set(recolorStyle.rawValue, forKey: kStyle)
            if enabled { stop(); start() }
        }
    }
    var bgColor = savedColor(kBG, or: Color(red: 0.10, green: 0.11, blue: 0.16))
    var fgColor = savedColor(kFG, or: Color(red: 0.95, green: 0.95, blue: 0.97))
    var bg2Color = savedColor(kBG2, or: Color(red: 0.35, green: 0.20, blue: 0.55))
    var bgMidColor = savedColor(kBGMid, or: Color(red: 0.22, green: 0.15, blue: 0.35))
    var gradientOn = UserDefaults.standard.bool(forKey: kGradient)
    var threeColorOn = UserDefaults.standard.bool(forKey: kThreeColor)
    var desktopTint = UserDefaults.standard.bool(forKey: kTint)
    var boostFaint = UserDefaults.standard.bool(forKey: kBoost)
    var showInScreenshots = UserDefaults.standard.bool(forKey: kShots)
    var notchFade = UserDefaults.standard.bool(forKey: kNotchFade)
    /// Set by ContentView's onAppear/onDisappear — the capture-heavy permission
    /// and background probes only matter while their notices can be seen.
    var settingsWindowVisible = false
    // Defaults to .original — matching the real bar is the natural look. Falls
    // back to the boolean key this setting replaced (true = original, false =
    // muted, which is what the off state painted).
    var coloredIcons: ColoredIconMode = {
        if let raw = UserDefaults.standard.string(forKey: kColoredIcons),
           let m = ColoredIconMode(rawValue: raw) { return m }
        if let old = UserDefaults.standard.object(forKey: kKeepColors) as? Bool {
            return old ? .original : .muted
        }
        return .original
    }()

    // Follow-appearance: two full ThemeSpec slots. The bar always renders the
    // slot matching the actual system appearance; the chip picks which slot the
    // controls edit. Every edit is persisted into the editing slot by
    // applyTheme(), so switching slots just loads — no save step needed.
    var followAppearance = UserDefaults.standard.bool(forKey: kFollow) {
        didSet {
            guard followAppearance != oldValue else { return }
            UserDefaults.standard.set(followAppearance, forKey: kFollow)
            if followAppearance {
                // Seed missing slots from the current colors so enabling is lossless.
                if storedSlot(.light) == nil { saveSlotSpec(editingSpec(), for: .light) }
                if storedSlot(.dark) == nil { saveSlotSpec(editingSpec(), for: .dark) }
                editingSlot = systemIsDark ? .dark : .light   // didSet loads the slot
            }
            applyTheme()
        }
    }
    var editingSlot: AppearanceSlot = .light {
        didSet { if followAppearance { loadEditingSurface(slotSpec(editingSlot)) } }
    }
    private(set) var systemIsDark = false

    var customPresets = loadCustomPresets() {
        didSet {
            guard let data = try? JSONEncoder().encode(customPresets) else { return }
            UserDefaults.standard.set(data, forKey: kCustomPresets)
        }
    }

    private(set) var permissionGranted = screenCapturePermissionNow()
    private(set) var menuBarBackgroundOn = menuBarBackgroundOnNow()
    private(set) var stats = MirrorStats()

    private let engine = MirrorEngine()
    private let tintOverlay = TintOverlay()
    private var statsTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var themeChangeObserver: NSObjectProtocol?

    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.onSpaceChanged()
                self?.tintOverlay.onSpaceChanged()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushDisplays() }
        }
        systemIsDark = NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        editingSlot = systemIsDark ? .dark : .light
        if followAppearance { loadEditingSurface(slotSpec(editingSlot)) }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceDidChange() } }
        }
        // KVO on effectiveAppearance has a history of not firing for background
        // (accessory) apps — the distributed notification is the belt to its braces.
        themeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // effectiveAppearance may not have flipped yet at delivery — settle first.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceDidChange() } }
        }
        if enabled { start() }   // restore persisted state (e.g. after a login-item launch)
    }

    private func snapshotDisplays() -> [DisplaySnapshot] {
        NSScreen.screens.compactMap { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let did = CGDirectDisplayID(num.uint32Value)
            // The notch is the gap between the two auxiliary top areas (both nil
            // on non-notched displays). Convert to display-local points; if the
            // rects ever come back screen-global on a non-origin display, the
            // centered-notch sanity check falls back to the raw values.
            var notch: NotchSpan? = nil
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                var lo = l.maxX - s.frame.minX, hi = r.minX - s.frame.minX
                if abs((lo + hi) / 2 - s.frame.width / 2) > 2 { lo = l.maxX; hi = r.minX }
                if hi > lo { notch = NotchSpan(minXPt: lo, maxXPt: hi) }
            }
            return DisplaySnapshot(displayID: did, cgBounds: CGDisplayBounds(did),
                                   appKitFrame: s.frame, scale: s.backingScaleFactor, notch: notch)
        }
    }

    private func pushDisplays() {
        engine.setDisplays(snapshotDisplays())
        tintOverlay.refreshFrames()
    }

    /// Hand the resolved theme to both paths — each is a no-op while inactive.
    private func pushTheme() {
        let t = currentTheme()
        engine.setTheme(t)
        tintOverlay.apply(t)
    }

    private func currentTheme() -> MirrorTheme {
        let spec = followAppearance ? slotSpec(systemIsDark ? .dark : .light) : editingSpec()
        return MirrorTheme(bg: spec.bg, bg2: spec.bg2, bgMid: spec.bgMid,
                           gradient: spec.gradient, fg: spec.fg,
                           desktopTint: desktopTint, boostFaint: boostFaint,
                           coloredIcons: coloredIcons, notchFade: notchFade,
                           showInScreenshots: showInScreenshots)
    }

    func applyTheme() {
        let d = UserDefaults.standard
        let spec = editingSpec()
        if followAppearance {
            saveSlotSpec(spec, for: editingSlot)
        } else {
            d.set([spec.bg.x, spec.bg.y, spec.bg.z], forKey: kBG)
            d.set([spec.fg.x, spec.fg.y, spec.fg.z], forKey: kFG)
            d.set([spec.bg2.x, spec.bg2.y, spec.bg2.z], forKey: kBG2)
            d.set(spec.gradient, forKey: kGradient)
            let m = rgb(bgMidColor)
            d.set([m.x, m.y, m.z], forKey: kBGMid)
            d.set(threeColorOn, forKey: kThreeColor)
        }
        d.set(desktopTint, forKey: kTint)
        d.set(boostFaint, forKey: kBoost)
        d.set(showInScreenshots, forKey: kShots)
        d.set(coloredIcons.rawValue, forKey: kColoredIcons)
        d.set(notchFade, forKey: kNotchFade)
        pushTheme()
    }

    // MARK: Appearance slots

    private func slotKey(_ s: AppearanceSlot) -> String { s == .light ? kThemeLight : kThemeDark }

    private func storedSlot(_ s: AppearanceSlot) -> ThemeSpec? {
        guard let data = UserDefaults.standard.data(forKey: slotKey(s)) else { return nil }
        return try? JSONDecoder().decode(ThemeSpec.self, from: data)
    }

    private func slotSpec(_ s: AppearanceSlot) -> ThemeSpec { storedSlot(s) ?? editingSpec() }

    private func saveSlotSpec(_ spec: ThemeSpec, for s: AppearanceSlot) {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        UserDefaults.standard.set(data, forKey: slotKey(s))
    }

    private func editingSpec() -> ThemeSpec {
        ThemeSpec(bg: rgb(bgColor), bgMid: threeColorOn ? rgb(bgMidColor) : nil,
                  bg2: rgb(bg2Color), gradient: gradientOn, fg: rgb(fgColor))
    }

    private func loadEditingSurface(_ spec: ThemeSpec) {
        bgColor = color(spec.bg); bg2Color = color(spec.bg2)
        if let m = spec.bgMid { bgMidColor = color(m); threeColorOn = true }
        else { threeColorOn = false }
        gradientOn = spec.gradient; fgColor = color(spec.fg)
    }

    private func appearanceDidChange() {
        let dark = NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        if followAppearance { pushTheme() }
    }

    // MARK: Presets

    func applyPreset(_ spec: ThemeSpec) {
        loadEditingSurface(spec)
        applyTheme()
    }

    /// Save the current colors under `name`. A name that matches an existing
    /// preset (case-insensitively) REPLACES that preset's colors instead of
    /// appending an indistinguishable duplicate swatch.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let i = customPresets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            customPresets[i].name = trimmed   // adopt the typed casing
            customPresets[i].spec = editingSpec()
        } else {
            customPresets.append(CustomPreset(id: UUID(), name: trimmed, spec: editingSpec()))
        }
    }

    /// Whether saving under `name` would replace an existing preset.
    func presetExists(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return customPresets.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func renamePreset(_ preset: CustomPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let i = customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        customPresets[i].name = trimmed
    }

    /// Overwrite the preset's colors with whatever the controls currently show.
    func updatePreset(_ preset: CustomPreset) {
        guard let i = customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        customPresets[i].spec = editingSpec()
    }

    func deletePreset(_ preset: CustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
    }

    /// Back to the colors the app ships with — resets only the surface being
    /// edited (with follow-appearance on, that's the slot the chip shows).
    func resetTheme() {
        loadEditingSurface(ThemeSpec(bg: .init(0.10, 0.11, 0.16), bg2: .init(0.10, 0.11, 0.16),
                                     gradient: false, fg: .init(0.95, 0.95, 0.97)))
        applyTheme()
    }

    // MARK: Settings transfer

    func exportSettings() -> SettingsExportV1.MirrorSettings {
        .init(enabled: enabled, followAppearance: followAppearance, desktopTint: desktopTint,
              boostFaint: boostFaint, showInScreenshots: showInScreenshots,
              coloredIcons: coloredIcons.rawValue,
              notchFade: notchFade,
              style: recolorStyle.rawValue,
              gradient: gradientOn,
              bg: rgb(bgColor), bgMid: threeColorOn ? rgb(bgMidColor) : nil,
              bg2: rgb(bg2Color), fg: rgb(fgColor),
              light: storedSlot(.light), dark: storedSlot(.dark), customPresets: customPresets)
    }

    func importSettings(_ m: SettingsExportV1.MirrorSettings) {
        customPresets = m.customPresets
        if let l = m.light { saveSlotSpec(l, for: .light) }
        if let dk = m.dark { saveSlotSpec(dk, for: .dark) }
        desktopTint = m.desktopTint
        boostFaint = m.boostFaint
        showInScreenshots = m.showInScreenshots
        notchFade = m.notchFade ?? false     // absent in older exports
        if let raw = m.coloredIcons, let mode = ColoredIconMode(rawValue: raw) {
            coloredIcons = mode
        } else if let old = m.keepColors {   // exports from the boolean era
            coloredIcons = old ? .original : .muted
        } else {                             // pre-feature exports
            coloredIcons = .original
        }
        loadEditingSurface(ThemeSpec(bg: m.bg, bgMid: m.bgMid, bg2: m.bg2,
                                     gradient: m.gradient, fg: m.fg))
        followAppearance = m.followAppearance
        // If follow was already on, the didSet skipped — make the editing surface
        // reflect the imported slot rather than the standalone colors.
        if followAppearance { loadEditingSurface(slotSpec(editingSlot)) }
        recolorStyle = RecolorStyle(rawValue: m.style ?? "") ?? .mirror
        enabled = m.enabled          // didSet starts/stops the engine — set last
        applyTheme()
    }

    func start() {
        switch recolorStyle {
        case .mirror:
            permissionGranted = screenCapturePermissionNow()
            engine.setTheme(currentTheme())
            engine.setDisplays(snapshotDisplays())
            engine.start()
        case .tint:
            tintOverlay.apply(currentTheme())
            tintOverlay.start()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stats = self.recolorStyle == .mirror
                    ? self.engine.snapshotStats()
                    : MirrorStats(activeDisplays: self.tintOverlay.activeDisplays)
                self.appearanceDidChange()   // self-heal if both observers miss a flip
                // The permission/background probes cost a capture + full pixel
                // scan each — mirror-only, and only while their notices can be
                // seen. In tint mode the whole point is that nothing ever
                // reads the screen.
                if self.settingsWindowVisible && self.recolorStyle == .mirror { self.refreshChecks() }
            }
        }
    }

    func refreshChecks() {
        permissionGranted = screenCapturePermissionNow()
        menuBarBackgroundOn = menuBarBackgroundOnNow()
    }

    func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        engine.stop()
        tintOverlay.stop()
        statsTimer?.invalidate(); statsTimer = nil
        stats = MirrorStats()
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        permissionGranted = screenCapturePermissionNow()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func rgb(_ c: Color) -> SIMD3<Double> {
    let ns = (NSColor(c).usingColorSpace(.sRGB)) ?? .black
    return SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
}

private func color(_ v: SIMD3<Double>) -> Color {
    Color(red: v.x, green: v.y, blue: v.z)
}
