import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from ContentView (which has the SwiftUI openWindow action); lets the
    /// reopen handler show Settings even after the window was closed.
    static var openSettings: (() -> Void)?
    /// True only during a silent login-item start; cleared once the launch
    /// window has been closed so later manual opens behave normally.
    private(set) static var launchedAsLoginItem = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The mirror must outlive the settings window: without this, macOS's
        // automatic termination reaps the windowless process — and the themed
        // bar with it.
        ProcessInfo.processInfo.disableAutomaticTermination("menu-bar mirror runs in the background")
        #if SPARKLE
        SparkleUpdater.start()
        #endif

        // A login-item start should be silent: the window is created normally
        // (so reopen/openWindow plumbing works), then immediately closed.
        let ev = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAsLoginItem = ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
        if Self.launchedAsLoginItem {
            DispatchQueue.main.async {
                for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true {
                    w.close()
                }
                Self.launchedAsLoginItem = false
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Re-launching the app (Finder/Spotlight/Dock) is the no-icon path back to
    // Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let open = Self.openSettings {
            open()
            sender.activate()
            return false
        }
        return true
    }
}

@main
struct ReBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Owned at app scope so the mirror's render loop and display observer survive
    // the window being closed.
    @State private var mirror = MenuBarMirrorController()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("ReBar", id: "main") {
            ContentView(mirror: mirror)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarExtraMenu(mirror: mirror)
        } label: {
            Image(nsImage: menuBarIcon)
        }
    }
}

/// Symbolic (template) rendition of the app icon — the caliper: two vertical
/// jaws pinching three dots. Drawn at runtime so it's crisp at every backing
/// scale; `isTemplate` lets the system tint it like any SF Symbol.
private let menuBarIcon: NSImage = {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(roundedRect: NSRect(x: 13, y: 3, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
        for x: CGFloat in [6.5, 9.0, 11.5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1, y: 8, width: 2, height: 2)).fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}()

private struct MenuBarExtraMenu: View {
    @Bindable var mirror: MenuBarMirrorController
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Recolor the Menu Bar", isOn: $mirror.enabled)
        Divider()
        Button("Settings…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        #if SPARKLE
        SparkleCheckForUpdatesButton()
        #endif
        Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
        Divider()
        Button("Quit ReBar") { NSApp.terminate(nil) }
    }
}
