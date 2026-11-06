import SwiftUI

/// Opens a mission's site walk by its id (a value page: declared at the root, scripts/test_navigation.py).
struct SiteWalkLink: Hashable, Sendable {
    let id: String
}

/// The site walk (#129): the agreed actions from the last mission first, then the site checklist, then
/// Finish. Everything is saved as it changes; opened again, it comes back as it was.
struct SiteWalkScreen: View {
    let list: MissionListModel
    let id: String
    @State private var walk: SiteWalkModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let walk {
                ScrollView { SiteWalkView(model: walk) }
                    .scrollDismissesKeyboard(.interactively)
                    // A tap outside a field closes the keyboard, and the field saves as it closes.
                    .simultaneousGesture(TapGesture().onEnded {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil,
                                                        from: nil, for: nil)
                    })
            } else if cannotOpen {
                Text("The site walk cannot open. Unlock the app, and make sure the mission's pack is downloaded.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the site walk")
            }
        }
        .fieldScreen()
        .navigationTitle(walk?.language == "fr" ? "Visite de site" : "Site walk")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard walk == nil else { return }
            guard let store = list.openStore, let model = try? SiteWalkModel.load(mission: id, store: store) else {
                cannotOpen = true
                return
            }
            walk = model
        }
    }
}

/// The walk without the scrolling, for the screenshot tests too.
struct SiteWalkView: View {
    @Bindable var model: SiteWalkModel
    var words = SiteWalkWords()
    @State private var confirming = false
    @State private var camera: CameraTarget?

    private var locked: Bool { model.finished != nil }

    /// The page's words in the walk's language, dates in that language too.
    private var local: SiteWalkWords {
        var local = words
        local.language = model.language
        if model.language == "fr" {
            local.missions = MissionWords(locale: Locale(identifier: "fr_FR"), timeZone: words.missions.timeZone)
        }
        return local
    }

    var body: some View {
        let words = local
        VStack(alignment: .leading, spacing: 22) {
            header
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(.warning))
            }
            AgreedActionsSection(walk: model.walk, words: words, locked: locked,
                                 onCheck: { seen, note, key in model.check(seen, note: note, action: key) },
                                 onPhoto: openCamera, thumbnail: model.thumbnail)
            ChecklistSection(walk: model.walk, words: words, locked: locked,
                             onAnswer: { value, question in model.answer(value, to: question) },
                             onPlace: { question in await model.recordPlace(for: question) },
                             onPhoto: openCamera, thumbnail: model.thumbnail)
            finish
        }
        .padding(16)
        .fullScreenCover(item: $camera) { open in
            CameraView(onPhoto: { image in
                camera = nil
                Task { await model.photoTaken(image, for: open.target) }
            }, onCancel: {
                camera = nil
                model.cameraCancelled()
            })
            .ignoresSafeArea()
        }
    }

    /// Opens the camera for a slot, or says why it cannot (asked for only now, MASVS-PRIVACY-1).
    private func openCamera(_ target: SiteWalkModel.PhotoTarget) {
        if let problem = CameraAccess.current().problem(app: SiteWalkModel.appName, language: model.language) {
            model.problem = problem
            return
        }
        model.cameraOpening()
        camera = CameraTarget(target: target)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(local.progress(model.walk.progress, finished: model.finished),
                  systemImage: locked ? "lock.fill" : "figure.walk")
                .font(.headline)
                .foregroundStyle(Color(locked ? .success : .text))
            if locked {
                Text(local.text(.locked))
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            }
            if model.walk.form.hasFrench {
                Picker("Language", selection: $model.language) {
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(local.text(.languageLabel))
            }
        }
    }

    @ViewBuilder private var finish: some View {
        if !locked {
            if model.walk.canFinish {
                Button(local.text(.finish)) { confirming = true }
                    .buttonStyle(.fieldPrimary)
                    .confirmationDialog(local.text(.finishQuestion), isPresented: $confirming,
                                        titleVisibility: .visible) {
                        Button(local.text(.finishConfirm)) { model.finish() }
                        Button(local.text(.notYet), role: .cancel) {}
                    } message: {
                        Text(local.text(.finishWarning))
                    }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(local.text(.stillToDo))
                        .font(.headline)
                    ForEach(Array(model.walk.missing.enumerated()), id: \.offset) { _, missing in
                        Label(SiteWalkWords.missing(missing, in: model.walk), systemImage: "circle")
                            .font(.subheadline)
                            .foregroundStyle(Color(.secondaryText))
                    }
                }
                .walkCard()
            }
        }
    }
}

extension View {
    /// The walk's cards: glass, like Before you go, with room around the text.
    func walkCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
    }
}
