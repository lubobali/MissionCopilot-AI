import Foundation

/// A walk answer in words by its question's type (#161, step 7.2.8, found on the iPhone: "Edge_breaks",
/// "2026-11-06", raw GPS, "Evidence:1"), for any form: a choice by its label, a date like the rest of the report,
/// a location with how sure it is, a photo as taken. What Ask and the report show; the signed answer is unchanged.
enum WalkAnswerWords {
    static func words(_ answer: String, question: ChecklistQuestion, choices: [String: [ChecklistChoice]]) -> String {
        switch question.kind {
        case .selectOne(let list):
            return label(answer, in: choices[list])
        case .selectMultiple(let list):
            return answer.split(separator: " ").map { label(String($0), in: choices[list]) }.joined(separator: ", ")
        case .date:
            guard answer.count == 10, let day = FactGrounding.isoDay.date(from: answer) else { return answer }
            return FactGrounding.formatter("d MMM yyyy").string(from: day)
        case .geopoint:
            guard let place = Place(geopoint: answer) else { return answer }
            return String(format: "%.5f, %.5f (within %.0f m)", place.latitude, place.longitude, place.accuracy)
        case .image:
            return answer.hasPrefix("evidence:") ? "photo taken" : answer
        case .text, .integer, .decimal, .note:
            return answer
        }
    }

    /// The choice's English label (the walk's question titles are English too); a name the form lacks stays.
    private static func label(_ name: String, in list: [ChecklistChoice]?) -> String {
        list?.first { $0.name == name }?.label.english ?? name
    }
}
