// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimal MLV header reading (no frame data is touched).
public enum MLVHeader {
    /// Horizontal anamorphic squeeze factor from the RAWC block (same ratio as
    /// MLVFS's DefaultScale: (binning_x+skipping_x) : (binning_y+skipping_y),
    /// reduced). Returns nil unless the footage is squeezed horizontally only
    /// (e.g. 3 for 1x3 anamorphic), when there is no RAWC block before the
    /// first video frame, or when the file is unreadable.
    public static func horizontalSqueeze(of url: URL) -> Int? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var offset: UInt64 = 0
        for _ in 0..<64 {
            guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return nil }
            let type = String(decoding: head.prefix(4), as: UTF8.self)
            let size = head.withUnsafeBytes { UInt64($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
            if type == "VIDF" { return nil }
            guard size >= 16 else { return nil }
            if type == "RAWC" {
                // After blockType, blockSize, timestamp(8): res_x, res_y, crop, reserved (2 each), then 4 bytes.
                guard size >= 28, (try? fh.seek(toOffset: offset + 24)) != nil,
                      let s = try? fh.read(upToCount: 4), s.count == 4 else { return nil }
                let sx = Int(s[0]) + Int(s[1]), sy = Int(s[2]) + Int(s[3])
                guard sx > 0, sy > 0 else { return nil }
                var a = sx, b = sy
                while b != 0 { (a, b) = (b, a % b) }
                let h = sx / a, v = sy / a
                return (v == 1 && h > 1) ? h : nil
            }
            offset += size
            guard (try? fh.seek(toOffset: offset)) != nil else { return nil }
        }
        return nil
    }

    /// Start time and format of a clip, from MLVI/RAWI/RTCI/VIDF. Walks every
    /// block (seeking over frame data) including `.M00`… chunk files to count
    /// video frames. `start` = RTCI local time + (first VIDF ts − RTCI ts).
    /// Returns nil when RTCI, VIDF, MLVI or RAWI is missing or unreadable.
    public static func timing(of url: URL) -> ClipTiming? {
        var rtc: DateComponents?
        var rtcTs: UInt64 = 0
        var firstTs: UInt64?
        var frames = 0
        var fps = 0.0
        var width = 0, height = 0

        func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
        func u32(_ d: Data, _ o: Int) -> UInt64 { UInt64(u16(d, o)) | UInt64(u16(d, o + 2)) << 16 }
        func u64(_ d: Data, _ o: Int) -> UInt64 { u32(d, o) | u32(d, o + 4) << 32 }

        func walk(_ file: URL, isMain: Bool) -> Bool {
            guard let fh = try? FileHandle(forReadingFrom: file) else { return !isMain }
            defer { try? fh.close() }
            guard let end = try? fh.seekToEnd() else { return false }
            var offset: UInt64 = 0
            while offset + 16 <= end {
                guard (try? fh.seek(toOffset: offset)) != nil,
                      let head = try? fh.read(upToCount: 16), head.count == 16 else { break }
                let type = String(decoding: head.prefix(4), as: UTF8.self)
                let size = u32(head, 4)
                guard size >= 16 else { break }
                switch type {
                case "MLVI" where isMain:
                    if size >= 52, let b = try? fh.read(upToCount: 36), b.count == 36 {
                        // b starts at file offset 16; fps nom/denom at 44/48.
                        let nom = Double(u32(b, 44 - 16)), den = Double(u32(b, 48 - 16))
                        if den > 0 { fps = nom / den }
                    }
                case "RAWI" where isMain:
                    if size >= 20, let b = try? fh.read(upToCount: 4), b.count == 4 {
                        width = u16(b, 0); height = u16(b, 2)
                    }
                case "RTCI" where isMain && rtc == nil:
                    if size >= 28, let b = try? fh.read(upToCount: 12), b.count == 12 {
                        let sec = u16(b, 0), min = u16(b, 2), hour = u16(b, 4)
                        let day = u16(b, 6), mon = u16(b, 8), year = u16(b, 10) + 1900
                        guard (0...59).contains(sec), (0...59).contains(min), (0...23).contains(hour),
                              (1...31).contains(day), (0...11).contains(mon), year >= 2000 else { return false }
                        var c = DateComponents()
                        c.second = u16(b, 0); c.minute = u16(b, 2); c.hour = u16(b, 4)
                        c.day = u16(b, 6); c.month = u16(b, 8) + 1; c.year = u16(b, 10) + 1900
                        c.timeZone = TimeZone.current
                        rtc = c; rtcTs = u64(head, 8)
                    }
                case "VIDF":
                    guard offset + size <= end else { break }
                    frames += 1
                    if firstTs == nil { firstTs = u64(head, 8) }
                default: break
                }
                offset += size
            }
            return true
        }

        guard walk(url, isMain: true) else { return nil }
        // Chunk files: name.M00, name.M01, …
        let base = url.deletingPathExtension()
        for i in 0..<100 {
            let chunk = base.appendingPathExtension(String(format: "M%02d", i))
            guard FileManager.default.fileExists(atPath: chunk.path) else { break }
            _ = walk(chunk, isMain: false)
        }
        guard let comps = rtc, let first = firstTs, frames > 0, fps > 0, width > 0, height > 0,
              let base0 = Calendar(identifier: .gregorian).date(from: comps) else { return nil }
        let start = base0.addingTimeInterval((Double(first) - Double(rtcTs)) / 1_000_000)
        return ClipTiming(start: start, frames: frames, fps: fps, width: width, height: height,
                          squeeze: horizontalSqueeze(of: url) ?? 1)
    }
}

public struct ClipTiming: Sendable {
    /// Wall-clock (camera local time) of the first video frame.
    public let start: Date
    public let frames: Int
    public let fps: Double
    /// DNG size as served (RAWI xRes/yRes).
    public let width: Int
    public let height: Int
    /// Horizontal anamorphic squeeze (1 when none).
    public let squeeze: Int

    public init(start: Date, frames: Int, fps: Double, width: Int, height: Int, squeeze: Int) {
        self.start = start; self.frames = frames; self.fps = fps
        self.width = width; self.height = height; self.squeeze = squeeze
    }
    public var duration: TimeInterval { Double(frames) / fps }
}
