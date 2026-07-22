// ImagePicker.swift
// 选图/相册 picker：新手用来「测试识别」流程。
// 注意：真机「无感截图」走的是 ScreenshotIntent（快捷指令），不需要这个 picker。
import SwiftUI
import PhotosUI
import Combine

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let item = results.first else { return }
            item.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                Task { @MainActor in
                    self.parent.image = obj as? UIImage
                }
            }
        }
    }
}
