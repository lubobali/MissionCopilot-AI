import SwiftUI

/// Our own airplane (#123), drawn by scripts/airplane_mark.py and kept as a template vector, so the theme
/// colors it and it stays sharp at every text size. Not Apple's SF Symbol: its license forbids symbols in
/// app icons and logos, and this mark is half of both.
struct AirplaneMark: View {
    static let imageName = "Airplane"
    var role: ColorRole = .accent
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 96

    var body: some View {
        Image(Self.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: height, height: height)
            .foregroundStyle(Color(role))
            .accessibilityHidden(true)
    }
}

/// The home screen's mark: the developer's logo, a thin line, the airplane (#123). Side by side; at the
/// largest text sizes it stacks, so it is never cut. Decoration: VoiceOver skips it, the title below names
/// the app.
struct BrandLockup: View {
    @ScaledMetric(relativeTo: .largeTitle) private var length: CGFloat = 32
    @ScaledMetric(relativeTo: .largeTitle) private var thickness: CGFloat = 2

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { parts(line: CGSize(width: length, height: thickness)) }
            VStack(spacing: 12) { parts(line: CGSize(width: thickness, height: length)) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func parts(line: CGSize) -> some View {
        LogoMark()
        Capsule()
            .fill(Color(.decoration))
            .frame(width: line.width, height: line.height)
        AirplaneMark()
    }
}
