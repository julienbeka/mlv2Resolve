// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum LensProfileError: Error, Equatable {
    case invalid
    case unreadable
    case invalidFocal
    case dimensionMismatch(expected: String, found: String)
}

/// Gyroflow `calibration_data` for a clip.
public enum LensProfile {
    /// EOS M sensor pitch: 22.3 mm over 5184 px.
    public static let eosMPitchMM = 22.3 / 5184

    /// Pinhole profile (no distortion) computed from the declared focal length. Dimensions are those of the
    /// desqueezed image (width × squeeze); the focal in pixels is focal / sensor pitch, independent of the crop.
    public static func computed(focalMM: Double, lensName: String = "", timing: ClipTiming) throws -> [String: Any] {
        guard focalMM.isFinite, focalMM > 0 else { throw LensProfileError.invalidFocal }
        let w = timing.width * timing.squeeze, h = timing.height
        let f = focalMM / eosMPitchMM
        let dim: [String: Any] = ["w": w, "h": h]
        let label = lensName.isEmpty ? String(format: "%g mm", focalMM) : lensName
        return [
            "asymmetrical": false,
            "calib_dimension": dim,
            "calibrated_by": "mlv2Resolve",
            "calibrator_version": "1.0",
            "camera_brand": "Canon",
            "camera_model": "EOS M",
            "camera_setting": "APSC_Horizontal Squeeze_\(String(format: "%.2f", Double(timing.squeeze)))",
            "compatible_settings": [Any](),
            "crop": NSNull(),
            "crop_factor": NSNull(),
            "date": today(),
            "digital_lens": NSNull(),
            "digital_lens_params": NSNull(),
            "distortion_model": NSNull(),
            "fisheye_params": [
                "RMS_error": 0.1,
                "camera_matrix": [[f, 0, Double(w) / 2], [0, f, Double(h) / 2], [0, 0, 1]],
                "distortion_coeffs": [0.0, 0.0, 0.0, 0.0],
                "radial_distortion_limit": NSNull(),
            ] as [String: Any],
            "focal_length": focalMM,
            "fps": timing.fps,
            "frame_readout_time": RollingShutter.readoutMS(for: timing) ?? 0,
            "global_shutter": false,
            "gyro_lpf": NSNull(),
            "identifier": "",
            "input_horizontal_stretch": timing.squeeze,
            "input_vertical_stretch": 1,
            "interpolations": NSNull(),
            "lens_model": "",
            "name": "mlv2Resolve \(label) \(w)x\(h) 1x\(timing.squeeze)",
            "note": "",
            "num_images": 1,
            "official": false,
            "orig_dimension": dim,
            "output_dimension": dim,
            "sync_settings": ["do_autosync": false],
        ]
    }

    /// Reads a user-supplied Gyroflow lens profile; accepted only if it was calibrated for the clip's geometry.
    public static func calibrated(_ url: URL, for timing: ClipTiming) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { throw LensProfileError.unreadable }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dim = obj["calib_dimension"] as? [String: Any],
              let w = (dim["w"] as? NSNumber)?.doubleValue, let h = (dim["h"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { throw LensProfileError.invalid }
        let stretch = (obj["input_horizontal_stretch"] as? NSNumber)?.doubleValue ?? 1
        let ew = Double(timing.width * timing.squeeze), eh = Double(timing.height)
        let aspectOK = abs((w / h) / (ew / eh) - 1) <= 0.01
        let stretchOK = abs(stretch / Double(timing.squeeze) - 1) <= 0.01
        guard aspectOK && stretchOK else {
            throw LensProfileError.dimensionMismatch(
                expected: "\(Int(ew))x\(Int(eh)) stretch \(timing.squeeze)",
                found: "\(Int(w))x\(Int(h)) stretch \(stretch)")
        }
        obj["sync_settings"] = ["do_autosync": false]
        return obj
    }

    /// Calibration dimensions and horizontal stretch of a Gyroflow lens profile, to check a file on import.
    public static func dimensions(of url: URL) throws -> (width: Int, height: Int, stretch: Double) {
        guard let data = try? Data(contentsOf: url) else { throw LensProfileError.unreadable }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dim = obj["calib_dimension"] as? [String: Any],
              let w = (dim["w"] as? NSNumber)?.doubleValue, let h = (dim["h"] as? NSNumber)?.doubleValue,
              w > 0, h > 0, w.isFinite, h.isFinite else { throw LensProfileError.invalid }
        let stretch = (obj["input_horizontal_stretch"] as? NSNumber)?.doubleValue ?? 1
        return (Int(w.rounded()), Int(h.rounded()), stretch)
    }

    /// Where imported profiles are copied: `<root>/<lens id>/`.
    public static func importedDirectory(lensID: UUID, root: URL) -> URL {
        root.appendingPathComponent(lensID.uuidString, isDirectory: true)
    }

    /// Checks a Gyroflow lens profile and copies it to `<root>/<lens id>/<file name>` (replacing a previous copy
    /// of the same name), so the lens keeps working if the original is moved. Returns the copy's URL.
    public static func importProfile(_ url: URL, lensID: UUID, root: URL) throws -> URL {
        _ = try dimensions(of: url)
        let fm = FileManager.default
        let dir = importedDirectory(lensID: lensID, root: root)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if dest.standardizedFileURL == url.standardizedFileURL { return dest }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.copyItem(at: url, to: tmp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        return dest
    }

    /// Deletes the copies in `<root>/<lens id>/` that are not in `keep` (all of them when `keep` is empty).
    public static func pruneImported(lensID: UUID, root: URL, keep: [URL]) {
        let fm = FileManager.default
        let dir = importedDirectory(lensID: lensID, root: root)
        let kept = Set(keep.map { $0.standardizedFileURL.path })
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names {
            let u = dir.appendingPathComponent(n)
            if !kept.contains(u.standardizedFileURL.path) { try? fm.removeItem(at: u) }
        }
        if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
