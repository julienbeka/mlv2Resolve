// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import ServiceManagement
import MLV2DNGCore

enum LaunchAtLogin {
    static let initKey = "launchAtLoginInitialized"
    /// On by default: registered once at first launch.
    static func initializeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: initKey) else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            NSLog("Launch at login: not registering, app not in /Applications (\(Bundle.main.bundleURL.path))")
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: initKey)
        } catch { NSLog("Launch at login: \(error)") }
    }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Launch at login: \(error)") }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { on in
                LaunchAtLogin.set(on)
                launchAtLogin = LaunchAtLogin.isEnabled
            }))
            DisclosureGroup("Advanced") {
                Toggle("Fix Dead Pixels", isOn: $state.fixBadPixels)
                Toggle("Fix Focus Pixels", isOn: $state.fixFocusPixels)
                Text("Applied the next time a shoot is mounted.").font(.caption).foregroundStyle(.secondary)
                Button("Open Logs Folder") {
                    let dir = EngineLog.defaultDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
            Section("About") {
                Text("Inspired by Switch by Danne · MLVFS by David Milligan · focus pixel maps and LJ92 decoder from MLV App (ilia3101 and contributors)")
                Text("Free software under the GPL-3.0-or-later license.")
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
