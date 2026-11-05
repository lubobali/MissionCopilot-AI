import SwiftUI

/// The home screen's mark (#123, prototype for Lubo's look): the developer's logo and our airplane on one
/// piece of Liquid Glass. When it appears a glowing trail draws itself from the logo and the plane flies
/// along it to its place; then the trail glows softly and a pill-shaped reflection slides across the glass,
/// left to right, in a loop. Tap to fly again.
/// With Reduce Motion it is drawn at rest, nothing moves. Decoration: VoiceOver skips it.
struct BrandMedallion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillMarks) private var stillMarks
    @ScaledMetric(relativeTo: .largeTitle) private var unit: CGFloat = 1
    /// 1 on the home screen; smaller where it is only a header (the mission workspace, #125).
    var size: CGFloat = 1
    @State private var flight: CGFloat = 1  // 0 at the logo, 1 at rest; onAppear always sets it first
    @State private var glow = false

    /// The design, in points at the default text size, and how far it may grow (1.5 x 248 = 372 pt fits a
    /// phone's 382 pt column).
    static let largest: CGFloat = 1.5
    static let size = CGSize(width: 248, height: 92)
    static let logoCentre = CGPoint(x: 52, y: 46)
    static let arc = FlightArc(start: CGPoint(x: 86, y: 54), control: CGPoint(x: 154, y: 84),
                               end: CGPoint(x: 196, y: 42))

    var body: some View {
        let scale = min(unit, Self.largest) * size  // grows with the text, up to a point: it is decoration
        ZStack {
            trail(scale: scale)
            // The marks take the medallion's own scale, never their own text-size growth (#125): a small or
            // capped medallion would otherwise be overrun by a full-size logo.
            LogoMark(height: 44 * scale, inset: 8 * scale)
                .environment(\.dynamicTypeSize, .large)
                .position(x: Self.logoCentre.x * scale, y: Self.logoCentre.y * scale)
            AirplaneMark(size: 56 * scale)
                .environment(\.dynamicTypeSize, .large)
                .modifier(FlightPose(time: flight, arc: Self.arc, scale: scale))
        }
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
        .glassEffect(.regular.tint(Color(.accent).opacity(0.12)), in: .capsule)
        .overlay { if !still { Reflection(scale: scale) } }
        .contentShape(.capsule)
        .onTapGesture(perform: fly)
        .onAppear(perform: fly)
        .accessibilityHidden(true)
    }

    /// Nothing moves: the person asked for less motion, or a screenshot wants the medallion at rest.
    private var still: Bool { reduceMotion || stillMarks }

    private func trail(scale: CGFloat) -> some View {
        let path = Self.arc.path.applying(CGAffineTransform(scaleX: scale, y: scale))
        let colors = Gradient(colors: [Color(.decoration).opacity(0.2), Color(.decoration), Color(.accent)])
        return ZStack {
            path.trim(from: 0, to: flight)
                .stroke(Color(.decoration), style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round))
                .blur(radius: 5 * scale)
                .opacity(glow ? 0.55 : 0.25)
            path.trim(from: 0, to: flight)
                .stroke(LinearGradient(gradient: colors, startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
        }
    }

    private func fly() {
        guard !still else { flight = 1; glow = false; return }
        flight = 0
        glow = false
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 1.6)) { flight = 1 }
        withAnimation(.easeInOut(duration: 2.4).delay(1.6).repeatForever(autoreverses: true)) { glow = true }
    }
}

/// The airplane's place and turn along the takeoff curve at `time`, animated frame by frame.
private struct FlightPose: ViewModifier, Animatable {
    var time: CGFloat
    let arc: FlightArc
    let scale: CGFloat

    nonisolated var animatableData: CGFloat {
        get { time }
        set { time = newValue }
    }

    func body(content: Content) -> some View {
        let point = arc.point(at: time)
        return content
            .rotationEffect(arc.turn(at: time))
            .scaleEffect(0.6 + 0.4 * time)
            .opacity(min(1, time * 5))
            .position(x: point.x * scale, y: point.y * scale)
    }
}

/// A mirror-like reflection shaped like the medallion itself, only narrower, sliding across the glass from
/// left to right, then resting, in a loop. Clipped to the medallion, so it never leaves the glass.
private struct Reflection: View {
    let scale: CGFloat
    static let pass: TimeInterval = 2.8, rest: TimeInterval = 3.2  // Lubo: 25% slower, twice (1.8, 2.25)

    var body: some View {
        TimelineView(.animation) { timeline in
            let period = Self.pass + Self.rest
            let elapsed = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            let progress = min(elapsed / Self.pass, 1)  // 0 to 1 while it passes, then held off the glass
            GeometryReader { box in
                // The medallion's own shape, narrower: full height and clearly wider than tall (a pill, never
                // a circle), round ends, an even sheen with soft sides.
                let width = max(box.size.width * 0.6, box.size.height * 1.6)
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0.08), location: 0),
                                                 .init(color: .white.opacity(0.38), location: 0.3),
                                                 .init(color: .white.opacity(0.38), location: 0.7),
                                                 .init(color: .white.opacity(0.08), location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: box.size.height)
                    .position(x: -width / 2 + (box.size.width + width) * progress, y: box.size.height / 2)
            }
        }
        .clipShape(.capsule)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

extension EnvironmentValues {
    /// Draws the brand marks at rest, with no motion (screenshots and tests, #123).
    @Entry var stillMarks = false
}
