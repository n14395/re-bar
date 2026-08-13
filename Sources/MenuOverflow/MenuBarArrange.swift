import AppKit
import SwiftUI

// MARK: - Rearranging third-party menu bar items (position-store backend)
//
// macOS 27's authoritative item order lives in com.apple.MenuBarAgent's
// TrailingItemPreferredPositions dict: "status:<signing-id>::<autosave>" → x,
// where a LARGER trailing offset sits further LEFT. The store is plain user
// prefs: rewrite the positions and restart MenuBarAgent (KeepAlive relaunches
// it, the bar repopulates in a few seconds) and items land per the store —
// live-proven; written values survive, the agent doesn't fight back.
// Only `status:` (third-party) keys are touched; `module:` (system) never.

struct ArrangeItem: Identifiable, Equatable {
    let storeKey: String
    let appName: String
    let icon: NSImage?
    let autosave: String
    let trailing: Double
    let showsAutosave: Bool
    var isSystem = false
    var isInactiveCapable = false   // may hold a bar slot while not currently drawn
    var isRunning = true            // false: installed app, item parked until it launches
    var bundleURL: URL? = nil       // resolvable only for not-running rows
    var id: String { storeKey }
    static func == (l: Self, r: Self) -> Bool { l.storeKey == r.storeKey }
}

@MainActor @Observable
final class ArrangeController {
    var items: [ArrangeItem] = []
    private(set) var applying = false
    private var baseline: [String] = []

    var dirty: Bool { items.map(\.id) != baseline }

    private static let domain = "com.apple.MenuBarAgent"
    private static let storeKey = "TrailingItemPreferredPositions"

    static func readStore() -> [String: Any] {
        (CFPreferencesCopyValue(storeKey as CFString, domain as CFString,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]) ?? [:]
    }

    /// The store keys by code-signing identifier, which is variously the bundle
    /// id, a team-id-prefixed bundle id, or a bare executable name — match all.
    static func match(token: String, in apps: [NSRunningApplication]) -> NSRunningApplication? {
        apps.first { a in
            if let b = a.bundleIdentifier, b == token || token.hasSuffix(b) { return true }
            if a.localizedName == token { return true }
            if a.executableURL?.lastPathComponent == token { return true }
            return false
        }
    }

