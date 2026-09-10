#!/usr/bin/env swift
// Renders the Gitwall app icon with CoreGraphics and fills the AppIcon asset catalog.
//
// Usage (from the repository root):
//     swift Scripts/make-icon.swift
//
// Outputs:
//     Scripts/out/icon-1024.png            full design (brick texture + pull-request glyph), 1024×1024
//     Scripts/out/icon-small-1024.png      simplified design (2×2) used for the 16 pt slot
//     Scripts/out/preview.png              contact sheet of every size on light + dark
//     Gitwall/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png + Contents.json
//     docs/icon.png                        copy of the 1024 master
//
// No dependencies beyond AppKit and the `sips` tool that ships with macOS.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot: URL = {
    // Scripts/make-icon.swift → the repository root is two levels up.
    if scriptURL.lastPathComponent == "make-icon.swift" {
        return scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()
let outDir = repoRoot.appendingPathComponent("Scripts/out", isDirectory: true)
let appIconSet = repoRoot.appendingPathComponent(
    "Gitwall/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let docsIcon = repoRoot.appendingPathComponent("docs/icon.png")
/// The widget gallery shows the extension's own icon, so the same set lives in the widget target too.
let widgetIconSet = repoRoot.appendingPathComponent("GitwallWidget/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

// MARK: - Design constants (macOS icon grid on a 1024 canvas)

let canvas: CGFloat = 1024
let shapeInset: CGFloat = 100          // transparent margin on each side
let shapeCornerRadius: CGFloat = 185   // ≈ 22.4 % of the 824 pt shape

// MARK: - Drawing helpers

@MainActor let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

@MainActor
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: srgb, components: [r, g, b, alpha])!
}

@MainActor
func makeContext(size: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

@MainActor
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

@MainActor
func writePNG(_ ctx: CGContext, to url: URL) throws {
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(url.path)"])
    }
    try data.write(to: url, options: .atomic)
}

// MARK: - Icon (concept F: faint brick wall behind a teal pull-request glyph, DX Heroes palette)

let navy: UInt32 = 0x131A39
let teal: UInt32 = 0x2AD8BF

/// Rounded, staggered bricks clipped to `rect` (used as a faint texture).
@MainActor
func drawBricks(into ctx: CGContext, in rect: CGRect, rows: Int, perRow: Int, gap: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.setAlpha(alpha)
    ctx.setFillColor(rgb(0xFFFFFF))
    let brickH = (rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
    let brickW = (rect.width - CGFloat(perRow - 1) * gap) / CGFloat(perRow)
    for row in 0..<rows {
        let y = rect.minY + CGFloat(rows - 1 - row) * (brickH + gap)
        var x = rect.minX + (row.isMultiple(of: 2) ? 0 : -(brickW + gap) / 2)
        while x < rect.maxX {
            let brick = CGRect(x: x, y: y, width: brickW, height: brickH)
            ctx.addPath(CGPath(roundedRect: brick, cornerWidth: brickH * 0.18, cornerHeight: brickH * 0.18, transform: nil))
            ctx.fillPath()
            x += brickW + gap
        }
    }
    ctx.restoreGState()
}

/// Git pull-request glyph: trunk with two nodes on the left, a branch curving into a node on the right.
@MainActor
func drawPullRequestGlyph(into ctx: CGContext, in rect: CGRect, lineFactor: CGFloat, nodeFactor: CGFloat) {
    let w = rect.width
    let lineW = w * lineFactor
    let r = w * nodeFactor
    let leftX = rect.minX + w * 0.28
    let rightX = rect.minX + w * 0.72
    let topY = rect.maxY - w * 0.22
    let bottomY = rect.minY + w * 0.22

    ctx.setLineWidth(lineW)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(teal))
    ctx.move(to: CGPoint(x: leftX, y: topY))
    ctx.addLine(to: CGPoint(x: leftX, y: bottomY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: leftX + r, y: topY))
    ctx.addCurve(to: CGPoint(x: rightX, y: topY - w * 0.22),
                 control1: CGPoint(x: leftX + w * 0.30, y: topY),
                 control2: CGPoint(x: rightX, y: topY - w * 0.02))
    ctx.addLine(to: CGPoint(x: rightX, y: bottomY))
    ctx.strokePath()
    for center in [CGPoint(x: leftX, y: topY), CGPoint(x: leftX, y: bottomY), CGPoint(x: rightX, y: bottomY)] {
        let ring = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(rgb(teal))
        ctx.fillEllipse(in: ring)
        ctx.setFillColor(rgb(navy))
        ctx.fillEllipse(in: ring.insetBy(dx: r * 0.42, dy: r * 0.42))
    }
}

/// Draws the icon into `ctx` (1024×1024, origin bottom-left).
/// `small` renders the master for the 16 pt slot: no brick texture, bolder glyph.
@MainActor
func drawIcon(into ctx: CGContext, small: Bool) {
    let shapeRect = CGRect(x: shapeInset, y: shapeInset,
                           width: canvas - 2 * shapeInset, height: canvas - 2 * shapeInset)
    let shape = CGPath(roundedRect: shapeRect, cornerWidth: shapeCornerRadius,
                       cornerHeight: shapeCornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(navy), 0.0), (rgb(0x1A2A5C), 0.6), (rgb(0x10425A), 1.0)]),
                           start: CGPoint(x: canvas / 2, y: shapeRect.maxY),
                           end: CGPoint(x: canvas / 2, y: shapeRect.minY), options: [])
    ctx.drawRadialGradient(gradient([(rgb(0xFFFFFF, 0.14), 0.0), (rgb(0xFFFFFF, 0.0), 1.0)]),
                           startCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), startRadius: 0,
                           endCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), endRadius: 820, options: [])
    if !small {
        drawBricks(into: ctx, in: shapeRect.insetBy(dx: -40, dy: -40), rows: 7, perRow: 4, gap: 22, alpha: 0.07)
    }
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: rgb(0x000000, 0.45))
    if small {
        drawPullRequestGlyph(into: ctx, in: CGRect(x: 232, y: 222, width: 560, height: 580), lineFactor: 0.12, nodeFactor: 0.15)
    } else {
        drawPullRequestGlyph(into: ctx, in: CGRect(x: 262, y: 252, width: 500, height: 520), lineFactor: 0.085, nodeFactor: 0.115)
    }
    ctx.restoreGState()
}

