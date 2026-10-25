// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Chooses which A1 logs (and which lag range) to search for a clip.
public enum LogMatcher {
    /// Half-width of the search window around the expected position, in seconds.
    public static let windowSeconds = 30.0

    /// Skew convention: camera time = A1 time − skew (A1 = camera + skew).
    /// With a known skew only logs overlapping the expected clip interval ±30 s
    /// are returned, closest first, each searched at expected ± 30 s. Without,
    /// every log is returned (closest start first) with the full range.
    public static func candidates(for clip: ClipTiming, logs: [A1Log], skew: TimeInterval?)
        -> [(log: A1Log, searchMs: ClosedRange<Int>)] {
        let clipMs = Int((clip.duration * 1000).rounded())
        guard let skew else {
            return logs
                .sorted { abs($0.start.timeIntervalSince(clip.start)) < abs($1.start.timeIntervalSince(clip.start)) }
                .map { ($0, (-clipMs)...Int(($0.duration * 1000).rounded())) }
        }
        let w = windowSeconds
        var out: [(log: A1Log, searchMs: ClosedRange<Int>, key: Double)] = []
        for log in logs {
            let expected = clip.start.timeIntervalSince(log.start) + skew  // clip start in log time (s)
            let lo = expected - w, hi = expected + clip.duration + w
            guard hi >= 0, lo <= log.duration else { continue }
            let ms = Int((expected * 1000).rounded())
            let wms = Int(w * 1000)
            let dist = expected < 0 ? -expected : max(0, expected - log.duration)
            let key = dist * 1e6 + abs(expected - log.duration / 2)  // inside-log ties: nearest the log centre
            out.append((log, (ms - wms)...(ms + wms), key))
        }
        return out.sorted { $0.key < $1.key }.map { ($0.log, $0.searchMs) }
    }

    /// Median over synced entries of (log.start + lagMs/1000 − clip.start); nil if empty.
    public static func estimateSkew(_ synced: [(clip: ClipTiming, log: A1Log, lagMs: Int)]) -> TimeInterval? {
        let v = synced.map { $0.log.start.timeIntervalSince($0.clip.start) + Double($0.lagMs) / 1000 }.sorted()
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }
}
