// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// In-app language choice, mapped onto the app's own `AppleLanguages` default
/// (the same key macOS writes for System Settings → Language & Region → Applications).
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, fr

    /// Value to store under `AppleLanguages`; `nil` means "remove the override".
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .en: return ["en"]
        case .fr: return ["fr"]
        }
    }

    /// Derives the choice from an `AppleLanguages` array. Only the first entry counts;
    /// unsupported languages fall back to `.system`.
    public init(appleLanguages: [String]?) {
        guard let first = appleLanguages?.first?.lowercased() else { self = .system; return }
        let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? first
        switch code {
        case "fr": self = .fr
        case "en": self = .en
        default: self = .system
        }
    }
}
