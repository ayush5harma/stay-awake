// Draws Stay Awake's app icon from code, at build time, so no binary asset
// lives in the repo: a .png is a blob nobody can diff and nothing
// regenerates, while a hundred lines of CoreGraphics edits like source.
// build.sh compiles and runs this, then throws the output away.
//
// Usage: icon <output-dir>   (build.sh compiles this file into a binary it
// calls `iconrender` and runs with a scratch directory)
// Writes, into <output-dir>:
//   AppIcon.icon/      an Icon Composer package (icon.json + Assets/), the
//                      only format that carries light and dark appearance
//                      variants, compiled to Assets.car by actool
//   AppIcon.iconset/   the ten legacy tiles, for `iconutil -c icns` when
//                      actool is absent (it ships with Xcode, not with the
//                      Command Line Tools, which is all a fresh Mac has
//                      during bootstrap)
//
// The glyph is a cup and saucer with steam because that is already the app's
// vocabulary: main.swift puts a steaming cup in the menu bar when the toggle
// is on, and the mechanism underneath is literally `caffeinate`.

import AppKit

struct Appearance {
    let name: String
    let tileTop: NSColor
    let tileBottom: NSColor
    let glyph: NSColor
}

// Amber cup in light, espresso with a cream cup in dark. The glyph inverts
// rather than merely shifting, which is what an appearance variant is for:
// the same drawing at the same contrast against two different desktops.
let light = Appearance(
    name: "light",
    tileTop: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.34, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.87, green: 0.44, blue: 0.15, alpha: 1),
    glyph: NSColor(srgbRed: 0.26, green: 0.13, blue: 0.06, alpha: 1))
let dark = Appearance(
    name: "dark",
    tileTop: NSColor(srgbRed: 0.25, green: 0.16, blue: 0.10, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.10, green: 0.07, blue: 0.05, alpha: 1),
    glyph: NSColor(srgbRed: 0.98, green: 0.90, blue: 0.78, alpha: 1))

// MARK: - Drawing primitives

// Apple's icon corner is a continuous curve, not a circular arc, and AppKit
// has no public API for one. A superellipse |x|^n + |y|^n = 1 at n = 5 tracks
// it closely enough that the difference is invisible below 512 pt, and it
// costs a loop instead of a dependency.
func squircle(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

// Draws into a square bitmap of `pixels` a side and encodes it as PNG. `draw`
// is handed that side length, so it can place everything as a fraction of it.
func renderPNG(pixels: Int, _ draw: (CGFloat) -> Void) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate a \(pixels)x\(pixels) bitmap") }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.shouldAntialias = true
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode a \(pixels)x\(pixels) PNG")
    }
    return png
}

// MARK: - The glyph

// Cup, saucer and steam in a `size` x `size` canvas. Every measurement is a
// fraction of the canvas, so the same code renders the 1024 pt layer and a
// 16 pt tile; the shapes are solid masses rather than thin outlines for the
// same reason, since a 1 px outline at 16 pt is a smudge.
func drawGlyph(_ size: CGFloat, _ appearance: Appearance) {
    appearance.glyph.setFill()
    appearance.glyph.setStroke()

    // Handle first, so the cup body paints over the joint and the two read as
    // one shape rather than a ring stuck to a box.
    let handle = NSBezierPath()
    handle.appendArc(withCenter: NSPoint(x: size * 0.655, y: size * 0.505),
                     radius: size * 0.093, startAngle: 84, endAngle: -84, clockwise: true)
    handle.lineWidth = size * 0.052
    handle.lineCapStyle = .round
    handle.stroke()

    // Body: a rim-width mouth tapering to a narrower, rounded base.
    let top = size * 0.615, bottom = size * 0.335
    let halfTop = size * 0.185, halfBottom = size * 0.135
    let cx = size * 0.475
    let body = NSBezierPath()
    body.move(to: NSPoint(x: cx - halfTop, y: top))
    body.line(to: NSPoint(x: cx + halfTop, y: top))
    body.line(to: NSPoint(x: cx + halfBottom + size * 0.012, y: bottom + size * 0.055))
    body.curve(to: NSPoint(x: cx + halfBottom - size * 0.030, y: bottom),
               controlPoint1: NSPoint(x: cx + halfBottom + size * 0.006, y: bottom + size * 0.012),
               controlPoint2: NSPoint(x: cx + halfBottom - size * 0.006, y: bottom))
    body.line(to: NSPoint(x: cx - halfBottom + size * 0.030, y: bottom))
    body.curve(to: NSPoint(x: cx - halfBottom - size * 0.012, y: bottom + size * 0.055),
               controlPoint1: NSPoint(x: cx - halfBottom + size * 0.006, y: bottom),
               controlPoint2: NSPoint(x: cx - halfBottom - size * 0.006, y: bottom + size * 0.012))
    body.close()
    body.fill()

    // Saucer: a flat lozenge wider than the cup, which is what separates a cup
    // from a bucket at small sizes.
    let saucer = NSRect(x: size * 0.220, y: size * 0.252, width: size * 0.510, height: size * 0.056)
    NSBezierPath(roundedRect: saucer, xRadius: saucer.height / 2, yRadius: saucer.height / 2).fill()

    // Two steam curls. Offset from each other in both x and phase so they read
    // as rising vapour and not as a pair of quote marks.
    for (dx, height) in [(-size * 0.072, size * 0.150), (size * 0.058, size * 0.185)] {
        let x = cx + dx
        let y0 = size * 0.680
        let curl = NSBezierPath()
        curl.move(to: NSPoint(x: x, y: y0))
        curl.curve(to: NSPoint(x: x, y: y0 + height),
                   controlPoint1: NSPoint(x: x - size * 0.075, y: y0 + height * 0.34),
                   controlPoint2: NSPoint(x: x + size * 0.075, y: y0 + height * 0.66))
        curl.lineWidth = size * 0.040
        curl.lineCapStyle = .round
        curl.stroke()
    }
}

