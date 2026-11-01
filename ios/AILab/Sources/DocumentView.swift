import SwiftUI
import VisionKit

/// Spike #15 screen: read the built-in pages, or scan a printed page and score it against the answer key.
struct DocumentView: View {
    @State private var model = DocumentLabModel()
    @State private var condition = DocumentLabModel.Condition.printedFlat
    @State private var scanning = false
    @State private var scanningAnyPage = false

    var body: some View {
        List {
            Section("1. Does the A15 read documents?") {
                Button("Read built-in pages (cold + warm)") { model.readBuiltInPages() }
            }
            Section("2. Scan a page (the page is detected by code)") {
                Picker("Condition", selection: $condition) {
                    ForEach(DocumentLabModel.Condition.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Scan with camera") { scanning = true }
                    .disabled(!VNDocumentCameraViewController.isSupported)
                Button("Re-score saved scans") { model.rescoreSavedScans() }
            }
            .disabled(model.running)
            Section("Real paper of your own (unscored: counts only, no text or photo kept)") {
                Button("Read any page") { scanningAnyPage = true }
                    .disabled(!VNDocumentCameraViewController.isSupported)
            }
            .disabled(model.running)
            #if !NO_MLX
            Section("3. Scan -> AI -> 8 facts, checked by code (offline)") {
                Button("Run scan -> facts (clean x3 + saved photos)") { model.runScanToFacts() }
            }
            .disabled(model.running)
            #endif
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Documents #15")
        .fullScreenCover(isPresented: $scanningAnyPage) {
            DocumentScanner { images in
                scanningAnyPage = false
                if !images.isEmpty { model.readAnyPage(images) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if !images.isEmpty { model.scanned(images, condition: condition) }
            }
            .ignoresSafeArea()
        }
    }
}

/// VisionKit's document camera (no SwiftUI version exists): finds the page edges and straightens it.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void

        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onFinish([])
        }
    }
}
