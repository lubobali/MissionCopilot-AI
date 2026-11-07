import SwiftUI

/// Documents (#138): scan an invoice or a report with Apple's document camera. For now it says how many
/// pages came back; storing and reading them comes next (6.5.2, 6.5.3).
struct DocumentsCard: View {
    let scan: ScanOutcome?
    var onScan: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "doc.viewfinder")
                    .font(.title2)
                    .foregroundStyle(Color(.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Documents")
                        .font(.headline)
                        .foregroundStyle(Color(.text))
                    Text(scan?.words ?? "Scan an invoice or a progress report")
                        .font(.subheadline)
                        .foregroundStyle(Color(scan.map { $0.scanned ? .success : .secondaryText } ?? .secondaryText))
                }
            }
            .accessibilityElement(children: .combine)
            Button("Scan a document", systemImage: "doc.viewfinder", action: onScan)
                .buttonStyle(.fieldPrimary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

extension MissionWorkspaceScreen {
    /// Scans with Apple's document camera and saves each page as signed evidence of this mission (#138).
    static func scanAndSave(_ row: MissionRow, store: MissionStore?) async -> ScanOutcome {
        let (outcome, pages) = await DocumentScanner.shared.scan()
        guard outcome.scanned, let store else { return store == nil && outcome.scanned ? .notSaved : outcome }
        do {
            try store.addScan(pages, to: row.id, signer: SecureEnclaveEvidenceSigner(user: AppSession.localProfile))
            return outcome
        } catch {
            return .notSaved
        }
    }
}
