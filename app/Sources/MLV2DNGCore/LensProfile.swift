// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum LensProfileError: Error, Equatable {
    case invalid
    case dimensionMismatch(expected: String, found: String)
}

/// Gyroflow `calibration_data` for a clip.
public enum LensProfile {
    /// EOS M sensor pitch: 22.3 mm over 5184 px.
    public static let eosMPitchMM = 22.3 / 5184

    /// Pinhole profile (no distortion) computed from the declared focal length. Dimensions are those of the
    /// desqueezed image (width × squeeze); the focal in pixels is focal / sensor pitch, independent of the crop.
    public static func computed(focalMM: Double, lensName: String = "", timing: ClipTiming) -> [String: Any] {
        let w = timing.width * timing.squeeze, h = timing.height
        let f = focalMM / eosMPitchMM
        let dim: [String: Any] = ["w": w, "h": h]
        let label = lensName.isEmpty ? String(format: "%g mm", focalMM) : lensName
        return [
            "asymmetrical": false,
            "calib_dimension": dim,
            "calibrated_by": "mlv2dng",
            "calibrator_version": "1.0",
            "camera_brand": "Canon",
            "camera_model": "EOS M",
            "camera_setting": "APSC_Horizontal Squeeze_\(String(format: "%.2f", Double(timing.squeeze)))",
            "compatible_settings": [Any](),
            "crop": NSNull(),
            "crop_factor": NSNull(),
            "date": "2026-10-25",
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
            "frame_readout_time": 15.8,
            "global_shutter": false,
            "gyro_lpf": NSNull(),
            "identifier": "",
            "input_horizontal_stretch": timing.squeeze,
            "input_vertical_stretch": 1,
            "interpolations": NSNull(),
            "lens_model": "",
            "name": "mlv2dng \(label) \(w)x\(h) 1x\(timing.squeeze)",
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
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
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
}
