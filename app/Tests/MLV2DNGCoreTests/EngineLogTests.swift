// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2DNGCore

final class EngineLogTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineLogTests-\(UUID().uuidString)/Logs/mlv2dng", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent())
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testCreatesDirectoryAndAppends() throws {
        let url = EngineLog.file(in: dir, name: "Jour 1")
        XCTAssertEqual(url.lastPathComponent, "Jour 1.log")
        for line in ["a\n", "b\n"] {
            let h = try EngineLog.openForAppend(url)
            try h.write(contentsOf: Data(line.utf8))
            try h.close()
        }
        XCTAssertEqual(read(url), "a\nb\n")
    }

    func testRotatesWhenOverLimit() throws {
        let url = EngineLog.file(in: dir, name: "A")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 11).write(to: url)
        try Data("older".utf8).write(to: URL(fileURLWithPath: url.path + ".1"))
        let h = try EngineLog.openForAppend(url, rotateAbove: 10)
        try h.write(contentsOf: Data("new\n".utf8))
        try h.close()
        XCTAssertEqual(read(url), "new\n")
        XCTAssertEqual(read(URL(fileURLWithPath: url.path + ".1")), String(repeating: "A", count: 11))

        let h2 = try EngineLog.openForAppend(url, rotateAbove: 10) // 4 bytes: no rotation
        try h2.close()
        XCTAssertEqual(read(url), "new\n")
    }

    func testFoundationLauncherSendsStdoutAndStderrToLog() async throws {
        let url = EngineLog.file(in: dir, name: "Shell")
        let done = expectation(description: "exit")
        let p = try FoundationLauncher().launch(URL(fileURLWithPath: "/bin/sh"),
                                                ["-c", "echo to-stdout; echo to-stderr >&2"], log: url)
        p.onExit = { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        let text = read(url)
        XCTAssertTrue(text.hasPrefix("=== "), text)
        XCTAssertTrue(text.contains("to-stdout\n"), text)
        XCTAssertTrue(text.contains("to-stderr\n"), text)
    }
}
