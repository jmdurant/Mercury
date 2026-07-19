//
//  ClawWatchWidgetBundle.swift
//  ClawWatch Widget
//

import WidgetKit
import SwiftUI

@main
struct ClawWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadWidget()
        if #available(iOS 16.1, *) {
            CallLiveActivity()
        }
    }
}
