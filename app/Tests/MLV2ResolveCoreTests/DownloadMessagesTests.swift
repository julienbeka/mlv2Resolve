// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

final class DownloadMessagesTests: XCTestCase {
    override func setUp() { L10n.bundle = L10nTests.bundle("en") }
    func testOffline() {
        XCTAssertTrue(downloadFailureMessage(error: URLError(.notConnectedToInternet)).contains("offline"))
    }
    func testServerStatus() {
        XCTAssertTrue(downloadFailureMessage(httpStatus: 503).hasPrefix("Server unavailable"))
    }
    func testDiskFull() {
        let e = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertTrue(downloadFailureMessage(error: e).contains("Not enough disk space"))
    }
    func testTruncated() {
        XCTAssertEqual(downloadFailureMessage(received: 10, expected: 100), "Download incomplete. Try again.")
    }
    func testUnknownIsGenericAndLocalized() {
        let m = downloadFailureMessage(error: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "English text"]))
        XCTAssertTrue(m.contains("unknown error")); XCTAssertFalse(m.contains("English"))
    }
}
