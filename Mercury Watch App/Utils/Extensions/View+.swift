//
//  View+.swift
//  Mercury Watch App
//
//  Created by Alessandro Alberti on 21/08/24.
//

import SwiftUI

extension View {
    var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    
    /// Applies the given transform if the given condition evaluates to `true`.
    /// - Parameters:
    ///   - condition: The condition to evaluate.
    ///   - transform: The transform to apply to the source `View`.
    /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    /// Overlays a `ProgressView` on top of the View if the `isLoading` is true
    func loadable(isLoading: Bool) -> some View {
        modifier(LoadableModifier(isLoading: isLoading))
    }

    /// Applies Liquid Glass effect on watchOS 26+, falls back to the given style on older versions
    @ViewBuilder func liquidGlass(fallback: some ShapeStyle = .clear) -> some View {
        if #available(watchOS 26, *) {
            self.glassEffect()
        } else {
            self.background(fallback)
        }
    }
}
