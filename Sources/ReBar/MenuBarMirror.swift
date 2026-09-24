import AppKit
import SwiftUI
import CoreGraphics
import QuartzCore
import ScreenCaptureKit

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

// MARK: - Route B capture: one-shot ScreenCaptureKit window grabs (no capsule)
//
// macOS 27 keeps the bar's glyphs out of every capturable window — except
// MenuBarAgent's own scene windows, which ScreenCaptureKit can address by
// window even though the window list reports them off-screen. Capturing one of
// those returns the whole live bar — app menus and every system and third-party
// status item — as glyphs on a TRANSPARENT alpha channel. That is strictly
// better input than a composite: no background to subtract, no wallpaper
// bleeding through the matte, and our own overlay can never leak back in
// because the filter only ever sees that one window.
//
// The reason this route exists is the privacy indicator. Measured on 27.2
// (26B5086k): compositing the bar rect lights the small screenshot dot within
// ~0.2 s AND the wide blue "your screen is being observed" capsule after ~11 s
// of continuous capture; an SCK *stream* (display or window) does the same.
// Repeated one-shot SCScreenshotManager calls do NOT raise the capsule — 90 s
// at 10 Hz (611 captures) left it dark, as did 40 s at 10 Hz and 20 s at 5 Hz.
// So this route runs indefinitely with only the small dot, no duty cycling.
// The composite path below stays as the fallback for anything this can't read.

/// Opt-in tracing for the capture routes, off unless
/// `defaults write com.n14395.re-bar mirror.debugLog -bool true`. Writes to
/// ~/Library/Logs/ReBar-mirror.log; used to diagnose Space-switch behaviour,
/// where the interesting events are a second wide and invisible from outside.
private let mirrorDebugLog = UserDefaults.standard.bool(forKey: "mirror.debugLog")
private let mirrorLogURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
    .first?.appendingPathComponent("Logs/ReBar-mirror.log")
private let mirrorLogLock = NSLock()
private func mlog(_ line: @autoclosure () -> String) {
    guard mirrorDebugLog, let url = mirrorLogURL else { return }
    let stamp = String(format: "%.3f ", CACurrentMediaTime())
    let data = Data((stamp + line() + "\n").utf8)
    mirrorLogLock.lock(); defer { mirrorLogLock.unlock() }
    if let fh = try? FileHandle(forWritingTo: url) {
        try? fh.seekToEnd(); try? fh.write(contentsOf: data); try? fh.close()
    } else {
        try? data.write(to: url)
    }
}

/// A mutable cell a detached Task can write and the render queue can read.
private final class LockedValue<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// One MenuBarAgent scene window, ready to capture. SCWindow isn't Sendable;
/// the render queue is the only thing that ever touches this.
private struct AgentWindow: @unchecked Sendable {
    let window: SCWindow
    let windowID: CGWindowID
    let pxWidth: Int
    let pxHeight: Int
}

/// Every MenuBarAgent window whose frame matches this display. They are all
/// flagged off-screen (one per Space, only one of them is the live bar), so the
/// enumeration must explicitly include off-screen windows.
private func agentWindows(displayBounds: CGRect, scale: CGFloat) -> [AgentWindow] {
    let out = LockedValue<[AgentWindow]>([])
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        defer { done.signal() }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return }
        var found: [AgentWindow] = []
        for w in content.windows
        where w.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" {
            let f = w.frame
            guard abs(f.origin.x - displayBounds.origin.x) < 4,
                  abs(f.origin.y - displayBounds.origin.y) < 4,
                  abs(f.width - displayBounds.width) < 4,
                  f.height > 8, f.height < 80 else { continue }
            found.append(AgentWindow(window: w, windowID: w.windowID,
                                     pxWidth: Int((f.width * scale).rounded()),
                                     pxHeight: Int((f.height * scale).rounded())))
        }
        out.value = found
    }
    guard done.wait(timeout: .now() + 2.0) == .success else { return [] }
    return out.value
}

/// One-shot grab of a single agent window. Deliberately NOT an SCStream: an
/// open stream session is what raises the observation capsule, individual
/// screenshot calls are not.
private func captureAgentWindow(_ target: AgentWindow, timeout: Double = 0.6) -> CGImage? {
    let out = LockedValue<CGImage?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        defer { done.signal() }
        let cfg = SCStreamConfiguration()
        cfg.width = target.pxWidth
        cfg.height = target.pxHeight
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.backgroundColor = .clear
        cfg.ignoreShadowsSingleWindow = true
        out.value = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target.window),
            configuration: cfg)
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return out.value
}

/// Per-column ink of a window grab: alpha summed down each column. This is the
/// layout signature used to tell the live Space's window from its siblings.
private func alphaColumnProfile(_ src: [UInt8], w: Int, h: Int) -> [Double] {
    var prof = [Double](repeating: 0, count: w)
    src.withUnsafeBufferPointer { S in
        for y in 0..<h {
            for x in 0..<w { prof[x] += Double(S[(y * w + x) * 4 + 3]) }
        }
    }
    return prof
}