    /// Resolve a store token to an installed app's bundle URL — reverse-DNS
    /// tokens only, trying the raw token and the team-ID-stripped spelling.
    static func bundleURL(for token: String) -> URL? {
        guard token.contains("."), !token.hasPrefix("com.apple.") else { return nil }
        var ids = [token]
        let comps = token.split(separator: ".", maxSplits: 1)
        if comps.count == 2, comps[0].wholeMatch(of: /[A-Z0-9]{10}/) != nil {
            ids.append(String(comps[1]))
        }
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    // System modules that ARE ⌘-draggable get friendly names + symbols; the
    // clock and Control Center (BentoBox) are pinned by macOS and stay excluded.
    private static let moduleNames: [String: (String, String)] = [
        "WiFi": ("Wi-Fi", "wifi"),
        "Bluetooth": ("Bluetooth", "dot.radiowaves.left.and.right"),
        "Battery": ("Battery", "battery.75"),
        "Sound": ("Sound", "speaker.wave.2.fill"),
        "AudioVideoModule": ("Audio & Video", "video.fill"),
        "UserSwitcher": ("Fast User Switching", "person.crop.circle"),
        "Focus": ("Focus", "moon.fill"),
        "NowPlaying": ("Now Playing", "play.circle"),
        "ScreenMirroring": ("Screen Mirroring", "rectangle.on.rectangle"),
        "Display": ("Display", "sun.max"),
        "KeyboardBrightness": ("Keyboard Brightness", "keyboard"),
        "MusicRecognition": ("Music Recognition", "music.note"),
    ]

    // Modules that legitimately hold an in-band slot while not being drawn
    // (conditional indicators), plus the daemon-hosted legacy items — macOS
    // records no live-visibility signal we can read, so these are hidden from
    // the list unless "Show inactive system items" is on.
    private static let inactiveCapableModules: Set<String> = [
        "AudioVideoModule", "ScreenMirroring", "MusicRecognition", "NowPlaying",
        "UserSwitcher", "Focus",
    ]

    func load() {
        let dict = Self.readStore()
        let apps = NSWorkspace.shared.runningApplications
        // Absent key = on, so the not-running rows stay visible by default.
        let showInactiveApps = UserDefaults.standard.object(forKey: "arrange.showInactiveApps") as? Bool ?? true
        struct Cand {
            let key: String, autosave: String, token: String, pos: Double
            let app: NSRunningApplication, exactBundle: Bool
        }
        var cands: [Cand] = []
        var offline: [String: (key: String, autosave: String, pos: Double, url: URL, exact: Bool)] = [:]
        for (key, val) in dict {
            guard key.hasPrefix("status:") else { continue }
            let body = String(key.dropFirst("status:".count))
            guard let rr = body.range(of: "::") else { continue }
            let token = String(body[..<rr.lowerBound]), autosave = String(body[rr.upperBound...])
            let pos: Double
            if let n = val as? NSNumber { pos = n.doubleValue }
            else if let s = val as? String, let d = Double(s) { pos = d }
            else { continue }
            guard let app = Self.match(token: token, in: apps) else {
                // Not running — but if the app is still on disk, its item is just
                // parked until the next launch. Show it (grayed) instead of
                // silently vanishing; truly stale keys (app gone) stay hidden
                // and are Clean Up's business.
                if showInactiveApps, let url = Self.bundleURL(for: token) {
                    let ident = "\(url.path)|\(autosave)"
                    let exact = Bundle(url: url)?.bundleIdentifier == token
                    if let existing = offline[ident], !(exact && !existing.exact) { continue }
                    offline[ident] = (key: key, autosave: autosave, pos: pos, url: url, exact: exact)
                }
                continue
            }
            cands.append(Cand(key: key, autosave: autosave, token: token, pos: pos,
                              app: app, exactBundle: token == app.bundleIdentifier))
        }
        // The store accumulates alternate key spellings for the same item across
        // re-signs (e.g. "SpeedLauncher" vs "com.n14395.SpeedLauncher", same
        // autosave) — keep one per (app, autosave), preferring the exact-bundle key.
        var byIdentity: [String: Cand] = [:]
        for c in cands {
            let idKey = "\(c.app.processIdentifier)|\(c.autosave)"
            if let existing = byIdentity[idKey] {
                if c.exactBundle && !existing.exactBundle { byIdentity[idKey] = c }
            } else {
                byIdentity[idKey] = c
            }
        }
        let kept = Array(byIdentity.values)
        var perApp: [pid_t: Int] = [:]
        for c in kept { perApp[c.app.processIdentifier, default: 0] += 1 }
        var rows = kept.map { (c: Cand) -> ArrangeItem in
            // Items hosted by always-running system daemons (SystemUIServer holds
            // the legacy Siri icon; screencaptureui the recording indicator) should
            // be labeled by the ITEM, not the daemon, and tagged as system.
            if c.token == "com.apple.systemuiserver" || c.token == "com.apple.screencaptureui" {
                let name = c.autosave == "Item-0" ? "Screen Capture" : c.autosave
                let symbol = name == "Siri" ? "waveform" : "record.circle"
                return ArrangeItem(storeKey: c.key, appName: name,
                                   icon: NSImage(systemSymbolName: symbol, accessibilityDescription: name),
                                   autosave: c.autosave, trailing: c.pos,
                                   showsAutosave: false, isSystem: true, isInactiveCapable: true)
            }
            return ArrangeItem(storeKey: c.key, appName: c.app.localizedName ?? c.token,
                               icon: c.app.icon, autosave: c.autosave, trailing: c.pos,
                               showsAutosave: (perApp[c.app.processIdentifier] ?? 0) > 1)
        }
        for o in offline.values {
            rows.append(ArrangeItem(storeKey: o.key,
                                    appName: o.url.deletingPathExtension().lastPathComponent,
                                    icon: NSWorkspace.shared.icon(forFile: o.url.path),
                                    autosave: o.autosave, trailing: o.pos,
                                    showsAutosave: false, isRunning: false, bundleURL: o.url))
        }

        // Movable system modules. Live visibility isn't reliably recorded anywhere
        // (Control Center's "VisibleCC" keys are config, not state — Sound shows
        // with AirPods connected yet has no key), but the agent PARKS hidden
        // modules at out-of-band offsets (Sound sat at 1055 while hidden vs 720
        // visible), so "within the band of real items" is the honest filter. A
        // conditionally-shown module holding an in-band slot (e.g. the camera
        // indicator) stays listed — arranging it chooses where it will appear.
        let band = (rows.map(\.trailing).max() ?? 900) + 80
        for (key, val) in dict {
            guard key.hasPrefix("module:") else { continue }
            let name = String(key.dropFirst("module:".count))
            guard name != "Clock", !name.hasPrefix("BentoBox") else { continue }   // pinned by macOS
            let pos: Double
            if let n = val as? NSNumber { pos = n.doubleValue }
            else if let s = val as? String, let d = Double(s) { pos = d }
            else { continue }
            guard pos <= band else { continue }   // parked out-of-band = hidden
            var pretty = ""
            for (i, ch) in name.enumerated() {
                if i > 0, ch.isUppercase { pretty.append(" ") }
                pretty.append(ch)
            }
            let (title, symbol) = Self.moduleNames[name] ?? (pretty, "circle.grid.2x2")
            rows.append(ArrangeItem(storeKey: key, appName: title,
                                    icon: NSImage(systemSymbolName: symbol, accessibilityDescription: title),
                                    autosave: name, trailing: pos,
                                    showsAutosave: false, isSystem: true,
                                    isInactiveCapable: Self.inactiveCapableModules.contains(name)))
        }

        if !UserDefaults.standard.bool(forKey: "arrange.showInactive") {
            rows.removeAll { $0.isInactiveCapable }
        }
        items = rows.sorted { $0.trailing > $1.trailing }   // larger trailing = leftmost
        baseline = items.map(\.id)
    }

    func move(_ item: ArrangeItem, by delta: Int) {
        guard let i = items.firstIndex(of: item) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
    }

    /// Permute the SAME set of trailing offsets over the new order (leftmost row
    /// gets the largest), so the cluster's overall geometry is preserved and any
    /// interleaved system items stay where they are.
    func apply() {
        guard dirty, !applying else { return }
        var dict = Self.readStore()
        backupStore(dict)
        let slots = items.map(\.trailing).sorted(by: >)
        for (item, slot) in zip(items, slots) { dict[item.storeKey] = slot }
        CFPreferencesSetValue(Self.storeKey as CFString, dict as CFDictionary,
                              Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        applying = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["MenuBarAgent"]   // KeepAlive: relaunches, reads the store
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                self.applying = false
                self.load()
            }
        }
    }

