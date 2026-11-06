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

    /// Where a photo goes: the checklist's photo question, or an agreed action (by its key).
    enum PhotoTarget: Equatable, Sendable {
        case question(String), action(String)
    }

    /// The photo just taken, kept as evidence and linked to its question or action; a retake points at the
    /// newest and the older one stays (evidence is append-only). An action needs what was seen first.
    func photoTaken(_ image: UIImage, for target: PhotoTarget) async -> Int? {
        if case .action(let key) = target, walk.checks[key] == nil {
            problem = SiteWalkWords(language: language).text(.pickFirst)
            return nil
        }
        guard let seq = await photoTaken(image) else { return nil }
        let note = problem  // "saved without its place" survives the link below
        switch target {
        case .question(let question):
            answer("evidence:\(seq)", to: question)
        case .action(let key):
            guard let check = walk.checks[key] else { return seq }
            save { try store.saveCheck(check.seen, note: check.note, photo: seq, action: key, mission: mission,
                                       now: now()) }
        }
        if problem == nil { problem = note }
        return seq
    }

    /// A photo's thumbnail (600 px), opened from its sealed file in memory only.
    func thumbnail(_ seq: Int) -> UIImage? {
        if let opened = thumbnails[seq] { return opened }
        guard let file = try? store.evidenceFile(in: mission, seq: seq), let image = UIImage(data: file),
              let thumbnail = image.preparingThumbnail(of: Self.thumbnailSize(of: image.size)) else { return nil }
        thumbnails[seq] = thumbnail
        return thumbnail
    }

    /// The camera closed without a photo: the place reading is no longer needed.
    func cameraCancelled() {
        pendingPlace?.cancel()
        pendingPlace = nil
    }

    static func thumbnailSize(of size: CGSize) -> CGSize {
        let scale = min(1, 600 / max(size.width, size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// The seq an "evidence:<seq>" answer names.
    static func photoSeq(inAnswer answer: String) -> Int? {
        guard answer.hasPrefix("evidence:") else { return nil }
        return Int(answer.dropFirst("evidence:".count))
    }

    static func withoutPlace(_ reading: PlaceReading, language: String) -> String {
        let reason = reading.problem(app: appName, language: language) ?? ""
        return (language == "fr" ? "La photo est enregistrée sans son emplacement. "
                                 : "The photo is saved without its place. ") + reason
    }
}
