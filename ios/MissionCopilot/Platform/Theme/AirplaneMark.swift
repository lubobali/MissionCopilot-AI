import SwiftUI

/// Our own airplane (#123), drawn by scripts/airplane_mark.py and kept as a template vector, so the theme
/// colors it and it stays sharp at every text size. Not Apple's SF Symbol: its license forbids symbols in
/// app icons and logos, and this mark is half of both.
struct AirplaneMark: View {
    static let imageName = "Airplane"
    var role: ColorRole = .accent
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 96

    init(role: ColorRole = .accent, size: CGFloat = 96) {
        self.role = role
        _height = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Image(Self.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: height, height: height)
            .foregroundStyle(Color(role))
            .accessibilityHidden(true)
    }
}
