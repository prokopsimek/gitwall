import AppKit
import GitwallCore
import OSLog

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "avatars")

/// Downloads author avatars into the App Group so the widget can render them offline.
actor AvatarDownloader {
    private let container: URL
    private let session: URLSession
    private var inFlight: Set<URL> = []
    static let targetSize: CGFloat = 64
    static let maxPerRun = 80

    init(container: URL, session: URLSession = .shared) {
        self.container = container
        self.session = session
    }

    func download(for items: [WorkItem]) async {
        let directory = AvatarFiles.directory(in: container)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var wanted: [URL] = []
        var seen: Set<URL> = []
        for item in items {
            for url in [item.author.avatarURL] + item.assignees.map(\.avatarURL) + item.requestedReviewers.map(\.avatarURL) {
                guard let url, !seen.contains(url) else { continue }
                seen.insert(url)
                let target = AvatarFiles.fileURL(for: url, in: container)
                if !FileManager.default.fileExists(atPath: target.path) { wanted.append(url) }
            }
        }
        guard !wanted.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for url in wanted.prefix(Self.maxPerRun) where !inFlight.contains(url) {
                inFlight.insert(url)
                group.addTask { await self.fetch(url) }
            }
        }
    }

    private func fetch(_ url: URL) async {
        defer { inFlight.remove(url) }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else { return }
            guard let png = Self.downscaledPNG(data) else { return }
            try png.write(to: AvatarFiles.fileURL(for: url, in: container), options: .atomic)
        } catch {
            log.debug("Avatar download failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps widget memory low: avatars are stored at 64×64 points.
    nonisolated static func downscaledPNG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = NSSize(width: targetSize, height: targetSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }
}
