//
//  islaApp.swift
//  isla
//
//  Created by Scotty Matthewman on 4/5/26.
//

import SwiftUI
import AppKit
import Combine
import LocalAuthentication

private enum AppLockDefaults {
    static let autoLockIdleMinutesKey = "isla.autoLockIdleMinutes"
    static let requireAuthOnLaunchKey = "isla.requireAuthenticationOnLaunch"

    /// 0 = never auto-lock from idle (launch lock still applies when enabled).
    static var autoLockIdleMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: autoLockIdleMinutesKey) as? Int
        return raw ?? 60
    }

    static var requireAuthenticationOnLaunch: Bool {
        if UserDefaults.standard.object(forKey: requireAuthOnLaunchKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: requireAuthOnLaunchKey)
    }
}

@main
struct islaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appStore = AppStore()
    @StateObject private var security = AppSecurityController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStore)
                .environmentObject(security)
                .background(WindowConfigurator())
                .overlay {
                    if !security.isUnlocked {
                        AppLockOverlay()
                            .environmentObject(security)
                    }
                }
                .disabled(!security.isUnlocked)
                .blur(radius: security.isUnlocked ? 0 : 10)
                .task {
                    security.requestUnlockIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    security.handleScenePhase(newPhase)
                }
        }
        .defaultSize(width: 1180, height: 860)

        Settings {
            AppLockSettingsView()
                .environmentObject(security)
        }
    }
}

@MainActor
final class AppSecurityController: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published var unlockError: String?

    private var lastInteractionAt = Date()
    private var eventMonitor: Any?
    private var inactivityTimer: Timer?
    private var isSceneActive = false
    private var lastScenePhase: ScenePhase?

    init() {
        if !AppLockDefaults.requireAuthenticationOnLaunch {
            isUnlocked = true
            lastInteractionAt = Date()
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor in
                self?.registerInteraction()
            }
            return event
        }

        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluateAutoLock()
            }
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        inactivityTimer?.invalidate()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Sleep or another app in front should not burn down the idle timer; only time
            // while active and unlocked should count toward auto-lock.
            if isUnlocked, lastScenePhase.map({ $0 == .inactive || $0 == .background }) == true {
                lastInteractionAt = Date()
            }
            isSceneActive = true
            evaluateAutoLock()
            requestUnlockIfNeeded()
            registerInteraction()
            lastScenePhase = phase
        case .inactive, .background:
            isSceneActive = false
            lastScenePhase = phase
        @unknown default:
            lastScenePhase = phase
            break
        }
    }

    func registerInteraction() {
        guard isUnlocked else { return }
        lastInteractionAt = Date()
    }

    func requestUnlockIfNeeded() {
        guard !isUnlocked, !isAuthenticating else { return }
        Task {
            await requestUnlock()
        }
    }

    func requestUnlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        unlockError = nil

        let (didUnlock, errorMessage) = await evaluateAuthentication()

        isAuthenticating = false
        if didUnlock {
            isUnlocked = true
            lastInteractionAt = Date()
        } else {
            isUnlocked = false
            unlockError = errorMessage
        }
    }

    /// Reflects changes from Settings (immediate); launch behavior uses `AppLockDefaults` on next cold start.
    func applyLaunchAuthPreference(requireAuthentication: Bool) {
        if requireAuthentication {
            isUnlocked = false
            unlockError = nil
            if isSceneActive {
                requestUnlockIfNeeded()
            }
        } else {
            isUnlocked = true
            lastInteractionAt = Date()
        }
    }

    private func evaluateAutoLock() {
        guard isUnlocked else { return }
        let minutes = AppLockDefaults.autoLockIdleMinutes
        guard minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        guard Date().timeIntervalSince(lastInteractionAt) >= interval else { return }
        isUnlocked = false
        unlockError = nil
        if isSceneActive {
            requestUnlockIfNeeded()
        }
    }

    private func evaluateAuthentication() async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            context.localizedCancelTitle = "Not Now"

            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
                continuation.resume(returning: (false, authError?.localizedDescription ?? "Local authentication is unavailable."))
                return
            }

            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Isla to access your secrets."
            ) { success, error in
                if success {
                    continuation.resume(returning: (true, nil))
                } else {
                    continuation.resume(returning: (false, error?.localizedDescription ?? "Authentication failed."))
                }
            }
        }
    }
}

private struct AppLockSettingsView: View {
    @EnvironmentObject private var security: AppSecurityController
    @AppStorage(AppLockDefaults.autoLockIdleMinutesKey) private var autoLockIdleMinutes = 60
    @AppStorage(AppLockDefaults.requireAuthOnLaunchKey) private var requireAuthenticationOnLaunch = true

    var body: some View {
        Form {
            Section {
                Picker("Lock after inactivity while Isla is open", selection: $autoLockIdleMinutes) {
                    Text("Never").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                    Text("8 hours").tag(480)
                }
                Toggle("Require Touch ID or password when Isla opens", isOn: $requireAuthenticationOnLaunch)
            } header: {
                Text("App lock")
            } footer: {
                Text(
                    "Isla uses the same login as your Mac (Touch ID or account password). " +
                    "Turning off “when Isla opens” is convenient on a trusted machine but lets anyone who can use your Mac session see secrets without another prompt."
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onChange(of: requireAuthenticationOnLaunch) { _, newValue in
            security.applyLaunchAuthPreference(requireAuthentication: newValue)
        }
    }
}

private struct AppLockOverlay: View {
    @EnvironmentObject private var security: AppSecurityController

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.primary)

                Text("Isla Is Locked")
                    .font(.title2.bold())

                Text("Use Touch ID or your Mac password to unlock.")
                    .foregroundStyle(.secondary)

                if let unlockError = security.unlockError {
                    Text(unlockError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button {
                    Task {
                        await security.requestUnlock()
                    }
                } label: {
                    if security.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 120)
                    } else {
                        Text("Unlock Isla")
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(security.isAuthenticating)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 18)
            )
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

            window.minSize = NSSize(width: 920, height: 760)

            if let screenFrame {
                let targetHeight = screenFrame.height
                let targetWidth = max(window.frame.width, window.minSize.width)
                let newOriginY = screenFrame.maxY - targetHeight
                window.setFrame(
                    NSRect(
                        x: window.frame.origin.x,
                        y: newOriginY,
                        width: targetWidth,
                        height: targetHeight
                    ),
                    display: true
                )
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
