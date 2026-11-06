import Foundation

/// What one rule found (ADR 0010, #134): a flag, clear, or not checked with the reason. A missing input is
/// never clear. It keeps the rule's version, the computed value, the threshold and every input it used.
struct RedFlagResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable { case flag, clear, notChecked(NotChecked) }

    enum NotChecked: String, Codable, Sendable {
        case noContracts, noMilestones, zeroValue, needsScan, needsPhotos, unknownRule
    }

    /// One input a result used, citable: a pack field or a signed photo.
    enum Input: Sendable, Equatable {
        case pack(PackCitation)
        case evidence(PhotoRef)
    }

    let rule: RuleRef
    let outcome: Outcome
    /// What it is about: a contract's ocid, a milestone's id, the repeated invoice or amount.
    let subject: String?
    let computed: Double?
    let threshold: RedFlagRule.Threshold
    let inputs: [Input]
    /// Missions that could not be read for this rule (shredded), so a clear is never more than it is.
    var skippedMissions = 0
}

/// What the rules read: the pack's figures, today. A nil input is "not in this pack".
struct RedFlagInputs: Sendable {
    var contracts: PackContracts?
    var milestones: PackMilestones?
    var photos: PhotoReuseCheck?
}

/// Plain code, never the model (ADR 0005, 0010): the same inputs always give the same results, in the
/// rules file's order. Thresholds come from the file; the formulas are here, one per rule id.
struct RedFlagEngine: Sendable {
    let rules: RedFlagRules

    func run(_ inputs: RedFlagInputs, walk: Date, timeZone: TimeZone) -> [RedFlagResult] {
        rules.rules.flatMap { rule in
            let context = Context(rule: rule, inputs: inputs, walkDay: PackDay.day(of: walk, in: timeZone))
            switch rule.id {
            case "R068": return context.overpaid()
            case "R067": return context.lateMilestones()
            case "MC-01": return context.paidAheadOfBuilt()
            case "MC-02": return context.sameInvoiceTwice()
            case "MC-03": return [context.result(.notChecked(.needsScan))]
            case "MC-04": return context.samePhotoAgain()
            default: return [context.result(.notChecked(.unknownRule))]
            }
        }
    }
}

/// Days as the pack writes them (yyyy-MM-dd), counted in whole calendar days.
enum PackDay {
    static func day(of date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Whole days from `start` to `end` (negative when end is earlier); nil if either is not a day.
    static func days(from start: String, to end: String) -> Int? {
        let format = Date.ISO8601FormatStyle().year().month().day()
        guard let from = try? Date(start, strategy: format), let until = try? Date(end, strategy: format)
        else { return nil }
        return Int((until.timeIntervalSince(from) / 86_400).rounded())
    }
}

private struct Context {
    let rule: RedFlagRule
    let inputs: RedFlagInputs
    let walkDay: String

    func result(_ outcome: RedFlagResult.Outcome, subject: String? = nil, computed: Double? = nil,
                inputs: [RedFlagResult.Input] = []) -> RedFlagResult {
        RedFlagResult(rule: rule.ref, outcome: outcome, subject: subject, computed: computed,
                      threshold: rule.threshold, inputs: inputs)
    }

    func judged(_ value: Double, subject: String?, inputs: [RedFlagResult.Input]) -> RedFlagResult {
        result(rule.threshold.isCrossed(by: value) ? .flag : .clear, subject: subject, computed: value,
               inputs: inputs)
    }

    /// The contract rules run once per contract; with no contracts they are not checked.
    private func perContract(_ judge: (PackContracts, Int, PackContracts.Contract) -> [RedFlagResult])
        -> [RedFlagResult] {
        guard let pack = inputs.contracts, !pack.contracts.isEmpty else {
            return [result(.notChecked(.noContracts))]
        }
        return pack.contracts.enumerated().flatMap { index, contract in judge(pack, index, contract) }
    }

    private func paid(_ pack: PackContracts, _ index: Int, _ contract: PackContracts.Contract)
        -> (percent: Double, inputs: [RedFlagResult.Input]) {
        let total = contract.payments.map(\.amount).reduce(0, +)
        let cited = [pack.file.cite("/contracts/\(index)/contractValue")]
            + contract.payments.indices.map { pack.file.cite("/contracts/\(index)/payments/\($0)/amount") }
        return (Double(total) * 100 / Double(contract.contractValue), cited.map(RedFlagResult.Input.pack))
    }

