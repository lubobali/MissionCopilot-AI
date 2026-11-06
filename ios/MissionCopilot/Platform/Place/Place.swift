import CoreLocation
import Foundation

/// A place on the ground: where the officer stood when the sample point was recorded (#129).
struct Place: Equatable, Sendable {
    let latitude: Double, longitude: Double, altitude: Double, accuracy: Double

    /// The XLSForm geopoint answer: "latitude longitude altitude accuracy" (metres); six decimals of a
    /// degree is about 11 cm, far finer than any phone's fix.
    var geopoint: String {
        String(format: "%.6f %.6f %.1f %.1f", latitude, longitude, altitude, accuracy)
    }

    init(latitude: Double, longitude: Double, altitude: Double, accuracy: Double) {
        (self.latitude, self.longitude, self.altitude, self.accuracy) = (latitude, longitude, altitude, accuracy)
    }

    /// A geopoint answer read back, or nil if it is not one.
    init?(geopoint: String) {
        let parts = geopoint.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        self.init(latitude: parts[0], longitude: parts[1], altitude: parts[2], accuracy: parts[3])
    }
}

/// One try at finding the place, and every way it can fail.
enum PlaceReading: Equatable, Sendable {
    case place(Place)
    case denied  // the officer said no to this app
    case offForPhone  // Location Services are off for the whole iPhone
    case restricted  // blocked by the phone's settings or the organization
    case noFix  // no position in time

    /// What went wrong and what to do, or nil for a place.
    func problem(app: String) -> String? {
        switch self {
        case .place: nil
        case .denied: "Location is off for \(app). Turn it on in Settings, then try again."
        case .offForPhone: "Location Services are off on this iPhone. Turn them on in Settings, Privacy & Security."
        case .restricted: "Location is blocked on this iPhone by its settings or your organization."
        case .noFix: "No position yet. Move under open sky, wait a moment, and try again."
        }
    }
}

/// Finds where the phone is, once. Apple's on the phone; a fake in tests (the Simulator has no GPS).
protocol PlaceFinder: Sendable {
    func onePlace() async -> PlaceReading
}

/// Apple's location: asked for only when called (the session asks for "while using the app" the first
/// time), the best reading within 20 seconds, stopping early once one is within 20 metres. GPS needs no
/// network, so it works in airplane mode.
struct ApplePlaceFinder: PlaceFinder {
    static let patience: Duration = .seconds(20)
    static let goodEnough: Double = 20  // metres

    func onePlace() async -> PlaceReading {
        await withTaskGroup(of: PlaceReading?.self) { group in
            group.addTask { await Self.readings() }
            group.addTask {
                try? await Task.sleep(for: Self.patience)
                return nil  // time is up
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .noFix
        }
    }

    /// Reads until a good enough fix or a refusal; the best fix so far if the sequence ends.
    private static func readings() async -> PlaceReading? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        var best: Place?
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDeniedGlobally { return .offForPhone }
                if update.authorizationRestricted { return .restricted }
                if update.authorizationDenied { return .denied }
                guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                let place = Place(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                  altitude: location.altitude, accuracy: location.horizontalAccuracy)
                if best.map({ place.accuracy < $0.accuracy }) ?? true { best = place }
                if place.accuracy <= goodEnough { return .place(place) }
            }
        } catch {
            return best.map(PlaceReading.place) ?? .noFix
        }
        return best.map(PlaceReading.place)
    }
}
