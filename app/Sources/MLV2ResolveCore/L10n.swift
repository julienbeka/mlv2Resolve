// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Localization entry point of the core package. Strings live in `Resources/Localizable.xcstrings`
/// (English is the source language, French is a full translation).
enum L10n {
    /// The package resource bundle that holds the catalog.
    static let moduleBundle: Bundle = .module
    /// Bundle the messages are read from. Production uses the module bundle (which follows the app's
    /// preferred language); tests pin it to a given `.lproj` so assertions do not depend on the machine's language.
    nonisolated(unsafe) static var bundle: Bundle = moduleBundle
}
