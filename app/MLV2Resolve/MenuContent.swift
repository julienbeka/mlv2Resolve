// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLV2ResolveCore

/// File size in the app's language (decimal units, like Finder). `ByteCountFormatter` cannot be pointed at the app's
/// preferred localization (it prints "GB" even in French), so the units are chosen from the UI language.
func localizedSize(_ bytes: Int64, language: String = Bundle.main.preferredLocalizations.first ?? "en") -> String {
    let french = language.hasPrefix("fr")
    let units: [(String, Double)] = french
        ? [("To", 1e12), ("Go", 1e9), ("Mo", 1e6), ("Ko", 1e3)]
        : [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
    let b = Double(bytes)
    for (u, v) in units where b >= v {
        let n = NumberFormatter()
        n.locale = Locale(identifier: french ? "fr_FR" : "en_US")
        n.maximumFractionDigits = b / v < 10 ? 1 : 0
        return "\(n.string(from: NSNumber(value: b / v)) ?? "") \(u)"
    }
    return french ? "\(bytes) octets" : "\(bytes) bytes"
}

func shootTitle(_ s: Shoot) -> String {
    let n = s.clips.count
    return String(localized: "\(s.name) — \(String(localized: "\(n) clips")) · \(localizedSize(s.totalBytes))")
}

/// Actions shared by the menu and the main window.
@MainActor
enum MenuActions {
    static var resolveURL: URL? { resolveAppURL(fileExists: { FileManager.default.fileExists(atPath: $0) }) }

    static func openResolve(state: AppState) {
        guard let url = resolveURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func confirmSwitch(_ current: String, _ target: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Switch Resolve project?")
        alert.informativeText = String(localized: "Save “\(current)” and open “\(target)”? Resolve will save the current project before switching.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Save and Open"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func openLinked(_ link: ResolveProjectStore.Link, state: AppState) {
        guard let url = resolveURL else { return }
        Task {
            let result = await state.openLinkedProject(link, launch: {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }, confirmSwitch: confirmSwitch)
            if let result { showDetail(result.text, style: result.isError ? .warning : .informational) {} }
        }
    }

    static func createProject(state: AppState) {
        guard let url = resolveURL, !state.openingResolve, !state.waitingForResolveGyro else { return }
        var waitForGyro = false
        if state.gyro?.progress.isActive == true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Gyro files are still being prepared")
            alert.informativeText = String(localized: "Some .gyroflow files are not ready yet. Wait for gyro sync to finish before editing these clips.")
            alert.addButton(withTitle: String(localized: "Wait"))
            alert.addButton(withTitle: String(localized: "Open Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response != .alertThirdButtonReturn else { return }
            waitForGyro = response == .alertFirstButtonReturn
        }
        Task {
            if waitForGyro, !(await state.waitForResolveGyro()) { return }
            let result = await state.openResolveProjects(launch: {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }, confirmSwitch: { current, target in
                let alert = NSAlert()
                alert.messageText = String(localized: "Switch Resolve project?")
                alert.informativeText = String(localized: "Save “\(current)” and open “\(target)”? Resolve will save the current project before switching.")
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.addButton(withTitle: String(localized: "Save and Open"))
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertSecondButtonReturn
            }, createOnly: true)
            if let result { showDetail(result.text, style: result.isError ? .warning : .informational) {} }
        }
    }

    static func desqueeze(state: AppState) {
        Task {
            guard let result = await state.desqueezeInResolve() else { return }
            showDetail(result.text, style: result.isError ? .warning : .informational) {}
        }
    }

    static func showDNGsInFinder() {
        let root = MountPaths.defaultRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    static func chooseFolder(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.choose(folder: url) }
        }
    }

    static func showDetail(_ text: String, style: NSAlert.Style, clear: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = "mlv2Resolve"
        a.informativeText = text
        a.addButton(withTitle: String(localized: "OK"))
        a.runModal()
        clear()
    }
}

struct MenuLabel: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 2) {
            if state.alert != nil || state.needsFuseT {
                Image(systemName: "exclamationmark.triangle")
            } else {
                Image(systemName: "infinity")
                if !state.mounted.isEmpty { Text("\(state.mounted.count)") }
            }
            if let gyro = state.gyro { GyroMenuActivity(gyro: gyro) }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.needsFuseT {
            Button("Install FUSE-T…") { AppDelegate.shared?.showOnboarding() }
            Divider()
        }
        if let alert = state.alert {
            Button("⚠︎ Problem — See Details") { MenuActions.showDetail(alert, style: .warning) { state.clearAlert() } }
            Divider()
        }
        if let info = state.info {
            Button("ℹ︎ Resolve Tip") { MenuActions.showDetail(info, style: .informational) { state.clearInfo() } }
            Divider()
        }
        if let folder = state.folder { Text(verbatim: folder.lastPathComponent) } else { Text("No folder chosen") }
        ForEach(state.shoots, id: \.folder) { shoot in
            let on = state.mounted.contains(shoot.folder.standardizedFileURL.path)
            Button {
                Task { await state.toggle(shoot) }
            } label: {
                if on { Label(shootTitle(shoot), systemImage: "circle.fill").foregroundStyle(.green) }
                else { Text(shootTitle(shoot)) }
            }
            .disabled(state.busy.contains(shoot.folder.standardizedFileURL.path))
        }
        if let gyro = state.gyro { GyroProgressLabel(gyro: gyro) }
        Divider()
        Button("Choose Folder…") { MenuActions.chooseFolder(state: state) }
        Button("Create Project") { MenuActions.createProject(state: state) }
            .disabled(state.mounted.isEmpty || state.openingResolve || state.waitingForResolveGyro)
        Button("Open Resolve") { MenuActions.openResolve(state: state) }
            .disabled(MenuActions.resolveURL == nil || state.openingResolve || state.waitingForResolveGyro || state.desqueezing)
        Button("Desqueeze in Resolve") { MenuActions.desqueeze(state: state) }
            .disabled(state.desqueezing || state.openingResolve || state.waitingForResolveGyro || state.desqueezeTargets.isEmpty || MenuActions.resolveURL == nil)
        Button("Show DNGs in Finder") { MenuActions.showDNGsInFinder() }
        Divider()
        Button("Unmount All") {
            Task { await state.unmountAll() }
        }
        .disabled(state.mounted.isEmpty)
        Button("Open mlv2Resolve Window") { AppDelegate.shared?.showMainWindow() }
        Button("Settings…") {
            AppDelegate.shared?.showSettings(state: state)
        }
        Button("Quit mlv2Resolve") { NSApp.terminate(nil) }
    }
}
