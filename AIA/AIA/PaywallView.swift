// PaywallView.swift
// 订阅页：¥88/年（推荐） + ¥8.8/月。
// 触发场景：设置页「我的权益」卡片点击、试用到期/额度耗尽时的引导。
import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sub = SubscriptionManager.shared
    @StateObject private var ent = EntitlementManager.shared

    @State private var selected: SubscriptionProduct = .yearly
    @State private var browserTarget: BrowserTarget?
    @State private var showError = false
    @State private var showSuccess = false

    /// 触发来源（用于顶部说明文案）
    var reason: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    benefitCard
                    planPicker
                    subscribeButton
                    footerActions
                    legalText
                    // >>> CHANGE-[2026-08-20 16:30:00]-订阅页补3.1.2条款链接 开始
                    termsLinks
                    // <<< CHANGE-[2026-08-20 16:30:00]-订阅页补3.1.2条款链接 结束
                    }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AIATheme.fillSoft)
            .navigationTitle("升级 Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .inAppBrowser(target: $browserTarget)
        .task {
            if sub.products.isEmpty { await sub.loadProducts() }
            await sub.refreshEntitlements()
        }
        .onChange(of: sub.lastError) { _, new in
            showError = (new != nil)
        }
        .centeredAlert(isPresented: $showError,
                       message: sub.lastError ?? "",
                       onDismiss: { sub.lastError = nil })
        .centeredAlert(isPresented: $showSuccess,
                       title: "订阅成功",
                       message: "云端功能已全部解锁，感谢支持！",
                       onDismiss: { dismiss() })
    }

    // MARK: - 顶部
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(AIATheme.blue)
                .padding(.top, 8)
            Text(sub.isSubscribed ? "你已是 Pro 会员" : "解锁全部云端能力")
                .font(AIATheme.Font.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitleText)
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitleText: String {
        if sub.isSubscribed {
            if let e = sub.expiresAt {
                let f = DateFormatter()
                f.dateFormat = "yyyy年M月d日"
                return "当前套餐：\(sub.activeProduct?.title ?? "")，将于 \(f.string(from: e)) 自动续期"
            }
            return "当前套餐：\(sub.activeProduct?.title ?? "")"
        }
        if let reason, !reason.isEmpty { return reason }
        switch ent.plan {
        case .trial:     return "免费体验还剩 \(ent.trialRemainingDays) 天，订阅后不中断"
        case .freeQuota: return "本月免费云端次数有限，订阅后不限量使用"
        case .expired:   return "体验已结束，订阅后可继续使用云端功能"
        default:         return "本地功能永久免费，订阅解锁云端识别与对话"
        }
    }

    // MARK: - 权益列表
    private var benefitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefitRow("photo.badge.checkmark", "图片视觉识别", "小票 / 截图 / 营养表，云端大模型精准解析")
            benefitRow("text.bubble", "自然语言记账", "一句话记账单、待办、饮食、健康")
            benefitRow("bubble.left.and.text.bubble.right", "小记智能问答", "查数据、做统计、写总结，全部对话完成")
            benefitRow("arrow.triangle.2.circlepath", "多端云同步", "手机 / 小程序数据实时互通，换机不丢")
            benefitRow("star.fill", "新功能 / 专属功能优先体验", "高级模块、实验特性、Pro 专属能力抢先开放")
        }
        .padding(14)
        .card()
    }

    private func benefitRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(AIATheme.Font.callout)
                .foregroundStyle(AIATheme.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 套餐选择（年 / 月）
    private var planPicker: some View {
        VStack(spacing: 10) {
            planRow(.yearly)
            planRow(.monthly)
        }
    }

    private func planRow(_ item: SubscriptionProduct) -> some View {
        let isSel = selected == item
        return Button {
            selected = item
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSel ? "largecircle.fill.circle" : "circle")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(isSel ? AIATheme.blue : AIATheme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let badge = item.savingBadge {
                            Text(badge)
                                .font(AIATheme.Font.micro.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AIATheme.warn)
                                .clipShape(Capsule())
                        }
                    }
                    if let per = sub.formattedPerMonth(for: item) {
                        Text(per)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    } else {
                        Text("灵活订阅，随时取消")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sub.priceText(for: item))
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.periodText)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .padding(14)
            .background(AIATheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rLG)
                    .stroke(isSel ? AIATheme.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 订阅按钮
    private var subscribeButton: some View {
        Group {
            if sub.isSubscribed {
                Button {
                    sub.openManageSubscriptions()
                } label: {
                    Text("管理订阅")
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AIATheme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task {
                        let ok = await sub.purchase(selected)
                        if ok { showSuccess = true }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if sub.purchasingId != nil {
                            ProgressView().tint(.white)
                        }
                        Text(sub.purchasingId != nil ? "处理中…" : "立即订阅 · \(sub.formattedPricePeriod(for: selected) ?? sub.priceText(for: selected))")
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AIATheme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
                .disabled(sub.purchasingId != nil)
            }
        }
    }

    // MARK: - 恢复购买 / 管理
    private var footerActions: some View {
        HStack(spacing: 18) {
            Button {
                Task { await sub.restore() }
            } label: {
                HStack(spacing: 5) {
                    if sub.isRestoring { ProgressView().controlSize(.mini) }
                    Text("恢复购买")
                }
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.blue)
            }
            .buttonStyle(.plain)
            .disabled(sub.isRestoring)

            if !sub.isSubscribed {
                Button {
                    sub.openManageSubscriptions()
                } label: {
                    Text("管理订阅")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var legalText: some View {
        Text("订阅为自动续期。付款在确认购买时计入 Apple ID 账户；除非在当期结束前至少 24 小时关闭自动续期，否则将自动续订并按同价扣费。可在系统「设置 → Apple ID → 订阅」中随时管理或取消。\n本地功能（OCR、离线记账、数据浏览）不受订阅影响，永久免费。")
            .font(AIATheme.Font.micro)
            .foregroundStyle(AIATheme.muted)
            .lineSpacing(3)
            .padding(.top, 2)
    }

    // >>> CHANGE-[2026-08-20 16:30:00]-订阅页补3.1.2条款链接 开始
    // 原因: 订阅页原仅 legalText 纯文字说明，缺《用户协议》《隐私政策》可点击链接，违反 App Review Guideline 3.1.2 硬性要求
    // 回退: 删除本段 termsLinks 视图 + 主 VStack 内 `termsLinks` 调用即可
    // MARK: - 用户协议 / 隐私政策链接（Guideline 3.1.2 要求，App 内打开）
    private var termsLinks: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                browserTarget = BrowserTarget(url: AppURLs.userAgreement)
            } label: {
                Text("《用户协议》")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.blue)
            }
            Button {
                browserTarget = BrowserTarget(url: AppURLs.privacyPolicy)
            } label: {
                Text("《隐私政策》")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.blue)
            }
            Spacer()
        }
        .padding(.top, 2)
    }
    // <<< CHANGE-[2026-08-20 16:30:00]-订阅页补3.1.2条款链接 结束
}