    // MARK: Stale-entry cleanup

    struct CleanupCandidate: Identifiable, Equatable {
        let storeKey: String
        let title: String
        let reason: String
        var id: String { storeKey }
    }

    /// Store keys that are provably safe to remove: alternate spellings of a
    /// running item's key that lost the dedup, and reverse-DNS keys whose app
    /// no longer exists on disk. Apple's own daemons and anything ambiguous
    /// (bare executable names, apps merely not running) are never touched.
    func computeCleanup() -> [CleanupCandidate] {
        let dict = Self.readStore()
        let apps = NSWorkspace.shared.runningApplications
        struct Parsed { let key: String, token: String, autosave: String }
        var parsed: [Parsed] = []
        for key in dict.keys where key.hasPrefix("status:") {
            let body = String(key.dropFirst("status:".count))
            guard let rr = body.range(of: "::") else { continue }
            parsed.append(Parsed(key: key, token: String(body[..<rr.lowerBound]),
                                 autosave: String(body[rr.upperBound...])))
        }
        var out: [CleanupCandidate] = []
        // (a) Alternate-spelling duplicates for a running (app, autosave): the
        // exact-bundle-id key wins; the other spellings are dead weight.
        var groups: [String: [(p: Parsed, app: NSRunningApplication, exact: Bool)]] = [:]
        for p in parsed {
            guard let app = Self.match(token: p.token, in: apps) else { continue }
            groups["\(app.processIdentifier)|\(p.autosave)", default: []]
                .append((p, app, p.token == app.bundleIdentifier))
        }
        for members in groups.values where members.count > 1 && members.contains(where: { $0.exact }) {
            for m in members where !m.exact && !m.p.token.hasPrefix("com.apple.") {
                out.append(CleanupCandidate(storeKey: m.p.key,
                                            title: m.app.localizedName ?? m.p.token,
                                            reason: "duplicate spelling of its entry"))
            }
        }
        // (b) Reverse-DNS keys for apps gone from disk. Tokens may carry a
        // team-ID prefix ("ABCDE12345.com.foo.Bar") — try both spellings, and
        // only call it gone when every spelling is unknown to Launch Services.
        for p in parsed {
            guard Self.match(token: p.token, in: apps) == nil,
                  p.token.contains("."), !p.token.hasPrefix("com.apple."),
                  Self.bundleURL(for: p.token) == nil else { continue }
            out.append(CleanupCandidate(storeKey: p.key, title: p.token,
                                        reason: "app no longer installed"))
        }
        return out.sorted { $0.title < $1.title }
    }

