import AppKit
import Observation

/// Reads and writes the two undocumented global defaults that control menu
/// bar item layout on macOS. They live in the ByHost ("-currentHost") scope
/// of the global domain — the same thing `defaults -currentHost write -g …`
/// touches. Writing them needs no special permission.
enum MenuBarSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    /// The value macOS uses when the keys are unset.
    static let systemDefault = 16

    static func read(_ key: String) -> Int {
        let value = CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        return (value as? NSNumber)?.intValue ?? systemDefault
    }

    static var spacing: Int { read(spacingKey) }
    static var padding: Int { read(paddingKey) }

    static func apply(spacing: Int, padding: Int) {
        set(spacingKey, NSNumber(value: spacing))
        set(paddingKey, NSNumber(value: padding))
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Remove the keys so the system default (16) applies again.
    static func resetToDefault() {
        set(spacingKey, nil)
        set(paddingKey, nil)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private static func set(_ key: String, _ value: NSNumber?) {
        CFPreferencesSetValue(
            key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
    }

    /// Trigger the standard macOS log-out (the surest way to apply the change
    /// everywhere). The system shows its own confirmation dialog.
    static func logOut() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to log out"])
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}

// MARK: - "Apply to Running Apps" (relaunch helper)
//
// AppKit reads NSStatusItemSpacing ONCE per process, at first status-item
// creation — restarting MenuBarAgent does not re-apply it and running apps
// never re-read it (proven by live measurement). The only refresh point is a
// process launch, so the one honest "apply now" is to politely quit and
// reopen the background apps that own bar items.

@MainActor @Observable
final class SpacingRelaunchController {
    struct Target: Identifiable {
        let name: String
        let icon: NSImage?
        let bundleURL: URL
        let app: NSRunningApplication
        var state: State = .pending
        enum State { case pending, quitting, relaunching, done, skippedNoQuit, failedLaunch }
        var id: pid_t { app.processIdentifier }
    }

    var targets: [Target] = []
    private(set) var running = false
    private(set) var finished = false

    /// Background (accessory) apps owning a bar item. Regular apps with open
    /// windows, anything Apple, and MenuOverflow itself are never candidates.
    func compute() {
        let ours = ProcessInfo.processInfo.processIdentifier
        targets = ArrangeController.statusItemOwners().compactMap { app in
            guard app.processIdentifier != ours,
                  app.activationPolicy == .accessory,
                  app.bundleIdentifier?.hasPrefix("com.apple.") != true,
                  !app.isTerminated,
                  let url = app.bundleURL else { return nil }
            return Target(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                          icon: app.icon, bundleURL: url, app: app)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        finished = false
    }

    /// Serial quit→wait→reopen per app. Serial keeps failures attributable and
    /// avoids churning the bar layout with simultaneous item removals.
    func run() async {
        guard !running else { return }
        running = true
        for i in targets.indices {
            let app = targets[i].app
            if !app.isTerminated {
                targets[i].state = .quitting
                app.terminate()                              // polite; never force
                var waited = 0
                while !app.isTerminated && waited < 50 {     // up to 5 s
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                if !app.isTerminated {
                    targets[i].state = .skippedNoQuit        // it declined; leave it be
                    continue
                }
            }
            targets[i].state = .relaunching
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: targets[i].bundleURL,
                                                                 configuration: cfg)
                targets[i].state = .done
            } catch {
                targets[i].state = .failedLaunch
            }
            try? await Task.sleep(for: .milliseconds(250))   // let the bar settle
        }
        running = false
        finished = true
    }

    var doneCount: Int { targets.count { $0.state == .done } }
}
