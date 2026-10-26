// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MLV2ResolveCore

/// Shared helper for the gated tests that run on real clips (MLV2Resolve_GYRO_DIR).
enum RealGyroFixture {
    static func motion(base: URL, clip: String = "M24-1845.MLV") throws -> [MotionSample] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tool = repo.appendingPathComponent("build/engine/mlvmotion")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("mlvmotion not built") }
        let p = Process()
        p.executableURL = tool
        p.arguments = [base.appendingPathComponent(clip).path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().compactMap {
            let c = $0.split(separator: ",").compactMap { Double($0) }
            return c.count == 4 ? MotionSample(frame: Int(c[0]), dx: c[1], dy: c[2], peak: c[3]) : nil
        }
    }
}
