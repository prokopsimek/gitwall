#!/usr/bin/env swift
// Renders app-icon concept variants for Gitwall and a contact sheet to compare them at real sizes.
//
//   swift Scripts/icon-variants.swift
//
// Output: Scripts/out/variants/<letter>-<name>.png (1024×1024) and Scripts/out/variants/contact-sheet.png

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Shared drawing helpers

let canvas: CGFloat = 1024
let shapeInset: CGFloat = 100
let shapeCornerRadius: CGFloat = 185
@MainActor let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

@MainActor
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

@MainActor
func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

@MainActor
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "png", code: 1) }
    try data.write(to: url)
}

// Brand palette (dxheroes.io)
let navy: UInt32 = 0x131A39
let navyLight: UInt32 = 0x1C2C63
let teal: UInt32 = 0x2AD8BF
let tealLight: UInt32 = 0x86F2E0
let blue: UInt32 = 0x4F8BFF
let paper: UInt32 = 0xF4F7FB

var shapeRect: CGRect { CGRect(x: shapeInset, y: shapeInset, width: canvas - 2 * shapeInset, height: canvas - 2 * shapeInset) }
var shapePath: CGPath { CGPath(roundedRect: shapeRect, cornerWidth: shapeCornerRadius, cornerHeight: shapeCornerRadius, transform: nil) }

/// Fills the icon shape with a vertical gradient and a soft top light.
@MainActor
func drawBackground(_ ctx: CGContext, stops: [(UInt32, CGFloat)], light: CGFloat = 0.14, edge: UInt32 = 0xFFFFFF) {
    ctx.saveGState()
    ctx.addPath(shapePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient(stops.map { (rgb($0.0), $0.1) }),
                           start: CGPoint(x: canvas / 2, y: shapeRect.maxY), end: CGPoint(x: canvas / 2, y: shapeRect.minY), options: [])
    if light > 0 {
        ctx.drawRadialGradient(gradient([(rgb(0xFFFFFF, light), 0), (rgb(0xFFFFFF, 0), 1)]),
                               startCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), startRadius: 0,
                               endCenter: CGPoint(x: canvas / 2, y: shapeRect.maxY + 120), endRadius: 820, options: [])
    }
    ctx.addPath(shapePath)
    ctx.setStrokeColor(rgb(edge, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

@MainActor
func fillRounded(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, top: UInt32, bottom: UInt32, shadow: Bool = true) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.06), blur: rect.height * 0.14, color: rgb(0x000000, 0.28))
        ctx.addPath(path)
        ctx.setFillColor(rgb(top))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(top), 0), (rgb(bottom), 1)]),
                           start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

/// Square brackets like the DX Heroes mark, around `rect`.
@MainActor
func drawBrackets(_ ctx: CGContext, around rect: CGRect, thickness: CGFloat, reach: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    let leftX = rect.minX - thickness
    let rightX = rect.maxX
    for (x, opensRight) in [(leftX, true), (rightX, false)] {
        ctx.fill(CGRect(x: x, y: rect.minY, width: thickness, height: rect.height))
        let armX = opensRight ? x : x + thickness - reach
        ctx.fill(CGRect(x: armX, y: rect.maxY - thickness, width: reach, height: thickness))
        ctx.fill(CGRect(x: armX, y: rect.minY, width: reach, height: thickness))
    }
}

