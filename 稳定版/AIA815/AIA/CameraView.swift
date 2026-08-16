// CameraView.swift
// 自定义相机界面：基于 AVFoundation（系统原生捕获）实现，UI 简洁、文字随系统语言。
// 支持：点击对焦（对焦框动画）、双指捏合变焦（1x ~ 设备上限，封顶 10x）。
import SwiftUI
import AVFoundation
import Combine

struct CameraView: View {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss
    @StateObject private var manager = CameraManager()
    @State private var showError = false
    @State private var focusPoint: CGPoint?
    @State private var showReticle = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: manager.session, manager: manager) { point in
                focusPoint = point
                withAnimation(.easeInOut(duration: 0.18)) { showReticle = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    withAnimation(.easeInOut(duration: 0.3)) { showReticle = false }
                }
            }
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                if let focusPoint, showReticle {
                    FocusReticle()
                        .position(focusPoint)
                        .scaleEffect(showReticle ? 1 : 1.6)
                        .opacity(showReticle ? 1 : 0)
                }
            }

            VStack(spacing: 0) {
                // 顶部：关闭 + 变焦倍数 + 闪光灯
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(AIATheme.Font.title1.weight(.medium))
                    }
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())

                    Spacer()

                    if manager.zoomFactor > 1.01 {
                        Text(String(format: "%.1fx", manager.zoomFactor))
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button { manager.toggleFlash() } label: {
                        Image(systemName: manager.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(AIATheme.Font.title2)
                    }
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                // 底部：切换镜头 + 快门
                HStack(spacing: 0) {
                    Button { manager.switchCamera() } label: {
                        Image(systemName: "camera.rotate")
                            .font(AIATheme.Font.title1)
                    }
                    .frame(maxWidth: .infinity)

                    Button { manager.capture() } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(.white)
                                .frame(width: 60, height: 60)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.bottom, 42)
                .background(.black.opacity(0.25))
            }
        }
        .statusBar(hidden: true)
        .onAppear { manager.start() }
        .onDisappear { manager.stop() }
        .onChange(of: manager.capturedImage) { _, new in
            if let new {
                image = new
                dismiss()
            }
        }
        .centeredAlert(isPresented: $showError,
                       title: "无法使用相机",
                       message: "请检查相机权限或稍后重试。",
                       dismissTitle: "确定",
                       onDismiss: { dismiss() })
        .onReceive(manager.$error) { err in
            showError = err != nil
        }
    }
}

// MARK: - 对焦框
struct FocusReticle: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 72, height: 72)
            Rectangle().fill(Color.yellow).frame(width: 2, height: 14)
            Rectangle().fill(Color.yellow).frame(width: 14, height: 2)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 0)
    }
}

// MARK: - 摄像头预览
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    weak var manager: CameraManager?
    let onFocusViewPoint: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = session
        view.manager = manager
        view.onFocusViewPoint = onFocusViewPoint
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.manager = manager
        uiView.onFocusViewPoint = onFocusViewPoint
        uiView.setNeedsLayout()
    }

    final class PreviewUIView: UIView {
        var session: AVCaptureSession? {
            didSet { setupPreviewLayer() }
        }
        weak var manager: CameraManager?
        var onFocusViewPoint: ((CGPoint) -> Void)?

        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var pinchStartZoom: CGFloat = 1

        private func setupPreviewLayer() {
            guard previewLayer == nil, let session = session else { return }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.backgroundColor = UIColor.black.cgColor
            self.layer.addSublayer(layer)
            previewLayer = layer

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            self.addGestureRecognizer(tap)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            self.addGestureRecognizer(pinch)

            setNeedsLayout()
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            let viewPoint = g.location(in: self)
            let devicePoint = previewLayer?.captureDevicePointConverted(fromLayerPoint: viewPoint) ?? viewPoint
            manager?.focus(at: devicePoint)
            onFocusViewPoint?(viewPoint)
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchStartZoom = manager?.zoomFactor ?? 1
            case .changed:
                manager?.setZoom(pinchStartZoom * g.scale)
            default:
                break
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
            updateOrientation()
        }

        private func updateOrientation() {
            guard let connection = previewLayer?.connection, connection.isVideoOrientationSupported else { return }
            let deviceOrientation = UIDevice.current.orientation
            let videoOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue) ?? .portrait
            connection.videoOrientation = videoOrientation
        }
    }
}

