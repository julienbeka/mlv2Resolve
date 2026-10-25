// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reader for NiYien SenseFlow A1 gyro logs (`*_mix.bin`). Read-only; format in poc/NOTES.md.
public struct A1Log: Sendable {
    public enum ReadError: Error, Equatable {
        case tooShort
        case notSenseFlow
        case invalidDate
    }

    public static let headerSize = 0x200
    public static let recordSize = 16
    /// Gyroscope scale: 32.8 LSB per degree/second (±1000 °/s).
    public static let gyroLSBPerDPS: Float = 32.8

    public let url: URL
    /// Log start, header date interpreted in the current time zone (1 s resolution).
    public let start: Date
    public let rateHz: Double
    /// Gyro samples in rad/s, axes as in the log.
    public let gyro: [SIMD3<Float>]

    public var duration: TimeInterval { Double(gyro.count) / rateHz }

    public static func read(_ url: URL) throws -> A1Log {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= headerSize else { throw ReadError.tooShort }
        let magic = Array("SenseFlow".utf8)
        guard data.prefix(magic.count).elementsEqual(magic) else { throw ReadError.notSenseFlow }

        let base = data.startIndex
        let d = (0..<6).map { Int(data[base + 0x40 + $0]) }
        var comps = DateComponents()
        comps.year = 2000 + d[0]; comps.month = d[1]; comps.day = d[2]
        comps.hour = d[3]; comps.minute = d[4]; comps.second = d[5]
        comps.timeZone = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        guard let start = cal.date(from: comps), cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: start) == {
                var c = comps; c.timeZone = nil; return c }()
        else { throw ReadError.invalidDate }

        let scale = Float.pi / 180 / gyroLSBPerDPS
        var gyro: [SIMD3<Float>] = []
        gyro.reserveCapacity((data.count - headerSize) / recordSize)
        let end = data.count
        var pos = headerSize
        while pos + recordSize <= end {
            let p = base + pos
            if data[p] == 0xAA, data[p + 1] == 0x55, data[p + 2] == 0x03 {
                func i16(_ o: Int) -> Int16 {
                    Int16(bitPattern: UInt16(data[p + o]) | UInt16(data[p + o + 1]) << 8)
                }
                gyro.append(SIMD3(Float(i16(9)), Float(i16(11)), Float(i16(13))) * scale)
                pos += recordSize
            } else if data[p] == 0x55, data[p + 1] == 0xAA, data[p + 2] == 0x40 {
                pos += recordSize  // one-second marker
            } else {
                pos += 1  // stray byte: resync on the next record header
            }
        }
        return A1Log(url: url, start: start, rateHz: 1000, gyro: gyro)
    }

    /// Every `*_mix.bin` under `folder`, recursively; skips hidden items and `Temp` directories.
    public static func find(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if u.lastPathComponent.lowercased() == "temp" { en.skipDescendants() }
            } else if u.lastPathComponent.hasSuffix("_mix.bin") {
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}