/// Git pull-request glyph (two nodes on the left joined by a line, a branch curving to a node on the right).
@MainActor
func drawPullRequestGlyph(_ ctx: CGContext, in rect: CGRect, stroke: CGColor, node: CGColor, nodeCore: CGColor) {
    let w = rect.width
    let lineW = w * 0.085
    let r = w * 0.115
    let leftX = rect.minX + w * 0.28
    let rightX = rect.minX + w * 0.72
    let topY = rect.maxY - w * 0.22
    let bottomY = rect.minY + w * 0.22

    ctx.setLineWidth(lineW)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(stroke)
    // Left trunk.
    ctx.move(to: CGPoint(x: leftX, y: topY))
    ctx.addLine(to: CGPoint(x: leftX, y: bottomY))
    ctx.strokePath()
    // Branch: from the top node to the right and down into the right node.
    ctx.move(to: CGPoint(x: leftX + r, y: topY))
    ctx.addCurve(to: CGPoint(x: rightX, y: topY - w * 0.22),
                 control1: CGPoint(x: leftX + w * 0.30, y: topY),
                 control2: CGPoint(x: rightX, y: topY - w * 0.02))
    ctx.addLine(to: CGPoint(x: rightX, y: bottomY))
    ctx.strokePath()
    // Nodes.
    for center in [CGPoint(x: leftX, y: topY), CGPoint(x: leftX, y: bottomY), CGPoint(x: rightX, y: bottomY)] {
        let ring = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(node)
        ctx.fillEllipse(in: ring)
        ctx.setFillColor(nodeCore)
        ctx.fillEllipse(in: ring.insetBy(dx: r * 0.42, dy: r * 0.42))
    }
}

