import SwiftUI

/// 「Pro会员权益介绍」页面：复用「我的权益」模块（MembershipCompareView）的对照表与订阅入口。
struct ProBenefitsView: View {
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            MembershipCompareView(showPaywall: $showPaywall)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(AppBackgroundView())
        .navigationTitle("Pro会员权益介绍")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }
}
