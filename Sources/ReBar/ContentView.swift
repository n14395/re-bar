import AppKit
import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Bindable var mirror: MenuBarMirrorController

    private enum Tab: Hashable { case spacing, color, arrange }
    @State private var tab: Tab = .spacing
    @State private var arrange = ArrangeController()
    @State private var importGen = 0
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Environment(\.openWindow) private var openWindow

    // NB: not a TabView — macOS's NSTabView-backed TabView sizes itself to its
    // LARGEST tab, leaving dead space around shorter ones and never letting the
    // window shrink. A segmented switcher + conditional content means the ideal
    // height is always the selected tab's own height, and (with the scene's
    // .windowResizability(.contentSize)) the window hugs it on every switch.
    var body: some View {
        VStack(spacing: 12) {
            Picker("Tab", selection: $tab) {
                Label("Spacing", systemImage: "arrow.left.and.right").tag(Tab.spacing)
                Label("Color", systemImage: "paintpalette").tag(Tab.color)
                Label("Arrange", systemImage: "arrow.left.arrow.right").tag(Tab.arrange)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .spacing: SpacingTab()
                case .color: ColorTab(mirror: mirror)
                case .arrange: ArrangeTab(arrange: arrange)
                }
            }
            .id(importGen)   // tabs hold @State seeded from defaults — re-seed after an import

            Divider()

            HStack {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Menu {
                    Button("Export Settings…") { SettingsTransfer.runExportPanel(mirror: mirror) }
                    Button("Import Settings…") {
                        if SettingsTransfer.runImportPanel(mirror: mirror, arrange: arrange) {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            importGen += 1
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("Settings transfer")
            }
            .font(.callout)

            Text("Closing this window keeps ReBar running. With the menu bar icon hidden, launch ReBar again to reopen these settings.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding([.horizontal, .bottom], 12)
        .padding(.top, 10)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            AppDelegate.openSettings = { openWindow(id: "main") }
            // A menu-bar utility: no Dock presence in the background (LSUIElement),
            // but become a regular app while Settings is open so it shows in the
            // Dock and Cmd-Tab; drop back to accessory when the window closes.
            // (Skipped during a silent login start, whose window closes instantly.)
            if !AppDelegate.launchedAsLoginItem {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            mirror.settingsWindowVisible = true   // enables the capture-costly checks
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            mirror.settingsWindowVisible = false
        }
    }
}

// MARK: - Spacing (the original feature)

private struct Preset: Identifiable {
    let id = UUID()
    let name: String
    let spacing: Int
    let padding: Int
}

private let presets = [
    Preset(name: "Default", spacing: 16, padding: 16),
    Preset(name: "Comfortable", spacing: 10, padding: 8),
    Preset(name: "Tight", spacing: 6, padding: 6),
    Preset(name: "Packed", spacing: 0, padding: 0),
]

struct SpacingTab: View {
    @State private var spacing = Double(MenuBarSpacing.spacing)
    @State private var padding = Double(MenuBarSpacing.padding)
    @State private var status: String?

    private var dirty: Bool {
        Int(spacing) != MenuBarSpacing.spacing || Int(padding) != MenuBarSpacing.padding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tighten the spacing between menu bar items.")
                .font(.callout).foregroundStyle(.secondary)

            preview

            HStack(spacing: 8) {
                ForEach(presets) { p in
                    Button(p.name) { spacing = Double(p.spacing); padding = Double(p.padding) }
                        .buttonStyle(.bordered)
                        .tint(isActive(p) ? .accentColor : nil)
                }
            }

            slider("Item spacing", value: $spacing)
            slider("Click padding", value: $padding)

            HStack {
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
                Button("Reset to Default") {
                    spacing = Double(MenuBarSpacing.systemDefault)
                    padding = Double(MenuBarSpacing.systemDefault)
                    MenuBarSpacing.resetToDefault()   // remove the keys outright
                    status = "Reset to the system default."
                }
                Spacer()
            }

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Changes apply to each app the next time it launches. To apply the new spacing everywhere at once, log out and back in.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Log Out…") { MenuBarSpacing.logOut() }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isActive(_ p: Preset) -> Bool {
        Int(spacing) == p.spacing && Int(padding) == p.padding
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...16, step: 1)
        }
    }

    private var preview: some View {
        let symbols = ["wifi", "battery.75", "bolt.fill", "clock", "magnifyingglass", "switch.2"]
        return HStack(spacing: CGFloat(spacing)) {
            ForEach(symbols, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 13))
                    .padding(.horizontal, CGFloat(padding) / 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func apply() {
        MenuBarSpacing.apply(spacing: Int(spacing), padding: Int(padding))
        status = "Saved (\(Int(spacing)) pt spacing, \(Int(padding)) pt padding)."
    }
}

// MARK: - Color (themed menu-bar mirror)

struct ColorTab: View {
    @Bindable var mirror: MenuBarMirrorController
    @State private var showSavePopover = false
    @State private var newPresetName = ""
    @State private var renamingPresetID: UUID?
    @State private var renameText = ""
    @FocusState private var presetNameFocused: Bool

    private struct ThemePreset: Identifiable {
        let name: String; let spec: ThemeSpec
        var id: String { name }   // stable across view re-inits, unlike a fresh UUID
    }
    private static func spec(_ bg: SIMD3<Double>, mid: SIMD3<Double>? = nil,
                             to bg2: SIMD3<Double>? = nil, fg: SIMD3<Double>) -> ThemeSpec {
        ThemeSpec(bg: bg, bgMid: mid, bg2: bg2 ?? bg, gradient: bg2 != nil, fg: fg)
    }
    // Each mode offers two 3-color gradients, one 2-color gradient, and one solid.
    // Dark leads with Forest, Light leads with Blush (each the first tile in its
    // appearance-filtered set, and Forest the overall default). Forest + Midnight
    // are 3-color with a pure-black middle to disguise the notch / Espresso
    // (2-color) / Ink (solid). Light: Blush + Sky (3-color) / Latte (2-color) /
    // Paper (solid).
    private let themePresets = [
        ThemePreset(name: "Forest", spec: Self.spec(.init(0.0719, 0.2690, 0.1674), mid: .init(0, 0, 0), to: .init(0.0459, 0.3504, 0.3752), fg: .init(0.85, 0.95, 0.85))),
        ThemePreset(name: "Midnight", spec: Self.spec(.init(0.16, 0.18, 0.34), mid: .init(0, 0, 0), to: .init(0.44, 0.20, 0.60), fg: .init(0.95, 0.95, 0.97))),
        ThemePreset(name: "Espresso", spec: Self.spec(.init(0.14, 0.09, 0.06), to: .init(0.45, 0.24, 0.12), fg: .init(0.98, 0.90, 0.75))),
        ThemePreset(name: "Ink", spec: Self.spec(.init(0, 0, 0), fg: .init(1, 1, 1))),
        ThemePreset(name: "Blush", spec: Self.spec(.init(0.99, 0.84, 0.90), mid: .init(0.92, 0.86, 0.98), to: .init(1.0, 0.93, 0.80), fg: .init(0.35, 0.12, 0.20))),
        ThemePreset(name: "Sky", spec: Self.spec(.init(0.78, 0.88, 0.98), mid: .init(0.84, 0.80, 0.98), to: .init(0.98, 0.83, 0.90), fg: .init(0.09, 0.20, 0.36))),
        ThemePreset(name: "Latte", spec: Self.spec(.init(0.96, 0.92, 0.85), to: .init(0.80, 0.64, 0.45), fg: .init(0.30, 0.20, 0.12))),
        ThemePreset(name: "Paper", spec: Self.spec(.init(0.97, 0.96, 0.94), fg: .init(0.13, 0.13, 0.14))),
    ]
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    /// While following the system appearance, only offer the built-ins that fit
    /// the slot being edited (dark themes for Dark, light for Light). User
    /// presets are always shown.
    private var visiblePresets: [ThemePreset] {
        guard mirror.followAppearance else { return themePresets }
        let wantDark = mirror.editingSlot == .dark
        return themePresets.filter { isDarkSpec($0.spec) == wantDark }
    }

    private func isDarkSpec(_ spec: ThemeSpec) -> Bool {
        0.2126 * spec.bg.x + 0.7152 * spec.bg.y + 0.0722 * spec.bg.z < 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Recolor the menu bar", isOn: $mirror.enabled)
                .toggleStyle(.switch)

            HStack(spacing: 10) {
                Text("Style")
                Picker("Recolor style", selection: $mirror.recolorStyle) {
                    Text("Full Mirror").tag(RecolorStyle.mirror)
                    Text("Background Tint").tag(RecolorStyle.tint)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Text(mirror.recolorStyle == .mirror
                 ? "Draw a recolored copy over the real menu bar — same layout, your colors. Clicks pass straight through to the real bar underneath."
                 : "Lay a translucent wash of your color over the menu bar — everything stays visible through it. No permissions needed, and no recording indicator, ever.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            preview

            if mirror.recolorStyle == .mirror {
                if !mirror.permissionGranted {
                    permissionNotice
                }
                if !mirror.menuBarBackgroundOn {
                    backgroundNotice
                }
            }

            themeControls
                .disabled(!mirror.enabled)

            if mirror.enabled {
                Text(statusLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            Divider()

            Text(mirrorCaption)
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if mirror.recolorStyle == .mirror { mirror.refreshChecks() } }
    }

    // Everything below the master switch — grayed out while the mirror is off.
    private var themeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Match system appearance (separate light & dark themes)",
                   isOn: $mirror.followAppearance)
            if mirror.followAppearance {
                HStack(spacing: 8) {
                    Text("Editing").font(.subheadline)
                    Picker("Editing theme", selection: $mirror.editingSlot) {
                        Text("Light").tag(AppearanceSlot.light)
                        Text("Dark").tag(AppearanceSlot.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                    Text("System is in \(mirror.systemIsDark ? "Dark" : "Light") Mode")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(visiblePresets) { p in themeButton(p) }
            }
            Divider()
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(mirror.customPresets) { p in customButton(p) }
                savePresetButton
            }

            HStack(spacing: 20) {
                ColorPicker("Background", selection: $mirror.bgColor, supportsOpacity: false)
                    .onChange(of: mirror.bgColor) { _, _ in mirror.applyTheme() }
                if mirror.recolorStyle == .mirror {
                    ColorPicker("Icons & text", selection: $mirror.fgColor, supportsOpacity: false)
                        .onChange(of: mirror.fgColor) { _, _ in mirror.applyTheme() }
                        .disabled(mirror.desktopTint)
                }
                Spacer()
                // NB: a .borderless button here vanishes from the AX tree
                // entirely (VoiceOver + scripting can't reach it) — keep it
                // bordered.
                Button("Reset") { mirror.resetTheme() }
                    .controlSize(.small)
                    .help("Back to the default colors")
            }
            .font(.subheadline)

            HStack(spacing: 20) {
                Toggle("Gradient background", isOn: $mirror.gradientOn)
                    .onChange(of: mirror.gradientOn) { _, _ in mirror.applyTheme() }
                if mirror.gradientOn {
                    ColorPicker("Right color", selection: $mirror.bg2Color, supportsOpacity: false)
                        .onChange(of: mirror.bg2Color) { _, _ in mirror.applyTheme() }
                        .font(.subheadline)
                }
            }

            if mirror.gradientOn {
                HStack(spacing: 20) {
                    Toggle("Three-color gradient", isOn: $mirror.threeColorOn)
                        .onChange(of: mirror.threeColorOn) { _, _ in mirror.applyTheme() }
                    if mirror.threeColorOn {
                        ColorPicker("Middle color", selection: $mirror.bgMidColor, supportsOpacity: false)
                            .onChange(of: mirror.bgMidColor) { _, _ in mirror.applyTheme() }
                            .font(.subheadline)
                    }
                }
            }
            // Everything below styles the captured GLYPHS — meaningless in tint
            // mode, where macOS keeps drawing the icons itself.
            if mirror.recolorStyle == .mirror {
                HStack(spacing: 10) {
                    Text("Colored icons")
                    Picker("Colored icons", selection: $mirror.coloredIcons) {
                        Text("Original").tag(ColoredIconMode.original)
                        Text("Muted").tag(ColoredIconMode.muted)
                        Text("Themed").tag(ColoredIconMode.themed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: mirror.coloredIcons) { _, _ in mirror.applyTheme() }
                }
                if NSScreen.screens.contains(where: { $0.auxiliaryTopLeftArea != nil }) {
                    Toggle("Fade to black around the notch", isOn: $mirror.notchFade)
                        .onChange(of: mirror.notchFade) { _, _ in mirror.applyTheme() }
                }
                Toggle("Tint icons with each desktop's wallpaper color", isOn: $mirror.desktopTint)
                    .onChange(of: mirror.desktopTint) { _, _ in mirror.applyTheme() }
                Toggle("Brighten faint icons (disabled/dimmed items)", isOn: $mirror.boostFaint)
                    .onChange(of: mirror.boostFaint) { _, _ in mirror.applyTheme() }
            }
            Toggle("Show themed bar in screenshots & screen sharing", isOn: $mirror.showInScreenshots)
                .onChange(of: mirror.showInScreenshots) { _, _ in mirror.applyTheme() }
        }
    }

    // Colors restored from UserDefaults round-trip through Float32, so exact
    // Color equality fails (0.16 → 0.15999999…); compare with a tolerance.
    private func colorsMatch(_ a: Color, _ b: Color) -> Bool {
        guard let x = NSColor(a).usingColorSpace(.sRGB),
              let y = NSColor(b).usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.005
            && abs(x.greenComponent - y.greenComponent) < 0.005
            && abs(x.blueComponent - y.blueComponent) < 0.005
    }

    // Each preset button is drawn in its own theme — the swatch IS the preview.
    private func swatch(name: String, style: AnyShapeStyle, fg: Color, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(style, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.2),
                                  lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) theme")
    }

    private func swatchStyle(_ spec: ThemeSpec) -> AnyShapeStyle {
        guard spec.gradient else { return AnyShapeStyle(spec.bg.uiColor) }
        var colors = [spec.bg.uiColor]
        if let m = spec.bgMid { colors.append(m.uiColor) }
        colors.append(spec.bg2.uiColor)
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
    }

    /// Does the current editing surface show exactly this spec? (Drives the
    /// selection ring; tolerance-based because colors round-trip through Float32.)
    private func surfaceMatches(_ spec: ThemeSpec) -> Bool {
        guard colorsMatch(mirror.bgColor, spec.bg.uiColor),
              colorsMatch(mirror.fgColor, spec.fg.uiColor),
              mirror.gradientOn == spec.gradient else { return false }
        guard spec.gradient else { return true }
        guard colorsMatch(mirror.bg2Color, spec.bg2.uiColor) else { return false }
        if let m = spec.bgMid {
            return mirror.threeColorOn && colorsMatch(mirror.bgMidColor, m.uiColor)
        }
        return !mirror.threeColorOn
    }

    private func themeButton(_ p: ThemePreset) -> some View {
        swatch(name: p.name, style: swatchStyle(p.spec), fg: p.spec.fg.uiColor,
               selected: surfaceMatches(p.spec)) {
            mirror.applyPreset(p.spec)
        }
    }

    private func customButton(_ p: CustomPreset) -> some View {
        swatch(name: p.name, style: swatchStyle(p.spec), fg: p.spec.fg.uiColor,
               selected: surfaceMatches(p.spec)) {
            mirror.applyPreset(p.spec)
        }
        .contextMenu {
            Button("Rename…") {
                renameText = p.name
                renamingPresetID = p.id
            }
            Button("Update to Current Colors") { mirror.updatePreset(p) }
            Divider()
            Button("Delete “\(p.name)”", role: .destructive) { mirror.deletePreset(p) }
        }
        .popover(isPresented: Binding(get: { renamingPresetID == p.id },
                                      set: { if !$0 { renamingPresetID = nil } }),
                 arrowEdge: .bottom) {
            HStack {
                TextField("Preset name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { commitRename(p) }
                Button("Rename") { commitRename(p) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusPopoverField() }
            }
        }
    }

    private func commitRename(_ p: CustomPreset) {
        mirror.renamePreset(p, to: renameText)
        renamingPresetID = nil
    }

    private var savePresetButton: some View {
        Button { showSavePopover = true } label: {
            Label("Save…", systemImage: "plus")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save current colors as a preset")
        .popover(isPresented: $showSavePopover, arrowEdge: .bottom) {
            HStack {
                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($presetNameFocused)
                    .onSubmit(saveNewPreset)
                Button(mirror.presetExists(named: newPresetName) ? "Replace" : "Save",
                       action: saveNewPreset)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .defaultFocus($presetNameFocused, true)
            .onAppear {
                // SwiftUI popovers don't reliably hand their field first-responder
                // status on any FocusState timing — go through AppKit once the
                // popover window actually exists.
                presetNameFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusPopoverField() }
            }
        }
    }

    private func saveNewPreset() {
        mirror.saveCurrentAsPreset(named: newPresetName)
        newPresetName = ""
        showSavePopover = false
    }

    private func focusPopoverField() {
        guard let pop = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Popover") }),
              let field = firstEditableTextField(in: pop.contentView) else { return }
        pop.makeKey()
        pop.makeFirstResponder(field)
    }

    private func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable { return tf }
        for sub in view.subviews {
            if let found = firstEditableTextField(in: sub) { return found }
        }
        return nil
    }

    private var statusLine: String {
        let n = mirror.stats.activeDisplays
        return "Active on \(n) display\(n == 1 ? "" : "s")"
    }

    /// The footnote under the Color controls. In Full Mirror it also says which
    /// recording indicator to expect, because that differs by capture path:
    /// reading the menu bar's own window shows only the small screenshot dot,
    /// while the fallback — compositing the screen behind the bar — also raises
    /// the wide “screen is being observed” badge after ten seconds or so.
    private var mirrorCaption: String {
        guard mirror.recolorStyle == .mirror else {
            return "Wash only — a translucent layer of your color over the whole bar, icons included, so contrast is softer than the Full Mirror. It can't move or hide items."
        }
        let base = "Recolor only — it can't move or hide items. The theme briefly reveals the real bar during Mission Control, Spaces, and full-screen. Needs Screen Recording permission to read the bar; nothing leaves your Mac."
        return mirror.stats.windowCapture
            ? base + " It reads the menu bar's own window, so macOS shows the small screenshot dot but not the “screen is being observed” badge."
            : base
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Screen Recording permission is needed to read the menu bar.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            HStack {
                Button("Grant Screen Recording…") { mirror.requestPermission() }
                Button("Open Settings") { mirror.openScreenRecordingSettings() }
            }
            Text("After granting, quit and reopen ReBar.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var backgroundNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS's “Show menu bar background” is off — the mirror needs it on to read the bar.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Button("Open Menu Bar Settings") { mirror.openMenuBarSettings() }
            Text("In System Settings ▸ Menu Bar, turn on “Show menu bar background.”")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // A live swatch of the chosen theme so the look is visible even without permission.
    private var preview: some View {
        let symbols = ["wifi", "battery.75", "clock"]
        return HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "applelogo").font(.system(size: 13))
                Text("File").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            ForEach(symbols, id: \.self) { Image(systemName: $0).font(.system(size: 13)) }
            Text("100%").font(.system(size: 12))
        }
        .foregroundStyle(previewFG)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(previewBG, in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewBG: AnyShapeStyle {
        if mirror.gradientOn {
            var colors = [mirror.bgColor]
            if mirror.threeColorOn { colors.append(mirror.bgMidColor) }
            colors.append(mirror.bg2Color)
            return AnyShapeStyle(LinearGradient(colors: colors,
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(mirror.bgColor)
    }

    private var previewFG: Color {
        guard mirror.recolorStyle == .tint else { return mirror.fgColor }
        // Tint mode: macOS keeps drawing the glyphs itself — approximate with
        // plain white/black picked by the background's brightness.
        let ns = NSColor(mirror.bgColor).usingColorSpace(.sRGB) ?? .black
        let lum = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return lum < 0.5 ? .white : Color(white: 0.1)
    }
}

private extension SIMD3<Double> {
    var uiColor: Color { Color(red: x, green: y, blue: z) }
}