/// Staggered brick wall clipped to `rect`.
@MainActor
func drawBricks(_ ctx: CGContext, in rect: CGRect, rows: Int, perRow: Int, gap: CGFloat,
                brickTop: UInt32, brickBottom: UInt32, accents: [Int: (UInt32, UInt32)], alpha: CGFloat = 1, shadow: Bool = true) {
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.setAlpha(alpha)
    let brickH = (rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
    let brickW = (rect.width - CGFloat(perRow - 1) * gap) / CGFloat(perRow)
    var index = 0
    for row in 0..<rows {
        let y = rect.minY + CGFloat(rows - 1 - row) * (brickH + gap)
        let offset = row.isMultiple(of: 2) ? 0 : -(brickW + gap) / 2
        var x = rect.minX + offset
        while x < rect.maxX {
            let brick = CGRect(x: x, y: y, width: brickW, height: brickH)
            let colors = accents[index] ?? (brickTop, brickBottom)
            fillRounded(ctx, brick, radius: brickH * 0.18, top: colors.0, bottom: colors.1, shadow: shadow)
            x += brickW + gap
            index += 1
        }
    }
    ctx.restoreGState()
}

/// Centered text in SF Rounded, black weight.
@MainActor
func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, color: CGColor, center: CGPoint, weight: NSFont.Weight = .black) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if let rounded = font.fontDescriptor.withDesign(.rounded) {
        font = NSFont(descriptor: rounded, size: size) ?? font
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Variants

struct Variant {
    let letter: String
    let name: String
    let draw: @MainActor (CGContext) -> Void
}

@MainActor
let variants: [Variant] = [
    // A – brick wall
    Variant(letter: "A", name: "brick-wall") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.55), (0x0F4F5C, 1)])
        let area = CGRect(x: 232, y: 262, width: 560, height: 500)
        drawBricks(ctx, in: area, rows: 4, perRow: 3, gap: 30, brickTop: 0xFFFFFF, brickBottom: 0xE1E8F1,
                   accents: [1: (tealLight, teal), 6: (0x9CC3FF, blue), 10: (tealLight, teal)])
    },
    // B – pull request glyph in brackets
    Variant(letter: "B", name: "pr-glyph") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.6), (0x0F4F5C, 1)])
        let glyph = CGRect(x: 262, y: 262, width: 500, height: 500)
        drawBrackets(ctx, around: glyph.insetBy(dx: -70, dy: -40), thickness: 26, reach: 68, color: rgb(teal))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x000000, 0.35))
        drawPullRequestGlyph(ctx, in: glyph, stroke: rgb(0xFFFFFF), node: rgb(0xFFFFFF), nodeCore: rgb(teal))
        ctx.restoreGState()
    },
    // C – monogram G in brackets
    Variant(letter: "C", name: "monogram") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.6), (0x123F66, 1)])
        let box = CGRect(x: 292, y: 262, width: 440, height: 500)
        drawBrackets(ctx, around: box, thickness: 30, reach: 78, color: rgb(teal))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 34, color: rgb(0x000000, 0.35))
        drawText(ctx, "G", size: 470, color: rgb(0xFFFFFF), center: CGPoint(x: canvas / 2, y: canvas / 2 + 6))
        ctx.restoreGState()
    },
    // D – light wall: white shape, navy tiles, teal accent
    Variant(letter: "D", name: "light-wall") { ctx in
        drawBackground(ctx, stops: [(0xFFFFFF, 0), (0xEEF2F8, 1)], light: 0, edge: 0x131A39)
        let area: CGFloat = 540
        let gap: CGFloat = 36
        let tile = (area - 2 * gap) / 3
        let origin = CGPoint(x: (canvas - area) / 2, y: (canvas - area) / 2)
        for row in 0..<3 {
            for col in 0..<3 {
                let rect = CGRect(x: origin.x + CGFloat(col) * (tile + gap), y: origin.y + area - tile - CGFloat(row) * (tile + gap), width: tile, height: tile)
                let accent = (row == 0 && col == 0)
                fillRounded(ctx, rect, radius: tile * 0.22, top: accent ? tealLight : 0x22305F, bottom: accent ? teal : navy, shadow: true)
            }
        }
        drawBrackets(ctx, around: CGRect(x: origin.x - 44, y: origin.y - 28, width: area + 88, height: area + 56), thickness: 20, reach: 56, color: rgb(navy))
    },
    // E – four big tiles in brackets (simplified current concept)
    Variant(letter: "E", name: "four-tiles") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.55), (0x0F5D62, 1)])
        let area: CGFloat = 500
        let gap: CGFloat = 44
        let tile = (area - gap) / 2
        let origin = CGPoint(x: (canvas - area) / 2, y: (canvas - area) / 2)
        for row in 0..<2 {
            for col in 0..<2 {
                let rect = CGRect(x: origin.x + CGFloat(col) * (tile + gap), y: origin.y + area - tile - CGFloat(row) * (tile + gap), width: tile, height: tile)
                let accent = (row == 0 && col == 0)
                fillRounded(ctx, rect, radius: tile * 0.24, top: accent ? tealLight : 0xFFFFFF, bottom: accent ? teal : 0xE1E8F1)
            }
        }
        drawBrackets(ctx, around: CGRect(x: origin.x - 60, y: origin.y - 36, width: area + 120, height: area + 72), thickness: 28, reach: 74, color: rgb(teal))
    },
    // F – faint wall texture with a teal pull-request glyph on top
    Variant(letter: "F", name: "wall-and-branch") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (0x1A2A5C, 0.6), (0x10425A, 1)])
        ctx.saveGState()
        ctx.addPath(shapePath)
        ctx.clip()
        drawBricks(ctx, in: shapeRect.insetBy(dx: -40, dy: -40), rows: 7, perRow: 4, gap: 22,
                   brickTop: 0xFFFFFF, brickBottom: 0xFFFFFF, accents: [:], alpha: 0.07, shadow: false)
        ctx.restoreGState()
        let glyph = CGRect(x: 262, y: 252, width: 500, height: 520)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: rgb(0x000000, 0.45))
        drawPullRequestGlyph(ctx, in: glyph, stroke: rgb(teal), node: rgb(teal), nodeCore: rgb(navy))
        ctx.restoreGState()
    },
    // G – one PR card with status dots
    Variant(letter: "G", name: "status-card") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.55), (0x0F5D62, 1)])
        let card = CGRect(x: 232, y: 292, width: 560, height: 440)
        fillRounded(ctx, card, radius: 64, top: 0xFFFFFF, bottom: 0xE6ECF4)
        // Title bars
        let pad: CGFloat = 60
        ctx.setFillColor(rgb(0x2B3556))
        ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + pad, y: card.maxY - pad - 44, width: 300, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(rgb(0xB8C3D3))
        ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + pad, y: card.maxY - pad - 44 - 34 - 30, width: 210, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.fillPath()
        // Status dots: teal (approved), blue (checks), gray (draft)
        let dot: CGFloat = 92
        for (index, colors) in [(tealLight, teal), (0x9CC3FF, blue), (0xD9E0EA, 0xB8C3D3)].enumerated() {
            let rect = CGRect(x: card.minX + pad + CGFloat(index) * (dot + 36), y: card.minY + pad, width: dot, height: dot)
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(rgb(colors.0), 0), (rgb(colors.1), 1)]),
                                   start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            ctx.restoreGState()
        }
    },
    // H – minimal: brackets with a 3×3 dot grid
    Variant(letter: "H", name: "dot-grid") { ctx in
        drawBackground(ctx, stops: [(navy, 0), (navyLight, 0.6), (0x123F66, 1)])
        let area: CGFloat = 420
        let origin = CGPoint(x: (canvas - area) / 2, y: (canvas - area) / 2)
        let step = area / 2
        let r: CGFloat = 58
        for row in 0..<3 {
            for col in 0..<3 {
                let center = CGPoint(x: origin.x + CGFloat(col) * step, y: origin.y + area - CGFloat(row) * step)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
                let accent = (row == 0 && col == 0) || (row == 1 && col == 2)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x000000, 0.3))
                ctx.setFillColor(accent ? rgb(teal) : rgb(0xFFFFFF))
                ctx.fillEllipse(in: rect)
                ctx.restoreGState()
            }
        }
        drawBrackets(ctx, around: CGRect(x: origin.x - r - 90, y: origin.y - r - 40, width: area + 2 * r + 180, height: area + 2 * r + 80),
                     thickness: 28, reach: 74, color: rgb(teal))
    },
]

