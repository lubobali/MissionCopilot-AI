import SwiftUI

/// After the approval (#173): Send to the server, a spinner while it goes, then the receipt, or why it waits.
struct SendSection: View {
    let model: ReportModel
    let review: () -> Void

    var body: some View {
        if model.sending {
            HStack(spacing: 10) {
                ProgressView()
                Text("Sending to the server…")
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
        } else if case .received = model.sendOutcome {
            Label(model.sendWords, systemImage: "checkmark.icloud.fill")
                .font(.subheadline)
                .foregroundStyle(Color(.success))
        } else {
            Button("Send to the server", systemImage: "icloud.and.arrow.up", action: review)
                .buttonStyle(.fieldPrimary)
            if !model.sendWords.isEmpty {
                let waiting = model.sendOutcome == .waiting
                Label(model.sendWords, systemImage: waiting ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color(waiting ? .secondaryText : .warning))
            }
        }
    }
}

/// Exactly what goes, before it goes (privacy row P06): the counts and the size; Send or Cancel.
struct SendReview: View {
    let model: ReportModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SendReviewContent(model: model, done: done)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
        }
    }
}

/// The review without its navigation, for the screenshot tests too.
struct SendReviewContent: View {
    let model: ReportModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What goes to the server")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.text))
            Text(model.sendReview)
                .foregroundStyle(Color(.text))
            Text("Only this approved report and the records it cites. The server checks every signature "
                 + "before it keeps anything.")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryText))
            Spacer()
            Button("Send", systemImage: "icloud.and.arrow.up") {
                done()
                Task { await model.send() }
            }
            .buttonStyle(.fieldPrimary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fieldScreen()
    }
}
