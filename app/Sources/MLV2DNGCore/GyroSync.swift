// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Image motion between frame `frame - 1` and `frame`, as produced by `mlvmotion`.
public struct MotionSample: Sendable {
    public let frame: Int
    public let dx: Double
    public let dy: Double
    /// Relative match confidence (mlvmotion's own scale); only used for ranking.
    public let peak: Double

    public init(frame: Int, dx: Double, dy: Double, peak: Double) {
        self.frame = frame; self.dx = dx; self.dy = dy; self.peak = peak
    }
}

public struct SyncResult: Sendable, Equatable {
    /// Time of the clip's first frame in the log, in ms from the log start (negative: the clip starts before the log).
    public let lagMs: Int
    public let r2: Double
    /// Best R² at a lag more than 500 ms away from the winner.
    public let secondPeak: Double
    /// Gyro (rad) to image (px) map, 3 rows (gx gy gz) × 2 columns (dx dy).
    public let map: [[Double]]
}

public enum SyncRefusal: Error, Equatable {
    case notEnoughMotion
    case noOverlap
    case ambiguous(r2: Double, second: Double)
}

/// Finds where a clip sits inside a gyro log by matching per-frame image motion to the
/// gyro rotation integrated over each frame interval (mirrors poc/sync_gyro.py).
public enum GyroSync {
    public static let minR2 = 0.35
    public static let minMargin = 0.15
    public static let minMotionRMS = 1.0
    /// A lag is scorable if the log covers at least this many seconds of the clip...
    public static let minCoveredSeconds = 8.0
    /// ...or at least this fraction of the clip duration.
    public static let minCoveredFraction = 0.8
    static let minFrames = 8
    static let coarseStepMs = 10
    static let fineRadiusMs = 15
    static let secondPeakDistanceMs = 500
    static let dropFraction = 0.10

