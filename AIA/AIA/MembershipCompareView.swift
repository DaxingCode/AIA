// MembershipCompareView.swift
// 「我的权益」模块：常驻免费版 / Pro 版 对比表，右上角展示真实身份与到期时间。
import SwiftUI

/// 能力行的三态。
private enum CapState {
    case full                              // ✅ 完整可用
    case limited(String)                  // ⚠️ 受限（带说明，如「每月限 N 次」）
    case none                              // ❌ 不可用

    var icon: String {
        switch self {
        case .full:       return "checkmark.circle.fill"
        case .limited:    return "exclamationmark.circle.fill"
        case .none:       return "xmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .full:       return AIATheme.ok
        case .limited:    return AIATheme.warn
        case .none:       return AIATheme.muted
        }
    }
}

struct MembershipCompareView: View {
    @Binding var showPaywall: Bool

    @ObservedObject private var ent = EntitlementManager.shared
    @ObservedObject private var sub = SubscriptionManager.shared

    @State private var showAccount = false
    @State private var toastText = "已复制"
    @State private var showCopied = false

    // MARK: - 能力行定义
    // 每行：能力名 + 免费版态 + Pro版态。
    private var rows: [(name: String, free: CapState, pro: CapState)] {
        return [
            ("离线AI识别（不够准）",           .full,       .full),
            ("离线记账、待办、饮食、健康",       .full,       .full),
            ("云端AI文字、视觉识别（体验好）",   .none,       .full),
            ("云端大模型AI对话（体验好）",       .none,       .full),
            ("云同步（多端实时）",               .none,       .full),
            ("数据备份与恢复",                   .none,       .full),
            ("新功能优先体验",                   .none,       .full),
            ("优先客服支持",                     .none,       .full),
            ("头像专属皇冠标识",                 .none,       .full),
            ("首页模块布局自定义（拖拽/隐藏/排序）", .none,     .full),
            ("App 自定义背景图",                 .none,       .full),
        ]
    }

    // MARK: - 右上角真实身份
    private var currentTierText: String {
        if ent.simulateFree { return "免费版" }
        if ent.isTempPro && !ent.isFullAccess { return "Pro 体验中" }
        switch ent.plan {
        case .tester:    return "Pro版（测试）"
        case .paid:
            switch sub.activeProduct {
            case .monthly: return "Pro包月版"
            case .yearly:  return "Pro包年版"
            default:       return "Pro版"
            }
        case .trial:     return "Pro体验版"
        case .expired:   return "免费版"
        case .freeQuota: return "免费版"
        case .free:      return "免费版"
        case .unknown:   return "加载中…"
        }
    }

    /// 右上角到期时间文案（体验/订阅有效时显示）。
    private var currentTierDetail: String? {
        if ent.simulateFree { return nil }
        if ent.isTempPro && !ent.isFullAccess { return "剩余 \(ent.proTrialRemainingText)" }
        switch ent.plan {
        case .trial:
            guard let start = ent.trialStartAt else { return nil }
            let exp = Date(timeIntervalSince1970: start + Double(EntitlementManager.trialDays) * 86400)
            return "到期 \(formatDate(exp))"
        case .paid:
            guard let exp = sub.expiresAt else { return nil }
            return "到期 \(formatDate(exp))"
        default:
            return nil
        }
    }

