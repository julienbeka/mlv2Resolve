// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLVSwitchCore

/// Launch with `-MLVSwitchForceOnboarding YES` to force the "FUSE-T missing" state (manual testing).
enum OnboardingSupport {
    static var forced: Bool { UserDefaults.standard.bool(forKey: "MLVSwitchForceOnboarding") }
    static func currentState() -> DependencyState {
        forced ? .fuseTMissing : Dependencies.live.check()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var state: DependencyState = OnboardingSupport.currentState()
    @Published var progress: Double?
    @Published var errorMessage: String?
    @Published var installerOpened = false
    let resolveFound = resolveAppURL(fileExists: { FileManager.default.fileExists(atPath: $0) }) != nil
    var onReady: () -> Void = {}
    private var timer: Timer?

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func recheck() {
        state = OnboardingSupport.currentState()
        if state == .ready { stopPolling(); onReady() }
    }

    func install() {
        errorMessage = nil
        progress = 0
        Task {
            do {
                let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .deletingLastPathComponent().appendingPathComponent("Caches/MLV Switch")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(Dependencies.fuseTInstaller.lastPathComponent)
                let (bytes, response) = try await URLSession.shared.bytes(from: Dependencies.fuseTInstaller)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                let total = Double(response.expectedContentLength)
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if total > 0, data.count % 65536 == 0 { progress = Double(data.count) / total }
                }
                try data.write(to: dest, options: .atomic)
                progress = nil
                installerOpened = true
                NSWorkspace.shared.open(dest)
            } catch {
                progress = nil
                errorMessage = "Le téléchargement a échoué (\(error.localizedDescription)). Vérifiez votre connexion et réessayez."
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bienvenue dans MLV Switch").font(.title2.bold())
            Text("Pour afficher vos MLV en DNG, MLV Switch a besoin de FUSE-T, un composant gratuit qui ne modifie pas la sécurité de votre Mac. L'installation demande votre mot de passe une seule fois.")
                .fixedSize(horizontal: false, vertical: true)
            if case let .fuseTOutdated(found, minimum) = model.state {
                Text("La version de FUSE-T installée (\(found)) est trop ancienne (minimum \(minimum)).")
                    .foregroundStyle(.orange)
            }
            if let p = model.progress {
                ProgressView(value: p > 0 ? p : nil) { Text("Téléchargement de FUSE-T…") }
            }
            if let e = model.errorMessage { Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if model.installerOpened {
                Text("Suivez l'installateur. Cette fenêtre se fermera automatiquement.").foregroundStyle(.secondary)
            }
            if !model.resolveFound {
                Text("DaVinci Resolve n'a pas été trouvé — vous pourrez l'installer plus tard.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Installer FUSE-T") { model.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.progress != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = OnboardingModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard model.state != .ready else { return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model)))
        w.title = "MLV Switch"
        w.styleMask = [.titled, .closable]
        w.center()
        window = w
        model.onReady = { [weak self] in self?.window?.close(); self?.window = nil }
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
