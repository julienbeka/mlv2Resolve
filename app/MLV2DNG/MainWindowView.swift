// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLV2DNGCore

/// The main window: the same commands as the menu-bar menu, for when the icon is hidden (notch, full menu bar).
struct MainWindowView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let alert = state.alert {
                banner(alert, button: "OK", tint: .orange, icon: "exclamationmark.triangle.fill") { state.clearAlert() }
            }
            if let info = state.info {
                banner(info, button: "Close", tint: .blue, icon: "info.circle.fill") { state.clearInfo() }
            }
            HStack {
                Group {
                    if let folder = state.folder { Text("Folder: \(folder.lastPathComponent)") } else { Text("No folder chosen") }
                }
                .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { MenuActions.chooseFolder(state: state) }
            }
            if !state.shoots.isEmpty {
                let list = VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.shoots, id: \.folder) { shoot in
                        let key = shoot.folder.standardizedFileURL.path
                        HStack(spacing: 6) {
                            Toggle(shootTitle(shoot), isOn: Binding(
                                get: { state.mounted.contains(key) },
                                set: { _ in Task { await state.toggle(shoot) } }))
                            .disabled(state.busy.contains(key))
                            if state.busy.contains(key) { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if state.shoots.count > 8 {
                    ScrollView { list.padding(.vertical, 2) }.frame(height: 8 * 24)
                } else {
                    list
                }
            }
            Picker("Dual ISO", selection: Binding(get: { state.mode }, set: { m in Task { await state.setMode(m) } })) {
                Text("Smooth Editing").tag(DualISOMode.montageFluide)
                Text("Grading Quality").tag(DualISOMode.qualiteEtalonnage)
            }
            .pickerStyle(.segmented)
            Divider()
            HStack {
                Button("Open Resolve") { MenuActions.openResolve() }.disabled(MenuActions.resolveURL == nil)
                Button("Desqueeze in Resolve") { MenuActions.desqueeze(state: state) }
                    .disabled(state.desqueezing || state.desqueezeTargets.isEmpty || MenuActions.resolveURL == nil)
                Button("Show DNGs in Finder") { MenuActions.showDNGsInFinder() }
                Spacer()
            }
            HStack {
                Button("Unmount All") { Task { await state.unmountAll() } }.disabled(state.mounted.isEmpty)
                Button("Settings…") { AppDelegate.shared?.showSettings(state: state) }
                if state.needsFuseT {
                    Button("Install FUSE-T…") { AppDelegate.shared?.showOnboarding() }
                }
                Spacer()
            }
            Text("mlv2dng stays available in the menu bar (∞ icon). If the icon doesn't appear, the menu bar may be full: this window also opens when you double-click the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func banner(_ text: String, button: LocalizedStringKey, tint: Color, icon: String, clear: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: clear)
        }
        .padding(10)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
