// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLVSwitchCore

private func frenchSizes(_ bytes: Int64) -> String {
    // ByteCountFormatter follows the formatter's locale via the system; French units (Go/Mo) via Bundle language is not
    // controllable here, so format with a French number style explicitly.
    let units: [(String, Double)] = [("To", 1e12), ("Go", 1e9), ("Mo", 1e6), ("Ko", 1e3)]
    let b = Double(bytes)
    for (u, v) in units where b >= v {
        let n = NumberFormatter()
        n.locale = Locale(identifier: "fr_FR")
        n.maximumFractionDigits = b / v < 10 ? 1 : 0
        return "\(n.string(from: NSNumber(value: b / v)) ?? "") \(u)"
    }
    return "\(bytes) octets"
}

func shootTitle(_ s: Shoot) -> String {
    let n = s.clips.count
    return "\(s.name) — \(n) clip\(n > 1 ? "s" : "") · \(frenchSizes(s.totalBytes))"
}

struct MenuLabel: View {
    @ObservedObject var state: AppState
    var body: some View {
        if state.alert != nil {
            Image(systemName: "exclamationmark.triangle")
        } else {
            HStack(spacing: 2) {
                Image(systemName: "film.stack")
                if !state.mounted.isEmpty { Text("\(state.mounted.count)") }
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let alert = state.alert {
            Button("⚠︎ Problème — voir le détail") { showDetail(alert, style: .warning) { state.clearAlert() } }
            Divider()
        }
        if let info = state.info {
            Button("ℹ︎ Conseil Resolve") { showDetail(info, style: .informational) { state.clearInfo() } }
            Divider()
        }
        Text(state.folder?.lastPathComponent ?? "Aucun dossier choisi")
        ForEach(state.shoots, id: \.folder) { shoot in
            let on = state.mounted.contains(shoot.folder.standardizedFileURL.path)
            Button {
                Task { await state.toggle(shoot) }
            } label: {
                if on { Label(shootTitle(shoot), systemImage: "circle.fill").foregroundStyle(.green) }
                else { Text(shootTitle(shoot)) }
            }
        }
        Divider()
        Button("Choisir un dossier…") { chooseFolder() }
        Button("Ouvrir Resolve") { openResolve() }
            .disabled(resolveURL == nil)
        Button("Afficher les DNG dans le Finder") {
            let root = MountPaths.defaultRoot
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
        Picker("Dual ISO", selection: Binding(get: { state.mode }, set: { m in Task { await state.setMode(m) } })) {
            Text("Montage fluide").tag(DualISOMode.montageFluide)
            Text("Qualité étalonnage").tag(DualISOMode.qualiteEtalonnage)
        }
        Divider()
        Button("Tout démonter") {
            Task { await state.unmountAll() }
        }
        .disabled(state.mounted.isEmpty)
        Button("Réglages…") {
            AppDelegate.shared?.showSettings(state: state)
        }
        Button("Quitter") { NSApp.terminate(nil) }
    }

    private func showDetail(_ text: String, style: NSAlert.Style, clear: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = "MLV Switch"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
        clear()
    }

    private var resolveURL: URL? { resolveAppURL(fileExists: { FileManager.default.fileExists(atPath: $0) }) }

    private func openResolve() {
        guard let url = resolveURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.choose(folder: url) }
        }
    }
}
