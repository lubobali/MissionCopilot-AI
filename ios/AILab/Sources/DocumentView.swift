import SwiftUI
import VisionKit

/// Spike #15 screen: read the built-in pages, or scan a printed page and score it against the answer key.
struct DocumentView: View {
    @State private var model = DocumentLabModel()
    @State private var condition = DocumentLabModel.Condition.printedFlat
    @State private var scanning = false

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
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Documents #15")
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
