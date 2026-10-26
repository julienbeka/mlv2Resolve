// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

/// The core catalog is shipped as `en.lproj` / `fr.lproj` `Localizable.strings` (SwiftPM's command-line build
/// does not compile `.xcstrings`, so plain strings files are used).
@MainActor
final class L10nTests: XCTestCase {
    /// The `<lang>.lproj` of the core resource bundle, so assertions never depend on the machine's language.
    nonisolated static func bundle(_ lang: String) -> Bundle {
        guard let path = L10n.moduleBundle.path(forResource: lang, ofType: "lproj"), let b = Bundle(path: path) else {
            fatalError("missing \(lang).lproj in the core resource bundle")
        }
        return b
    }

    private func table(_ lang: String) throws -> [String: String] {
        let url = try XCTUnwrap(Self.bundle(lang).url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    override func tearDown() { L10n.bundle = Self.bundle("en") }

    func testEveryEnglishKeyHasANonEmptyFrenchTranslation() throws {
        let en = try table("en"), fr = try table("fr")
        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(Set(en.keys), Set(fr.keys), "en and fr must define the same keys")
        for key in en.keys {
            let value = try XCTUnwrap(fr[key], "no French translation for: \(key)")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty French translation for: \(key)")
            // Placeholders must survive translation.
            let count: (String) -> Int = { $0.components(separatedBy: "%").count }
            XCTAssertEqual(count(value), count(key), "placeholder mismatch for: \(key)")
        }
    }

    func testMessagesAreFrenchWhenFrenchIsSelected() {
        L10n.bundle = Self.bundle("fr")
        XCTAssertEqual(AppState.unplugAlert(URL(fileURLWithPath: "/Volumes/SSD")), "Disque « SSD » débranché")
        XCTAssertEqual(downloadFailureMessage(received: 10, expected: 100), "Téléchargement incomplet. Réessayez.")
        XCTAssertEqual(AppState.busyAlert(["A"]),
                       "Impossible de démonter « A » : des fichiers sont peut-être ouverts dans Resolve.")
    }

    func testMessagesAreEnglishWhenEnglishIsSelected() {
        L10n.bundle = Self.bundle("en")
        XCTAssertEqual(AppState.unplugAlert(URL(fileURLWithPath: "/Volumes/SSD")), "Disk “SSD” was unplugged")
    }
}
