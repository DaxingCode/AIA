// AIAApp.swift
// App 入口。创建 SwiftData 容器，并通过 AppDelegate/SceneDelegate 创建窗口。
import SwiftUI
import SwiftData

@main
struct AIAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let container: ModelContainer

    init() {
        // 容器交给 AppPersistence 统一构建（主 App 与 App Intents 共用同一 store 文件）。
        container = AppPersistence.makeContainer()
        // 把容器注入 AppDelegate（实际存到 AppDelegate.sharedContainer，
        // 让 application delegate 与 scene delegate 两个实例都能取到）。
        #if DEBUG
        print("[AIAApp] container initialized, store URL: \(AppPersistence.storeURL)")
        #endif
        appDelegate.container = container
        #if DEBUG
        print("[AIAApp] injected appDelegate.container")
        #endif
    }

    var body: some Scene {
        // 真实 UIWindow 由 AppDelegate.scene(_:willConnectTo:) 手动创建，
        // 这里用 WindowGroup 只是为了满足 App 协议，内容是空占位。
        WindowGroup {
            EmptyView()
        }
    }
}
