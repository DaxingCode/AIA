// ShareSheet.swift
// 系统分享面板封装：CSV 文件、月报图片等都通过它调起 iOS 分享 / 存储 / 隔空投送等。
import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType] = []

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.excludedActivityTypes = excludedActivityTypes
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 分享载荷（Identifiable，便于配合 .sheet(item:) 使用）。
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}