    private var currentTierColor: Color {
        if ent.simulateFree { return AIATheme.muted }
        if ent.isTempPro && !ent.isFullAccess { return AIATheme.warn }
        switch ent.plan {
        case .tester, .paid: return AIATheme.ok
        case .trial:         return AIATheme.warn
        case .expired:       return AIATheme.over
        default:             return AIATheme.muted
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            compareTable
            pricingTagline
            ctaButton
            proTrialCard
            summary
            accountDisclosure
        }
        .padding(14)
        .card()
        .overlay(alignment: .top) {
            if showCopied {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                    Text(toastText)
                        .font(AIATheme.Font.footnote.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
    }

    // MARK: - 头部：图标 + 标题 + 真实身份徽标 + 到期时间
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(AIATheme.blue)
            Text("我的权益")
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if ent.isPro {
                        Image(systemName: "crown.fill")
                            .font(AIATheme.Font.micro.weight(.semibold))
                            .foregroundStyle(AIATheme.amber)
                            .accessibilityHidden(true)
                    }
                    Text(currentTierText)
                        .font(AIATheme.Font.micro.weight(.semibold))
                        .foregroundStyle(currentTierColor)
                }
                if let detail = currentTierDetail {
                    Text(detail)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(currentTierColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
        }
    }

    // MARK: - 两列对比表（常驻）
    private var compareTable: some View {
        VStack(spacing: 0) {
            // 列头
            HStack(spacing: 0) {
                Text("能力")
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                columnHeader("免费版")
                columnHeader("Pro 版", isPro: true)
            }
            .padding(.vertical, 6)

            Divider().background(AIATheme.hairline)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    Text(row.name)
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.free)
                    cell(row.pro)
                }
                .padding(.vertical, 7)
                Divider().background(AIATheme.hairline)
            }
        }
    }

    private func columnHeader(_ title: String, isPro: Bool = false) -> some View {
        HStack(spacing: 4) {
            if isPro {
                Image(systemName: "crown.fill")
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AIATheme.amber)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(AIATheme.Font.micro.weight(.semibold))
                .foregroundStyle(AIATheme.muted)
        }
        .frame(width: 92, alignment: .center)
        .padding(.vertical, 4)
    }

    private func cell(_ state: CapState) -> some View {
        VStack(spacing: 2) {
            Image(systemName: state.icon)
                .font(AIATheme.Font.caption)
                .foregroundStyle(state.color)
            if case .limited(let note) = state {
                Text(note.replacingOccurrences(of: "每月限 ", with: "限 "))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 92)
            }
        }
        .frame(width: 92)
        .padding(.vertical, 4)
    }

    // MARK: - Pro 版免费体验 10 分钟（每月一次）
    /// 所有用户均展示；仅开发者免费版演示模式(simulateFree)下隐藏。
    @ViewBuilder
    private var proTrialCard: some View {
        if !ent.simulateFree {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: ent.proTrialActive ? "timer" : "gift.fill")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(ent.proTrialActive ? AIATheme.warn : AIATheme.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pro 版免费体验 10 分钟")
                            .font(AIATheme.Font.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(proTrialSubtitle)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(ent.proTrialActive ? AIATheme.warn : AIATheme.muted)
                    }
                    Spacer(minLength: 8)
                    if ent.proTrialActive {
                        Text(ent.proTrialRemainingText)
                            .font(AIATheme.Font.subhead.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(AIATheme.warn)
                            .contentTransition(.numericText())
                    }
                }
                proTrialButton
            }
            .padding(10)
            .background((ent.proTrialActive ? AIATheme.warn : AIATheme.blue).opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            // proTrialTick 每秒自增，驱动倒计时文案刷新
            .id(ent.proTrialActive ? ent.proTrialTick : -1)
        }
    }

    private var proTrialSubtitle: String {
        if ent.proTrialActive { return "体验中：云端识别、对话与同步已解锁" }
        if ent.proTrialUsedThisMonth { return "本月已体验过，下月可再次开启" }
        return "每月可免费开启一次，到时自动结束"
    }

    @ViewBuilder
    private var proTrialButton: some View {
        if ent.proTrialActive {
            Button {
                ent.endProTrial()
            } label: {
                Text("提前结束体验")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(AIATheme.warn.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
            }
            .buttonStyle(.plain)
        } else {
            let usable = ent.canStartProTrial
            Button {
                ent.startProTrial()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: usable ? "play.circle.fill" : "lock.fill")
                        .font(AIATheme.Font.footnote)
                    Text(usable ? "开启 10 分钟体验" : "本月已体验")
                        .font(AIATheme.Font.footnote.weight(.medium))
                }
                .foregroundStyle(usable ? .white : AIATheme.muted)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(usable ? AIATheme.blue : AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
        }
    }

    // MARK: - 价格一句话总结（放在订阅按钮上方、Pro 体验卡上方）
    private var pricingTagline: some View {
        Text("本地功能永久免费，订阅 Pro 解锁云端识别、对话与多端同步。")
            .font(AIATheme.Font.micro)
            .foregroundStyle(AIATheme.muted)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部文案
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ent.simulateFree {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.blue)
                    Text("你正在体验免费版：云端AI文字与视觉识别、云端大模型AI对话、同步与备份均不可用，仅离线AI识别与离线记账、待办、饮食、健康可演示。关闭「免费版体验模式」开关即恢复真实权益。")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.blue)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
        }
    }

    // MARK: - 账号信息（开发者用，默认收起）
    private var accountDisclosure: some View {
        DisclosureGroup(isExpanded: $showAccount) {
            VStack(alignment: .leading, spacing: 8) {
                if !ent.userId.isEmpty { accountChip("账号 ID", ent.userId) }
                if !ent.userPhone.isEmpty { accountChip("手机号", ent.userPhone) }
                accountChip("设备 ID", ent.deviceId)
            }
            .padding(.top, 8)
        } label: {
            Text("账号信息（开发者）")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }

    private func accountChip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            Text(value.prefix(12).map(String.init).joined() + (value.count > 12 ? "…" : ""))
                .font(AIATheme.Font.micro.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "doc.on.doc")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.blue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .onTapGesture { copyAccountId(value) }
    }

    // MARK: - CTA
    private var ctaButton: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sub.isSubscribed ? "gearshape.fill" : "sparkles")
                    .font(AIATheme.Font.callout)
                Text(ctaTitle)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !sub.isSubscribed {
                    Text(ctaPrice)
                        .font(AIATheme.Font.micro.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(sub.isSubscribed ? AIATheme.ink : AIATheme.blue)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
    }

    private var ctaTitle: String {
        if sub.isSubscribed { return "管理订阅" }
        return "立即订阅Pro版"
    }
    // >>> CHANGE-[2026-08-29 22:13:01]-订阅价格按地区本地化 开始
    // 原因: 原 ctaPrice 写死 "¥8.8元/月丨¥88元/年"，外币用户看到人民币符号与中文单位；
    //       改为走 StoreKit 本地化价格（货币符号+金额+周期单位均跟随用户 App Store 地区）。
    // 回退: 还原本行 `private var ctaPrice: String { "¥8.8元/月丨¥88元/年" }` 即可。
    private var ctaPrice: String {
        let m = sub.formattedPricePeriod(for: .monthly)
        let y = sub.formattedPricePeriod(for: .yearly)
        switch (m, y) {
        case let (m?, y?): return "\(m)丨\(y)"
        case let (m?, nil): return m
        case let (nil, y?): return y
        default: return "订阅解锁 Pro"
        }
    }
    // <<< CHANGE-[2026-08-29 22:13:01]-订阅价格按地区本地化 结束

    // MARK: - 复制账号标识（白名单录入用）
    private func copyAccountId(_ value: String) {
        UIPasteboard.general.string = value
        toastText = "已复制：\(String(value.prefix(12)))"
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { showCopied = false }
        }
    }
}
