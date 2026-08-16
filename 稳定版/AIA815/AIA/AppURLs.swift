// AppURLs.swift
// 全局可复用的协议/文档链接，避免各入口各写一份。
// 优先读云端下发（GlobalConfigStore，启动时/回前台拉取并缓存），
// 云端缺值时回退到 CloudBase 静态托管的默认域名链接（作为兜底，保证不崩）。
import Foundation

enum AppURLs {
    // —— 兜底默认值（云端未配置时使用的 CloudBase 默认域名）——
    private static let defaultPrivacy = "https://arvti3crmf.feishu.cn/wiki/H7yYwwC8NiWR0XkjObecyyvknOe"
    private static let defaultAgreement = "https://arvti3crmf.feishu.cn/wiki/NeU0wzsOeigh77k0X8qcnhqZndg"
    private static let defaultFeatureIntro = "https://mp.weixin.qq.com/s/ekSczrt_yItd6UH4_n1PhA"

    /// 隐私政策链接：云端下发优先，缺值时回退默认域名。
    static var privacyPolicy: URL {
        GlobalConfigStore.shared.privacyPolicyUrl
            ?? URL(string: defaultPrivacy)!
    }

    /// 用户协议链接：云端下发优先，缺值时回退默认域名。
    static var userAgreement: URL {
        GlobalConfigStore.shared.userAgreementUrl
            ?? URL(string: defaultAgreement)!
    }

    /// 「App 功能介绍」灯泡按钮链接：云端下发优先，缺值时回退默认微信文章。
    static var featureIntro: URL {
        GlobalConfigStore.shared.featureIntroUrl
            ?? URL(string: defaultFeatureIntro)!
    }
}
