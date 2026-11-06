import SwiftUI

/// A number or text answer, saved when the officer leaves the field, presses Done or return, never on every
/// letter (one audit event per answer, not per key). Found on the iPhone (#129): the number pad has no
/// return key, so a Done bar sits above it; and the field takes the saved answer only when nobody is typing
/// in it, so a redraw never wipes what is being typed.
struct TypedAnswer: View {
    let kind: QuestionKind
    let answer: String
    var words = SiteWalkWords()
    var onCommit: (String) -> Void = { _ in }
    @State private var text: String
    @FocusState private var typing: Bool

    init(kind: QuestionKind, answer: String, words: SiteWalkWords = SiteWalkWords(),
         onCommit: @escaping (String) -> Void = { _ in }) {
        (self.kind, self.answer, self.words, self.onCommit) = (kind, answer, words, onCommit)
        _text = State(initialValue: answer)
    }

    var body: some View {
        TextField(words.text(kind == .text ? .yourAnswer : .number), text: $text)
            .keyboardType(kind == .integer ? .numberPad : kind == .decimal ? .decimalPad : .default)
            .autocorrectionDisabled()
            .textInputAutocapitalization(kind == .text ? .characters : .never)
            .font(.title3)
            .padding(12)
            .frame(minHeight: 48)
            .background(Color(.surface), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
            .focused($typing)
            .submitLabel(.done)
            .onSubmit { typing = false }
            .toolbar {
                if typing {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(words.language == "fr" ? "OK" : "Done") { typing = false }
                            .font(.headline)
                    }
                }
            }
            .onChange(of: typing) { _, isTyping in if !isTyping { commit() } }
            .onChange(of: answer) { _, saved in if !typing { text = saved } }
    }

    private func commit() {
        let value = Self.saved(text, kind: kind)
        if value != answer { onCommit(value) }
    }

    /// What is saved: no spaces around it; a decimal comma (French keyboards) as the form's point.
    static func saved(_ text: String, kind: QuestionKind) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return kind == .decimal ? trimmed.replacingOccurrences(of: ",", with: ".") : trimmed
    }
}

/// A date answer: set it (today to start), change it with the picker, or clear it.
struct DateAnswer: View {
    let answer: String
    let words: SiteWalkWords
    var onSet: (String) -> Void = { _ in }

    var body: some View {
        if let date = words.date(fromAnswer: answer) {
            HStack {
                DatePicker("Date", selection: Binding(get: { date }, set: { onSet(words.dateAnswer($0)) }),
                           displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Button(words.text(.clear)) { onSet("") }
                    .buttonStyle(.fieldSecondary)
            }
        } else {
            Button(words.text(.setDate)) { onSet(words.dateAnswer(Date())) }
                .buttonStyle(.fieldSecondary)
        }
    }
}

/// The sample point's place: recorded only when the officer taps (location is asked for then).
struct PlaceAnswer: View {
    let answer: String
    var words = SiteWalkWords()
    var onRecord: () async -> Void = {}
    @State private var finding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = Place(geopoint: answer) {
                Label(SiteWalkWords.place(place, language: words.language), systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
            }
            Button {
                finding = true
                Task {
                    await onRecord()
                    finding = false
                }
            } label: {
                Label(words.text(finding ? .finding : answer.isEmpty ? .recordLocation : .recordAgain),
                      systemImage: "location.circle")
            }
            .buttonStyle(answer.isEmpty ? AnyButtonStyle(.fieldPrimary) : AnyButtonStyle(.fieldSecondary))
            .disabled(finding)
        }
    }
}

/// Either field button style, chosen at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<Style: ButtonStyle>(_ style: Style) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
