// ImagePicker.swift
// 选图/相册 picker：新手用来「测试识别」流程。
// 注意：真机「无感截图」走的是 ScreenshotIntent（快捷指令），不需要这个 picker。
import SwiftUI
import PhotosUI
import Combine
import UIKit

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

// MARK: - 实时相机拍照 Presenter
// 相机按钮调用：调起系统相机拍照，拍完直接拿 originalImage 回调给调用方。
// 模拟器无摄像头，调用方需先用 UIImagePickerController.isSourceTypeAvailable(.camera) 判断。
//
// 【为什么不用 SwiftUI 呈现】
// 早期实现是 `CameraPicker: UIViewControllerRepresentable` + `.fullScreenCover`，踩了两个坑：
//   ① 白边：fullScreenCover 在相机 VC 背后保留一层白底托管容器，在安全区
//      （刘海/灵动岛/底部 Home Indicator）之外留白，VC 内刷 window.backgroundColor 无效。
//   ② 白屏一帧：即便改成「空壳 launcher 被 cover 托管 → viewDidAppear 再弹黑 window」，
//      launcher 本身仍走 cover 呈现动画，那一帧浅色容器就是用户看到的「先白屏一下」。
// 根治：彻底脱离 SwiftUI 呈现链。点按时直接在当前 UIWindowScene 上建**透明**临时 UIWindow
// （windowLevel = .statusBar + 1），再在其 root VC 上 present 相机，无任何过渡白。
//
// 【动画怎么来的】
// window 的显隐（makeKeyAndVisible / isHidden）是**瞬时的、无转场**的，
// 所以不能把相机直接 addChild 嵌进 root VC —— 那样相机会「凭空出现/消失」没有动画。
// 正确做法：window 本身透明且立刻显示（用户看不见它），相机则用
// `present(_:animated: true)` 弹出、`dismiss(animated: true)` 收起，
// 由 UIKit 提供原生上滑/下滑转场；等 dismiss 动画**完成后**再拆窗。
// 透明 window 的必要性：若 window 是黑底，present 动画期间下方会露出纯黑而非 App 内容，
// 观感像「先黑屏再滑出相机」；透明则能透出底下真实 App 界面，转场自然。
final class CameraPresenter: NSObject {
    static let shared = CameraPresenter()
    private override init() { super.init() }

    /// 当前这次拍照的回调。同一时刻只允许一个相机会话。
    private var onImage: ((UIImage?) -> Void)?

    /// 拉起系统相机拍照，拍完/取消后回调 UIImage?（取消为 nil）。
    /// - Important: 调用方需先用 `UIImagePickerController.isSourceTypeAvailable(.camera)` 判断可用性；
    ///   取不到 foregroundActive 的 UIWindowScene 时直接回调 nil，不弹窗、不崩溃。
    @MainActor
    func present(onImage: @escaping (UIImage?) -> Void) {
        // 已有相机会话在跑（重复点按）时直接忽略，避免叠窗。
        guard CameraWindowHolder.shared.window == nil else { return }

        guard let scene = (UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive && $0 is UIWindowScene }
            as? UIWindowScene) else {
            onImage(nil)
            return
        }

        self.onImage = onImage

        let w = UIWindow(windowScene: scene)
        w.frame = scene.screen.bounds
        w.windowLevel = (.statusBar + 1)
        // 透明承载窗：自身不可见，只作为 present 相机的宿主，
        // 让相机的上滑转场能透出底下真实 App 界面。
        w.backgroundColor = .clear
        w.isOpaque = false
        w.overrideUserInterfaceStyle = .dark

        // 承载用的透明根 VC（不再嵌入相机，改为 present）
        let host = CameraHostViewController()
        host.overrideUserInterfaceStyle = .dark

        CameraWindowHolder.shared.window = w
        w.rootViewController = host
        w.makeKeyAndVisible()

        // 相机容器：黑底铺满，消除刘海/Home Indicator 处白边
        let container = CameraContainerViewController()
        container.delegate = self
        container.onFinish = { [weak self] picked in
            self?.dismissCamera(with: picked)
        }
        // 全屏呈现，避免 iOS 13+ 默认的卡片式（pageSheet）留出顶部间隙
        container.modalPresentationStyle = .fullScreen
        // animated: true —— 这就是「启动动画」的来源
        host.present(container, animated: true)
    }

    /// 收尾：先播 dismiss 动画，动画完成后再拆窗，最后回调结果。
    /// 顺序很重要：
    /// ① 必须等 dismiss 动画结束再拆 window，否则窗一撤动画就断了，又变成瞬间消失；
    /// ② 必须先拆窗再回调，保证回调里若立刻跳页/弹 sheet 不会被相机窗挡住。
    @MainActor
    private func dismissCamera(with image: UIImage?) {
        let callback = onImage
        onImage = nil

        let teardown: @MainActor () -> Void = {
            if let w = CameraWindowHolder.shared.window {
                w.isHidden = true
                w.rootViewController = nil
                CameraWindowHolder.shared.window = nil
            }
            callback?(image)
        }

        guard let host = CameraWindowHolder.shared.window?.rootViewController,
              host.presentedViewController != nil else {
            teardown()
            return
        }
        host.dismiss(animated: true) {
            MainActor.assumeIsolated { teardown() }
        }
    }
}

extension CameraPresenter: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let img = info[.originalImage] as? UIImage
        (picker.parent as? CameraContainerViewController)?.finish(with: img)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        (picker.parent as? CameraContainerViewController)?.finish(with: nil)
    }
}

// 持有临时相机 window 的单例，负责回收避免泄漏。
private final class CameraWindowHolder {
    static let shared = CameraWindowHolder()
    var window: UIWindow?
}

// 透明宿主 VC：自身完全不可见，仅作为 present 相机的载体。
// 透明是为了让相机的上滑/下滑转场能透出底下真实 App 界面，
// 而不是在一块纯黑背景上滑动（那样观感像先黑屏）。
private final class CameraHostViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        view.isOpaque = false
    }

    // 状态栏样式交给 present 出来的相机自己决定
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

// 用黑色背景的容器把 UIImagePickerController 铺满全屏（含安全区域），
// 并强制深色外观，消除系统相机在刘海/灵动岛和底部 Home Indicator 区域的白边。
// 注意：只染容器本身，不递归刷子视图——否则会遮住相机预览层导致画面全黑。
private final class CameraContainerViewController: UIViewController {
    var delegate: (UIImagePickerControllerDelegate & UINavigationControllerDelegate)?
    var onFinish: ((UIImage?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraFlashMode = .auto
        picker.delegate = delegate
        picker.overrideUserInterfaceStyle = .dark
        // 相机 UI 自己延伸到安全区边缘，避免上下留白
        picker.extendedLayoutIncludesOpaqueBars = true
        picker.edgesForExtendedLayout = .all

        addChild(picker)
        view.addSubview(picker.view)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.view.topAnchor.constraint(equalTo: view.topAnchor),
            picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        picker.didMove(toParent: self)
    }

    func finish(with image: UIImage?) { onFinish?(image) }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var childForStatusBarStyle: UIViewController? { nil }
}

