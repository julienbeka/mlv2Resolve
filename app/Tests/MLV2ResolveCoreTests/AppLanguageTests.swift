// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class AppLanguageTests: XCTestCase {
    func testAppleLanguagesMapping() {
        XCTAssertNil(AppLanguage.system.appleLanguages)
        XCTAssertEqual(AppLanguage.en.appleLanguages, ["en"])
        XCTAssertEqual(AppLanguage.fr.appleLanguages, ["fr"])
    }
    func testInitFromAppleLanguages() {
        XCTAssertEqual(AppLanguage(appleLanguages: nil), .system)
        XCTAssertEqual(AppLanguage(appleLanguages: []), .system)
        XCTAssertEqual(AppLanguage(appleLanguages: ["fr-FR"]), .fr)
        XCTAssertEqual(AppLanguage(appleLanguages: ["fr"]), .fr)
        XCTAssertEqual(AppLanguage(appleLanguages: ["en"]), .en)
        XCTAssertEqual(AppLanguage(appleLanguages: ["en-GB", "fr"]), .en)
        XCTAssertEqual(AppLanguage(appleLanguages: ["de"]), .system)
    }
    func testRoundTrip() {
        for l in AppLanguage.allCases { XCTAssertEqual(AppLanguage(appleLanguages: l.appleLanguages), l) }
    }
}
