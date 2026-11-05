import CoreGraphics
import SwiftUI

/// The takeoff curve from the logo to the airplane (#123): a quadratic curve, so the plane dips under the
/// logo and climbs to its place. Pure geometry, so the motion is tested without drawing.
struct FlightArc: Equatable, Sendable {
    let start: CGPoint, control: CGPoint, end: CGPoint

    /// Where the plane is at `time` (0 at the logo, 1 at rest); outside the flight it holds at the ends.
    func point(at time: CGFloat) -> CGPoint {
        let now = min(max(time, 0), 1), left = 1 - now  // how far along, and how much is left
        return CGPoint(x: left * left * start.x + 2 * left * now * control.x + now * now * end.x,
                       y: left * left * start.y + 2 * left * now * control.y + now * now * end.y)
    }

    /// The direction of flight at `time`, as a screen angle (y down, 0 = flying right).
    func heading(at time: CGFloat) -> Angle {
        let now = min(max(time, 0), 1)
        let run = 2 * (1 - now) * (control.x - start.x) + 2 * now * (end.x - control.x)
        let rise = 2 * (1 - now) * (control.y - start.y) + 2 * now * (end.y - control.y)
        return .radians(atan2(rise, run))
    }

    /// How far to turn the airplane mark, which is drawn flying up and right (-45 degrees), so its nose
    /// points along the curve.
    func turn(at time: CGFloat) -> Angle {
        heading(at: time) + .degrees(45)
    }

    var path: Path {
        Path { path in
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
        }
    }
}
