//
//  AIAWidgetBundle.swift
//  AIAWidget
//
//  Created by DAXING on 2026/8/6.
//

import WidgetKit
import SwiftUI

@main
struct AIAWidgetBundle: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        BillWidget()
        TodoWidget()
        DietWidget()
        HealthWidget()
        SummaryWidget()
        UpcomingWidget()
        ChatWidget()
        QuickActionsWidget()
    }
}