/// The same signature recovered from a composited strip, where glyphs still
/// have to be separated from the bar's own background: per column, how far the
/// middle rows depart from that column's own top/bottom backdrop.
///
/// Deliberately UNTHRESHOLDED. An earlier version only counted departures over
/// 40/255, which quietly made the signature depend on the wallpaper: over a
/// light desktop the bar's white glyphs sit at low contrast, most of their
/// pixels fell under the cut, and the correct window scored 0.66 against the
/// bar it was actually showing. Summing the raw departure scores the right
/// window at 0.99 on light and dark desktops alike (siblings stay ≤0.70).
private func compositeColumnProfile(_ src: [UInt8], w: Int, h: Int) -> [Double] {
    let band = max(4, Int((Double(h) * 0.22).rounded()))
    var prof = [Double](repeating: 0, count: w)
    src.withUnsafeBufferPointer { S in
        for x in 0..<w {
            var back = (0.0, 0.0, 0.0)
            var n = 0.0
            for y in 0..<band {
                let i = (y * w + x) * 4
                back.0 += Double(S[i]); back.1 += Double(S[i+1]); back.2 += Double(S[i+2]); n += 1
            }
            for y in (h - band)..<h {
                let i = (y * w + x) * 4
                back.0 += Double(S[i]); back.1 += Double(S[i+1]); back.2 += Double(S[i+2]); n += 1
            }
            let br = back.0 / n, bg = back.1 / n, bb = back.2 / n
            var sum = 0.0
            for y in band..<(h - band) {
                let i = (y * w + x) * 4
                sum += max(abs(Double(S[i]) - br), max(abs(Double(S[i+1]) - bg), abs(Double(S[i+2]) - bb)))
            }
            prof[x] = sum
        }
    }
    return prof
}

/// How far the composite reference may sit from the agent window's own
/// coordinates and still count as the same layout, in points.
///
/// Needed because CGWindowListCreateImage's composite of the bar is sometimes
/// offset by 3 pt (6 px) from where MenuBarAgent's window draws it — the whole
/// bar after some Space switches, or just one group of items (the third-party
/// block, say) — and stays that way for the whole visit to that Space. It is a
/// quirk of the window-list compositor only: framebuffer screenshots taken at
/// the same moments show the bar exactly where the agent window puts it
/// (27.2, 26B5086k, roughly one Space switch in three). Without the tolerance
/// the correct window scored 0.67 against a composite of itself.
private let agentShiftTolerancePt: CGFloat = 4

/// Ink on the right half of a window grab, in opaque-pixel equivalents. The
/// hosted status items live there, and only the live window has them.
private func rightHalfInk(_ src: [UInt8], w: Int, h: Int) -> Double {
    var sum = 0
    src.withUnsafeBufferPointer { S in
        for y in 0..<h {
            let row = y * w
            for x in (w / 2)..<w { sum += Int(S[(row + x) * 4 + 3]) }
        }
    }
    return Double(sum) / 255.0
}

/// Block-wise, shift-tolerant cosine similarity of two column profiles: the
/// columns are cut into blocks of `block`, each block finds its own best
/// offset within ±`maxShift` (so groups of items that the compositor placed a
/// few px apart still line up), and the per-block dot products and norms are
/// pooled into one score. Also reports the most common offset, for the log.
/// The live window scores ~0.95+ against what is actually on screen; a sibling
/// window showing another Space's menus, or one without the hosted items,
/// stays below ~0.8.
private func profileMatch(_ a: [Double], _ b: [Double], block: Int, maxShift: Int) -> (score: Double, shift: Int) {
    guard a.count == b.count, !a.isEmpty, block > 0 else { return (0, 0) }
    let n = a.count
    var dot = 0.0, na = 0.0, nb = 0.0
    var shiftVotes = [Int: Int]()
    a.withUnsafeBufferPointer { A in
        b.withUnsafeBufferPointer { B in
            var x0 = 0
            while x0 < n {
                let x1 = min(n, x0 + block)
                var best = (score: -1.0, shift: 0, dot: 0.0, na: 0.0, nb: 0.0)
                for s in -maxShift...maxShift {
                    let lo = max(0, x0 + s), hi = min(n, x1 + s)      // a[i] against b[i - s]
                    guard hi > lo else { continue }
                    var d = 0.0, p = 0.0, q = 0.0
                    for i in lo..<hi {
                        let x = A[i], y = B[i - s]
                        d += x * y; p += x * x; q += y * y
                    }
                    let score = (p > 0 && q > 0) ? d / (p * q).squareRoot() : 0
                    if score > best.score { best = (score, s, d, p, q) }
                }
                dot += best.dot; na += best.na; nb += best.nb
                if best.na > 0, best.nb > 0 { shiftVotes[best.shift, default: 0] += 1 }
                x0 = x1
            }
        }
    }
    guard na > 0, nb > 0 else { return (0, 0) }
    let shift = shiftVotes.max { $0.value < $1.value }?.key ?? 0
    return (dot / (na * nb).squareRoot(), shift)
}