    public static func solve(motion: [MotionSample], fps: Double, gyro: [SIMD3<Float>],
                             rateHz: Double, searchMs: ClosedRange<Int>) throws -> SyncResult {
        guard motion.count >= minFrames, fps > 0, rateHz > 0 else { throw SyncRefusal.notEnoughMotion }

        // Drop the least reliable matches (lowest 10 % by peak).
        let sortedPeaks = motion.map(\.peak).sorted()
        let cut = sortedPeaks[min(sortedPeaks.count - 1, Int(Double(sortedPeaks.count) * dropFraction))]
        let kept = motion.filter { $0.peak >= cut }
        guard kept.count >= minFrames else { throw SyncRefusal.notEnoughMotion }

        let n = Double(kept.count)
        let mx = kept.reduce(0) { $0 + $1.dx } / n
        let my = kept.reduce(0) { $0 + $1.dy } / n
        let variance = kept.reduce(0) { $0 + ($1.dx - mx) * ($1.dx - mx) + ($1.dy - my) * ($1.dy - my) } / n
        guard variance.squareRoot() >= minMotionRMS else { throw SyncRefusal.notEnoughMotion }

        // Cumulative integrated angle (rad); index = log sample.
        var angle = [SIMD3<Double>](repeating: .zero, count: gyro.count + 1)
        var acc = SIMD3<Double>.zero
        for i in 0..<gyro.count {
            acc += SIMD3<Double>(gyro[i]) / rateHz
            angle[i + 1] = acc
        }
        let samplesPerMs = rateHz / 1000
        let count = kept.count
        var i0 = [Int](repeating: 0, count: count)  // frame interval start, in log samples from the clip start
        var i1 = [Int](repeating: 0, count: count)
        var dx = [Double](repeating: 0, count: count)
        var dy = [Double](repeating: 0, count: count)
        for (k, s) in kept.enumerated() {
            i0[k] = Int((Double(s.frame - 1) * 1000 / fps * samplesPerMs).rounded())
            i1[k] = Int((Double(s.frame) * 1000 / fps * samplesPerMs).rounded())
            dx[k] = s.dx; dy[k] = s.dy
        }
        let logCount = gyro.count
        let clipSeconds = Double(motion.count) / fps

        func score(_ lagMs: Int) -> (r2: Double, map: [[Double]])? {
            let off = Int((Double(lagMs) * samplesPerMs).rounded())
            // Sums over covered frames of x = [gx gy gz], y = [dx dy].
            var m = 0
            var sx = SIMD3<Double>.zero
            var sxx = [Double](repeating: 0, count: 9)
            var sy = SIMD2<Double>.zero
            var syy = SIMD2<Double>.zero
            var sxy = [Double](repeating: 0, count: 6)
            angle.withUnsafeBufferPointer { a in
                for k in 0..<count {
                    let s = off + i0[k], e = off + i1[k]
                    if s < 0 || e > logCount { continue }
                    let g = a[e] - a[s]
                    let yx = dx[k], yy = dy[k]
                    m += 1
                    sx += g
                    sy.x += yx; sy.y += yy
                    syy.x += yx * yx; syy.y += yy * yy
                    sxx[0] += g.x * g.x; sxx[1] += g.x * g.y; sxx[2] += g.x * g.z
                    sxx[4] += g.y * g.y; sxx[5] += g.y * g.z; sxx[8] += g.z * g.z
                    sxy[0] += g.x * yx; sxy[1] += g.x * yy
                    sxy[2] += g.y * yx; sxy[3] += g.y * yy
                    sxy[4] += g.z * yx; sxy[5] += g.z * yy
                }
            }
            let fraction = Double(m) / Double(count)
            let covered = fraction * clipSeconds
            guard m >= minFrames, covered >= minCoveredSeconds || fraction >= minCoveredFraction else { return nil }
            let mf = Double(m)
            // Centered normal equations (intercept eliminated): C b = c.
            let mean = sx / mf
            let ym = sy / mf
            var C = [[Double]](repeating: [0, 0, 0], count: 3)
            let raw: [[Double]] = [[sxx[0], sxx[1], sxx[2]], [sxx[1], sxx[4], sxx[5]], [sxx[2], sxx[5], sxx[8]]]
            let mv = [mean.x, mean.y, mean.z]
            for r in 0..<3 { for c in 0..<3 { C[r][c] = raw[r][c] - mf * mv[r] * mv[c] } }
            let cross: [[Double]] = [[sxy[0], sxy[1]], [sxy[2], sxy[3]], [sxy[4], sxy[5]]]
            let ymv = [ym.x, ym.y]
            var c = [[Double]](repeating: [0, 0], count: 3)
            for r in 0..<3 { for j in 0..<2 { c[r][j] = cross[r][j] - mf * mv[r] * ymv[j] } }
            let sst = (syy.x - mf * ym.x * ym.x) + (syy.y - mf * ym.y * ym.y)
            guard sst > 1e-12, let b = solve3(C, c) else { return nil }
            var explained = 0.0
            for r in 0..<3 { for j in 0..<2 { explained += b[r][j] * c[r][j] }}
            return (min(1, max(0, explained / sst)), b)
        }

        // Coarse pass.
        var coarse: [(r2: Double, lag: Int)] = []
        var lag = searchMs.lowerBound
        while lag <= searchMs.upperBound {
            if let s = score(lag) { coarse.append((s.r2, lag)) }
            lag += coarseStepMs
        }
        guard let top = coarse.max(by: { $0.r2 < $1.r2 }) else { throw SyncRefusal.noOverlap }

        // Fine pass around the coarse winner.
        var best = (r2: -1.0, lag: top.lag, map: [[Double]]())
        for l in max(searchMs.lowerBound, top.lag - fineRadiusMs)...min(searchMs.upperBound, top.lag + fineRadiusMs) {
            if let s = score(l), s.r2 > best.r2 { best = (s.r2, l, s.map) }
        }
        guard best.r2 >= 0 else { throw SyncRefusal.noOverlap }

        let second = coarse.filter { abs($0.lag - best.lag) > secondPeakDistanceMs }.map(\.r2).max() ?? 0
        guard best.r2 >= minR2, best.r2 - second >= minMargin else {
            throw SyncRefusal.ambiguous(r2: best.r2, second: second)
        }
        return SyncResult(lagMs: best.lag, r2: best.r2, secondPeak: second, map: best.map)
    }

    /// Solves C X = B for a symmetric 3×3 C and 3×2 B (Gaussian elimination, partial pivoting).
    private static func solve3(_ C: [[Double]], _ B: [[Double]]) -> [[Double]]? {
        var a = (0..<3).map { C[$0] + B[$0] }
        let scale = max(1e-300, (0..<3).map { abs(C[$0][$0]) }.max()!)
        for col in 0..<3 {
            var p = col
            for r in col + 1..<3 where abs(a[r][col]) > abs(a[p][col]) { p = r }
            if abs(a[p][col]) < 1e-12 * scale { return nil }
            a.swapAt(col, p)
            for r in 0..<3 where r != col {
                let f = a[r][col] / a[col][col]
                if f != 0 { for k in col..<5 { a[r][k] -= f * a[col][k] } }
            }
        }
        return (0..<3).map { [a[$0][3] / a[$0][$0], a[$0][4] / a[$0][$0]] }
    }
}
