// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MLV2ResolveCore

/// Launch with `-MLV2ResolveForceOnboarding YES` to force the "FUSE-T missing" state (manual testing).
enum OnboardingSupport {
    static var forced: Bool { UserDefaults.standard.bool(forKey: "MLV2ResolveForceOnboarding") || UserDefaults.standard.bool(forKey: "MLV2DNGForceOnboarding") }
    static func currentState() -> DependencyState {
        forced ? .fuseTMissing : Dependencies.live.check()
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onDone: @Sendable (Result<URL, Error>, Int?, Int64, Int64) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void,
         onDone: @escaping @Sendable (Result<URL, Error>, Int?, Int64, Int64) -> Void) {
        self.onProgress = onProgress; self.onDone = onDone
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { onProgress(Double(w) / Double(e)) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        // Move out of the temp location before the delegate returns (it is deleted afterwards).
        let status = (t.response as? HTTPURLResponse)?.statusCode
        let expected = t.response?.expectedContentLength ?? -1
        let size = (try? FileManager.default.attributesOfItem(atPath: loc.path)[.size] as? Int64) ?? 0
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: loc, to: keep); onDone(.success(keep), status, size, expected) }
        catch { onDone(.failure(error), status, size, expected) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onDone(.failure(error), (task.response as? HTTPURLResponse)?.statusCode, 0, -1) }
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
    private var downloading = false
    private var expectedSize: Int64?
    private var session: URLSession?

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mlv2Resolve")
    }
    private var pkgURL: URL { cacheDir.appendingPathComponent(Dependencies.fuseTInstaller.lastPathComponent) }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func recheck() {
        Task.detached {
            let s = OnboardingSupport.currentState()
            await MainActor.run { [weak self] in
                guard let self, self.timer != nil else { return }
                self.state = s
                if s == .ready { self.stopPolling(); self.onReady() }
            }
        }
    }

    func install() {
        guard !downloading else { return }
        errorMessage = nil
        if installerOpened, let size = (try? FileManager.default.attributesOfItem(atPath: pkgURL.path)[.size] as? Int64),
           size > 0, size == expectedSize {
            NSWorkspace.shared.open(pkgURL); return
        }
        downloading = true
        progress = 0
        let dest = pkgURL
        let delegate = DownloadDelegate(
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDone: { [weak self] result, status, size, expected in
                Task { @MainActor in self?.finish(result, status, size, expected, dest) }
            })
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: Dependencies.fuseTInstaller).resume()
    }

    private func finish(_ result: Result<URL, Error>, _ status: Int?, _ size: Int64, _ expected: Int64, _ dest: URL) {
        guard downloading else { return }
        downloading = false; progress = nil
        session?.finishTasksAndInvalidate(); session = nil
        switch result {
        case .failure(let e):
            errorMessage = downloadFailureMessage(error: e, httpStatus: status)
        case .success(let tmp):
            if let status, status != 200 {
                try? FileManager.default.removeItem(at: tmp)
                errorMessage = downloadFailureMessage(httpStatus: status); return
            }
            if expected > 0, size != expected {
                try? FileManager.default.removeItem(at: tmp)
                errorMessage = downloadFailureMessage(received: size, expected: expected); return
            }
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                expectedSize = size
                installerOpened = true
                NSWorkspace.shared.open(dest)
            } catch { errorMessage = downloadFailureMessage(error: error) }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to mlv2Resolve").font(.title2.bold())
            Text("To show your MLV files as DNG, mlv2Resolve needs FUSE-T, a free component that doesn't change your Mac's security. Installation asks for your password once.")
                .fixedSize(horizontal: false, vertical: true)
            if case let .fuseTOutdated(found, minimum) = model.state {
                Text("The installed version of FUSE-T (\(found)) is too old (minimum \(minimum)).")
                    .foregroundStyle(.orange)
            }
            if let p = model.progress {
                ProgressView(value: p > 0 ? p : nil) { Text("Downloading FUSE-T…") }
            }
            if let e = model.errorMessage { Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if model.installerOpened {
                Text("Follow the installer. This window will close automatically.").foregroundStyle(.secondary)
            }
            if !model.resolveFound {
                Text("DaVinci Resolve wasn't found — you can install it later.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.installerOpened ? LocalizedStringKey("Reopen Installer") : LocalizedStringKey("Install FUSE-T")) { model.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.progress != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var backgroundCheck: Timer?
    private let model = OnboardingModel()
    static weak var shared: AppDelegate?

    func showSettings(state: AppState) {
        showMainWindow()
        state.showSettings()
    }

    private var mainWindow: NSWindow?
    private static let mainWindowShownKey = "mainWindowShownOnce"

    /// Opens (or brings back) the main window; marks the first-launch display as done.
    func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindowView(state: AppCore.shared.state))
            let w = NSWindow(contentViewController: hosting)
            w.title = "mlv2Resolve"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 880, height: 800))
            w.minSize = NSSize(width: 700, height: 600)
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let vf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Self.mainWindowShownKey)
    }

    /// First launch ever: show the main window (deferred while the onboarding window is up).
    private func showMainWindowIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.mainWindowShownKey) else { return }
        guard window == nil else { return } // onboarding showing: becomeReady() shows it once FUSE-T is ready; closing onboarding alone does not
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// One mlv2Resolve at a time, whatever copy was opened: two instances would fight over the
    /// same mounts. A second launch hands over to the running one (which shows its window
    /// through the reopen event) and quits before starting anything.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        guard let id = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }),
              let url = other.bundleURL else { return }
        NSLog("mlv2Resolve: already running (pid \(other.processIdentifier)), handing over")
        handingOver = true // applicationDidFinishLaunching must not start (stale-mount cleanup would hit the other instance)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in exit(0) }
    }

    private var handingOver = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handingOver else { return }
        AppDelegate.shared = self
        LaunchAtLogin.initializeIfNeeded()
        #if DEBUG
        if CommandLine.arguments.contains("--debug-relaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { LanguageSwitch.relaunch() }
        }
        #endif
        guard model.state != .ready else {
            AppCore.shared.start()
            showMainWindowIfFirstLaunch()
            return
        }
        // FUSE-T missing: the menu shows the alert icon and « Installer FUSE-T… »; closing the
        // onboarding window keeps a quiet background check that starts the app once ready.
        AppCore.shared.state.needsFuseT = true
        NSLog("mlv2Resolve: FUSE-T not ready (\(String(describing: model.state))), waiting")
        model.onReady = { [weak self] in self?.becomeReady() }
        startBackgroundCheck()
        showOnboarding()
    }

    /// Opens (or brings back) the FUSE-T onboarding window.
    func showOnboarding() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "mlv2Resolve"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(hosting.view.fittingSize)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.main ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]
            let vf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
            window = w
        }
        model.startPolling()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Every 5 s, off the main thread, while FUSE-T is not ready.
    private func startBackgroundCheck() {
        backgroundCheck?.invalidate()
        backgroundCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task.detached {
                guard OnboardingSupport.currentState() == .ready else { return }
                await MainActor.run { AppDelegate.shared?.becomeReady() }
            }
        }
    }

    /// FUSE-T became ready (onboarding poll or background check): start once.
    func becomeReady() {
        guard AppCore.shared.state.needsFuseT else { return }
        backgroundCheck?.invalidate()
        backgroundCheck = nil
        model.stopPolling()
        window?.close()
        AppCore.shared.state.needsFuseT = false
        NSLog("mlv2Resolve: FUSE-T ready, starting")
        AppCore.shared.start()
        showMainWindowIfFirstLaunch()
    }

    /// Unmount asynchronously (terminateLater) so the main thread is never
    /// blocked while unmount machinery may need it; 10 s safety timeout.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false }
        let once = Once()
        let reply: @Sendable () -> Void = {
            once.lock.lock(); defer { once.lock.unlock() }
            guard !once.done else { return }
            once.done = true
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        Task { await AppCore.shared.shutdown(); reply() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { reply() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {}

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        window = nil
    }
}
