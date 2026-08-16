// VoiceRecordView.swift
// 语音记录：调用麦克风 + 系统语音识别引擎（SFSpeechRecognizer）实时把用户说的话转成文字，
// 停止后把文字发给云端 /recognize 解析意图，识别结果走与图片一致的「结果确认页」，
// 用户确认后才写入对应板块（饮食/账单/待办/健康）。
// 注意：语音识别需真机（模拟器无麦克风/无语音框架能力）。
import SwiftUI
import SwiftData
import Speech
import AVFoundation
import Combine

/// 语音识别封装：管理 AVAudioEngine + SFSpeechRecognitionTask 的生命周期，实时回传转写文字。
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 标记本次停止是否由用户主动触发（发送/停止按钮）。
    /// 用户手动 stop 时 cancel 任务会附带 error，常见如 "No speech detected"，属于误报，不应展示红字。
    private var cancelledByUser = false

    var isAvailable: Bool {
        (speechRecognizer?.isAvailable ?? false) && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// 申请权限并开始录音 + 实时识别
    func start() {
        transcript = ""
        errorMessage = nil
        cancelledByUser = false
        let status = SFSpeechRecognizer.authorizationStatus()
        #if DEBUG
        print("[SpeechRecognizer] start(), status=\(status.rawValue)")
        #endif
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] auth in
                #if DEBUG
                print("[SpeechRecognizer] authorization callback: \(auth.rawValue)")
                #endif
                guard auth == .authorized else {
                    DispatchQueue.main.async {
                        self?.errorMessage = "未授权语音识别，请在系统设置中开启。"
                        #if DEBUG
                        print("[SpeechRecognizer] not authorized, errorMessage set")
                        #endif
                    }
                    return
                }
                self?.beginRecording()
            }
        } else if status == .authorized {
            beginRecording()
        } else {
            errorMessage = "未授权语音识别，请在系统设置中开启。"
        }
    }

    private func beginRecording() {
        #if DEBUG
        print("[SpeechRecognizer] beginRecording()")
        #endif
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DispatchQueue.main.async { self.errorMessage = "无法启动麦克风：\(error.localizedDescription)" }
            #if DEBUG
            print("[SpeechRecognizer] audio session error: \(error)")
            #endif
            return
        }

        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        engine.prepare()
        do { try engine.start() } catch {
            DispatchQueue.main.async { self.errorMessage = "录音启动失败：\(error.localizedDescription)" }
            return
        }

        audioEngine = engine
        request = req
        DispatchQueue.main.async { self.isRecording = true }
        #if DEBUG
        print("[SpeechRecognizer] beginRecording OK, isRecording=true")
        #endif

        task = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            // 引擎自动结束（停顿）或出错都停止。
            // 注意：用户手动 stop()/send() 取消任务时也会进 error 分支，常见 "No speech detected" / "Recognition request was canceled" 是误报，
            // 用 cancelledByUser 标记 + 取消类错误描述双重过滤；真正的未识别/系统静音超时（非手动）仍可提示。
            if result?.isFinal == true || error != nil {
                let shouldReport: Bool
                if let error = error {
                    #if DEBUG
                    print("[SpeechRecognizer] recognition task error: \(error)")
                    #endif
                    let desc = error.localizedDescription.lowercased()
                    let isCancelError = desc.contains("canceled") || desc.contains("cancelled") || desc.contains("no speech detected") || desc.contains("recognition request")
                    shouldReport = !self.cancelledByUser && !isCancelError
                } else {
                    shouldReport = false
                }
                DispatchQueue.main.async {
                    if shouldReport {
                        self.errorMessage = "语音识别失败：\(error!.localizedDescription)"
                    }
                    self.cancelledByUser = false
                    self.stop()
                }
            }
        }
    }

    /// 停止录音与识别
    func stop() {
        guard isRecording else { return }
        // 用户主动停止/发送时，cancel 任务会触发 error 回调（常见 No speech detected），
        // 用 cancelledByUser 标记，让回调忽略这种误报。
        cancelledByUser = true
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit { stop() }
}

