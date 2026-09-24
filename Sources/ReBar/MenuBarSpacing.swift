// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

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