/// Per-column backdrop colors (0…1 RGB triples) read from the bar's own
/// material window — a single-window grab, which raises no indicator at all.
/// The window-capture route has no background of its own, so this is where the
/// "tint icons with the desktop's color" option gets its colors.
private func materialBackdropColumns(wid: UInt32, w: Int, h: Int) -> [Double]? {
    guard let img = captureStrip(wid), img.width == w, img.height == h else { return nil }
    let src = drawSource(img)
    let band = max(4, Int((Double(h) * 0.22).rounded()))
    let lo = band, hi = max(band + 1, h - band)
    var cols = [Double](repeating: 0, count: w * 3)
    src.withUnsafeBufferPointer { S in
        for x in 0..<w {
            var r = 0.0, g = 0.0, b = 0.0
            for y in lo..<hi {
                let i = (y * w + x) * 4
                r += Double(S[i]); g += Double(S[i+1]); b += Double(S[i+2])
            }
            let n = Double(hi - lo) * 255.0
            cols[x*3] = r / n; cols[x*3+1] = g / n; cols[x*3+2] = b / n
        }
    }
    return cols
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

// MARK: - Is the menu bar shown right now? (private SkyLight query)
// A full-screen app and the "Automatically hide and show the menu bar" setting
// both slide the bar off the top of its display, but neither leaves a public
// trace the render loop can use: the Window Server "Menubar" window keeps
// reporting on-screen at its usual place in a full-screen Space, and
// MenuBarAgent's scene window still carries every glyph — so the mirror would
// happily paint a themed bar over the full-screen app. WindowServer knows,
// though: SLSIsMenuBarVisibleOnSpace answers for the Space a display is showing
// and tracks the LIVE state, so a hover-reveal of a hidden bar reads as shown
// again (verified on 27.2 in all three states: desktop, full-screen hidden and
// revealed, auto-hide hidden). ~20 µs per call — cheap enough for every tick.
private typealias FnCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
private typealias FnMenuBarVisible = @convention(c) (Int32, UInt64) -> Bool
private let slsManagedDisplayGetCurrentSpace = slsSym(["SLSManagedDisplayGetCurrentSpace"], as: FnCurrentSpace.self)
private let slsIsMenuBarVisibleOnSpace = slsSym(["SLSIsMenuBarVisibleOnSpace"], as: FnMenuBarVisible.self)

/// Whether the menu bar is currently shown on the display with this UUID —
/// false while a full-screen app or the auto-hide setting has it tucked away.
/// `nil` when the query isn't available (unknown; callers should assume shown).
private func menuBarVisible(displayUUID: String) -> Bool? {
    guard !displayUUID.isEmpty, let mainConn = slsMainConnectionID,
          let currentSpace = slsManagedDisplayGetCurrentSpace,
          let visibleOnSpace = slsIsMenuBarVisibleOnSpace else { return nil }
    let cid = mainConn()
    let sid = currentSpace(cid, displayUUID as CFString)
    guard sid != 0 else { return nil }
    return visibleOnSpace(cid, sid)
}

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
/// window NAMES are hidden from CGWindowListCopyWindowInfo without Screen
/// Recording, so being able to find the "Menubar" window by name IS the grant.
/// Note this probe deliberately reads no pixels — it used to capture the bar,
/// which lit the screenshot indicator once a second while Settings was open.
private func screenCapturePermissionNow() -> Bool {
    CGPreflightScreenCaptureAccess()
        || findMenubarWindow(displayBounds: CGDisplayBounds(CGMainDisplayID())) != nil
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

/// Recolor a window-capture frame (Route B), where the glyphs arrive already
/// separated on the alpha channel. Everything the clean-row version has to
/// estimate — the backdrop, the matte, the glyph's own color — is exact here:
/// alpha IS the matte and un-premultiplying by it IS the glyph color. Returns
/// the themed image and the fraction of inked pixels (≈0 ⇒ nothing to show).
private func renderThemedAlpha(src: [UInt8], w: Int, h: Int, theme: MirrorTheme,
                               notchBand: NotchBandPx? = nil,
                               backdrop: [Double]? = nil) -> (CGImage, Double)? {
    guard w > 32, h >= 24, src.count == w * h * 4 else { return nil }
    var out = [UInt8](repeating: 0, count: w * h * 4)
    var inked = 0

    // Background wash and notch fade: identical to the composite path — the
    // difference between the two renderers is only where the glyphs come from.
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
    let fadeMul: [Double]? = notchBand.map { b in
        (0..<w).map { x in
            let d = max(b.minX - Double(x), Double(x) - b.maxX)
            return smoothstep(d / b.fadeWidth)
        }
    }
    let tintCols: [Double]? = (theme.desktopTint && backdrop?.count == w * 3) ? backdrop : nil

    src.withUnsafeBufferPointer { S in
    out.withUnsafeMutableBufferPointer { O in
        // Pass 1 — per-column chroma evidence, same trick as the composite
        // renderer: a column that passes through a colored fill lets the
        // low-chroma pixels inside that fill (the dark digits in the yellow
        // battery pill) keep their own color instead of being repainted.
        var colChroma = [Double](repeating: 0, count: w)
        if theme.coloredIcons == .original {
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let a = Double(S[i+3]) / 255.0
                    guard a >= 0.5 else { continue }
                    let gr = min(1.0, Double(S[i])   / 255.0 / a)
                    let gg = min(1.0, Double(S[i+1]) / 255.0 / a)
                    let gb = min(1.0, Double(S[i+2]) / 255.0 / a)
                    let chroma = max(gr, max(gg, gb)) - min(gr, min(gg, gb))
                    if chroma > colChroma[x] { colChroma[x] = chroma }
                }
            }
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let aRaw = Double(S[i+3]) / 255.0
                if aRaw > 0.03 { inked += 1 }
                var a = aRaw
                if theme.boostFaint { a = a.squareRoot() }

                var base = colBG?[x] ?? theme.bg
                if let f = fadeMul { base *= f[x] }

                var cr = theme.fg.x, cg = theme.fg.y, cb = theme.fg.z
                if let tint = tintCols {
                    let br = tint[x*3], bg = tint[x*3+1], bb = tint[x*3+2]
                    if 0.2126*base.x + 0.7152*base.y + 0.0722*base.z > 0.55 {
                        cr = 0.35*br; cg = 0.35*bg; cb = 0.35*bb
                    } else {
                        cr = 0.5 + 0.5*br; cg = 0.5 + 0.5*bg; cb = 0.5 + 0.5*bb
                    }
                }

                if theme.coloredIcons != .themed, aRaw > 0.12 {
                    let ar = max(aRaw, 0.25)
                    let gr = min(1.0, Double(S[i])   / 255.0 / ar)
                    let gg = min(1.0, Double(S[i+1]) / 255.0 / ar)
                    let gb = min(1.0, Double(S[i+2]) / 255.0 / ar)
                    let chroma = max(gr, max(gg, gb)) - min(gr, min(gg, gb))
                    let kPix = smoothstep((chroma - 0.18) / 0.17)
                    let edge = smoothstep((aRaw - 0.12) / 0.15)
                    if theme.coloredIcons == .original {
                        let kCol = smoothstep((colChroma[x] - 0.25) / 0.20)
                        let k = max(kPix, kCol) * edge
                        if k > 0 { cr += k * (gr - cr); cg += k * (gg - cg); cb += k * (gb - cb) }
                    } else {
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
    return (outImg, Double(inked) / Double(w * h))
}

// MARK: - Display snapshot (captured on main, read on the render queue)

/// The notch's horizontal span in points from the display's LEFT edge.
struct NotchSpan: Sendable, Equatable {
    let minXPt: CGFloat
    let maxXPt: CGFloat
}

struct DisplaySnapshot: Sendable {
    let displayID: CGDirectDisplayID
    let uuid: String           // CGDisplayCreateUUIDFromDisplayID; "" if unavailable
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

struct MirrorStats: Sendable {
    var activeDisplays = 0
    /// Displays whose menu bar is currently hidden (full-screen app or the
    /// auto-hide setting) — the overlay stands down there until it returns.
    var hiddenDisplays = 0
    /// True while at least one display is being read through the window-capture
    /// route — the path that carries glyphs without the observation capsule.
    var windowCapture = false
}

/// Which path the mirror reads the bar with. `auto` (the default) prefers the
/// window-capture route and falls back to the composite whenever that can't
/// produce a frame; the other two pin one path, for troubleshooting via
/// `defaults write com.n14395.re-bar mirror.captureRoute window|composite|auto`.
enum CaptureRoute: String, Sendable {
    case auto, window, composite
    static var preferred: CaptureRoute {
        CaptureRoute(rawValue: UserDefaults.standard.string(forKey: "mirror.captureRoute") ?? "") ?? .auto
    }
}

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
    // Set under `lock` when the chosen agent windows must be picked again from
    // scratch (display change, restart); consumed by the next tick.
    private var agentInvalidate = true
    // Set under `lock` when the live bar has probably moved to another of
    // MenuBarAgent's per-Space windows (a Space switch). Unlike the flag above
    // this keeps the current window on screen — it only forces an immediate
    // check, so a mid-transition tick can't pick a wrong window out of a
    // reference that isn't capturable yet.
    private var agentRecheck = false

    // Damage-gate state: render-queue-only (touched exclusively inside tick(),
    // which runs solely on `q`), so no locking needed.
    private struct RenderKey: Equatable {
        let theme: MirrorTheme
        let band: NotchBandPx?
        let w: Int
        let h: Int
        let fromWindow: Bool
    }
    private var lastHash: [CGDirectDisplayID: UInt64] = [:]
    private var lastKey: [CGDirectDisplayID: RenderKey] = [:]
    private var ticksSinceRender: [CGDirectDisplayID: Int] = [:]
    private var lastGen: [CGDirectDisplayID: Int] = [:]
    // Displays whose bar was hidden (full-screen / auto-hide) on the last tick.
    private var barHidden: Set<CGDirectDisplayID> = []
    // Cached Menubar-window resolution per display: the full window-list walk is
    // the priciest part of an idle tick, so between periodic re-resolutions we
    // only ask "is that window still on screen?" (a one-window query).
    private var barCache: [CGDirectDisplayID: (wid: UInt32, rect: CGRect)] = [:]
    private var barCacheAge: [CGDirectDisplayID: Int] = [:]
    // Window-capture route state, also render-queue-only: which MenuBarAgent
    // scene window each display is read from and how it was chosen (see readBar).
    private enum AgentPick { case ink, composite }
    private var agentWin: [CGDirectDisplayID: AgentWindow] = [:]
    // The display's MenuBarAgent windows, kept between resolves: their IDs are
    // stable for the life of the agent, and re-enumerating costs ~70 ms that a
    // Space switch can't spare.
    private var agentPool: [CGDirectDisplayID: [AgentWindow]] = [:]
    private var agentEnumAt: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var agentMode: [CGDirectDisplayID: AgentPick] = [:]
    // Right-half ink the chosen window is expected to carry; a large drop means
    // the hosted items have moved to another window.
    private var agentInk: [CGDirectDisplayID: Double] = [:]
    // What a hot window carries on this display, and when each window was last
    // the hot one — together they let a re-pick stop at the first grab.
    private var agentHotLevel: [CGDirectDisplayID: Double] = [:]
    private var agentLastHot: [CGWindowID: CFTimeInterval] = [:]
    // Next routine check against the real bar, and consecutive misses so far.
    private var agentCheckAt: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var agentFails: [CGDirectDisplayID: Int] = [:]
    // Space-switch settling: until when, and which window we were on before it.
    private var agentSettleUntil: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var agentPrev: [CGDirectDisplayID: CGWindowID] = [:]
    // Backoff after a failed pick (or a machine where the route can't work),
    // consecutive failed picks, and consecutive failed grabs of the current pick.
    private var agentRetryAt: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var agentResolveFails: [CGDirectDisplayID: Int] = [:]
    private var agentGrabFails: [CGDirectDisplayID: Int] = [:]
    // Per-column backdrop colors for the desktop-tint option (window route only).
    private var tintCols: [CGDirectDisplayID: [Double]] = [:]
    private var tintAge: [CGDirectDisplayID: Int] = [:]
    private let route = CaptureRoute.preferred
    /// How long after a Space switch the previous window stays suspect.
    private let agentSettleTime: CFTimeInterval = 2.0
    /// When, after a Space switch or a fresh pick during one, the pick is
    /// verified against the screen: late enough for the transition and the
    /// agent's item move to be over, early enough that a wrong bar barely shows.
    private let agentSettleVerify: CFTimeInterval = 0.6
    /// Routine verification cadence. Wall clock, not ticks — the adaptive
    /// cadence must not stretch it. Each check is a single composite frame,
    /// nowhere near the ~11 s of continuous capture that raises the capsule.
    /// An ink-picked window has its own continuous signal, so it needs less.
    private let agentCheckInterval: CFTimeInterval = 5
    private let agentCheckIntervalComposite: CFTimeInterval = 3
    /// Follow-up after a single failed check (one miss may be a blend).
    private let agentRecheckSoon: CFTimeInterval = 0.4
    /// Retry delays: a check that couldn't run (bar mid-transition), a pick that
    /// found nothing convincing, and a display with no agent windows at all.
    private let agentRetryInterval: CFTimeInterval = 0.3
    private let agentUnavailableRetry: CFTimeInterval = 5
    /// Ink lead that marks the live window (measured ~3–4×), and the fraction of
    /// its ink below which the items have evidently left.
    private let agentHotRatio = 1.5
    private let agentInkDrop = 0.6
    /// Below this the "hot" window has nothing on it (a hidden bar), so ink
    /// says nothing and the layout match decides.
    private let agentMinInk = 50.0
    /// A window carrying this share of the known hot level is the live one —
    /// no need to grab the rest of the pool.
    private let agentEarlyExit = 0.75
    /// A re-pick first grabs only this many windows (most recently hot first).
    /// If none carries the items the move is probably still in flight, so it
    /// waits agentTransitRetry and looks again before scanning everything.
    private let agentQuickScan = 3
    private let agentTransitRetry: CFTimeInterval = 0.15
    /// Consecutive failed grabs of the current window before it is given up —
    /// a single failure is routine in the middle of a Space transition.
    private let agentGrabFailLimit = 3
    /// Layout-match thresholds (block-wise, shift-tolerant cosine): a check
    /// passes above the first; a composite-based pick needs the second and a
    /// lead over the runner-up. Siblings measure ≤0.78 even mid-transition.
    private let agentPassScore = 0.80
    private let agentMatchScore = 0.85
    private let agentLeadMargin = 0.08
    /// Block width for the layout match, in points: one group of items.
    private let agentBlockPt: CGFloat = 128
    private func agentShiftPx(_ scale: CGFloat) -> Int { Int((agentShiftTolerancePt * scale).rounded()) }
    private func agentBlockPx(_ scale: CGFloat) -> Int { max(32, Int((agentBlockPt * scale).rounded())) }

    /// Ticks between desktop-tint backdrop refreshes (~2 s at 20 Hz).
    private let tintRefreshTicks = 40
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
        lock.lock(); displays = d; renderGen += 1; agentInvalidate = true; lock.unlock()
        let keep = Set(d.map(\.displayID))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.prunePanels(keeping: keep) } }
    }
    func snapshotStats() -> MirrorStats { lock.lock(); defer { lock.unlock() }; return stats }

    func start() {
        lock.lock(); isActive = true; renderGen += 1; agentInvalidate = true; lock.unlock()
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
        mlog("=== space changed ===")
        // The live bar moves to another of MenuBarAgent's per-Space windows, so
        // the window-capture route has to re-check its target right away.
        lock.lock(); renderGen += 1; agentRecheck = true; lock.unlock()
        frontBoostUntil = CACurrentMediaTime() + 0.5
        for p in panels.values { pinWindowToAllSpaces(p.windowNumber) }   // catch newly-created Spaces
        q.async { [weak self] in self?.tick() }
    }

    private func tick() {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        let t = theme, ds = displays, gen = renderGen
        let dropAgents = agentInvalidate
        let recheckAgents = agentRecheck
        agentInvalidate = false
        agentRecheck = false
        lock.unlock()
        guard !ds.isEmpty else { return }
        if dropAgents {
            agentWin.removeAll(); agentPool.removeAll(); agentInk.removeAll(); agentMode.removeAll()
            agentCheckAt.removeAll(); agentFails.removeAll(); agentSettleUntil.removeAll()
            agentPrev.removeAll(); agentRetryAt.removeAll(); agentEnumAt.removeAll()
            agentHotLevel.removeAll(); agentLastHot.removeAll()
            agentResolveFails.removeAll(); agentGrabFails.removeAll()
        } else if recheckAgents {
            // Space switch: the items will move to another window shortly. Show
            // the screen until they do, verify the new pick soon after.
            let now = CACurrentMediaTime()
            for (did, win) in agentWin {
                agentSettleUntil[did] = now + agentSettleTime
                agentPrev[did] = win.windowID
                agentCheckAt[did] = now + agentSettleVerify
                agentFails[did] = 0
            }
        }

        var active = 0
        var hidden = 0
        var anyWork = false      // false ⇔ every display took the unchanged-skip path
        var windowRoute = false  // true ⇔ some display read the bar without the capsule
        for d in ds {
            let did = d.displayID, frame = d.appKitFrame, scale = d.scale, show = t.showInScreenshots

            // The bar is hidden here — a full-screen app, or the auto-hide setting
            // — so there is nothing to mirror: take the overlay down at once and
            // skip the capture. (The capture would otherwise succeed: the agent
            // window keeps its glyphs while off the top of the screen.) The
            // moment the bar is back, including a hover-reveal, render in full.
            if menuBarVisible(displayUUID: d.uuid) == false {
                if barHidden.insert(did).inserted {
                    mlog("bar hidden on display \(did) -> overlay down")
                    anyWork = true
                }
                hidden += 1
                lastHash[did] = nil        // first frame after the reveal is a full render
                DispatchQueue.main.async { MainActor.assumeIsolated { self.hideForHiddenBar(did: did) } }
                continue
            }
            if barHidden.remove(did) != nil {
                mlog("bar shown on display \(did) -> overlay back")
                anyWork = true
            }

            // Resolve the bar window — from cache when it's fresh and still on
            // screen (Space switches retire the old per-Space window, which the
            // liveness probe catches), with a periodic full re-resolve. This is
            // metadata only: it answers "is a menu bar on screen here", which
            // drives the hold/hide decisions, and gives the fallback its rect.
            var bar = barCache[did]
            if let c = bar, (barCacheAge[did] ?? .max) < 24, menubarWindowOnscreen(c.wid) {
                barCacheAge[did]! += 1
            } else {
                bar = findMenubarWindow(displayBounds: d.cgBounds)
                barCache[did] = bar
                barCacheAge[did] = 0
            }
            let barExists = bar != nil

            // Read the bar: window route when it can be trusted, composite
            // otherwise (see readBar).
            guard let read = readBar(for: d, bar: bar) else {
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
            let src = read.src, w = read.w, h = read.h, fromWindow = read.fromWindow
            if fromWindow { windowRoute = true }

            let band: NotchBandPx? = (t.notchFade && d.notch != nil)
                ? NotchBandPx(minX: Double(d.notch!.minXPt * d.scale),
                              maxX: Double(d.notch!.maxXPt * d.scale),
                              fadeWidth: 48.0 * Double(d.scale))
                : nil

            // A window grab has no background of its own, so the desktop-tint
            // option reads its colors from the bar's material window instead —
            // a single-window grab, which raises no indicator at all. Wallpaper
            // changes slowly; refreshing it every ~2 s is plenty.
            var backdrop: [Double]? = nil
            if fromWindow, t.desktopTint {
                if (tintAge[did] ?? .max) >= tintRefreshTicks || tintCols[did]?.count != w * 3 {
                    tintCols[did] = bar.flatMap { materialBackdropColumns(wid: $0.wid, w: w, h: h) }
                    tintAge[did] = 0
                    lastHash[did] = nil        // fresh colors must defeat the damage gate
                } else {
                    tintAge[did]! += 1
                }
                backdrop = tintCols[did]
            }

            // Damage gate: hash a sparse sample of the normalized bytes and skip
            // the recolor passes + main-thread push when the bar, theme, and
            // geometry are all unchanged. A periodic forced render backstops
            // anything a sparse sample could alias past.
            let hash = sampleHash(src)
            let key = RenderKey(theme: t, band: band, w: w, h: h, fromWindow: fromWindow)
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
            let rendered = fromWindow
                ? renderThemedAlpha(src: src, w: w, h: h, theme: t, notchBand: band, backdrop: backdrop)
                : renderThemed(src: src, w: w, h: h, theme: t, notchBand: band)
            if let (out, ink) = rendered, ink > 0.002 {
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
        stats = MirrorStats(activeDisplays: active, hiddenDisplays: hidden, windowCapture: windowRoute)
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

    /// Read one display's menu bar for this frame.
    ///
    /// Prefers the window route — MenuBarAgent's own scene window, glyphs on
    /// alpha, no observation capsule. Which of the agent's per-Space windows is
    /// the live one is decided by INK, not by matching against the screen: the
    /// agent hosts every third-party status item in exactly one window at a
    /// time, the active Space's, so that window carries far more ink on its
    /// right half than its siblings (measured ~9k vs ~2–3k opaque-pixel
    /// equivalents; the mapping holds for the whole visit to a Space, and
    /// repeatedly capturing every window does not disturb it). The composite of
    /// the real bar is the fallback and an occasional sanity check only — it is
    /// a poor judge: the window-list compositor can place whole groups of
    /// glyphs 3 pt off from where the agent window draws them (see
    /// agentShiftTolerancePt), and for ~0.5 s around a Space switch it shows a
    /// blend of two bars, which is exactly when a check is most tempting.
    ///
    /// After a Space switch the agent moves the items to the new Space's window
    /// a few hundred ms after the switch is announced. Until the chosen window
    /// loses its ink the screen is the truth, so those frames come from the
    /// composite; the moment it drops, the pool is scanned and the new hot
    /// window adopted and painted straight away.
    private func readBar(for d: DisplaySnapshot,
                         bar: (wid: UInt32, rect: CGRect)?)
                         -> (src: [UInt8], w: Int, h: Int, fromWindow: Bool)? {
        let did = d.displayID
        let overlay = overlayID(for: did)
        func composite() -> (src: [UInt8], w: Int, h: Int, fromWindow: Bool)? {
            guard let b = bar,
                  let img = captureBarComposite(rect: b.rect, wid: b.wid, belowWindow: overlay),
                  img.width > 32, img.height >= 24 else { return nil }
            return (drawSource(img), img.width, img.height, false)
        }
        func painted(_ img: CGImage) -> (src: [UInt8], w: Int, h: Int, fromWindow: Bool) {
            (drawSource(img), img.width, img.height, true)
        }
        guard route != .composite, let b = bar else { return composite() }
        let now = CACurrentMediaTime()

        if agentWin[did] == nil {
            guard now >= (agentRetryAt[did] ?? 0) else { return composite() }
            if let pick = resolveAgentWindow(for: d, bar: b, reference: nil) { return painted(pick.image) }
            return composite()
        }
        guard let cand = agentWin[did], let img = captureAgentWindow(cand),
              img.width > 32, img.height >= 24 else {
            let fails = (agentGrabFails[did] ?? 0) + 1
            agentGrabFails[did] = fails
            mlog("grab failed wid=\(agentWin[did]?.windowID ?? 0) (\(fails))")
            if fails >= agentGrabFailLimit { agentWin[did] = nil }
            return composite()
        }
        agentGrabFails[did] = 0
        let src = drawSource(img)
        let w = img.width, h = img.height
        let ink = rightHalfInk(src, w: w, h: h)

        // The hosted items have left this window: it is no longer the live bar.
        // (Only meaningful for an ink-picked window; a bar with no third-party
        // items has nothing to lose.)
        if agentMode[did] == .ink {
            let level = agentInk[did] ?? 0
            if ink < agentInkDrop * level {
                mlog("ink drop wid=\(cand.windowID) \(Int(ink)) < \(Int(level)) -> re-pick")
                agentPrev[did] = cand.windowID         // scan the window we are leaving last
                if let pick = resolveAgentWindow(for: d, bar: b, reference: nil) { return painted(pick.image) }
                return composite()
            }
            // Track the level a drop is judged against: follows increases at
            // once, decays back from a transient (an open menu's highlight).
            agentInk[did] = max(ink, level * 0.98)
        }

        // Settling after a Space switch and still on the window we had before
        // it: the agent may not have moved the items yet, so show the screen.
        // (No composite mid-transition → keep the window rather than go blank.)
        let settling = now < (agentSettleUntil[did] ?? 0)
        if settling, cand.windowID == agentPrev[did], now < (agentCheckAt[did] ?? 0),
           let screen = composite() {
            return screen
        }

        // Routine sanity check against the real bar (plus the early one that
        // ends a settle). One miss is not evidence — the composite may be a
        // mid-transition blend — two in a row are.
        if now >= (agentCheckAt[did] ?? 0) {
            guard let ref = captureBarComposite(rect: b.rect, wid: b.wid, belowWindow: overlay),
                  ref.width == w, ref.height == h else {
                agentCheckAt[did] = now + agentRetryInterval
                return (src, w, h, true)
            }
            let refSrc = drawSource(ref)
            let refProfile = compositeColumnProfile(refSrc, w: w, h: h)
            let match = profileMatch(alphaColumnProfile(src, w: w, h: h), refProfile,
                                     block: agentBlockPx(d.scale), maxShift: agentShiftPx(d.scale))
            let fails = match.score >= agentPassScore ? 0 : (agentFails[did] ?? 0) + 1
            agentFails[did] = fails
            mlog("check wid=\(cand.windowID) score=\(String(format: "%.3f", match.score)) shift=\(match.shift) mode=\(agentMode[did].map { "\($0)" } ?? "?") fails=\(fails)")
            if fails == 0 {
                agentSettleUntil[did] = 0
                agentCheckAt[did] = now + (agentMode[did] == .ink ? agentCheckInterval
                                                                  : agentCheckIntervalComposite)
                return (src, w, h, true)
            }
            if fails < 2 {
                agentCheckAt[did] = now + agentRecheckSoon
                return settling ? (refSrc, w, h, false) : (src, w, h, true)
            }
            if let pick = resolveAgentWindow(for: d, bar: b, reference: refProfile) { return painted(pick.image) }
            return (refSrc, w, h, false)
        }
        return (src, w, h, true)
    }

    /// Pick this display's live agent window, and return its first frame so
    /// the caller can paint it without a second grab.
    ///
    /// Ink first: the window carrying the hosted status items is the live one
    /// (agentHotRatio ahead of the runner-up). Two windows that both stand out
    /// mean the items are mid-move; the destination is whichever one we were
    /// not showing. If no window stands out — a bar with no third-party items —
    /// each candidate's glyph layout is matched against the composite reference
    /// instead (block-wise, shift-tolerant). Re-enumerates the pool when nothing
    /// convinces: the agent creates and retires these windows as Spaces come
    /// and go. On failure the pick is cleared and retried after a short delay.
    private func resolveAgentWindow(for d: DisplaySnapshot,
                                    bar: (wid: UInt32, rect: CGRect),
                                    reference: [Double]?) -> (window: AgentWindow, image: CGImage)? {
        let did = d.displayID
        let now = CACurrentMediaTime()
        struct Scanned { let window: AgentWindow; let image: CGImage; let src: [UInt8]; let ink: Double }

        // Scan order: most recently hot first (two Spaces the user flips between
        // then cost one grab each), the window we are leaving last. With a known
        // hot level the scan stops at the first window that clearly carries the
        // items instead of grabbing all eleven.
        let prev = agentPrev[did] ?? agentWin[did]?.windowID
        let hotLevel = agentHotLevel[did] ?? 0
        func ordered(_ pool: [AgentWindow]) -> [AgentWindow] {
            pool.sorted { a, b in
                if a.windowID == prev { return false }
                if b.windowID == prev { return true }
                return (agentLastHot[a.windowID] ?? 0) > (agentLastHot[b.windowID] ?? 0)
            }
        }
        func scan(_ pool: [AgentWindow]) -> [Scanned] {
            var out: [Scanned] = []
            for c in ordered(pool) {
                guard let img = captureAgentWindow(c), img.width > 32, img.height >= 24 else { continue }
                let src = drawSource(img)
                let s = Scanned(window: c, image: img, src: src,
                                ink: rightHalfInk(src, w: img.width, h: img.height))
                out.append(s)
                if hotLevel > 0, c.windowID != prev, s.ink >= agentEarlyExit * hotLevel { break }
            }
            return out.sorted { $0.ink > $1.ink }
        }
        func adopt(_ s: Scanned, _ mode: AgentPick) -> (window: AgentWindow, image: CGImage) {
            agentWin[did] = s.window
            agentInk[did] = s.ink
            agentMode[did] = mode
            agentFails[did] = 0
            agentResolveFails[did] = 0
            agentGrabFails[did] = 0
            if mode == .ink { agentHotLevel[did] = s.ink; agentLastHot[s.window.windowID] = now }
            let settling = now < (agentSettleUntil[did] ?? 0)
            agentCheckAt[did] = now + (settling ? agentSettleVerify
                                       : mode == .ink ? agentCheckInterval : agentCheckIntervalComposite)
            mlog("adopt wid=\(s.window.windowID) mode=\(mode) ink=\(Int(s.ink))")
            return (s.window, s.image)
        }

        var refProfile = reference
        func decide(_ scanned: [Scanned]) -> (window: AgentWindow, image: CGImage)? {
            guard let top = scanned.first else { return nil }
            if top.ink >= agentMinInk {
                let second = scanned.count > 1 ? scanned[1] : nil
                guard let second else { return adopt(top, .ink) }
                if top.ink >= agentHotRatio * second.ink { return adopt(top, .ink) }
                if scanned.count > 2, second.ink >= agentHotRatio * scanned[2].ink, let prev {
                    if top.window.windowID == prev { return adopt(second, .ink) }
                    if second.window.windowID == prev { return adopt(top, .ink) }
                }
            }
            // No ink signal: match layouts against the real bar.
            if refProfile == nil,
               let ref = captureBarComposite(rect: bar.rect, wid: bar.wid, belowWindow: overlayID(for: did)) {
                refProfile = compositeColumnProfile(drawSource(ref), w: ref.width, h: ref.height)
            }
            guard let refProfile else { return nil }
            var best: (s: Scanned, score: Double)? = nil
            var runnerUp = 0.0
            for s in scanned {
                let profile = alphaColumnProfile(s.src, w: s.image.width, h: s.image.height)
                guard profile.count == refProfile.count else { continue }
                let score = profileMatch(profile, refProfile, block: agentBlockPx(d.scale),
                                         maxShift: agentShiftPx(d.scale)).score
                if best == nil || score > best!.score { runnerUp = best?.score ?? 0; best = (s, score) }
                else if score > runnerUp { runnerUp = score }
            }
            if let best, best.score >= agentMatchScore, best.score - runnerUp >= agentLeadMargin {
                return adopt(best.s, .composite)
            }
            mlog("no convincing window: ink \(Int(top.ink))/\(Int(scanned.count > 1 ? scanned[1].ink : 0)), best match \(String(format: "%.3f", best?.score ?? 0)) vs \(String(format: "%.3f", runnerUp))")
            return nil
        }

        var pool = agentPool[did] ?? []
        var enumerated = false
        if pool.isEmpty {
            pool = agentWindows(displayBounds: d.cgBounds, scale: d.scale)
            agentPool[did] = pool
            agentEnumAt[did] = now
            enumerated = true
            mlog("enumerated \(pool.count) agent windows")
        }
        let streak = agentResolveFails[did] ?? 0
        // Quick tier: the most recently hot windows first. If none of them
        // carries the items on the first try, the move is probably in flight —
        // a moment's wait beats grabbing all eleven.
        if hotLevel > 0, streak == 0, !enumerated, pool.count > agentQuickScan {
            let quick = scan(Array(ordered(pool).prefix(agentQuickScan)))
            if let top = quick.first, top.window.windowID != prev, top.ink >= agentEarlyExit * hotLevel {
                return adopt(top, .ink)
            }
            mlog("quick scan: no hot window (best \(Int(quick.first?.ink ?? 0)) of \(Int(hotLevel))) -> retry")
            agentResolveFails[did] = 1
            agentWin[did] = nil
            agentRetryAt[did] = now + agentTransitRetry
            return nil
        }
        if let pick = decide(scan(pool)) { return pick }
        // Still nothing. The pool may be stale (Spaces come and go); once the
        // miss has repeated, look again — but not more than once a second.
        if !enumerated, streak >= 1, now - (agentEnumAt[did] ?? 0) >= 1.0 {
            pool = agentWindows(displayBounds: d.cgBounds, scale: d.scale)
            agentPool[did] = pool
            agentEnumAt[did] = now
            mlog("re-enumerated \(pool.count) agent windows")
            if let pick = decide(scan(pool)) { return pick }
        }
        agentResolveFails[did] = streak + 1
        agentWin[did] = nil
        agentRetryAt[did] = now + (pool.isEmpty ? agentUnavailableRetry : agentRetryInterval)
        return nil
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

    /// The bar is hidden on this display (full-screen / auto-hide): no grace
    /// period — WindowServer said so, there is no capture hiccup to wait out.
    @MainActor private func hideForHiddenBar(did: CGDirectDisplayID) {
        panels[did]?.orderOut(nil)
        lastGoodTime[did] = nil
        blackSince[did] = nil
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
            let uuid = CGDisplayCreateUUIDFromDisplayID(did).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? ""
            return DisplaySnapshot(displayID: did, uuid: uuid, cgBounds: CGDisplayBounds(did),
                                   appKitFrame: s.frame, scale: s.backingScaleFactor, notch: notch)
        }
    }

    private func pushDisplays() {
        engine.setDisplays(snapshotDisplays())
    }

    /// Hand the resolved theme to the engine — a no-op while it is inactive.
    private func pushTheme() {
        engine.setTheme(currentTheme())
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
        enabled = m.enabled          // didSet starts/stops the engine — set last
        applyTheme()
    }

    func start() {
        permissionGranted = screenCapturePermissionNow()
        engine.setTheme(currentTheme())
        engine.setDisplays(snapshotDisplays())
        engine.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stats = self.engine.snapshotStats()
                self.appearanceDidChange()   // self-heal if both observers miss a flip
                // The permission/background probes cost a capture + full pixel
                // scan each — only run them while their notices can be seen.
                if self.settingsWindowVisible { self.refreshChecks() }
            }
        }
    }

    func refreshChecks() {
        permissionGranted = screenCapturePermissionNow()
        // "Show menu bar background" only matters to the composite route, which
        // has to separate glyphs from the bar's own backdrop. The window route
        // gets glyphs on alpha straight from MenuBarAgent, so a transparent bar
        // is fine there — don't nag about a setting that no longer applies.
        menuBarBackgroundOn = stats.windowCapture ? true : menuBarBackgroundOnNow()
    }

    func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        engine.stop()
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
