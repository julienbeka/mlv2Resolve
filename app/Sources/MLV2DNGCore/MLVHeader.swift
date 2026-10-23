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
}
