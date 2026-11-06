import SwiftUI

/// How faded a switched-off button is, so it looks switched off (#129: Retake photo on a locked walk
/// looked tappable). WCAG 1.4.3 does not ask contrast of a disabled control.
/// It reads the switch as a view, so it works even inside AnyButtonStyle (a style's own environment is not
/// filled in when another style calls it).
struct DisabledLook: ViewModifier {
    static let opacity = 0.4
    let pressed: Bool
    let pressedOpacity: Double
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? (pressed ? pressedOpacity : 1) : Self.opacity)
    }
}

/// The main action on a screen: full width, at least 48 pt high, accent fill (#87).
struct FieldPrimaryButtonStyle: ButtonStyle {
    static let fill = ColorRole.accent
    static let label = ColorRole.onAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)  // the largest text sizes wrap the words
            .foregroundStyle(Color(Self.label))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal)
            .background(Color(Self.fill), in: .rect(cornerRadius: 12))
            .modifier(DisabledLook(pressed: configuration.isPressed, pressedOpacity: 0.8))
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
            .modifier(DisabledLook(pressed: configuration.isPressed, pressedOpacity: 0.6))
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
