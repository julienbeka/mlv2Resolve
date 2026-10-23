// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin

/// Dual ISO processing mode; the raw value is mlvfs's `dual_iso` setting.
public enum DualISOMode: Int, Sendable {
    /// Fast preview (`--dual-iso-preview`): smooth editing.
    case montageFluide = 1
    /// Full-quality interpolation (`--dual-iso`): grading.
    case qualiteEtalonnage = 2

    /// Signal that switches a running mlvfs to this mode.
    var signal: Int32 {
        switch self {
        case .montageFluide: return SIGUSR1
        case .qualiteEtalonnage: return SIGUSR2
        }
    }

    var engineFlag: String {
        switch self {
        case .montageFluide: return "--dual-iso-preview"
        case .qualiteEtalonnage: return "--dual-iso"
        }
    }
}
