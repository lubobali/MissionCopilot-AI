import SwiftUI

/// The developer's logo (the L and the key), built from the source file by scripts/make_brand_assets.py.
/// It is not under the code license (README). It always sits on a white tile, like the app icon: its
/// dark blue and black would vanish on the dark background. Decoration unless it has a label for
/// VoiceOver.
struct LogoMark: View {
    static let imageName = "Logo"
    var label: String?
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 96
    @ScaledMetric(relativeTo: .largeTitle) private var inset: CGFloat = 14

    var body: some View {
        Image(Self.imageName)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .padding(inset)
            .background(.white, in: .rect(cornerRadius: inset * 1.6))
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
    }
}
