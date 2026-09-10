import CryptoKit
import Foundation

/// Where cached avatars live inside the App Group so the widget can show them without network access.
public enum AvatarFiles {
    public static let directoryName = "avatars"

    public static func directory(in container: URL) -> URL {
        container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Stable file name derived from the avatar URL.
    public static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    public static func fileURL(for url: URL, in container: URL) -> URL {
        directory(in: container).appendingPathComponent(fileName(for: url))
    }
}