// The glyph on its gradient tile: what a legacy .icns holds, since that format
// has no separate fill of its own.
func drawTile(_ size: CGFloat, _ appearance: Appearance) {
    let inset = size * 0.008
    let tile = squircle(in: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
    let gradient = NSGradient(starting: appearance.tileTop, ending: appearance.tileBottom)
    gradient?.draw(in: tile, angle: -90)
    drawGlyph(size, appearance)
}

// MARK: - Output

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: icon <output-dir>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])

let fileManager = FileManager.default
let iconPackage = outputDir.appendingPathComponent("AppIcon.icon")
let assetsDir = iconPackage.appendingPathComponent("Assets")
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset")
for directory in [assetsDir, iconsetDir] {
    try? fileManager.removeItem(at: directory)
    try! fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
}

// The Icon Composer layers: the tile is the package's `fill`, so the layer PNG
// carries only the glyph on transparency and the system masks, shadows and
// glazes it. One PNG per appearance, swapped by `image-name-specializations`.
for appearance in [light, dark] {
    let png = renderPNG(pixels: 1024) { size in drawGlyph(size, appearance) }
    try! png.write(to: assetsDir.appendingPathComponent("glyph-\(appearance.name).png"))
}

func iconComposerFill(_ appearance: Appearance) -> String {
    func srgb(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB)!
        return String(format: "srgb:%.5f,%.5f,%.5f,%.5f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
    return "{ \"linear-gradient\" : [ \"\(srgb(appearance.tileTop))\", \"\(srgb(appearance.tileBottom))\" ] }"
}

// Hand-written rather than JSONSerialization so the file reads like the ones
// Icon Composer saves. Schema notes, both learned by compiling and reading the
// result back with assetutil (2026-09-07):
//   - a `*-specializations` array must carry the BASE value as an entry with no
//     `appearance` key. A top-level `fill` plus a dark-only specialization
//     compiles without a word of complaint and silently drops the dark colour.
//   - `shadow`/`translucency` are pinned here rather than left to actool's
//     defaults, so the look cannot drift with the toolchain.
let json = """
{
  "fill-specializations" : [
    { "value" : \(iconComposerFill(light)) },
    { "appearance" : "dark", "value" : \(iconComposerFill(dark)) }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "name" : "Cup",
          "image-name-specializations" : [
            { "value" : "glyph-light.png" },
            { "appearance" : "dark", "value" : "glyph-dark.png" }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}

"""
try! Data(json.utf8).write(to: iconPackage.appendingPathComponent("icon.json"))

// The legacy set. Each tile is drawn at its own pixel size rather than
// downsampled from 1024, so the 16 pt one keeps its stroke instead of blurring.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = renderPNG(pixels: pixels) { size in drawTile(size, light) }
        try! png.write(to: iconsetDir.appendingPathComponent(name))
    }
}