struct VoiceRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @StateObject private var recognizer = SpeechRecognizer()
    @State private var isProcessing = false
    @State private var showResult = false
    @State private var savedSession: SavedSession?
    @State private var localError: String?

    /// 可选：识别完成后的回调（用于对话页语音输入，把文字回填输入框）。
    /// 不传则走原有「语音记录」流程（识别意图 → 结果确认页）。
    var onResult: ((String) -> Void)? = nil

    // 录音计时
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // 实时转写
                ScrollView {
                    Text(recognizer.transcript.isEmpty ? "点击下面的麦克风开始说话，松手后自动识别并记录。" : recognizer.transcript)
                        .font(AIATheme.Font.headline)
                        .foregroundStyle(recognizer.transcript.isEmpty ? AIATheme.sub : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                        .background(AIATheme.fillSoft, in: RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .padding(.horizontal)

                Spacer(minLength: 0)

                // 录音状态 / 计时
                if recognizer.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(AIATheme.warn).frame(width: 8, height: 8)
                            .opacity(0.6 + 0.4 * sin(elapsed * 4))
                        Text(timeString(elapsed))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(AIATheme.sub)
                    }
                    .animation(.easeInOut(duration: 0.3), value: elapsed)
                }

                // 麦克风按钮
                Button {
                    if recognizer.isRecording {
                        finishAndRecognize()
                    } else {
                        recognizer.start()
                        startTimer()
                    }
                } label: {
                    Circle()
                        .fill(recognizer.isRecording ? AIATheme.warn : AIATheme.blue)
                        .frame(width: 88, height: 88)
                        .overlay(
                            Image(systemName: recognizer.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(AIATheme.Font.ultra)
                                .foregroundStyle(.white)
                        )
                        .scaleEffect(recognizer.isRecording ? 1.06 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recognizer.isRecording)
                }
                .disabled(isProcessing)
                Text(recognizer.isRecording ? "点击结束" : "点击说话")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.sub)

                if let err = recognizer.errorMessage {
                    Text(err).font(AIATheme.Font.footnote).foregroundStyle(AIATheme.warn)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding(.vertical, 24)
            .navigationTitle("语音记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay {
                if isProcessing {
                    ProgressView("识别中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                }
            }
            .centeredAlert(isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } }),
                           message: localError ?? "")
        }
        .sheet(isPresented: $showResult) {
            if let s = savedSession {
                ResultConfirmView(result: s.result, rawText: s.rawText, sourceImage: s.sourceImage, existingSession: s)
                    .environment(\.modelContext, context)
            }
        }
        .onDisappear { recognizer.stop() }
    }

    // MARK: - 流程
    private func startTimer() {
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func finishAndRecognize() {
        timer?.invalidate()
        timer = nil
        let text = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizer.stop()
        guard !text.isEmpty else {
            localError = "没有听到内容，请再试一次。"
            return
        }
        // 对话页语音输入模式：直接把文字回传，不走记录确认流程
        if let onResult {
            onResult(text)
            dismiss()
            return
        }
        isProcessing = true
        Task {
            do {
                let output = try await RecognizeService.parseText(text)
                await Task { @MainActor in
                    // 招呼气泡定位锚点：必须打在插入本次第一条新消息（口述气泡）之前，
                    // 否则 ChatView.onAppear 会把这条口述算成历史，招呼气泡排到它后面。
                    NavigationRouter.shared.beginChatSession()
                    // 插入用户口述气泡
                    let userMsg = ChatMessage(role: .user, text: text, createdAt: Date())
                    context.insert(userMsg)
                    // 统一走识别卡片水槽（与图片/文字一致）：已保存/待确认卡片插入对话流
                    _ = await RecognitionSaver.processRecognition(
                        result: output.result, rawText: output.rawText, image: nil,
                        context: context, source: .local, entryOrigin: "voice")
                    isProcessing = false
                    // 卡片已插入对话页，跳转过去查看
                    NavigationRouter.shared.navigateToChat()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    localError = "识别失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
