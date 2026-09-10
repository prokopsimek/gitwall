#!/usr/bin/swift
// App Store screenshots for Gitwall.
//
//   swift Scripts/screenshots.swift capture <pid> <outdir>
//       Saves every visible window of process <pid> as a PNG (no shadow) into <outdir>
//       and prints "<file>\t<title>\t<width>x<height>" per window.
//   swift Scripts/screenshots.swift compose <window.png> <out.png>
//       Places the window on a 2880x1800 brand background (Mac App Store size, no alpha channel).
//   swift Scripts/screenshots.swift compose <spec.json> <out.png>
//       Same background, but a headline and several layers placed by hand:
//       {"title": "...", "subtitle": "...", "layers": [{"file": "a.png", "x": 140, "y": 460, "width": 1800}]}
//       Coordinates are canvas pixels from the top-left; "width" scales the layer, height follows.
//       An optional "crop": [x, y, width, height] (source pixels, top-left origin) shows part of a capture,
//       and "radius" rounds the crop's corners.
//
// Run the Debug app with `--debug-demo` first; see docs/RELEASING.md.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvasSize = CGSize(width: 2880, height: 1800)
let margin: CGFloat = 140

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct WindowInfo {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

func visibleWindows(of pid: pid_t) -> [WindowInfo] {
    // `.optionAll`, not `.optionOnScreenOnly`: the demo windows may sit on another Space while the script runs.
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { info -> WindowInfo? in
        guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        // Skip the menu bar item, tooltips and menus; real windows and the popover are bigger and on low layers.
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        guard rect.width >= 150, rect.height >= 100, layer < 100 else { return nil }
        let title = info[kCGWindowName as String] as? String ?? ""
        return WindowInfo(id: id, title: title, bounds: rect)
    }
}

func capture(pid: pid_t, outDir: URL) {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let windows = visibleWindows(of: pid).sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    guard !windows.isEmpty else { fail("no visible windows for pid \(pid)") }
    for (index, window) in windows.enumerated() {
        let slug = window.title.isEmpty ? "untitled" : window.title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let file = outDir.appendingPathComponent("window-\(index + 1)-\(slug).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-o", "-x", "-l", String(window.id), file.path]
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let image = NSImage(contentsOf: file) else {
            fail("capture failed for window \(window.id) (\(window.title))")
        }
        print("\(file.path)\t\(window.title)\t\(Int(image.size.width))x\(Int(image.size.height))")
    }
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(url.path)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

struct Layer {
    let image: CGImage
    let frame: CGRect   // canvas coordinates, origin bottom-left (CoreGraphics)
}

func drawBackground(_ ctx: CGContext, colorSpace: CGColorSpace) {
    // The icon's navy-to-teal gradient with a soft highlight, so shots read as one family.
    let stops: [(CGColor, CGFloat)] = [(rgb(0x131A39), 0), (rgb(0x1A2A5C), 0.55), (rgb(0x10425A), 1)]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvasSize.height), end: CGPoint(x: canvasSize.width, y: 0), options: [])
    let glow = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x2AD8BF, 0.22), rgb(0x2AD8BF, 0)] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: canvasSize.width * 0.75, y: canvasSize.height * 0.15)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: canvasSize.width * 0.6, options: [])
}

func drawLayer(_ ctx: CGContext, _ layer: Layer) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 70, color: rgb(0x000000, 0.5))
    // One transparency layer so the shadow follows the window's real outline (rounded corners, popover arrow).
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // Translucent materials (popover, sidebar) are captured with alpha; back them with a light fill so
    // they read as they do over a light desktop instead of sinking into the dark background.
    ctx.saveGState()
    ctx.clip(to: layer.frame, mask: layer.image)
    ctx.setFillColor(rgb(0xF2F2F5))
    ctx.fill(layer.frame)
    ctx.restoreGState()
    ctx.draw(layer.image, in: layer.frame)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func drawHeadline(_ ctx: CGContext, title: String, subtitle: String?) {
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.current = previous }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 92, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .kern: -1.5,
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 42, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.74), .paragraphStyle: paragraph,
    ]
    let titleRect = CGRect(x: margin, y: canvasSize.height - 130 - 120, width: canvasSize.width - 2 * margin, height: 120)
    NSAttributedString(string: title, attributes: titleAttributes).draw(in: titleRect)
    if let subtitle {
        let subtitleRect = CGRect(x: margin, y: titleRect.minY - 70, width: canvasSize.width - 2 * margin, height: 60)
        NSAttributedString(string: subtitle, attributes: subtitleAttributes).draw(in: subtitleRect)
    }
}

