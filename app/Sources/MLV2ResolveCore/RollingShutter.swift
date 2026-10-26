// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreFoundation

/// EOS M Crop Mood Slim sensor timing, derived from crop_rec.c at
/// 14078c6ef4ff97f57e8b21f20705b24836256051. See docs/research/eosm-slim-rolling-shutter.md.
/// Dimensions are the recorded RAWI size, before horizontal desqueeze.
public enum RollingShutter {
    public static func readoutMS(for timing: ClipTiming) -> Double? {
        guard timing.fps.isFinite, timing.fps > 0 else { return nil }
        let size = (timing.width, timing.height)
        func sampling(_ x: Int, _ y: Int) -> Bool {
            if let sx = timing.samplingX, let sy = timing.samplingY { return sx == x && sy == y }
            return timing.squeeze == (x == 3 && y == 1 ? 3 : 1)
        }
        func near(_ rates: [Double]) -> Bool { rates.contains { abs(timing.fps - $0) < 0.1 } }
        var timerA: Int?
        if sampling(3, 1) {
            switch size {
            case (1504, 2538): if near([22.25]) { timerA = 0x1FF }
            case (1600, 2400): if near([23.3]) { timerA = 0x1FF }
            case (1376, 2322), (1664, 2268): if near([23.976]) { timerA = 0x1FF }
            case (1736, 2214), (1736, 2178): if near([23.976]) { timerA = 0x207 }
            case (1280, 2160), (1472, 2208), (1360, 2040),
                 (1552, 2216), (1552, 2118), (1424, 1942),
                 (1600, 2040), (1472, 1878), (1600, 2008), (1472, 1846): if near([23.976, 25]) { timerA = 0x1FF }
            case (1736, 3478): timerA = 0x207 // Internal Anam_FLV preset.
            default: break
            }
        } else if sampling(1, 1) {
            switch size {
            case (2520, 1080): if near([23.976, 25, 29.97]) { timerA = 0x2CB }
            case (2880, 1226): if near([23.976, 25]) { timerA = 0x325 }
            case (3072, 1308): if near([23.976]) { timerA = 0x35B }
            case (2560, 1440): if near([23.976, 25]) { timerA = 0x2DB }
            case (1920, 1280): if near([23.976, 25]) { timerA = 0x235 }
            case (2160, 1620): if near([23.943]) { timerA = 0x279 }
            case (1920, 1080): if near([23.976, 25, 29.97]) { timerA = 0x235 }
            case (5208, 3478): if near([3]) { timerA = 0x56B }
            default: break
            }
        }
        // Equal horizontal/vertical sampling also has squeeze 1: try 3x3 independently.
        if timerA == nil, sampling(3, 3) {
            switch size {
            case (1736, 976): if near([46.8, 42]) { timerA = 0x20F }
            case (1736, 868): if near([50, 48]) { timerA = 0x207 }
            case (1736, 790): if near([54, 50]) { timerA = 0x207 }
            case (1736, 738), (1736, 726): if near([57, 50]) { timerA = 0x207 }
            case (1736, 694): if near([60]) { timerA = 0x207 }
            case (1736, 1160), (1736, 1152):
                if near([25]) { timerA = 0x27F }
                else if near([23.976, 29.97]) { timerA = 0x20F }
            default: break
            }
        }
        guard let timerA else { return nil }
        return Double(timing.height) * Double(timerA + 1) / 32_000
    }

    /// Known sensor modes take precedence over generic lens timing. Unknown modes retain a user profile's
    /// signed readout (including zero to disable correction); absent/invalid timing disables correction.
    static func resolvedMS(for timing: ClipTiming, calibration: [String: Any]) -> Double {
        if let known = readoutMS(for: timing) { return known }
        guard let value = calibration["frame_readout_time"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return 0 }
        return value.doubleValue
    }
}