    /// Full-store backup to Application Support — the one guard against a bad
    /// write. Called before every mutation (Apply Order and Clean Up alike).
    private func backupStore(_ dict: [String: Any]) {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MenuOverflow", isDirectory: true) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent(
            "TrailingItemPreferredPositions-\(df.string(from: Date())).plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: url)
        }
    }

    func performCleanup(_ candidates: [CleanupCandidate]) {
        guard !candidates.isEmpty else { return }
        var dict = Self.readStore()
        backupStore(dict)
        for c in candidates { dict.removeValue(forKey: c.storeKey) }
        CFPreferencesSetValue(Self.storeKey as CFString, dict as CFDictionary,
                              Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        load()
    }
}

struct ArrangeTab: View {
    @Bindable var arrange: ArrangeController
    @AppStorage("arrange.showInactive") private var showInactive = false
    @AppStorage("arrange.showInactiveApps") private var showInactiveApps = true
    @State private var cleanupCandidates: [ArrangeController.CleanupCandidate] = []
    @State private var showCleanupConfirm = false
    @State private var showCleanupEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag to reorder the menu bar items — the top of the list is the leftmost in the bar. The clock and Control Center are pinned by macOS and can't be moved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(arrange.items) { item in
                    HStack(spacing: 8) {
                        if let icon = item.icon {
                            // .fit inside the fixed box: SF symbols aren't square
                            // (Wi-Fi, battery) and must not be stretched into one.
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .opacity(item.isRunning ? 1 : 0.4)
                        }
                        Text(item.appName)
                            .opacity(item.isRunning ? 1 : 0.5)
                        if item.showsAutosave {
                            Text(item.autosave).font(.caption).foregroundStyle(.tertiary)
                        }
                        if item.isSystem {
                            Text("system").font(.caption).foregroundStyle(.tertiary)
                        }
                        if !item.isRunning {
                            Text("not running").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if !item.isRunning, let url = item.bundleURL {
                            Button {
                                let cfg = NSWorkspace.OpenConfiguration()
                                cfg.activates = false
                                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                                // Give it a moment to register its item, then re-list.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    MainActor.assumeIsolated { arrange.load() }
                                }
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Launch \(item.appName)")
                        }
                        Button { arrange.move(item, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item == arrange.items.first)
                        Button { arrange.move(item, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item == arrange.items.last)
                    }
                }
                .onMove { from, to in arrange.items.move(fromOffsets: from, toOffset: to) }
            }
            .frame(height: 300)
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Toggle("Show inactive system items (Siri, camera indicator, …)", isOn: $showInactive)
                .font(.callout)
                .onChange(of: showInactive) { _, _ in arrange.load() }

            Toggle("Show inactive apps (installed but not running)", isOn: $showInactiveApps)
                .font(.callout)
                .onChange(of: showInactiveApps) { _, _ in arrange.load() }

            HStack {
                Button("Apply Order") { arrange.apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!arrange.dirty || arrange.applying)
                Button("Refresh") { arrange.load() }
                    .disabled(arrange.applying)
                Button("Clean Up…") {
                    cleanupCandidates = arrange.computeCleanup()
                    if cleanupCandidates.isEmpty { showCleanupEmpty = true }
                    else { showCleanupConfirm = true }
                }
                .disabled(arrange.applying)
                Spacer()
                if arrange.applying {
                    ProgressView().controlSize(.small)
                    Text("Restarting menu bar…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Applying restarts the menu bar — it disappears for a few seconds, then comes back in the new order.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !arrange.dirty { arrange.load() } }
        .alert("Remove \(cleanupCandidates.count) stale \(cleanupCandidates.count == 1 ? "entry" : "entries")?",
               isPresented: $showCleanupConfirm) {
            Button("Remove", role: .destructive) { arrange.performCleanup(cleanupCandidates) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanupCandidates.map { "\($0.title) — \($0.reason)" }.joined(separator: "\n")
                 + "\n\nThe current layout store is backed up to Application Support first.")
        }
        .alert("Nothing to clean up", isPresented: $showCleanupEmpty) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No stale menu bar entries were found.")
        }
    }
}
