import SwiftUI

/// Shown while the app is locked (ADR 0012, #73). It asks once by itself when it appears (at launch, or
/// when the app comes back after the grace time), then waits for the button: a cancel never loops.
struct LockScreen: View {
    let session: AppSession
    @State private var askedOnce = false

    var body: some View {
        VStack(spacing: 16) {
            HeroIcon(systemName: "lock.fill")
            Text("Mission Copilot")
                .font(.title.bold())
            Text(Self.message(for: session.lastError))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(.secondaryText))
            Button("Unlock") { Task { await session.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            guard !askedOnce else { return }
            askedOnce = true
            await session.unlock()
        }
    }

    /// Every state tells the person what to do next.
    nonisolated static func message(for error: LockError?) -> String {
        switch error {
        case nil, .cancelled: "Unlock with Face ID or your passcode to see your missions."
        case .noPasscode: "Set a passcode on this iPhone first. Mission data stays closed without one."
        case .phoneLocked: "Unlock your iPhone, then try again."
        case .failed: "That did not work. Try again."
        }
    }
}

/// Covers everything whenever the app is not in front, so the app switcher never shows mission data.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.background).ignoresSafeArea()
            HeroIcon(systemName: "lock.shield", role: .secondaryText, label: "Mission Copilot is hidden")
        }
    }
}