// MARK: - Asset catalog slots

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    /// The 16 pt slot (16 px and 32 px files) uses the simplified 2×2 master.
    var usesSmallMaster: Bool { points == 16 }
}

let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

@MainActor
func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(tool) \(args.joined(separator: " ")) failed"])
    }
}

@MainActor
func contentsJSON() -> String {
    var lines: [String] = ["{", "  \"images\" : ["]
    for (i, slot) in slots.enumerated() {
        lines.append("    {")
        lines.append("      \"filename\" : \"\(slot.filename)\",")
        lines.append("      \"idiom\" : \"mac\",")
        lines.append("      \"scale\" : \"\(slot.scale)x\",")
        lines.append("      \"size\" : \"\(slot.points)x\(slot.points)\"")
        lines.append(i == slots.count - 1 ? "    }" : "    },")
    }
    lines += ["  ],", "  \"info\" : {", "    \"author\" : \"xcode\",", "    \"version\" : 1", "  }", "}", ""]
    return lines.joined(separator: "\n")
}

// MARK: - Preview sheet (for eyeballing the result)

@MainActor
func writePreview(files: [(px: Int, url: URL)], to url: URL) throws {
    let width = 1400, height = 760
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func load(_ u: URL) -> CGImage? {
        NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    // Two bands: light (top) and dark (bottom).
    ctx.setFillColor(rgb(0xECEEF2)); ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    ctx.setFillColor(rgb(0x1C1D22)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))

    // One file per pixel size (the catalog has duplicates, e.g. 32 px for 16@2x and 32@1x).
    var unique: [Int: URL] = [:]
    for (px, u) in files where unique[px] == nil { unique[px] = u }

    for band in 0..<2 {
        let baseY = CGFloat(band == 0 ? height / 2 : 0)
        var x: CGFloat = 40
        // Native sizes up to 256 px.
        for px in [16, 32, 64, 128, 256] {
            guard let u = unique[px], let img = load(u) else { continue }
            ctx.interpolationQuality = .none
            let s = CGFloat(px)
            ctx.draw(img, in: CGRect(x: x, y: baseY + 40, width: s, height: s))
            x += s + 28
        }
        // Magnified 16 and 32 px (×8, nearest neighbour) so the small variant can be judged.
        x += 40
        for px in [16, 32] {
            guard let u = unique[px], let img = load(u) else { continue }
            let s = CGFloat(px * 8)
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: x, y: baseY + 40, width: s, height: s))
            x += s + 28
        }
    }
    try writePNG(ctx, to: url)
}

// MARK: - Main

@MainActor
func main() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: appIconSet, withIntermediateDirectories: true)
    try fm.createDirectory(at: widgetIconSet, withIntermediateDirectories: true)

    // 1. Masters.
    let fullMaster = outDir.appendingPathComponent("icon-1024.png")
    let full = makeContext(size: Int(canvas))
    drawIcon(into: full, small: false)
    try writePNG(full, to: fullMaster)

    let smallMaster = outDir.appendingPathComponent("icon-small-1024.png")
    let small = makeContext(size: Int(canvas))
    drawIcon(into: small, small: true)
    try writePNG(small, to: smallMaster)
    print("rendered \(fullMaster.path)")
    print("rendered \(smallMaster.path)")

    // 2. Downsample with sips into Scripts/out, then copy into the appiconset.
    var produced: [(px: Int, url: URL)] = []
    for slot in slots {
        let master = slot.usesSmallMaster ? smallMaster : fullMaster
        let target = outDir.appendingPathComponent(slot.filename)
        try run("/usr/bin/sips", ["-z", "\(slot.pixels)", "\(slot.pixels)", master.path, "--out", target.path])
        for set in [appIconSet, widgetIconSet] {
            let dest = set.appendingPathComponent(slot.filename)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: target, to: dest)
        }
        produced.append((slot.pixels, target))
        print("  \(slot.filename)  \(slot.pixels)×\(slot.pixels)  ← \(master.lastPathComponent)")
    }

    // 3. Contents.json with filenames.
    for set in [appIconSet, widgetIconSet] {
        try contentsJSON().write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
    print("wrote \(appIconSet.appendingPathComponent("Contents.json").path)")

    // 4. docs/icon.png.
    try fm.createDirectory(at: docsIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: docsIcon.path) { try fm.removeItem(at: docsIcon) }
    try fm.copyItem(at: fullMaster, to: docsIcon)
    print("copied \(docsIcon.path)")

    // 5. Preview sheet.
    let preview = outDir.appendingPathComponent("preview.png")
    var previewFiles = produced
    previewFiles.append((1024, fullMaster))
    try writePreview(files: previewFiles, to: preview)
    print("preview \(preview.path)")
}

do {
    // Script top-level code runs on the main thread; make that explicit for the
    // @MainActor helpers so the file compiles in both Swift 5 and Swift 6 language modes.
    try MainActor.assumeIsolated { try main() }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
