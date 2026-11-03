import SwiftUI

/// Connecting this iPhone to its organization (#90): type the admin's one-time code, then wait for a
/// manager's approval. Every state says what to do next; nothing here is a secret worth hiding, the
/// code works once.
struct EnrollmentView: View {
    @Bindable var model: EnrollmentModel
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            HeroIcon(systemName: Self.icon(model.state))
            Text(Self.title(model.state))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(Self.explanation(model.state))
                .foregroundStyle(Color(.secondaryText))
                .multilineTextAlignment(.center)
            actions
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color(.warning))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .fieldScreen()
        .navigationTitle("Connect")
    }

    @ViewBuilder private var actions: some View {
        switch model.state {
        case .notEnrolled:
            TextField("One-time code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .padding(.horizontal)
                .frame(minHeight: 48)
                .background(Color(.surface), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
            Button("Connect this iPhone") { Task { await model.enroll(code: code) } }
                .buttonStyle(.fieldPrimary)
                .disabled(model.busy || code.isEmpty)
        case .waitingForApproval:
            Button("Check again") { Task { await model.checkApproval() } }
                .buttonStyle(.fieldPrimary)
                .disabled(model.busy)
        case .ready:
            Label("Connected and approved", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Color(.success))
        }
    }

    nonisolated static func icon(_ state: EnrollmentModel.State) -> String {
        switch state {
        case .notEnrolled: "link.badge.plus"
        case .waitingForApproval: "hourglass"
        case .ready: "checkmark.shield.fill"
        }
    }

    nonisolated static func title(_ state: EnrollmentModel.State) -> String {
        switch state {
        case .notEnrolled: "Connect this iPhone"
        case .waitingForApproval: "Waiting for approval"
        case .ready: "This iPhone is connected"
        }
    }

    nonisolated static func explanation(_ state: EnrollmentModel.State) -> String {
        switch state {
        case .notEnrolled: "Type the one-time code your admin gave you. It works once, for 15 minutes."
        case .waitingForApproval: "A manager must approve this iPhone before it can download missions."
        case .ready: "Missions can be downloaded to this iPhone for offline work."
        }
    }
}
