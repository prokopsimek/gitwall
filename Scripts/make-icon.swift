#!/usr/bin/env swift
// Renders the Gitwall app icon with CoreGraphics and fills the AppIcon asset catalog.
//
// Usage (from the repository root):
//     swift Scripts/make-icon.swift
//
// Outputs:
//     Scripts/out/icon-1024.png            full design (3×3 tile wall), 1024×1024
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

// MARK: - Icon

struct TileStyle {
    let top: UInt32
    let bottom: UInt32
    let detail: CGFloat     // alpha of the card details drawn on top of the tile

    static let paper = TileStyle(top: 0xFFFFFF, bottom: 0xE4EAF2, detail: 0)
    static let green = TileStyle(top: 0x5EEA9B, bottom: 0x22C55E, detail: 1)
    static let amber = TileStyle(top: 0xFDD264, bottom: 0xF59E0B, detail: 1)
}

/// Draws the icon into `ctx` (assumed 1024×1024, origin bottom-left).
/// - Parameters:
///   - grid: number of tile columns/rows (3 for the full icon, 2 for the small variant)
///   - highlights: tiles rendered in a status colour, keyed by (row from top, column)
///   - details: draw the abstract "card" marks (avatar dot + title bar) on each tile
@MainActor
func drawIcon(into ctx: CGContext, grid: Int, highlights: [[Int]: TileStyle], details: Bool) {
    let shapeRect = CGRect(x: shapeInset, y: shapeInset,
                           width: canvas - 2 * shapeInset, height: canvas - 2 * shapeInset)
    let shape = CGPath(roundedRect: shapeRect, cornerWidth: shapeCornerRadius,
                       cornerHeight: shapeCornerRadius, transform: nil)

    // Background: deep indigo (top) → teal (bottom), clipped to the icon shape.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let base = gradient([
        (rgb(0x3A2E9E), 0.0),
        (rgb(0x2C4BA6), 0.52),
        (rgb(0x0F9C90), 1.0),
    ])
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: canvas / 2, y: shapeRect.maxY),
                           end: CGPoint(x: canvas / 2, y: shapeRect.minY),
                           options: [])

    // Soft top light.
    let light = gradient([(rgb(0xFFFFFF, 0.26), 0.0), (rgb(0xFFFFFF, 0.0), 1.0)])
    ctx.drawRadialGradient(light,
                           startCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), startRadius: 0,
                           endCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), endRadius: 820,
                           options: [])

    // Slight darkening at the bottom edge so the tiles keep contrast on the teal.
    let shade = gradient([(rgb(0x000000, 0.0), 0.0), (rgb(0x000000, 0.14), 1.0)])
    ctx.drawLinearGradient(shade,
                           start: CGPoint(x: canvas / 2, y: shapeRect.midY),
                           end: CGPoint(x: canvas / 2, y: shapeRect.minY),
                           options: [])
    ctx.restoreGState()

    // Inner edge highlight (1.5 px) to lift the shape off dark backgrounds.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Tile wall.
    let area: CGFloat = grid == 3 ? 560 : 540
    let gap: CGFloat = grid == 3 ? 40 : 60
    let tile = (area - CGFloat(grid - 1) * gap) / CGFloat(grid)
    let radius = tile * 0.21
    let origin = CGPoint(x: (canvas - area) / 2, y: (canvas - area) / 2)

    for row in 0..<grid {
        for col in 0..<grid {
            let style = highlights[[row, col]] ?? .paper
            let x = origin.x + CGFloat(col) * (tile + gap)
            let y = origin.y + area - tile - CGFloat(row) * (tile + gap)   // row 0 = top
            let rect = CGRect(x: x, y: y, width: tile, height: tile)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            // Shadow pass.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -tile * 0.07), blur: tile * 0.16,
                          color: rgb(0x000000, 0.30))
            ctx.addPath(path)
            ctx.setFillColor(rgb(style.top))
            ctx.fillPath()
            ctx.restoreGState()

            // Fill pass (vertical gradient).
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(rgb(style.top), 0), (rgb(style.bottom), 1)]),
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
            ctx.restoreGState()

            guard details else { continue }

            // Abstract card marks: avatar dot + title bar + shorter second line.
            let pad = tile * 0.17
            let dot = tile * 0.15
            let barH = tile * 0.075
            let onPaper = style.detail == 0
            let strong = onPaper ? rgb(0xB8C3D3) : rgb(0xFFFFFF, 0.78)
            let weak = onPaper ? rgb(0xD5DDE8) : rgb(0xFFFFFF, 0.50)

            let dotRect = CGRect(x: rect.minX + pad, y: rect.maxY - pad - dot, width: dot, height: dot)
            ctx.setFillColor(strong)
            ctx.fillEllipse(in: dotRect)

            let barRect = CGRect(x: dotRect.maxX + tile * 0.08,
                                 y: dotRect.midY - barH / 2,
                                 width: rect.maxX - pad - (dotRect.maxX + tile * 0.08),
                                 height: barH)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
            ctx.setFillColor(strong)
            ctx.fillPath()

            let line2 = CGRect(x: rect.minX + pad, y: dotRect.minY - tile * 0.14 - barH,
                               width: tile * 0.46, height: barH)
            ctx.addPath(CGPath(roundedRect: line2, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
            ctx.setFillColor(weak)
            ctx.fillPath()
        }
    }
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

    // 1. Masters.
    let fullMaster = outDir.appendingPathComponent("icon-1024.png")
    let full = makeContext(size: Int(canvas))
    drawIcon(into: full, grid: 3,
             highlights: [[0, 0]: .green, [1, 2]: .amber],
             details: true)
    try writePNG(full, to: fullMaster)

    let smallMaster = outDir.appendingPathComponent("icon-small-1024.png")
    let small = makeContext(size: Int(canvas))
    drawIcon(into: small, grid: 2,
             highlights: [[0, 0]: .green],
             details: false)
    try writePNG(small, to: smallMaster)
    print("rendered \(fullMaster.path)")
    print("rendered \(smallMaster.path)")

    // 2. Downsample with sips into Scripts/out, then copy into the appiconset.
    var produced: [(px: Int, url: URL)] = []
    for slot in slots {
        let master = slot.usesSmallMaster ? smallMaster : fullMaster
        let target = outDir.appendingPathComponent(slot.filename)
        try run("/usr/bin/sips", ["-z", "\(slot.pixels)", "\(slot.pixels)", master.path, "--out", target.path])
        let dest = appIconSet.appendingPathComponent(slot.filename)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: target, to: dest)
        produced.append((slot.pixels, target))
        print("  \(slot.filename)  \(slot.pixels)×\(slot.pixels)  ← \(master.lastPathComponent)")
    }

    // 3. Contents.json with filenames.
    try contentsJSON().write(to: appIconSet.appendingPathComponent("Contents.json"),
                             atomically: true, encoding: .utf8)
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
