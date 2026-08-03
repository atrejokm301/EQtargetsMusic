//
//  TabBarHeightReader.swift
//  EQtargetsMusic
//
//  Reports how far the TOP edge of the system UITabBar is from the
//  bottom of the window — use that as MiniPlayer's bottom padding so it
//  sits just above the dock separator line.
//

import SwiftUI
import UIKit

struct TabBarHeightReader: UIViewRepresentable {
    /// Distance from the physical bottom of the window to the top of the tab bar.
    var onDockTopFromBottom: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onDockTopFromBottom = onDockTopFromBottom
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onDockTopFromBottom = onDockTopFromBottom
        uiView.probe()
    }

    final class ProbeView: UIView {
        var onDockTopFromBottom: ((CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            probe()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            probe()
        }

        func probe() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let value = Self.measureDockTopFromBottom(from: self) ?? Self.fallback(for: self)
                self.onDockTopFromBottom?(value)
            }
        }

        /// window.bottom → top edge of UITabBar (includes home-indicator region inside the bar).
        private static func measureDockTopFromBottom(from view: UIView) -> CGFloat? {
            guard let window = view.window ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return nil }
            guard let tab = findTabBar(in: window) else { return nil }
            let frame = tab.convert(tab.bounds, to: window)
            // Distance from bottom of screen up to the top of the dock.
            let fromBottom = window.bounds.maxY - frame.minY
            guard fromBottom > 30, fromBottom < window.bounds.height * 0.4 else { return nil }
            return fromBottom
        }

        private static func findTabBar(in root: UIView) -> UITabBar? {
            if let tab = root as? UITabBar, tab.bounds.height > 1 { return tab }
            for sub in root.subviews {
                if let tab = findTabBar(in: sub) { return tab }
            }
            return nil
        }

        private static func fallback(for view: UIView) -> CGFloat {
            let bottom = view.window?.safeAreaInsets.bottom
                ?? view.safeAreaInsets.bottom
            // Standard tab content ~49 + home indicator.
            return 49 + max(bottom, 0)
        }
    }
}
