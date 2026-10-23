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
                banner(info, button: "Fermer", tint: .blue, icon: "info.circle.fill") { state.clearInfo() }
            }
            HStack {
                Text(state.folder.map { "Dossier : \($0.lastPathComponent)" } ?? "Aucun dossier choisi")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choisir un dossier…") { MenuActions.chooseFolder(state: state) }
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
                Text("Montage fluide").tag(DualISOMode.montageFluide)
                Text("Qualité étalonnage").tag(DualISOMode.qualiteEtalonnage)
            }
            .pickerStyle(.segmented)
            Divider()
            HStack {
                Button("Ouvrir Resolve") { MenuActions.openResolve() }.disabled(MenuActions.resolveURL == nil)
                Button("Afficher les DNG dans le Finder") { MenuActions.showDNGsInFinder() }
                Spacer()
            }
            HStack {
                Button("Tout démonter") { Task { await state.unmountAll() } }.disabled(state.mounted.isEmpty)
                Button("Réglages…") { AppDelegate.shared?.showSettings(state: state) }
                if state.needsFuseT {
                    Button("Installer FUSE-T…") { AppDelegate.shared?.showOnboarding() }
                }
                Spacer()
            }
            Text("mlv2dng reste disponible dans la barre des menus (icône pellicule). Si l'icône n'apparaît pas, la barre des menus est peut-être pleine : cette fenêtre s'ouvre aussi en double-cliquant sur l'app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func banner(_ text: String, button: String, tint: Color, icon: String, clear: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: clear)
        }
        .padding(10)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