func render(layers: [Layer], title: String?, subtitle: String?, output: URL) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height), bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("cannot create canvas")
    }
    ctx.interpolationQuality = .high
    drawBackground(ctx, colorSpace: colorSpace)
    for layer in layers { drawLayer(ctx, layer) }
    if let title { drawHeadline(ctx, title: title, subtitle: subtitle) }
    guard let image = ctx.makeImage() else { fail("cannot render canvas") }
    try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    writePNG(image, to: output)
    print("\(output.path)\t\(Int(canvasSize.width))x\(Int(canvasSize.height))\tno alpha")
}

/// Re-draws an image with rounded, transparent corners (crops lose the window's own outline).
func roundedCorners(_ image: CGImage, radius: CGFloat) -> CGImage {
    guard radius > 0 else { return image }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
    return ctx.makeImage() ?? image
}

/// Single window, centered, never upscaled (captures are already 2x on Retina).
func compose(window: URL, output: URL) {
    let shot = loadImage(window)
    let available = CGRect(origin: .zero, size: canvasSize).insetBy(dx: margin, dy: margin)
    let scale = min(1, available.width / CGFloat(shot.width), available.height / CGFloat(shot.height))
    let size = CGSize(width: CGFloat(shot.width) * scale, height: CGFloat(shot.height) * scale)
    let origin = CGPoint(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2)
    render(layers: [Layer(image: shot, frame: CGRect(origin: origin, size: size))], title: nil, subtitle: nil, output: output)
}

/// Headline plus hand-placed layers from a JSON spec (paths relative to the spec file).
func compose(spec: URL, output: URL) {
    guard let data = try? Data(contentsOf: spec),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let layerSpecs = json["layers"] as? [[String: Any]] else { fail("cannot read spec \(spec.path)") }
    let base = spec.deletingLastPathComponent()
    var layers: [Layer] = []
    for item in layerSpecs {
        guard let file = item["file"] as? String, let x = item["x"] as? Double, let y = item["y"] as? Double else { fail("layer needs file, x, y") }
        var image = loadImage(URL(fileURLWithPath: file, relativeTo: base))
        if let crop = item["crop"] as? [Double], crop.count == 4 {
            let rect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
            guard let cropped = image.cropping(to: rect) else { fail("crop outside \(file)") }
            image = roundedCorners(cropped, radius: CGFloat((item["radius"] as? Double) ?? 0))
        }
        let width: CGFloat = (item["width"] as? Double).map { CGFloat($0) } ?? CGFloat(image.width)
        let height: CGFloat = width * CGFloat(image.height) / CGFloat(image.width)
        // Spec uses top-left coordinates; CoreGraphics draws from the bottom-left.
        let frame = CGRect(x: CGFloat(x), y: canvasSize.height - CGFloat(y) - height, width: width, height: height)
        layers.append(Layer(image: image, frame: frame))
    }
    render(layers: layers, title: json["title"] as? String, subtitle: json["subtitle"] as? String, output: output)
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "capture":
    guard arguments.count == 4, let pid = Int32(arguments[2]) else { fail("usage: capture <pid> <outdir>") }
    capture(pid: pid, outDir: URL(fileURLWithPath: arguments[3]))
case "compose":
    guard arguments.count == 4 else { fail("usage: compose <window.png|spec.json> <out.png>") }
    let input = URL(fileURLWithPath: arguments[2])
    if input.pathExtension.lowercased() == "json" {
        compose(spec: input, output: URL(fileURLWithPath: arguments[3]))
    } else {
        compose(window: input, output: URL(fileURLWithPath: arguments[3]))
    }
default:
    fail("usage: screenshots.swift capture <pid> <outdir> | compose <window.png|spec.json> <out.png>")
}