    func overpaid() -> [RedFlagResult] {
        perContract { pack, index, contract in
            guard contract.contractValue > 0 else {
                return [result(.notChecked(.zeroValue), subject: contract.ocid)]
            }
            let paid = paid(pack, index, contract)
            return [judged(paid.percent, subject: contract.ocid, inputs: paid.inputs)]
        }
    }

    func paidAheadOfBuilt() -> [RedFlagResult] {
        perContract { pack, index, contract in
            guard contract.contractValue > 0 else {
                return [result(.notChecked(.zeroValue), subject: contract.ocid)]
            }
            let paid = paid(pack, index, contract)
            let progress = contract.physicalProgress
            let built = progress.kmBuilt * 100 / progress.kmTotal
            let cited = ["kmBuilt", "kmTotal"].map { RedFlagResult.Input.pack(
                pack.file.cite("/contracts/\(index)/physicalProgress/\($0)")) }
            return [judged(paid.percent - built, subject: contract.ocid, inputs: paid.inputs + cited)]
        }
    }

    func sameInvoiceTwice() -> [RedFlagResult] {
        perContract { pack, index, contract in
            let cite = { (field: String, items: [Int]) in
                items.map { RedFlagResult.Input.pack(pack.file.cite("/contracts/\(index)/payments/\($0)/\(field)")) }
            }
            let byReference = Dictionary(grouping: contract.payments.indices) { contract.payments[$0].reference }
            let byAmount = Dictionary(grouping: contract.payments.indices) { contract.payments[$0].amount }
            let repeated = byReference.filter { $0.value.count > 1 }
                .sorted { $0.value[0] < $1.value[0] }
                .map { judged(Double($0.value.count), subject: $0.key, inputs: cite("reference", $0.value)) }
                + byAmount.filter { $0.value.count > 1 }
                .sorted { $0.value[0] < $1.value[0] }
                .map { judged(Double($0.value.count), subject: String($0.key), inputs: cite("amount", $0.value)) }
            guard repeated.isEmpty else { return repeated }
            let all = Array(contract.payments.indices)
            return [judged(contract.payments.isEmpty ? 0 : 1, subject: contract.ocid,
                           inputs: cite("reference", all) + cite("amount", all))]
        }
    }

    func lateMilestones() -> [RedFlagResult] {
        guard let pack = inputs.milestones, !pack.milestones.isEmpty else {
            return [result(.notChecked(.noMilestones))]
        }
        let cite = { (index: Int) in
            ["dueDate", "status"].map { RedFlagResult.Input.pack(pack.file.cite("/milestones/\(index)/\($0)")) }
        }
        let late = pack.milestones.enumerated().compactMap { index, milestone -> RedFlagResult? in
            guard milestone.status != .met, let days = PackDay.days(from: milestone.dueDate, to: walkDay),
                  rule.threshold.isCrossed(by: Double(days)) else { return nil }
            return judged(Double(days), subject: milestone.id, inputs: cite(index))
        }
        guard late.isEmpty else { return late }
        return [result(.clear, computed: 0, inputs: pack.milestones.indices.flatMap(cite))]
    }

    func samePhotoAgain() -> [RedFlagResult] {
        guard let check = inputs.photos, !check.photos.isEmpty else { return [result(.notChecked(.needsPhotos))] }
        var seen = Set<[PhotoRef]>()
        var flags: [RedFlagResult] = []
        for photo in check.photos {
            guard let same = check.sameBytes.values.first(where: { $0.contains(photo) }), same.count > 1,
                  seen.insert(same).inserted else { continue }
            var flag = judged(Double(same.count), subject: "photo \(photo.seq)",
                              inputs: same.map(RedFlagResult.Input.evidence))
            flag.skippedMissions = check.skipped.count
            flags.append(flag)
        }
        guard flags.isEmpty else { return flags }
        var clear = judged(1, subject: nil, inputs: check.photos.map(RedFlagResult.Input.evidence))
        clear.skippedMissions = check.skipped.count
        return [clear]
    }
}
