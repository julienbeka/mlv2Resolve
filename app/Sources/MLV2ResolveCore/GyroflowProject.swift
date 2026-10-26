// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where the IMU (SenseFlow) sits on the camera.
///
/// Gyroflow's `imu_orientation` is a 3-letter axis map: letter i names the sensor axis feeding camera axis i,
/// upper case = positive, lower case = negative. Only `top` ("XYZ") has been validated on a real clip.
/// The others are derived from it by rotating the sensor body with the face it is stuck on, i.e. composing
/// the Top map with a rotation of the camera frame:
/// - bottom: 180° about X  -> (x, -y, -z)  -> "Xyz"
/// - back:   +90° about X  -> (x,  z, -y)  -> "XZy"
/// - front:  -90° about X  -> (x, -z,  y)  -> "Xzy"
/// - left:   +90° about Y  -> (z,  y, -x)  -> "ZYx"
/// - right:  -90° about Y  -> (-z, y,  x)  -> "zYX"
/// `rotation` stays [0, 0, 0] for every position (the orientation string carries the whole mapping).
public enum MountingPosition: String, Codable, CaseIterable, Sendable {
    case top, bottom, front, back, left, right

    public var imuOrientation: String {
        switch self {
        case .top: "XYZ"
        case .bottom: "Xyz"
        case .back: "XZy"
        case .front: "Xzy"
        case .left: "ZYx"
        case .right: "zYX"
        }
    }

    public var rotation: [Double] { [0, 0, 0] }
}

public enum GyroflowProjectError: Error, Equatable {
    case serialization
    case invalidTiming
    case missingTemplate
}

/// Writer of the synced `.gyroflow` project read by Gyroflow (NiYien) and its DaVinci Resolve plugin.
public enum GyroflowProject {
    static func template() throws -> [String: Any] {
        guard let url = L10n.moduleBundle.url(forResource: "gyroflow-template", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GyroflowProjectError.missingTemplate }
        return obj
    }

    /// `<clipDir>_000000.gyroflow`
    public static func fileName(clipDir: String) -> String { "\(clipDir)_000000.gyroflow" }

    /// - Throws: `GyroflowProjectError`.
    /// - Parameter offsetMs: the Gyroflow offset, i.e. **minus** `SyncResult.lagMs` (negative when the log
    ///   starts before the clip; M24-1845: lag 4192 -> offset -4192).
    public static func make(clipDir: URL, timing: ClipTiming, log: URL, offsetMs: Double,
                            calibration: [String: Any], position: MountingPosition) throws -> Data {
        guard timing.fps.isFinite, timing.fps > 0, timing.frames > 0 else { throw GyroflowProjectError.invalidTiming }
        let durationMs = Double(timing.frames) / timing.fps * 1000
        let name = clipDir.lastPathComponent
        let w = timing.width, h = timing.height
        var p = try template()

        p["videofile"] = fileURL(clipDir.appendingPathComponent("\(name)_%06d.dng").path)
        p["date"] = isoDate()
        p["image_sequence_fps"] = num(timing.fps)
        p["image_sequence_start"] = 0
        p["offsets"] = offsets(durationMs: durationMs, offsetMs: offsetMs)

        var gyro = p["gyro_source"] as? [String: Any] ?? [:]
        gyro["filepath"] = fileURL(log.path)
        gyro["imu_orientation"] = position.imuOrientation
        gyro["rotation"] = position.rotation.map(num)
        p["gyro_source"] = gyro

        var cal = calibration
        cal["sync_settings"] = ["do_autosync": false]
        let readoutMS = RollingShutter.resolvedMS(for: timing, calibration: calibration)
        cal["frame_readout_time"] = readoutMS
        p["calibration_data"] = cal

        var stabilization = p["stabilization"] as? [String: Any] ?? [:]
        stabilization["frame_readout_time"] = readoutMS
        p["stabilization"] = stabilization

        var sync = p["synchronization"] as? [String: Any] ?? [:]
        sync["do_autosync"] = false
        sync["auto_sync_points"] = false
        p["synchronization"] = sync

        let ms = Int(durationMs.rounded())
        p["video_info"] = [
            "duration_ms": ms, "fps": num(timing.fps), "fps_scale": NSNull(), "height": h,
            "num_frames": timing.frames, "rotation": 0, "vfr_duration_ms": ms,
            "vfr_fps": num(timing.fps), "width": w,
        ] as [String: Any]

        var out = p["output"] as? [String: Any] ?? [:]
        out["output_folder"] = fileURL(clipDir.path)
        out["output_filename"] = "\(name)_000000_stabilized.gyroflow"
        out["output_width"] = w * timing.squeeze
        out["output_height"] = h
        p["output"] = out

        guard let data = try? JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { throw GyroflowProjectError.serialization }
        return data
    }

    /// Three sync points at 15/50/85 % of the clip. Key = gyro timestamp in µs = (video ms − offset) × 1000.
    static func offsets(durationMs: Double, offsetMs: Double) -> [String: Any] {
        var r = [String: Any]()
        for f in [0.15, 0.5, 0.85] {
            r[String(Int(((durationMs * f - offsetMs) * 1000).rounded()))] = offsetMs
        }
        return r
    }

    /// Atomic: temp file in the same directory, then replace; nothing left behind on error.
    public static func write(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // NiYien's scheme: "file:///" + absolute path (so "file:////Users/…"), every byte but unreserved and "/"
    // percent-encoded (so "%06d" -> "%2506d", space -> "%20").
    static func fileURL(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return "file:///" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    private static func num(_ d: Double) -> Any { d == d.rounded() && abs(d) < 1e9 ? Int(d) : d }

    private static func isoDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
