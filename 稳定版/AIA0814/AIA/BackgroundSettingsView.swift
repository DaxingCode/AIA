// BackgroundSettingsView.swift
// 设置 App 背景图（独立子页）：从相册选图、预览、遮罩浓度、恢复默认。
// 仅本机生效，图片不上传。由设置主页的「App 背景图」一行 push 进来。
import SwiftUI
import PhotosUI

struct BackgroundSettingsView: View {
    @State private var bgPicker: PhotosPickerItem?
    /// 选中的预览图（内存态，未落库）。Pro 在「保存并使用」时才写 store。
    @State private var bgPreview: UIImage?
    @State private var bgEnabled: Bool = AppBackgroundStore.shared.isEnabled
    /// 遮罩浓度（内存态，未落库）。
    @State private var bgMaskOpacity: Double = AppBackgroundStore.shared.maskOpacity
    @State private var hasUnsavedChange = false
    @State private var showToast = false
    @State private var toastText = "已保存背景"
    @ObservedObject private var ent = EntitlementManager.shared
    /// 非 Pro 用户点「保存并使用」/「恢复默认」时弹出订阅页（自定义背景图是 Pro 专属）。
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewCard
                pickerCard
                if bgEnabled {
                    maskCard
                }
                saveCard
                noteCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AIATheme.fillSoft)
        .navigationTitle("App 背景图")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if showToast {
                toast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showToast)
            }
        }
        .onChange(of: bgPicker) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    // 仅更新内存预览，不直接落库（保存时拦截）。
                    bgEnabled = true
                    bgPreview = img
                    hasUnsavedChange = true
                }
                bgPicker = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiaBackgroundChanged)) { _ in
            bgEnabled = AppBackgroundStore.shared.isEnabled
            bgPreview = AppBackgroundStore.shared.loadImage()
            bgMaskOpacity = AppBackgroundStore.shared.maskOpacity
            hasUnsavedChange = false
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - 预览
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.purple)
                Text("预览")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            if let img = bgPreview ?? AppBackgroundStore.shared.loadImage() {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(height: 200).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                    .contentShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                    .overlay(
                        Color.black.opacity(bgEnabled ? bgMaskOpacity : 0)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rLG)
                        .fill(AIATheme.surfaceSecondary)
                        .frame(height: 200)
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(AIATheme.Font.title3.weight(.regular))
                            .foregroundStyle(AIATheme.muted)
                        Text("尚未设置背景图")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 选择 / 恢复默认
    private var pickerCard: some View {
        VStack(spacing: 0) {
            PhotosPicker(selection: $bgPicker, matching: .images) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(AIATheme.blue)
                    Text(bgEnabled ? "更换背景图" : "从相册选择背景图")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)

            if bgEnabled {
                Divider().padding(.leading, 14).background(AIATheme.hairline)
                Button(role: .destructive) {
                    // 恢复默认 = 落库动作，非 Pro 拦截。
                    if !ent.isFullAccess {
                        showPaywall = true
                        return
                    }
                    resetBackground()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("恢复默认背景")
                            .font(AIATheme.Font.callout.weight(.medium))
                    }
                    .foregroundStyle(.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AIATheme.surface)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    // MARK: - 遮罩浓度
    private var maskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("遮罩浓度（保证文字可读）：\(Int(bgMaskOpacity * 100))%")
                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
            Slider(value: $bgMaskOpacity, in: 0...0.85)
                .onChange(of: bgMaskOpacity) { _, _ in hasUnsavedChange = true }
        }
        .padding(14)
        .card()
    }

    // MARK: - 保存（Pro 专属拦截点）
    private var saveCard: some View {
        Button {
            // 仅在确实改了内容时才拦截/落库。
            if !ent.isFullAccess {
                // 非 Pro：允许预览，但不允许保存落库，弹订阅页。
                showPaywall = true
                return
            }
            // Pro：落库当前预览图 + 遮罩浓度。
            if let img = bgPreview {
                AppBackgroundStore.shared.save(img)
            }
            AppBackgroundStore.shared.maskOpacity = bgMaskOpacity
            AppBackgroundStore.shared.isEnabled = bgEnabled
            hasUnsavedChange = false
            showToast("已保存并使用")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.white)
                Text(hasUnsavedChange ? "保存并使用（有未保存改动）" : "保存并使用")
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AIATheme.rLG, style: .continuous)
                    .fill(ent.isFullAccess ? AIATheme.blue : AIATheme.muted)
            )
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 说明
    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("仅首页与聊天页生效；图片仅保存在本机，不会上传。")
                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted).lineSpacing(2)
            if !ent.isFullAccess {
                Text("自定义背景图为 Pro 会员专属功能，免费版可预览但保存时不会生效。")
                    .font(AIATheme.Font.micro).foregroundStyle(AIATheme.amber).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    // MARK: - Toast
    private var toast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(toastText)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .padding(.top, 8)
    }

    private func resetBackground() {
        AppBackgroundStore.shared.reset()
        bgEnabled = false
        bgPreview = nil
        bgMaskOpacity = AppBackgroundStore.shared.maskOpacity
        hasUnsavedChange = false
        showToast("已恢复默认背景")
    }

    private func showToast(_ text: String) {
        toastText = text
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showToast = false }
    }
}
