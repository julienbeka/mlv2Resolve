// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One-time carry-over of settings from the previous app name ("MLV Switch",
/// defaults domain `net.mlvswitch.app`).
public enum LegacyMigration {
    public static let legacySuiteName = "net.mlvswitch.app"
    public static let migratedKey = "migratedFromMLVSwitch"
    static let keys = ["lastFolder", "mountedShoots", "dualISOMode", "fixBadPixels",
                       "fixFocusPixels", "launchAtLoginInitialized"]

    /// Copies the saved state when `defaults` has no `lastFolder` yet.
    /// Returns true when a migration happened.
    @discardableResult
    public static func migrateDefaults(into defaults: UserDefaults, from legacy: UserDefaults?) -> Bool {
        guard defaults.object(forKey: "lastFolder") == nil, let legacy else { return false }
        for key in keys {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: migratedKey)
        return true
    }

    public static func migrateDefaults(into defaults: UserDefaults) {
        migrateDefaults(into: defaults, from: UserDefaults(suiteName: legacySuiteName))
    }
}
