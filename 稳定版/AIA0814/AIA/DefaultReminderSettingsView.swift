// DefaultReminderSettingsView.swift
// 设置默认提醒时间：新建待办时自动按这些偏移生成通知，最多 4 个。
import SwiftUI
import Foundation
import Combine

final class DefaultReminderSettings: ObservableObject {
    static let shared = DefaultReminderSettings()

    @Published var presets: [ReminderOption] {
        didSet { save() }
    }

    private let defaultsKey = "defaultReminderPresets"

    static let currentVersion = 2
    private let versionKey = "defaultReminderPresetsVersion"

    private init() {
        let version = UserDefaults.standard.integer(forKey: versionKey)
        let raw: [String]
        if version < Self.currentVersion {
            // 升级默认值：重置为最新 4 个默认提醒（提前一周/一天/30分钟/准时）
            raw = Self.defaultRawPresets
            UserDefaults.standard.set(Self.currentVersion, forKey: versionKey)
        } else {
            raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? Self.defaultRawPresets
        }
        presets = raw.compactMap { ReminderOption(rawValue: $0) }
    }

    static var defaultRawPresets: [String] {
        // 默认四个节点：提前一周、提前一天、提前30分钟、准时的待办时间本身
        ["before1Week", "before1Day", "before30", "atTime"]
    }

    private func save() {
        UserDefaults.standard.set(presets.map(\.rawValue), forKey: defaultsKey)
        UserDefaults.standard.set(Self.currentVersion, forKey: versionKey)
    }

    /// 显式重置为 4 个默认提醒（用于"恢复默认"）
    func resetToDefaults() {
        presets = Self.defaultRawPresets.compactMap { ReminderOption(rawValue: $0) }
    }
    /// 将默认提醒时间应用到指定 reminder（仅当 reminder 有 due 且 remindTimes 为空时）
    func apply(to reminder: Reminder) {
        guard !presets.isEmpty, let due = reminder.due else { return }
        let times = presets.compactMap { ReminderOption.remindAt(for: due, option: $0) }
            .filter { $0 <= due }
            .sorted()
        reminder.remindTimes = times
        reminder.remindAt = times.first
    }

    var summary: String {
        if presets.isEmpty { return "未设置" }
        if presets.count == 1 { return presets[0].shortLabel }
        return presets.map(\.shortLabel).joined(separator: "/")
    }
}

struct DefaultReminderSettingsView: View {
    @StateObject private var settings = DefaultReminderSettings.shared

    private let options: [ReminderOption] = [.atTime, .before15, .before30, .before1Hour, .before1Day, .before1Week]

    var body: some View {
        List {
                Section {
                    if settings.presets.isEmpty {
                        Text("未设置默认提醒时间")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(settings.presets.indices, id: \.self) { index in
                            let current = settings.presets[index]
                            HStack(spacing: 12) {
                                Menu {
                                    ForEach(options) { opt in
                                        Button(opt.label) {
                                            updatePreset(at: index, to: opt)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text("提醒 \(index + 1)")
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(current.label)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(AIATheme.Font.micro)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    deletePreset(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(AIATheme.warn)
                                        .font(AIATheme.Font.title2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("默认提醒时间")
                } footer: {
                    Text("新建待办时会自动按这些时间发送通知，最多 4 个。")
                }

                Section {
                    Button {
                        settings.resetToDefaults()
                    } label: {
                        Label("恢复默认 4 个提醒", systemImage: "arrow.counterclockwise")
                    }
                    .foregroundStyle(AIATheme.blue)
                } footer: {
                    Text("恢复为：提前一周、提前一天、提前30分钟、准时。")
                }

                if settings.presets.count < 4 {
                    Section {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.presets.append(.before1Hour)
                            }
                        } label: {
                            Label("添加提醒时间", systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("默认提醒时间")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func updatePreset(at index: Int, to option: ReminderOption) {
        settings.presets[index] = option
    }

    private func deletePreset(at index: Int) {
        settings.presets.remove(at: index)
    }
}