// MARK: - 相机管理
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.aia.camera.session")
    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?

    /// 监听「对焦调整结束」的 KVO 句柄（绑定到当前设备）。
    private var focusObserver: NSKeyValueObservation?
    /// 监听「主体区域变化」通知的令牌（绑定到当前设备）。
    private var subjectAreaObserver: NSObjectProtocol?
    /// 是否正在执行用户点击触发的单次对焦；用于区分「点击对焦完成」与「持续对焦调整」。
    private var isTapFocusing = false
    /// 点击对焦的兜底定时器：若 KVO 未回切（如对焦点已合焦、isAdjustingFocus 无变化），超时后强制恢复持续对焦。
    private var tapFocusFallbackWorkItem: DispatchWorkItem?

    @Published var capturedImage: UIImage?
    @Published var isFlashOn = false
    @Published var error: CameraError?
    @Published var zoomFactor: CGFloat = 1

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession()
            if self.session.inputs.isEmpty {
                DispatchQueue.main.async { self.error = .noDevice }
                return
            }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func capture() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = self.isFlashOn ? .on : .off
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            self?.toggleCamera()
        }
    }

    func toggleFlash() {
        DispatchQueue.main.async { [weak self] in
            self?.isFlashOn.toggle()
        }
    }

    // 点击对焦：仅在后置摄像头支持手动对焦，执行「单次对焦」。
    // 单次对焦完成后（通过 KVO 监听 isAdjustingFocus 回到 false）会自动切回「持续自动对焦」，
    // 让相机持续追踪场景，避免一次对焦失败后画面永久发糊。
    func focus(at point: CGPoint) {
        guard let device = currentDevice, device.position == .back else { return }
        // 设备配置统一在 sessionQueue 上执行，避免阻塞主线程。
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                        // 标记进入单次对焦态，待对焦完成后再切回持续对焦。
                        self.isTapFocusing = true
                        // 兜底：若用户点击的位置已合焦，isAdjustingFocus 可能不发生变化，
                        // KVO 不会触发，因此用定时器超时强制回切，避免 isTapFocusing 卡死。
                        self.tapFocusFallbackWorkItem?.cancel()
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self, self.isTapFocusing else { return }
                            self.revertToContinuousFocusLocked()
                        }
                        self.tapFocusFallbackWorkItem = workItem
                        self.sessionQueue.asyncAfter(deadline: .now() + 3.0, execute: workItem)
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // 双指变焦：1x ~ 设备上限（封顶 10x）
    // 设备配置统一在 sessionQueue 上执行，避免与主线程/其他配置路径产生跨线程竞态。
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.currentDevice else { return }
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
            let clamped = min(max(factor, 1.0), maxZoom)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch { }
        }
    }

    /// 设备就绪（启动 / 切换镜头后）：重置为 1 倍焦距，并让相机持续自动对焦到画面中央。
    private func configureFocusAndZoom(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            // 默认 1 倍焦距
            device.videoZoomFactor = 1.0
            // 开启主体区域变化监测，便于场景显著变化时自动重新对焦。
            device.isSubjectAreaChangeMonitoringEnabled = true
            // 自动对焦：聚焦兴趣点取画面中心，优先持续自动对焦
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            // 曝光同步跟随中央，避免明暗失衡（默认持续自动曝光）
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = 1.0 }
            // 为当前设备建立「对焦完成 / 主体区域变化」监听（每次切换设备时更新）。
            observeDevice(device)
        } catch { }
    }

    // MARK: - 对焦监听

    /// 为指定设备建立「对焦调整结束」与「主体区域变化」监听。
    /// - 对焦调整结束：单次点击对焦完成后自动恢复持续对焦。
    /// - 主体区域变化：场景显著变化时自动把对焦/曝光重新锁定画面中央。
    private func observeDevice(_ device: AVCaptureDevice) {
        focusObserver?.invalidate()
        if let token = subjectAreaObserver {
            NotificationCenter.default.removeObserver(token)
            subjectAreaObserver = nil
        }

        focusObserver = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] observedDevice, _ in
            guard let self else { return }
            // 仅在对焦调整结束时响应（true -> false）。
            if !observedDevice.isAdjustingFocus {
                self.handleFocusAdjustmentFinished()
            }
        }

        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceSubjectAreaDidChange,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.resetFocusToCenter()
        }
    }

    /// 单次点击对焦完成后，切回持续自动对焦/曝光。所有状态访问均串行在 sessionQueue 上。
    private func handleFocusAdjustmentFinished() {
        sessionQueue.async { [weak self] in
            guard let self, self.isTapFocusing else { return }
            self.revertToContinuousFocusLocked()
        }
    }

    /// 将设备切回持续自动对焦/曝光模式。必须在 sessionQueue 上调用。
    private func revertToContinuousFocusLocked() {
        // 取消可能仍在排队的兜底定时器，避免与正常回切重复执行。
        tapFocusFallbackWorkItem?.cancel()
        tapFocusFallbackWorkItem = nil
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            isTapFocusing = false
        } catch { }
    }

    /// 场景主体区域变化时，把对焦/曝光兴趣点重置为画面中央并恢复持续模式。
    private func resetFocusToCenter() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isTapFocusing, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                let center = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = center
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = center
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                currentDevice = device
                // 启动即默认 1 倍焦距 + 自动对焦到画面中央
                configureFocusAndZoom(device)
            }
        } catch { return }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    private func toggleCamera() {
        guard let currentInput else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let previousInput = currentInput
        session.removeInput(currentInput)
        let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
            session.addInput(previousInput)
            return
        }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                self.currentInput = newInput
                // 切换镜头后同样重置为 1 倍焦距 + 自动对焦
                configureFocusAndZoom(device)
                self.currentDevice = device
                DispatchQueue.main.async { self.zoomFactor = 1 }
            } else {
                session.addInput(previousInput)
            }
        } catch {
            session.addInput(previousInput)
        }
    }

    deinit {
        // 清理需在 sessionQueue 上串行执行，避免与 observeDevice 的赋值产生跨线程数据竞争。
        let focusObs = focusObserver
        let subjectObs = subjectAreaObserver
        let fallback = tapFocusFallbackWorkItem
        sessionQueue.async {
            focusObs?.invalidate()
            if let subjectObs {
                NotificationCenter.default.removeObserver(subjectObs)
            }
            fallback?.cancel()
        }
    }
}

enum CameraError: Error, Identifiable {
    case noDevice
    var id: Self { self }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.capturedImage = image
        }
    }
}
