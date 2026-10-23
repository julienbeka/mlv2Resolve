// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit

/// Conservative support for the observed Resolve 21 local-library preset format.
public enum ResolvePresets {
    public enum Preparation: Equatable, Sendable { case ready, created, manual }

    public static var localFile: URL {
        ResolveDesqueeze.resolveSupportDirectory.appendingPathComponent(
            "Resolve Project Library/Resolve Projects/Settings/PTZRInputPresetList.xml")
    }

    public static func isResolveRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier?.lowercased().contains("blackmagic") == true
                && $0.bundleIdentifier?.lowercased().contains("resolve") == true)
                || ($0.localizedName?.lowercased().contains("davinci resolve") == true)
                || $0.executableURL?.lastPathComponent == "Resolve"
        }
    }

    /// Never creates a library or guesses an unknown XML schema. No writes while Resolve runs.
    public static func prepare(factors: [Int], file: URL = localFile,
                               isRunning: () -> Bool = isResolveRunning) -> Preparation {
        let factors = Set(factors)
        guard !factors.isEmpty else { return .ready }
        guard factors.isSubset(of: [3, 5]), !isRunning() else { return .manual }
        do {
            let original = try Data(contentsOf: file)
            let document = try XMLDocument(data: original, options: [.nodePreserveAll])
            guard document.dtd == nil, let root = document.rootElement(),
                  root.name == "SmPTZRInputPresetList",
                  root.elements(forName: "PresetList").count == 1 else { return .manual }
            let list = root.elements(forName: "PresetList")[0]
            let entries = list.elements(forName: "Element")
            guard entries.count == list.children?.filter({ $0.kind == .element }).count,
                  entries.allSatisfy({ $0.elements(forName: "SmPTZRPreset").count == 1 }) else { return .manual }
            let presets = entries.flatMap { $0.elements(forName: "SmPTZRPreset") }
            var missing: [Int] = []
            for factor in factors.sorted() {
                let existing = presets.filter { $0.elements(forName: "Name").first?.stringValue == ResolveDesqueeze.presetName(factor) }
                if existing.isEmpty { missing.append(factor) }
                else {
                    // A conflicting user preset must be handled manually, never replaced.
                    guard existing.count == 1,
                          existing[0].elements(forName: "Presets").first?.stringValue?.lowercased() == payload(factor) else { return .manual }
                }
            }
            guard !missing.isEmpty else { return .ready }
            for factor in missing {
                let entry = XMLElement(name: "Element")
                let preset = XMLElement(name: "SmPTZRPreset")
                preset.addAttribute(XMLNode.attribute(withName: "DbId", stringValue: UUID().uuidString.lowercased()) as! XMLNode)
                preset.addChild(XMLElement(name: "FieldsBlob"))
                for (key, value) in [("Name", ResolveDesqueeze.presetName(factor)), ("ID", "101"),
                                     ("IsCustom", "true"), ("Producer", "guest"), ("Presets", payload(factor))] {
                    preset.addChild(XMLElement(name: key, stringValue: value))
                }
                entry.addChild(preset)
                list.addChild(entry)
            }
            let updated = document.xmlData(options: [.nodePreserveAll])
            // Backup must succeed before replacement; recheck for launches and concurrent edits.
            guard !isRunning(), try Data(contentsOf: file) == original else { return .manual }
            let backup = file.deletingLastPathComponent().appendingPathComponent(
                file.lastPathComponent + ".mlv2dng-" + UUID().uuidString + ".bak")
            try original.write(to: backup, options: .withoutOverwriting)
            guard !isRunning(), try Data(contentsOf: file) == original else { return .manual }
            try updated.write(to: file, options: .atomic)
            return .created
        } catch {
            return .manual
        }
    }

    /// Width=factor, Height=1; all other fields match the manually saved Resolve preset.
    static func payload(_ factor: Int) -> String {
        let text = "{PN{7}K~10300001}I PB{Para|\(factor)}}PN{7}K~10300002}I PB{Para|1}}PN{7}K~10300003}I PB{Para|1}}PN{7}K~10300004}I PB{Para|}}PN{7}K~10300005}I PB{Para|}}PN{7}K~10300006}I PB{Para|}}PN{6}K~10300007}I PB{Para{}}PN{6}K~10300008}I PB{Para{}}}"
        return text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func createdMessage() -> String {
        String(localized: "Input Sizing presets created in the local Resolve library. A backup was saved beside the settings file. Open that library and a project in Resolve, then click Desqueeze in Resolve again. Shared or relocated libraries require manual preset creation.", bundle: L10n.bundle)
    }

    public static func manualMessage() -> String {
        String(localized: "To install the presets automatically, quit Resolve and click Desqueeze in Resolve again. Automatic installation supports only the default local library. Otherwise, create the presets manually:", bundle: L10n.bundle)
    }
}
