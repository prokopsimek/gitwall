import AppKit
import GitwallCore
import SwiftUI

/// Reads avatars the app downloaded into the App Group. Safe for the widget: file access only.
public enum AvatarCache {
    public static func image(for url: URL?, in container: URL?) -> Image? {
        guard let url, let container else { return nil }
        let fileURL = AvatarFiles.fileURL(for: url, in: container)
        guard let nsImage = NSImage(contentsOf: fileURL) else { return nil }
        return Image(nsImage: nsImage)
    }
}

/// SF Symbols offered for presets.
public enum PresetIcons {
    public static let all: [String] = [
        "tray.full", "person.crop.circle", "eye", "checkmark.seal", "exclamationmark.triangle",
        "flame", "bolt", "star", "flag", "tag", "folder", "building.2", "person.2", "hammer",
        "ladybug", "shippingbox", "arrow.triangle.pull", "smallcircle.filled.circle",
    ]
}
