import CoreGraphics
import Testing
@testable import MissionCopilot

/// The takeoff curve the airplane flies from the logo (#123): a quadratic curve, the plane's position and
/// the way its nose points at every moment.
struct FlightArcTests {
    let arc = FlightArc(start: CGPoint(x: 0, y: 0), control: CGPoint(x: 50, y: 40), end: CGPoint(x: 100, y: 0))

    @Test func itStartsAtTheLogoAndEndsAtThePlanesPlace() {
        #expect(arc.point(at: 0) == arc.start)
        #expect(arc.point(at: 1) == arc.end)
    }

    @Test func halfWayIsTheQuadraticMidpoint() {
        // B(0.5) = (start + 2 control + end) / 4
        #expect(arc.point(at: 0.5) == CGPoint(x: 50, y: 20))
    }

    @Test func theNoseFollowsTheCurve() {
        // Screen angles (y down): leaving towards the control point, arriving from it.
        #expect(abs(arc.heading(at: 0).degrees - atan2(40, 50) * 180 / .pi) < 0.001)
        #expect(abs(arc.heading(at: 1).degrees - atan2(-40, 50) * 180 / .pi) < 0.001)
        #expect(abs(arc.heading(at: 0.5).degrees) < 0.001, "level at the bottom of the dip")
    }

    @Test func timeOutsideTheFlightIsHeldAtItsEnds() {
        #expect(arc.point(at: -1) == arc.start)
        #expect(arc.point(at: 2) == arc.end)
    }

    @Test func theMarkTurnsSoItsDrawnHeadingMeetsTheCurve() {
        // The airplane is drawn flying up and right (-45 degrees on screen): turning by heading + 45 puts
        // its nose on the curve, and at the end of a curve that arrives at -45 it is not turned at all.
        let climb = FlightArc(start: .zero, control: CGPoint(x: 50, y: 50), end: CGPoint(x: 100, y: 0))

        #expect(abs(climb.turn(at: 1).degrees) < 0.001)
        #expect(abs(arc.turn(at: 0.5).degrees - 45) < 0.001)
    }
}
