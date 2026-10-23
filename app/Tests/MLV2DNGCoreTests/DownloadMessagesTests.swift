// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class DownloadMessagesTests: XCTestCase {
    func testOffline() {
        XCTAssertTrue(downloadFailureMessage(error: URLError(.notConnectedToInternet)).contains("hors ligne"))
    }
    func testServerStatus() {
        XCTAssertTrue(downloadFailureMessage(httpStatus: 503).hasPrefix("Serveur indisponible"))
    }
    func testDiskFull() {
        let e = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertTrue(downloadFailureMessage(error: e).contains("Espace disque insuffisant"))
    }
    func testTruncated() {
        XCTAssertEqual(downloadFailureMessage(received: 10, expected: 100), "Téléchargement incomplet. Réessayez.")
    }
    func testUnknownIsFrench() {
        let m = downloadFailureMessage(error: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "English text"]))
        XCTAssertTrue(m.contains("inconnue")); XCTAssertFalse(m.contains("English"))
    }
}
