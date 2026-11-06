import Foundation
import UIKit

/// Site photos as signed evidence (#129): the place is read from the moment the camera opens, so it is
/// ready by the shutter; the photo is prepared (no metadata in the file), signed into the mission's chain
/// with the phone's chip key and sealed with the mission key. With no place it is still kept and says so.
extension SiteWalkModel {
    /// The camera is opening: start reading the place now.
    func cameraOpening() {
        guard pendingPlace == nil else { return }
        let places = places
        pendingPlace = Task { await places.onePlace() }
    }

    /// The photo just taken, as evidence: its sequence number in the chain, or nil if it could not be kept.
    func photoTaken(_ image: UIImage) async -> Int? {
        guard finished == nil else {
            problem = finishedProblem
            return nil
        }
        if pendingPlace == nil { cameraOpening() }
        let reading = await pendingPlace?.value ?? .noFix
        pendingPlace = nil
        guard let file = try? SitePhoto.prepare(image) else {
            problem = saveProblem
            return nil
        }
        var location: EvidencePayload.Location?
        if case .place(let place) = reading {
            location = EvidencePayload.Location(latitude: place.latitude, longitude: place.longitude)
        }
        let capture = Capture(file: file, kind: .photo, capturedAt: now(), clockSource: .device, location: location)
        guard let record = try? store.addEvidence(capture, to: mission, signer: signer),
              let payload = try? JSONDecoder().decode(EvidencePayload.self, from: record.payload) else {
            problem = saveProblem
            return nil
        }
        problem = location == nil ? Self.withoutPlace(reading, language: language) : nil
        return payload.seq
    }

    static func withoutPlace(_ reading: PlaceReading, language: String) -> String {
        let reason = reading.problem(app: appName, language: language) ?? ""
        return (language == "fr" ? "La photo est enregistrée sans son emplacement. "
                                 : "The photo is saved without its place. ") + reason
    }
}
