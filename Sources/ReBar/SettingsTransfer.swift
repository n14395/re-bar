// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings export/import (versioned JSON)

struct SettingsExportV1: Codable {
    struct Spacing: Codable {
        var spacing: Int
        var padding: Int
    }
    struct MirrorSettings: Codable {
        var enabled: Bool
        var followAppearance: Bool
        var desktopTint: Bool
        var boostFaint: Bool
        var showInScreenshots: Bool
        var keepColors: Bool? = nil      // legacy boolean (exports from the toggle era)
        var coloredIcons: String? = nil  // ColoredIconMode raw value; absent in older exports
        var notchFade: Bool? = nil       // absent in older exports
        var gradient: Bool
        var bg: SIMD3<Double>
        var bgMid: SIMD3<Double>?   // present only for 3-color gradients
        var bg2: SIMD3<Double>
        var fg: SIMD3<Double>
        var light: ThemeSpec?
        var dark: ThemeSpec?
        var customPresets: [CustomPreset]
    }
    var version: Int = 1
    var spacing: Spacing
    var mirror: MirrorSettings
    var showMenuBarIcon: Bool
    var arrangeShowInactive: Bool
    var arrangeShowInactiveApps: Bool? = nil   // absent in older exports → treated as on
    var startAtLogin: Bool
}

@MainActor
enum SettingsTransfer {
    static func runExportPanel(mirror: MenuBarMirrorController) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ReBar Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let export = SettingsExportV1(
            spacing: .init(spacing: MenuBarSpacing.spacing, padding: MenuBarSpacing.padding),
            mirror: mirror.exportSettings(),
            showMenuBarIcon: UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true,
            arrangeShowInactive: UserDefaults.standard.bool(forKey: "arrange.showInactive"),
            arrangeShowInactiveApps: UserDefaults.standard.object(forKey: "arrange.showInactiveApps") as? Bool ?? true,
            startAtLogin: SMAppService.mainApp.status == .enabled)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(export).write(to: url)
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    /// Returns true when settings were imported (so the caller can refresh
    /// view state seeded from defaults).
    static func runImportPanel(mirror: MenuBarMirrorController, arrange: ArrangeController) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try Data(contentsOf: url)
            // Peek at the version before the full decode so a future format
            // fails with a real message instead of a decoding error.
            if let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = head["version"] as? Int, v > 1 {
                alert("Can't import", "This file was exported by a newer version of ReBar (format v\(v)).")
                return false
            }
            let settings = try JSONDecoder().decode(SettingsExportV1.self, from: data)
            apply(settings, mirror: mirror, arrange: arrange)
            return true
        } catch {
            alert("Import failed", error.localizedDescription)
            return false
        }
    }

    static func apply(_ s: SettingsExportV1, mirror: MenuBarMirrorController, arrange: ArrangeController) {
        MenuBarSpacing.apply(spacing: s.spacing.spacing, padding: s.spacing.padding)
        UserDefaults.standard.set(s.showMenuBarIcon, forKey: "showMenuBarIcon")
        UserDefaults.standard.set(s.arrangeShowInactive, forKey: "arrange.showInactive")
        UserDefaults.standard.set(s.arrangeShowInactiveApps ?? true, forKey: "arrange.showInactiveApps")
        mirror.importSettings(s.mirror)
        let svc = SMAppService.mainApp
        do {
            if s.startAtLogin, svc.status != .enabled { try svc.register() }
            else if !s.startAtLogin, svc.status == .enabled { try svc.unregister() }
        } catch {}   // non-fatal; the footer re-reads the real status
        arrange.load()
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