// MARK: - Contact sheet

@MainActor
func contactSheet(images: [(String, CGImage)], to url: URL) throws {
    let sizes: [CGFloat] = [512, 256, 128, 64, 32, 16]
    let pad: CGFloat = 40
    let labelW: CGFloat = 70
    let rowH: CGFloat = 512 + pad
    let totalW = labelW + sizes.reduce(0) { $0 + $1 + pad } + pad
    let halfH = CGFloat(images.count) * rowH + pad
    let ctx = makeContext(width: Int(totalW), height: Int(halfH * 2))
    // Light half on top, dark half below.
    ctx.setFillColor(rgb(0xECEEF2))
    ctx.fill(CGRect(x: 0, y: halfH, width: totalW, height: halfH))
    ctx.setFillColor(rgb(0x1C1D22))
    ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: halfH))

    for (half, textColor) in [(0, 0xFFFFFF as UInt32), (1, 0x1C1D22 as UInt32)] {
        for (row, (letter, image)) in images.enumerated() {
            let baseY = CGFloat(half) * halfH + halfH - pad - CGFloat(row + 1) * rowH + pad
            drawText(ctx, letter, size: 44, color: rgb(textColor), center: CGPoint(x: labelW / 2 + 10, y: baseY + 256), weight: .bold)
            var x = labelW + pad
            for size in sizes {
                let rect = CGRect(x: x, y: baseY + (512 - size) / 2, width: size, height: size)
                ctx.draw(image, in: rect)
                x += size + pad
            }
        }
    }
    try writePNG(ctx.makeImage()!, to: url)
}

// MARK: - Main

@MainActor
func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments.first ?? ".").deletingLastPathComponent().deletingLastPathComponent()
    let outDir = root.appendingPathComponent("Scripts/out/variants", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var rendered: [(String, CGImage)] = []
    for variant in variants {
        let ctx = makeContext(width: Int(canvas), height: Int(canvas))
        variant.draw(ctx)
        let image = ctx.makeImage()!
        let url = outDir.appendingPathComponent("\(variant.letter)-\(variant.name).png")
        try writePNG(image, to: url)
        rendered.append((variant.letter, image))
        print("rendered \(url.path)")
    }
    let sheet = outDir.appendingPathComponent("contact-sheet.png")
    try contactSheet(images: rendered, to: sheet)
    print("contact sheet \(sheet.path)")
}

try MainActor.assumeIsolated { try main() }
