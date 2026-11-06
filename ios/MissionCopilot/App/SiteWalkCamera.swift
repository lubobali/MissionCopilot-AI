import SwiftUI
import UIKit

/// Apple's camera screen, camera only: the walk never reads the photo library, so a site photo is always
/// one taken on site (#129; photos reused from other sites are a known fraud pattern).
struct CameraView: UIViewControllerRepresentable {
    var onPhoto: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto, onCancel: onCancel) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPhoto: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            (self.onPhoto, self.onCancel) = (onPhoto, onCancel)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPhoto(image) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// A photo slot: its thumbnail when there is one, and the button that opens the camera.
struct PhotoSlot: View {
    let seq: Int?
    let thumbnail: UIImage?
    let empty: String  // "Take photo" or "Add a photo"
    let words: SiteWalkWords
    var onTake: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(words.language == "fr" ? "Photo prise sur le site" : "Photo taken on site")
            }
            Button(action: onTake) {
                Label(seq == nil ? empty : words.text(.retakePhoto), systemImage: "camera")
            }
            .buttonStyle(seq == nil ? AnyButtonStyle(.fieldPrimary) : AnyButtonStyle(.fieldSecondary))
        }
    }
}

/// Which slot the camera is open for, so the photo lands there.
struct CameraTarget: Identifiable, Equatable {
    let target: SiteWalkModel.PhotoTarget
    var id: String {
        switch target {
        case .question(let name): "question:\(name)"
        case .action(let key): "action:\(key)"
        }
    }
}
