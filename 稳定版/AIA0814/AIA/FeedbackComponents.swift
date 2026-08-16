// FeedbackComponents.swift
// 意见反馈：应用内输入 + 调用系统邮件 composer 转发到指定邮箱。
import SwiftUI
import MessageUI

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
        vc.setMessageBody(body, isHTML: false)
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
