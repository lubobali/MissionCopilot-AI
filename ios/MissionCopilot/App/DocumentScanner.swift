import UIKit
import VisionKit

/// What a document scan gave back (#138): the pages saved as signed evidence, or why not.
enum ScanOutcome: Equatable, Sendable {
    case pages(Int)
    case cancelled
    case unavailable
    case failed
    case notSaved

    var scanned: Bool {
        if case .pages(let count) = self { count > 0 } else { false }
    }

    var words: String {
        switch self {
        case .pages(let count): count == 1 ? "1 page saved as signed evidence"
            : "\(count) pages saved as signed evidence"
        case .cancelled: "No pages scanned"
        case .unavailable: "This iPhone cannot scan documents. Take a photo of each page instead."
        case .failed: "The scan did not finish. Try again."
        case .notSaved: "The pages could not be saved. Try again."
        }
    }
}

/// Apple's document camera (camera only: it never offers the photo library), presented full screen straight
/// from the app's top view controller. Checked on the web before building (Nov 6): on iOS 26 it can crash
/// right after a photo when it ends up inside another navigation controller with Liquid Glass on (Apple
/// forums 811188), so it is never wrapped in SwiftUI's navigation or a sheet. Proven on the iPhone (6.5.1).
@MainActor
final class DocumentScanner: NSObject, VNDocumentCameraViewControllerDelegate {
    static let shared = DocumentScanner()

    private var waiting: CheckedContinuation<[UIImage]?, Never>?

    /// The scanned pages, or nil when the officer cancelled or the scan failed (the outcome says which).
    func scan() async -> (outcome: ScanOutcome, pages: [UIImage]) {
        guard VNDocumentCameraViewController.isSupported, let top = Self.topViewController() else {
            return (.unavailable, [])
        }
        guard waiting == nil else { return (.failed, []) }
        let camera = VNDocumentCameraViewController()
        camera.delegate = self
        camera.modalPresentationStyle = .fullScreen
        let pages = await withCheckedContinuation { continuation in
            waiting = continuation
            top.present(camera, animated: true)
        }
        guard let pages else { return (failedOrCancelled, []) }
        return (.pages(pages.count), pages)
    }

    private var failedOrCancelled = ScanOutcome.cancelled

    private func finish(_ controller: VNDocumentCameraViewController, _ pages: [UIImage]?, _ outcome: ScanOutcome) {
        failedOrCancelled = outcome
        controller.dismiss(animated: true)
        waiting?.resume(returning: pages)
        waiting = nil
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                  didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map(scan.imageOfPage)  // taken out here, then handed over
        MainActor.assumeIsolated { finish(controller, pages, .cancelled) }
    }

    nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        MainActor.assumeIsolated { finish(controller, nil, .cancelled) }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                  didFailWithError error: any Error) {
        MainActor.assumeIsolated { finish(controller, nil, .failed) }
    }

    /// The view controller on top of everything the app shows, to present from.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
