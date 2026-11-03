import SwiftUI

/// The states a mission pack can be in. Each has its own icon and words, so color is never the only
/// signal (WCAG 1.4.1, #87); the screens that set them come with the pack (#92).
enum StatusKind: CaseIterable, Sendable {
    case ready, downloading, paused, expiring, expired, notDownloaded

    var words: String {
        switch self {
        case .ready: "Ready for offline"
        case .downloading: "Downloading"
        case .paused: "Paused, waiting for connection"
        case .expiring: "Expires soon"
        case .expired: "Expired"
        case .notDownloaded: "Not downloaded"
        }
    }

    var icon: String {
        switch self {
        case .ready: "checkmark.seal.fill"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .expiring: "exclamationmark.triangle.fill"
        case .expired: "xmark.octagon.fill"
        case .notDownloaded: "icloud.and.arrow.down"
        }
    }

    var color: ColorRole {
        switch self {
        case .ready: .success
        case .downloading: .accent
        case .paused, .expiring: .warning
        case .expired: .danger
        case .notDownloaded: .secondaryText
        }
    }
}

/// An icon and words, in the status color, read by VoiceOver as the words.
struct StatusLabel: View {
    let kind: StatusKind

    var body: some View {
        Label(kind.words, systemImage: kind.icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(kind.color))
    }
}
