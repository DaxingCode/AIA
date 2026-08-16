// DataStatsExportView.swift
// 开发者中心 →「数据统计与导出」：跨用户的使用情况分析。
//
// 数据来自云函数 aia-sync 的 action=stats（需开发者口令）：
//   ① aia_records —— 已同步的业务数据（账单/待办/饮食/健康/识别/对话/饮水…），算功能热度与渗透率；
//   ② aia_events  —— UsageAnalytics 上报的行为埋点（启动/登录/页面访问/识别发起…），算活跃度。
// 云端已把结果拼成多张 CSV（带 BOM，Excel 打开中文不乱码），本页只负责展示概览 + 分享文件。
import SwiftUI

struct DataStatsExportView: View {
    @State private var result: UsageStatsResult?
    @State private var loading = false
    @State private var errorText: String?
    @State private var trendDays = 90
    @State private var share: SharePayload?
    @State private var expanded: Set<String> = []

    private let dayOptions = [30, 90, 365]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                rangeCard
                if loading && result == nil {
                    loadingCard
                } else if let err = errorText, result == nil {
                    errorCard(err)
                } else if let r = result {
                    summaryCard(r.summary)
                    exportAllCard(r.tables)
                    ForEach(r.tables) { table in
                        tableCard(table)
                    }
                    tipCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AIATheme.fillSoft)
        .navigationTitle("数据统计与导出")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(loading)
            }
        }
        .sheet(item: $share) { p in
            ShareSheet(items: p.items)
        }
        .task {
            UsageAnalytics.logOpen("data_stats")
            if result == nil { await load() }
        }
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        // 先把本机缓冲的埋点送上去，保证看到的是最新数据
        UsageAnalytics.flush()
        do {
            let r = try await UsageAnalytics.fetchStats(days: trendDays)
            result = r
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    // MARK: - 区块

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("趋势时间范围")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Picker("范围", selection: $trendDays) {
                ForEach(dayOptions, id: \.self) { d in
                    Text("近 \(d) 天").tag(d)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: trendDays) { _, _ in
                Task { await load() }
            }
            Text("只影响「日活趋势」表的行数；其余统计均为全量数据。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
        .padding(14)
        .card()
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在从云端聚合全部用户数据…")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .card()
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(AIATheme.Font.title2.weight(.medium))
                .foregroundStyle(AIATheme.warning)
            Text("统计拉取失败")
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(.primary)
            Text(msg)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
            Text("若提示 unknown action，说明云函数 aia-sync 还没部署最新版本。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(AIATheme.blue)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 14)
        .card()
    }

    private func summaryCard(_ s: UsageStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.3")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.purple)
                Text("总体概览")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricTile("总用户数", "\(s.totalUsers)", AIATheme.blue)
                metricTile("近 7 天活跃", "\(s.activeUsers7d)", AIATheme.green)
                metricTile("近 30 天活跃", "\(s.activeUsers30d)", AIATheme.green)
                metricTile("业务记录总数", "\(s.totalRecords)", AIATheme.purple)
                metricTile("行为事件总数", "\(s.totalEvents)", AIATheme.purple)
                metricTile("最受欢迎功能", s.topFeature, AIATheme.warning, sub: "\(s.topFeatureUsers) 人在用")
            }
            if !s.dateSpanStart.isEmpty {
                Text("数据区间：\(s.dateSpanStart) ~ \(s.dateSpanEnd)")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(14)
        .card()
    }

    private func metricTile(_ title: String, _ value: String, _ color: Color, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineLimit(1)
            Text(value)
                .font(AIATheme.Font.body.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func exportAllCard(_ tables: [UsageStatsTable]) -> some View {
        Button {
            let urls = UsageAnalytics.writeTempFiles(tables)
            guard !urls.isEmpty else {
                ToastCenter.shared.show("生成文件失败")
                return
            }
            UsageAnalytics.log("export_stats", meta: ["tables": urls.count])
            share = SharePayload(items: urls)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                Text("导出全部 \(tables.count) 张表（CSV）")
            }
            .font(AIATheme.Font.subhead.weight(.medium))
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(AIATheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
    }

    private func tableCard(_ table: UsageStatsTable) -> some View {
        let isOpen = expanded.contains(table.fileName)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "tablecells")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.title)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(table.rowCount) 行")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Button {
                    let urls = UsageAnalytics.writeTempFiles([table])
                    if let u = urls.first { share = SharePayload(items: [u]) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { expanded.remove(table.fileName) } else { expanded.insert(table.fileName) }
            }

            if isOpen {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(table.previewRows(limit: 10).enumerated()), id: \.offset) { idx, row in
                            HStack(spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(idx == 0 ? AIATheme.Font.micro.weight(.semibold) : AIATheme.Font.micro)
                                        .foregroundStyle(idx == 0 ? .primary : AIATheme.muted)
                                        .frame(minWidth: 60, alignment: .leading)
                                        .lineLimit(1)
                                }
                            }
                        }
                        if table.rowCount > 10 {
                            Text("…… 共 \(table.rowCount) 行，导出后查看完整数据")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                }
            }
        }
        .padding(14)
        .card()
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说明")
                .font(AIATheme.Font.micro.weight(.semibold))
                .foregroundStyle(AIATheme.muted)
            Text("• 统计覆盖所有已开启云同步的用户（按 userId 分区），软删数据已排除。\n• 「功能渗透率」按记录数与使用人数衡量热度，可据此判断该优先优化哪个功能。\n• 「行为事件统计」来自埋点，只统计埋点上线之后的行为，历史为空属正常。\n• CSV 已带 BOM，用 Excel / 数字表格直接打开中文不乱码。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
