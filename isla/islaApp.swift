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
    }
}

@MainActor
final class AppSecurityController: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published var unlockError: String?

    private let autoLockInterval: TimeInterval = 60 * 60
    private var lastInteractionAt = Date()
    private var eventMonitor: Any?
    private var inactivityTimer: Timer?
    private var isSceneActive = false

    init() {
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
            isSceneActive = true
            evaluateAutoLock()
            requestUnlockIfNeeded()
            registerInteraction()
        case .inactive, .background:
            isSceneActive = false
        @unknown default:
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

    private func evaluateAutoLock() {
        guard isUnlocked else { return }
        guard Date().timeIntervalSince(lastInteractionAt) >= autoLockInterval else { return }
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
