// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ServiceManagement
import MLVSwitchCore

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
            Toggle("Lancer au démarrage", isOn: Binding(get: { launchAtLogin }, set: { on in
                LaunchAtLogin.set(on)
                launchAtLogin = LaunchAtLogin.isEnabled
            }))
            DisclosureGroup("Avancé") {
                Toggle("Corriger les pixels morts", isOn: $state.fixBadPixels)
                Toggle("Corriger les focus pixels", isOn: $state.fixFocusPixels)
                Text("Appliqué au prochain montage.").font(.caption).foregroundStyle(.secondary)
            }
            Section("À propos") {
                Text("Inspiré de Switch par Danne · MLVFS par David Milligan · cartes de focus pixels et décodeur LJ92 issus de MLV App (ilia3101 et contributeurs)")
                Text("Logiciel libre sous licence GPL-3.0-or-later.")
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
