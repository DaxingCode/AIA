// FeedbackComponents.swift
// 意见反馈：应用内输入 + 调用系统邮件 composer 转发到指定邮箱。
import SwiftUI
import MessageUI
import Darwin

struct FeedbackSheet: View {
    @Binding var text: String
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(AIATheme.Font.callout)
                        .padding(10)
                        .frame(minHeight: 160)
                        .background(AIATheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    if isEmpty {
                        Text(NSLocalizedString("feedback.placeholder", comment: ""))
                            .font(AIATheme.Font.callout)
                            .foregroundStyle(AIATheme.muted)
                            .padding(.leading, 16)
                            .padding(.top, 18)
                    }
                }
                .padding()

                Spacer()
            }
            .background(AIATheme.fillSoft.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("chat.feedback", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(AIATheme.sub)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSend) {
                        Text(NSLocalizedString("common.send", comment: ""))
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(isEmpty ? AIATheme.muted : .white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(isEmpty ? AIATheme.surfaceSecondary : AIATheme.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isEmpty)
                }
            }
        }
    }
}

struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    var onFinished: (() -> Void)?

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: true)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var onFinished: (() -> Void)?

        init(onFinished: (() -> Void)?) {
            self.onFinished = onFinished
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true)
            onFinished?()
        }
    }
}

// >>> CHANGE-[2026-08-30 15:00:00]-[反馈邮件带系统设备信息] 开始
/// 精确机型标识，如 "iPhone16,2"；取不到回退 "Unknown"。
func deviceModelIdentifier() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "Unknown" }
    var machine = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &machine, &size, nil, 0)
    return String(cString: machine)
}

/// 反馈邮件底部自动附加的设备/系统信息块（HTML 右对齐，沉到正文右下角）。
func feedbackDeviceInfoHTML() -> String {
    let system = UIDevice.current.systemName           // iOS
    let osVersion = UIDevice.current.systemVersion      // 26.6.1
    let modelID = deviceModelIdentifier()              // iPhone16,2
    let deviceName = UIDevice.current.model             // iPhone

    let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                   ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String
                   ?? "好记AI"
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    let locale = Locale.current.identifier              // zh_CN

    return """
    <br/><br/>
    <div style="text-align:right; color:#888888; font-size:12px; line-height:1.6;">
    System: \(system) \(osVersion)<br/>
    Device: \(deviceName) (\(modelID))<br/>
    \(appName) version: \(appVersion) (\(build))<br/>
    Locale: \(locale)
    </div>
    """
}
// <<< CHANGE-[2026-08-30 15:00:00]-[反馈邮件带系统设备信息] 结束
