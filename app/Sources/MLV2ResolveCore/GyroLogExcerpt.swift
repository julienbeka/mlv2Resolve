// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Clip-sized, lossless SenseFlow telemetry. The original log is never changed.
/// Only constant sync offsets and the A1's fixed accel+gyro records are supported.
enum GyroLogExcerpt {
    enum Failure: Error, LocalizedError {
        case invalidProject, unsupportedLog, invalidChecksum, outsideLog, changedProject, missingExcerpt
        var errorDescription: String? {
            switch self {
            case .invalidProject: "Unsupported Gyroflow timing or synchronization points"
            case .unsupportedLog: "Unsupported SenseFlow log format"
            case .invalidChecksum: "Corrupt SenseFlow record: synchronization cannot be guaranteed"
            case .outsideLog: "The gyro log does not cover this clip"
            case .changedProject: "The Gyroflow project changed during optimization"
            case .missingExcerpt: "The clip's gyro excerpt is missing"
            }
        }
    }
    struct Prepared: Sendable {
        let projectData: Data
        let logURL: URL?
        let logData: Data?

        func persistLog() throws {
            try Task.checkCancellation()
            guard let logURL, let logData else { return }
            let fm = FileManager.default
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: logURL.path) {
                guard try Data(contentsOf: logURL) == logData else { throw Failure.invalidChecksum }
                return
            }
            try logData.write(to: logURL, options: .atomic)
        }
    }

    static func prepare(_ data: Data, destination: URL) throws -> Prepared {
        try Task.checkCancellation()
        guard var p = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var source = p["gyro_source"] as? [String: Any],
              let path = source["filepath"] as? String, let url = URL(string: path), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost"
        else { throw Failure.invalidProject }
        let logURL = URL(fileURLWithPath: url.path).standardizedFileURL
        let storage = destination.deletingLastPathComponent().appendingPathComponent(".mlv2resolve-gyro", isDirectory: true)
        if logURL.deletingLastPathComponent() == storage.standardizedFileURL {
            guard FileManager.default.fileExists(atPath: logURL.path) else { throw Failure.missingExcerpt }
            return Prepared(projectData: data, logURL: nil, logData: nil)
        }
        guard let offsets = p["offsets"] as? [String: Double], let offset = offsets.values.first,
              offset.isFinite, offsets.values.allSatisfy({ $0 == offset }),
              offsets.keys.allSatisfy({ Int64($0) != nil }),
              let info = p["video_info"] as? [String: Any],
              let frames = info["num_frames"] as? Double, let fps = info["fps"] as? Double,
              fps.isFinite, fps > 0, frames.isFinite, frames > 0
        else { throw Failure.invalidProject }
        let duration = frames / fps * 1000
        let lag = -offset
        let binary = try Data(contentsOf: logURL, options: .alwaysMapped)
        let (excerpt, shiftMS) = try cut(binary, lagMS: lag, durationMS: duration)
        let digest = SHA256.hash(data: excerpt).map { String(format: "%02x", $0) }.joined()
        let name = destination.deletingPathExtension().lastPathComponent
        let target = storage.appendingPathComponent("\(name)-\(digest.prefix(20)).bin")
        source["filepath"] = GyroflowProject.fileURL(target.path)
        p["gyro_source"] = source
        let shiftUS = Int64(shiftMS) * 1000
        var adjusted: [String: Double] = [:]
        for (key, value) in offsets {
            let (time, overflow) = Int64(key)!.subtractingReportingOverflow(shiftUS)
            guard !overflow else { throw Failure.invalidProject }
            adjusted[String(time)] = value + shiftMS
        }
        p["offsets"] = adjusted
        return Prepared(projectData: try JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted, .withoutEscapingSlashes]),
                        logURL: target, logData: excerpt)
    }

    /// All sensor bytes and checksums stay intact. Markers do not count as samples.
    private static func cut(_ data: Data, lagMS: Double, durationMS: Double) throws -> (Data, Double) {
        guard data.count >= 512, (data.count - 512) % 16 == 0 else { throw Failure.unsupportedLog }
        let startDate = try A1Log.parseHeader(data)
        return try data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let rate = (0..<4).reduce(0) { $0 | Int(b[92 + $1]) << ($1 * 8) }
            guard (1...10_000).contains(rate) else { throw Failure.unsupportedLog }
            let slots = (data.count - 512) / 16
            guard lagMS.isFinite, lagMS >= 0, durationMS.isFinite, durationMS > 0,
                  lagMS + durationMS <= Double(slots) / Double(rate) * 1000 + 1
            else { throw Failure.outsideLog }
            let shiftMS = max(0, floor((lagMS - 10_000) / 1000) * 1000)
            guard shiftMS < Double(Int64.max / 1000) else { throw Failure.outsideLog }
            // File-size bound above keeps conversions and microsecond arithmetic in range.
            let first = Int(shiftMS / 1000) * rate
            let wantedEnd = min(Double(slots), ceil((lagMS + durationMS + 10_000) / 1000 * Double(rate)))
            let end = Int(wantedEnd)
            var count = 0, begin: Int?, finish = data.count
            for pos in stride(from: 512, to: data.count, by: 16) {
                if pos & 0xFFFFF == 512 { try Task.checkCancellation() }
                if b[pos] == 0xAA, b[pos + 1] == 0x55, b[pos + 2] == 3 {
                    if count == first { begin = pos }
                    if count == end { finish = pos; break }
                    var sum: UInt8 = 0
                    for i in 3..<15 { sum &+= b[pos + i] }
                    guard sum == b[pos + 15] else { throw Failure.invalidChecksum }
                    count += 1
                } else if !(b[pos] == 0x55 && b[pos + 1] == 0xAA && b[pos + 2] == 0x40) {
                    throw Failure.unsupportedLog
                }
            }
            guard let begin, count > first,
                  lagMS + durationMS <= Double(count) / Double(rate) * 1000 + 1
            else { throw Failure.outsideLog }
            var head = Data(data.prefix(512))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let date = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                               from: startDate.addingTimeInterval(shiftMS / 1000))
            guard let year = date.year, (2000...2255).contains(year) else { throw Failure.unsupportedLog }
            head.replaceSubrange(64..<70, with: [year - 2000, date.month!, date.day!, date.hour!, date.minute!, date.second!].map(UInt8.init))
            head.append(data.subdata(in: begin..<finish))
            return (head, shiftMS)
        }
    }

    /// Called only for sidecars owned by mlv2Resolve. No motion analysis or lens changes.
    @discardableResult
    static func migrate(at destination: URL, backupDirectory: URL) throws -> Bool {
        let before = try Data(contentsOf: destination)
        let result = try prepare(before, destination: destination)
        guard result.projectData != before else { return false }
        try result.persistLog()
        try Task.checkCancellation()
        guard try Data(contentsOf: destination) == before else { throw Failure.changedProject }
        try GyroflowProject.backup(destination, to: backupDirectory)
        try Task.checkCancellation()
        try GyroflowProject.write(result.projectData, to: destination)
        return true
    }
}
