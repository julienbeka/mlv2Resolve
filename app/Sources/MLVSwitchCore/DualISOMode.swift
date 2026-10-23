// SPDX-License-Identifier: GPL-3.0-or-later

/// Dual ISO processing mode; the raw value is mlvfs's `dual_iso` web setting.
public enum DualISOMode: Int, Sendable {
    /// Fast preview (`--dual-iso-preview`): smooth editing.
    case montageFluide = 1
    /// Full-quality interpolation (`--dual-iso`): grading.
    case qualiteEtalonnage = 2

    var engineFlag: String {
        switch self {
        case .montageFluide: return "--dual-iso-preview"
        case .qualiteEtalonnage: return "--dual-iso"
        }
    }
}
