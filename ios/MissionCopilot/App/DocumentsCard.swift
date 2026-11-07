import SwiftUI

/// Opens a mission's documents by its id (declared at the stack's root, ContentView).
struct DocumentsLink: Hashable, Sendable {
    let id: String
}

/// Documents on the workspace (#138): how many scans and pages; opens the Documents page.
struct DocumentsCard: View {
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Documents")
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Color(.secondaryText))
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// The Documents page: scan with Apple's document camera; every page saved as signed evidence and read on
/// the phone, each with its thumbnail and where it is.
struct DocumentsScreen: View {
    let list: MissionListModel
    let id: String
    @State private var documents: DocumentsModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let documents {
                ScrollView { DocumentsView(model: documents) }
            } else if cannotOpen {
                Text("The documents cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the documents")
            }
        }
        .fieldScreen()
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard documents == nil else { return }
            guard let store = list.openStore else {
                cannotOpen = true
                return
            }
            let model = DocumentsModel(mission: id, store: store)
            documents = model
            await model.loadAndRead()
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct DocumentsView: View {
    let model: DocumentsModel
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.summary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Text("Pages are signed evidence and read on this iPhone, offline. A scan cannot be changed; "
                     + "to retake a page, scan it again.")
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
                if let outcome = model.outcome, !outcome.scanned {
                    Label(outcome.words, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            .accessibilityElement(children: .combine)
            Button(scanning ? "Scanning" : "Scan a document", systemImage: "doc.viewfinder") {
                scanning = true
                Task {
                    await model.scan()
                    scanning = false
                }
            }
            .buttonStyle(.fieldPrimary)
            .disabled(scanning)
            ForEach(Array(model.scans.reversed())) { scan in
                ScanCard(scan: scan, thumbnail: model.thumbnail)
            }
        }
        .padding(16)
    }
}

/// One scan on glass: when, then each page with its thumbnail and its state in words.
struct ScanCard: View {
    let scan: DocumentsModel.Scan
    var thumbnail: (Int) -> UIImage? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanned \(scan.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.secondaryText))
                .textCase(.uppercase)
            ForEach(Array(scan.pages.enumerated()), id: \.element.id) { index, page in
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let image = thumbnail(page.seq) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(Color(.secondaryText))
                        }
                    }
                    .frame(width: 72, height: 96)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Page \(index + 1)")
                            .font(.headline)
                            .foregroundStyle(Color(.text))
                        Label(page.state.words, systemImage: page.state.icon)
                            .font(.subheadline)
                            .foregroundStyle(Color(page.state.role))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

extension DocumentsModel.PageState {
    var icon: String {
        switch self {
        case .reading: "text.viewfinder"
        case .read: "checkmark.circle.fill"
        case .cropped: "crop"
        case .unreadable: "exclamationmark.triangle.fill"
        }
    }

    var role: ColorRole {
        switch self {
        case .reading: .secondaryText
        case .read: .success
        case .cropped, .unreadable: .warning
        }
    }
}

extension MissionWorkspaceScreen {
    /// The documents' summary for their card; nil when the mission has no pack yet or the app is locked.
    static func documentsSummary(_ row: MissionRow, store: MissionStore?) -> String? {
        guard row.pack != nil, let store, let scans = try? store.scans(in: row.id) else { return nil }
        return DocumentsModel.summary(scans: scans.count, pages: scans.reduce(0) { $0 + $1.pages.count })
    }
}
