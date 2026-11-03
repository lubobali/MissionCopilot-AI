import SwiftUI

/// The main action on a screen: full width, at least 48 pt high, accent fill (#87).
struct FieldPrimaryButtonStyle: ButtonStyle {
    static let fill = ColorRole.accent
    static let label = ColorRole.onAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(Self.label))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal)
            .background(Color(Self.fill), in: .rect(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(.rect)
    }
}

/// Any other action: at least 44 pt high, the whole area tappable.
struct FieldSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.accent))
            .frame(minHeight: 44)
            .padding(.horizontal)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == FieldPrimaryButtonStyle {
    static var fieldPrimary: FieldPrimaryButtonStyle { FieldPrimaryButtonStyle() }
}

extension ButtonStyle where Self == FieldSecondaryButtonStyle {
    static var fieldSecondary: FieldSecondaryButtonStyle { FieldSecondaryButtonStyle() }
}

/// A large symbol at the top of a screen that grows with the person's text size. Decoration unless it
/// has a label for VoiceOver.
struct HeroIcon: View {
    let systemName: String
    var role: ColorRole = .accent
    var label: String?
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 60

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(Color(role))
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
    }
}
