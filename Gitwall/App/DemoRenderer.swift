#if DEBUG
import AppKit
import GitwallCore
import SwiftUI
import WidgetKit

/// `--debug-demo --debug-demo-widgets`: shows the widget views with demo data in borderless, transparent
/// windows at the macOS widget sizes, so `Scripts/screenshots.swift capture` can grab them like any window.
/// WidgetKit cannot be driven from outside, and the sandbox forbids writing PNGs outside the container,
/// which rules out `ImageRenderer` here.
@MainActor
enum DemoRenderer {
    private static let families: [(WidgetFamily, String, CGSize, Int)] = [
        (.systemSmall, "counter", CGSize(width: 170, height: 170), 3),
        (.systemMedium, "list", CGSize(width: 364, height: 170), 0),
        (.systemLarge, "board", CGSize(width: 364, height: 382), 2),
        (.systemExtraLarge, "wideboard", CGSize(width: 748, height: 382), 2),
    ]
    private static var windows: [NSWindow] = []

    static func presentWidgetWindows(config: AppConfig, snapshot: Snapshot) {
        guard windows.isEmpty, let screen = NSScreen.main else { return }
        let now = Date()
        var origin = CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 40)
        for (family, name, size, presetIndex) in families {
            guard config.presets.indices.contains(presetIndex) else { continue }
            let preset = config.presets[presetIndex]
            let items = FilterEngine.items(matching: preset, in: snapshot.items, accounts: config.accounts, now: now)
            let entry = PresetEntry(
                date: now, preset: preset, items: items, fetchedAt: now.addingTimeInterval(-7), staleAfter: 900,
                container: nil, problem: nil, attention: false, isDefaultPreset: false, presetCount: config.presets.count
            )
            // System content margins (16 pt) and a light card stand in for what WidgetKit draws around a widget.
            // WidgetKit renders links as plain content; outside it they would turn into blue buttons.
            let view = GitwallWidgetView(entry: entry, family: family)
                .buttonStyle(.plain)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .environment(\.colorScheme, .light)
            origin.y -= size.height + 24
            let window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.title = "Widget \(name)"
            window.contentView = NSHostingView(rootView: view)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .floating
            window.ignoresMouseEvents = true
            window.orderFront(nil)
            windows.append(window)
        }
    }
}
#endif
