import SwiftUI

/// The developer's logo (the L and the key), built from the source file by scripts/make_brand_assets.py.
/// It is not under the code license (README). Decoration unless it has a label for VoiceOver.
struct LogoMark: View {
    static let imageName = "Logo"
    var label: String?
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 96

    var body: some View {
        Image(Self.imageName)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
    }
}
